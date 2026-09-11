// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LibString} from "solady/utils/LibString.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {IMultiplierAccountant} from "./interfaces/IMultiplierAccountant.sol";
import {ISettlementSource} from "./interfaces/ISettlementSource.sol";
import {Series} from "./Series.sol";
import {DepthGate} from "./DepthGate.sol";

/// @title FletcherFactory
/// @notice Permissionless creation of dated FLOOR/TURBO series. Pick a ticker, a split point and a
/// maturity, deposit, one transaction.
///
/// There is no listing committee and no admin key. The only things standing between a caller and a
/// new series are facts the chain can check for itself: the equity has measured AMM depth, the
/// maturity is a real daily settlement slot, and the split point sits in a band where both legs are
/// worth owning. Everything else, including which split points deserve to exist, is left to the
/// market. A series nobody mints into is a series that quietly stays empty.
///
/// Deployment is CREATE2 on the series' own terms, so `(stock, strike, maturity)` names exactly one
/// series address forever. Two callers racing to open the same series cannot fragment it into two
/// half-liquid copies, and an integrator can compute the address before it exists.
///
/// # There is deliberately no outstanding-notional cap
///
/// An earlier version accumulated raw stock per name and refused creation past a fraction of
/// measured depth. It was removed because it was both bypassable and permanently destructive:
///
///   - `Series.mint` is permissionless and does not touch the factory, so any size could be reached
///     by creating a minimal series and minting into it directly. The cap bound the wrong call.
///   - Nothing ever decremented it. Merging and settling returned the stock but left the counter at
///     its high-water mark, so a name accumulated toward its ceiling and then could never carry a
///     new series again. A ticker bricked itself within days of ordinary use.
///
/// The depth gate now gates **listing**, not size: a name either has a sustained book or it does
/// not. Nothing in this protocol accumulates a number that gates a later operation.
contract FletcherFactory {
    using SafeTransferLib for address;
    using LibString for uint256;

    /// @notice Corporate-action classifier every series is built with.
    IMultiplierAccountant public immutable accountant;

    /// @notice Official-close source every series settles against.
    ISettlementSource public immutable settlementSource;

    /// @notice Liquidity qualification for underlyings.
    DepthGate public immutable depthGate;

    /// @notice Seconds after midnight UTC at which a dated series matures. Settlement needs the
    /// official close of the trading day, which is not printed at the instant the bell rings.
    uint64 public constant SETTLEMENT_OFFSET = 22 hours;

    /// @notice A series may be dated at most this far out. Dated daily series are the product; a
    /// two-year strip would fragment the liquidity this shape exists to concentrate.
    uint64 public constant MAX_TENOR = 90 days;

    /// @notice The split point must leave at least this share of spot to FLOOR, in bps.
    /// @dev Below this, FLOOR is a leveraged instrument wearing a savings product's name.
    uint256 public constant MIN_STRIKE_BPS = 1_000;

    /// @notice And at most this share of spot, which is what actually bounds TURBO's leverage.
    ///
    /// Leverage is `p / (p - k)`, so the ceiling on `k` IS the ceiling on leverage: a strike at 99%
    /// of spot is 100x, and 100x on an instrument that settles tomorrow is not a leverage product,
    /// it is a coin flip where a 1% move against the holder takes the entire position. 98% caps it
    /// at 50x, which is still far beyond anything a listed turbo offers.
    uint256 public constant MAX_STRIKE_BPS = 9_800;

    /// @notice The leverage `MAX_STRIKE_BPS` implies, 1e18-scaled. Exposed so the bound is checkable
    /// rather than something a reader has to derive from a basis-point constant.
    uint256 public constant MAX_TURBO_LEVERAGE = 50e18;

    uint256 internal constant BPS = 10_000;

    /// @notice Every series ever created, in creation order.
    address[] public allSeries;

    /// @notice `seriesFor[stock][strikeX8][maturity]`.
    mapping(address => mapping(uint256 => mapping(uint64 => address))) public seriesFor;


    event SeriesCreated(
        address indexed series,
        address indexed stock,
        uint256 strikeX8,
        uint64 maturity,
        uint64 tradingDay,
        address floorToken,
        address turboToken,
        address indexed creator
    );

    error NotDepthQualified(address stock);
    error StockHalted();
    error BadMaturity();
    error BadStrike();
    error SeriesExists(address existing);
    error ZeroAmount();

    constructor(IMultiplierAccountant accountant_, ISettlementSource settlementSource_, DepthGate depthGate_) {
        accountant = accountant_;
        settlementSource = settlementSource_;
        depthGate = depthGate_;
    }

    function seriesCount() external view returns (uint256) {
        return allSeries.length;
    }

    /// @notice The maturity timestamp for a given trading day.
    function maturityFor(uint64 tradingDay) public pure returns (uint64) {
        return tradingDay * 1 days + SETTLEMENT_OFFSET;
    }

    /// @notice Deterministic address of the series for these terms, whether or not it exists yet.
    function computeSeriesAddress(address stock, uint256 strikeX8, uint64 tradingDay)
        public
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(stock, strikeX8, tradingDay));
        bytes32 initCodeHash = keccak256(_initCode(stock, strikeX8, tradingDay));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /// @notice Create a series and mint into it in one transaction.
    /// @param stock The tokenized equity to split.
    /// @param strikeX8 The split point, 1e8-scaled USD per share.
    /// @param tradingDay The trading day, in days since the Unix epoch, whose close settles it.
    /// @param rawStock How much stock to deposit immediately. Must be non-zero: an empty series is
    /// a listing, and this protocol does not do listings.
    /// @param to Who receives the two legs.
    function createSeries(address stock, uint256 strikeX8, uint64 tradingDay, uint256 rawStock, address to)
        external
        returns (Series series)
    {
        if (rawStock == 0) revert ZeroAmount();
        if (seriesFor[stock][strikeX8][tradingDay] != address(0)) {
            revert SeriesExists(seriesFor[stock][strikeX8][tradingDay]);
        }

        uint64 maturity = maturityFor(tradingDay);
        if (maturity <= block.timestamp || maturity > block.timestamp + MAX_TENOR) revert BadMaturity();

        IStockToken s = IStockToken(stock);
        if (s.paused() || s.tokenPaused()) revert StockHalted();
        if (!depthGate.qualifies(stock)) revert NotDepthQualified(stock);

        _checkStrike(stock, strikeX8);

        series = _deploy(s, strikeX8, tradingDay, maturity);

        seriesFor[stock][strikeX8][tradingDay] = address(series);
        allSeries.push(address(series));

        stock.safeTransferFrom(msg.sender, address(this), rawStock);
        stock.safeApprove(address(series), rawStock);
        series.mint(to, rawStock);

        emit SeriesCreated(
            address(series),
            stock,
            strikeX8,
            maturity,
            tradingDay,
            address(series.floorToken()),
            address(series.turboToken()),
            msg.sender
        );
    }

    /// @dev Deployment lives in its own frame. The ten constructor arguments and the four generated
    /// leg names are wide enough that sharing a stack with the gating locals above overflows the
    /// legacy pipeline's allocator.
    function _deploy(IStockToken s, uint256 strikeX8, uint64 tradingDay, uint64 maturity)
        internal
        returns (Series)
    {
        Names memory n = _names(s.symbol(), strikeX8, tradingDay);
        return new Series{salt: keccak256(abi.encode(address(s), strikeX8, tradingDay))}(
            s, strikeX8, maturity, tradingDay, accountant, settlementSource, n.fName, n.fSym, n.tName, n.tSym
        );
    }

    /// @dev The strike band is checked against the settlement source's live reference price, not
    /// against a pool. A caller who could pick the reference price could open a series struck at a
    /// number the market never traded at and mint TURBO that is already deep in the money.
    ///
    /// It reads `referencePrice`, NOT a recorded close. Creation must not depend on a history that
    /// can lapse: walking back through recorded closes meant a long enough gap in recording bricked
    /// creation for every name at once.
    function _checkStrike(address stock, uint256 strikeX8) internal view {
        (uint256 refX8,) = settlementSource.referencePrice(stock);
        if (refX8 == 0) revert BadStrike();
        uint256 lo = (refX8 * MIN_STRIKE_BPS) / BPS;
        uint256 hi = (refX8 * MAX_STRIKE_BPS) / BPS;
        if (strikeX8 < lo || strikeX8 > hi) revert BadStrike();
    }

    struct Names {
        string fName;
        string fSym;
        string tName;
        string tSym;
    }

    function _names(string memory symbol, uint256 strikeX8, uint64 tradingDay)
        internal
        pure
        returns (Names memory)
    {
        // Strike rendered in whole dollars, which is how every split point in the product is quoted.
        string memory k = (strikeX8 / 1e8).toString();
        string memory d = uint256(tradingDay).toString();
        string memory stem = string.concat(symbol, "-", k, "-", d);
        return Names({
            fName: string.concat("Fletcher FLOOR ", stem),
            fSym: string.concat("f", stem),
            tName: string.concat("Fletcher TURBO ", stem),
            tSym: string.concat("t", stem)
        });
    }

    function _initCode(address stock, uint256 strikeX8, uint64 tradingDay) internal view returns (bytes memory) {
        Names memory n = _names(IStockToken(stock).symbol(), strikeX8, tradingDay);
        return abi.encodePacked(
            type(Series).creationCode,
            abi.encode(
                stock,
                strikeX8,
                maturityFor(tradingDay),
                tradingDay,
                accountant,
                settlementSource,
                n.fName,
                n.fSym,
                n.tName,
                n.tSym
            )
        );
    }
}
