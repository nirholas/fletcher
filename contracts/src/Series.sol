// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {IMultiplierAccountant} from "./interfaces/IMultiplierAccountant.sol";
import {ISettlementSource} from "./interfaces/ISettlementSource.sol";
import {SeriesToken} from "./SeriesToken.sol";

/// @title Series
/// @notice One dated split of one tokenized equity into a FLOOR leg and a TURBO leg.
///
/// # The whole protocol in four lines
///
/// ```
/// mint    R raw stock in   ->  R FLOOR + R TURBO out
/// merge   R FLOOR + R TURBO in  ->  R raw stock out          (free, any time, no deadline)
/// settle  once, at maturity, against the official close print
/// redeem  each leg claims its share of the SAME vault
/// ```
///
/// # Why there is no liquidation engine
///
/// The vault never owes more than it holds. At settlement with close price `P` and split point `K`,
/// the vault's raw stock `R` divides as
///
/// ```
/// floorStock = R * min(P, K) / P
/// turboStock = R - floorStock
/// ```
///
/// which sums to `R` for every `P > 0`, including `P` far above `K` and `P` collapsing toward zero.
/// TURBO's ~20x leverage at mint comes from `K` sitting just under spot, not from borrowing, so
/// there is no margin call to issue, no liquidator to incentivise, no protocol balance sheet and no
/// bad debt. This matters more here than on a general-purpose chain: while a `Stock` token is
/// halted its `transfer` reverts outright, so a protocol that DID need to seize collateral could
/// not do it at any incentive. Fletcher never needs to.
///
/// # Why the multiplier cancels
///
/// A position's value is `raw * uiMultiplier / 1e18 * pricePerShare`. Both legs redeem in raw stock
/// out of one vault, so the multiplier appears on both sides of the division and drops out of the
/// settlement arithmetic entirely. It is not ignored: it is the reason the split point is carried
/// through corporate actions by `MultiplierAccountant`, which hands a dividend's accrual to FLOOR
/// by leaving `K` alone and preserves TURBO's leverage across a split by dividing `K` by the ratio.
contract Series is ReentrancyGuard {
    using SafeTransferLib for address;

    // ---------------------------------------------------------------------------------------
    // Immutable terms
    // ---------------------------------------------------------------------------------------

    /// @notice The tokenized equity held as collateral.
    IStockToken public immutable stock;

    /// @notice FLOOR: first claim on the vault up to the split point, plus the dividend accrual.
    SeriesToken public immutable floorToken;

    /// @notice TURBO: everything above the split point, and nothing below it.
    SeriesToken public immutable turboToken;

    /// @notice Classifies corporate actions into strike adjustments.
    IMultiplierAccountant public immutable accountant;

    /// @notice Where the official close comes from. Never a pool.
    ISettlementSource public immutable settlementSource;

    /// @notice Unix timestamp from which settlement may be attempted.
    uint64 public immutable maturity;

    /// @notice The trading day, as days since the Unix epoch, whose close settles this series.
    uint64 public immutable tradingDay;

    /// @notice The factory that created this series.
    address public immutable factory;

    // ---------------------------------------------------------------------------------------
    // Mutable state
    // ---------------------------------------------------------------------------------------

    /// @notice The split point, 1e8-scaled USD per share. Moves only on a classified split.
    uint256 public strikeX8;

    /// @notice The stock's `uiMultiplier()` as of the last `syncMultiplier()`.
    uint256 public observedMultiplier;

    /// @notice Set once, by `settle()`.
    bool public settled;

    /// @notice The close price this series settled at, 1e8.
    uint256 public settlementPriceX8;

    /// @notice Raw stock owed per unit of FLOOR at settlement, 1e18-scaled.
    uint256 public floorPerUnit1e18;

    /// @notice Raw stock owed per unit of TURBO at settlement, 1e18-scaled.
    uint256 public turboPerUnit1e18;

    /// @notice True when a corporate action could not be classified. Settlement is refused
    /// permanently and only `merge()` remains, so every holder can still leave whole.
    bool public frozen;

    uint256 internal constant WAD = 1e18;

    /// @notice How long a scheduled-but-unapplied corporate action may block settlement.
    ///
    /// Long enough that any real corporate action lands first (they are scheduled days ahead, not
    /// months), and short enough that an action the issuer never applies cannot strand a dated
    /// series permanently.
    uint256 public constant PENDING_ACTION_GRACE = 30 days;

    // ---------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------

    event Minted(address indexed to, uint256 rawStock);
    event Merged(address indexed from, uint256 rawStock);
    event Settled(uint256 priceX8, uint256 strikeX8, uint256 floorPerUnit1e18, uint256 turboPerUnit1e18);
    event Redeemed(address indexed who, uint256 floorAmount, uint256 turboAmount, uint256 rawStock);
    event StrikeAdjusted(
        uint256 fromStrikeX8, uint256 toStrikeX8, uint256 fromMultiplier, uint256 toMultiplier, uint8 kind
    );
    event Frozen(uint256 fromMultiplier, uint256 toMultiplier);

    // ---------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------

    error OnlyFactory();
    error AlreadySettled();
    error NotSettled();
    error NotMature();
    error SeriesFrozen();
    error StockHalted();
    error CloseUnavailable();
    error ZeroAmount();
    error CorporateActionPending();

    constructor(
        IStockToken stock_,
        uint256 strikeX8_,
        uint64 maturity_,
        uint64 tradingDay_,
        IMultiplierAccountant accountant_,
        ISettlementSource settlementSource_,
        string memory floorName,
        string memory floorSymbol,
        string memory turboName,
        string memory turboSymbol
    ) {
        factory = msg.sender;
        stock = stock_;
        strikeX8 = strikeX8_;
        maturity = maturity_;
        tradingDay = tradingDay_;
        accountant = accountant_;
        settlementSource = settlementSource_;
        observedMultiplier = stock_.uiMultiplier();
        floorToken = new SeriesToken(floorName, floorSymbol);
        turboToken = new SeriesToken(turboName, turboSymbol);
    }

    // ---------------------------------------------------------------------------------------
    // Corporate actions
    // ---------------------------------------------------------------------------------------

    /// @notice Fold any change in the stock's `uiMultiplier()` into the split point.
    ///
    /// Permissionless and idempotent. It runs automatically inside `mint`, `merge` and `settle`, so
    /// no keeper is load-bearing; calling it directly just makes the adjustment visible earlier.
    ///
    /// A change the accountant cannot classify freezes the series rather than guessing. Freezing is
    /// a real outcome, not a failure mode: merges keep working, so the two legs recombine into
    /// stock at par and nobody is trapped.
    function syncMultiplier() public {
        uint256 current = stock.uiMultiplier();
        uint256 observed = observedMultiplier;
        if (current == observed) return;

        IMultiplierAccountant.Classification memory c = accountant.classify(observed, current);

        if (c.kind == IMultiplierAccountant.Kind.Unknown) {
            frozen = true;
            observedMultiplier = current;
            emit Frozen(observed, current);
            return;
        }

        uint256 before = strikeX8;
        uint256 adjusted = accountant.adjustStrike(before, c);
        strikeX8 = adjusted;
        observedMultiplier = current;
        emit StrikeAdjusted(before, adjusted, observed, current, uint8(c.kind));
    }

    /// @notice True when the equity is transferable and no unclassified action has frozen us.
    /// @dev Named for the vocabulary the rest of the Robinhood Chain ecosystem uses for this check.
    function isSynced() public view returns (bool) {
        if (frozen) return false;
        if (stock.paused() || stock.tokenPaused()) return false;
        return true;
    }

    function _requireLive() internal view {
        if (frozen) revert SeriesFrozen();
        if (stock.paused() || stock.tokenPaused()) revert StockHalted();
    }

    // ---------------------------------------------------------------------------------------
    // Mint and merge
    // ---------------------------------------------------------------------------------------

    /// @notice Deposit `rawStock` of the equity, receive equal amounts of FLOOR and TURBO.
    /// @dev Fully collateralised at mint by construction: the vault's stock balance is exactly the
    /// supply of each leg.
    function mint(address to, uint256 rawStock) external nonReentrant {
        if (rawStock == 0) revert ZeroAmount();
        if (settled) revert AlreadySettled();
        syncMultiplier();
        _requireLive();

        address(stock).safeTransferFrom(msg.sender, address(this), rawStock);
        floorToken.mint(to, rawStock);
        turboToken.mint(to, rawStock);
        emit Minted(to, rawStock);
    }

    /// @notice Burn equal amounts of both legs and take the stock back. Free, and available for the
    /// whole life of the series.
    ///
    /// This is the mechanism that caps the two legs' combined price at parity: any premium is an
    /// arbitrage that ends with someone merging. It is also the escape hatch that makes freezing a
    /// safe answer to an unclassifiable corporate action, which is why it deliberately does NOT
    /// check `frozen`, and why it stays open even while the series is past maturity but unsettled.
    function merge(address to, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (settled) revert AlreadySettled();
        if (!frozen) syncMultiplier();

        floorToken.burn(msg.sender, amount);
        turboToken.burn(msg.sender, amount);
        address(stock).safeTransfer(to, amount);
        emit Merged(to, amount);
    }

    // ---------------------------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------------------------

    /// @notice Settle the series once, against the official close for its trading day.
    ///
    /// Permissionless: anyone may call it once the close is available, and it can only ever produce
    /// the one answer the source already published.
    ///
    /// Deliberately NOT gated on the stock being unhalted. A halted equity is exactly when holders
    /// most need the series to resolve, and settlement moves no stock: it only records the ratio.
    /// Redemption transfers, and will revert on its own while transfers are paused.
    function settle() external nonReentrant {
        if (settled) revert AlreadySettled();
        if (block.timestamp < maturity) revert NotMature();
        syncMultiplier();
        if (frozen) revert SeriesFrozen();

        // A corporate action scheduled to land at or before this series' maturity has not been
        // folded into the strike yet, and settling in front of it would settle the wrong terms.
        //
        // But this gate cannot be unconditional. The issuer schedules these, and nothing obliges
        // them to ever apply one: a scheduled action left pending forever would block settlement
        // forever, and a series that can never settle is one whose holders are left with merge as
        // their only exit for the rest of time. So the refusal expires. After `PENDING_ACTION_GRACE`
        // past maturity the series settles on the terms it can actually observe, which is strictly
        // better than never resolving.
        uint256 pending = stock.newUIMultiplier();
        if (
            pending != stock.uiMultiplier() && stock.effectiveAt() <= maturity
                && block.timestamp < uint256(maturity) + PENDING_ACTION_GRACE
        ) {
            revert CorporateActionPending();
        }

        if (!settlementSource.hasClose(address(stock), tradingDay)) revert CloseUnavailable();
        (uint256 priceX8,) = settlementSource.officialClose(address(stock), tradingDay);
        if (priceX8 == 0) revert CloseUnavailable();

        uint256 k = strikeX8;
        uint256 floorClaimX8 = priceX8 < k ? priceX8 : k;

        // Raw stock per unit of each leg. Sums to exactly WAD, so the vault is neither short nor
        // left with dust it cannot pay out.
        uint256 fpu = (floorClaimX8 * WAD) / priceX8;
        uint256 tpu = WAD - fpu;

        settled = true;
        settlementPriceX8 = priceX8;
        floorPerUnit1e18 = fpu;
        turboPerUnit1e18 = tpu;
        emit Settled(priceX8, k, fpu, tpu);
    }

    /// @notice After settlement, burn whatever legs you hold and take the stock they are owed.
    /// @dev Either amount may be zero; the legs are independent after settlement.
    function redeem(address to, uint256 floorAmount, uint256 turboAmount) external nonReentrant returns (uint256) {
        if (!settled) revert NotSettled();
        if (floorAmount == 0 && turboAmount == 0) revert ZeroAmount();

        uint256 owed = (floorAmount * floorPerUnit1e18) / WAD + (turboAmount * turboPerUnit1e18) / WAD;

        if (floorAmount != 0) floorToken.burn(msg.sender, floorAmount);
        if (turboAmount != 0) turboToken.burn(msg.sender, turboAmount);

        // Rounding down twice can leave a wei of stock stranded per redemption. Paying out the
        // vault's whole remaining balance to the last redeemer keeps the vault from retaining dust
        // forever without ever letting an earlier redeemer take more than they are owed.
        uint256 held = stock.balanceOf(address(this));
        if (floorToken.totalSupply() == 0 && turboToken.totalSupply() == 0 && held > owed) {
            owed = held;
        }
        if (owed != 0) address(stock).safeTransfer(to, owed);
        emit Redeemed(msg.sender, floorAmount, turboAmount, owed);
        return owed;
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    /// @notice What one unit of each leg would be worth in 1e8 USD at `priceX8`, if the series
    /// settled right now. The two always sum to `priceX8 * uiMultiplier / 1e18`.
    function quoteLegs(uint256 priceX8) external view returns (uint256 floorValueX8, uint256 turboValueX8) {
        uint256 k = strikeX8;
        uint256 m = stock.uiMultiplier();
        uint256 floorClaim = priceX8 < k ? priceX8 : k;
        floorValueX8 = (floorClaim * m) / WAD;
        turboValueX8 = ((priceX8 - floorClaim) * m) / WAD;
    }

    /// @notice TURBO's leverage against the underlying at `priceX8`, 1e18-scaled.
    /// @dev `price / (price - strike)`. Returns 0 when TURBO is at or out of the money, where it
    /// has no delta and leverage is undefined rather than infinite.
    function turboLeverage1e18(uint256 priceX8) external view returns (uint256) {
        uint256 k = strikeX8;
        if (priceX8 <= k) return 0;
        return (priceX8 * WAD) / (priceX8 - k);
    }

    /// @notice The vault's collateralisation, 1e18-scaled. Structurally exactly 1e18 before
    /// settlement; exposed so integrators can assert it rather than trust it.
    function collateralisation1e18() external view returns (uint256) {
        uint256 supply = floorToken.totalSupply();
        if (supply == 0) return WAD;
        return (stock.balanceOf(address(this)) * WAD) / supply;
    }
}
