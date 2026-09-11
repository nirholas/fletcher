// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {FletcherFactory} from "./FletcherFactory.sol";
import {Series} from "./Series.sol";
import {ISettlementSource} from "./interfaces/ISettlementSource.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

/// @title FletcherLaunchpad
/// @notice Opening a series the way a launchpad opens a coin, not the way a desk opens a book.
///
/// One transaction picks a ticker, a split point and a maturity, deposits the stock, and leaves two
/// tradeable markets behind: FLOOR against the underlying and TURBO against the underlying. The
/// liquidity is locked for the life of the series and the launcher earns the swap fees on both
/// legs, forever.
///
/// # Why the launcher, and not the protocol, seeds the book
///
/// The hard problem for an instrument like this is never pricing, it is bootstrapping: a split
/// point with no depth is a split point nobody can trade, and a protocol that picks the menu
/// centrally ends up defending strikes the market did not want. Paying the launcher the swap fees
/// in perpetuity makes seeding a real book the profitable move and makes listing a strike nobody
/// trades a waste of the launcher's own stock. The market picks which split points survive.
///
/// # Why both legs are quoted in the underlying
///
/// FLOOR and TURBO are the two halves of one share, so priced in that share their prices sum to
/// exactly 1. Quoting them in the stock rather than in USDG puts the protocol's core identity
/// directly on the screen: a FLOOR at 0.94 NVDA and a TURBO at 0.06 NVDA visibly add to one NVDA,
/// and any deviation is an arbitrage that ends in a `merge()`. Quoted in a stablecoin the same
/// relationship exists but nobody can see it. PAIR reached the same conclusion for the same reason.
///
/// # Why the principal is locked until the instrument is over, and not one day longer
///
/// Liquidity is locked for the life of the series: `withdrawPrincipal` reverts until
/// `maturity + LIQUIDITY_UNLOCK_DELAY`, and nothing else in this contract ever passes a negative
/// liquidity delta. `collectFees` runs `modifyLiquidity` at zero, which returns accrued fees and
/// cannot touch principal.
///
/// An earlier version locked it forever, which is right for a perpetual token and wrong here. These
/// are **dated** instruments. After settlement both legs are fixed claims on a settled vault and
/// then, once redeemed, worth nothing at all, so liquidity left in those pools is not a commitment
/// to a market, it is a launcher's principal destroyed on a book nobody will ever trade again. A
/// launchpad whose only rational participant is someone who does not mind burning their stake has
/// no participants. The lock has to outlive the instrument, not the launcher.
contract FletcherLaunchpad is IUnlockCallback, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeTransferLib for address;

    IPoolManager public immutable poolManager;
    FletcherFactory public immutable factory;
    ISettlementSource public immutable settlementSource;

    /// @notice Swap fee on both legs, in hundredths of a bip. 1% matches how a leveraged instrument
    /// with a short dated life actually trades; it is not a stable pair.
    uint24 public constant LP_FEE = 10_000;

    /// @notice Tick spacing paired with `LP_FEE`.
    int24 public constant TICK_SPACING = 200;

    /// @notice How long after maturity the seeded liquidity stays locked.
    ///
    /// Past maturity the legs are fixed claims, so the book has nothing left to price. The delay
    /// exists only so holders who are slow to redeem still find a market, not to bind the launcher.
    uint256 public constant LIQUIDITY_UNLOCK_DELAY = 30 days;

    /// @notice How far the seeded price may sit from the strike-implied parity split, in bps.
    /// @dev The launcher supplies the opening price and the contract bounds it. An unbounded
    /// opening price is how a launchpad pair ends up 35x away from the instrument it represents.
    uint256 public constant MAX_OPENING_DEVIATION_BPS = 1_000;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    struct Launch {
        address series;
        address launcher;
        PoolKey floorKey;
        PoolKey turboKey;
        uint128 floorLiquidity;
        uint128 turboLiquidity;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice `launchOf[series]`.
    mapping(address => Launch) internal launches;
    address[] public allLaunches;

    event Launched(
        address indexed series,
        address indexed launcher,
        address indexed stock,
        PoolId floorPoolId,
        PoolId turboPoolId,
        uint128 floorLiquidity,
        uint128 turboLiquidity
    );
    event FeesCollected(address indexed series, address indexed to, uint256 floorLegAmount, uint256 turboLegAmount);
    event PrincipalWithdrawn(address indexed series, address indexed to, uint128 floorLiquidity, uint128 turboLiquidity);

    error NotLauncher();
    error UnknownSeries();
    error OpeningPriceOutOfBand(uint256 impliedX18, uint256 suppliedX18);
    error NotPoolManager();
    error NothingSeeded();
    error StillLocked(uint256 unlockedAt);
    error AlreadyWithdrawn();

    constructor(IPoolManager poolManager_, FletcherFactory factory_, ISettlementSource settlementSource_) {
        poolManager = poolManager_;
        factory = factory_;
        settlementSource = settlementSource_;
    }

    function launchCount() external view returns (uint256) {
        return allLaunches.length;
    }

    function launchOf(address series) external view returns (Launch memory) {
        return launches[series];
    }

    // ------------------------------------------------------------------------------------------
    // Launch
    // ------------------------------------------------------------------------------------------

    struct LaunchParams {
        address stock;
        uint256 strikeX8;
        uint64 tradingDay;
        /// @notice Total raw stock deposited. Split between the two pools by the parity ratio.
        uint256 rawStock;
        /// @notice Reference share price used to derive the opening split, 1e8.
        uint256 referencePriceX8;
    }

    /// @notice Create a series, mint both legs and seed both books, in one transaction.
    ///
    /// The caller supplies the stock. The launchpad splits it, seeds FLOOR against the stock and
    /// TURBO against the stock at the parity-implied prices, and records the caller as the launcher
    /// entitled to the fees.
    function launch(LaunchParams calldata p) external nonReentrant returns (address series) {
        if (p.rawStock == 0) revert NothingSeeded();

        // The opening split comes from the strike and a reference close, not from the caller.
        // FLOOR is worth min(P,K)/P of a share and TURBO the rest, so a launcher cannot open a
        // book at a price the instrument's own terms do not support.
        (uint256 floorShareX18, uint256 turboShareX18) = _parityShares(p.strikeX8, p.referencePriceX8);
        _requireReferenceIsHonest(p.stock, p.referencePriceX8);

        p.stock.safeTransferFrom(msg.sender, address(this), p.rawStock);

        // Exactly half the deposit is split into legs and the other half is kept back as the quote
        // side of the two books. That is not a tunable ratio, it falls out of parity: the two pools
        // need `floorShare + turboShare == 1` share of stock per share that was split, so quoting a
        // mint of M costs exactly M of stock.
        uint256 mintAmount = p.rawStock / 2;
        if (mintAmount == 0) revert NothingSeeded();
        p.stock.safeApprove(address(factory), mintAmount);

        Series s = factory.createSeries(p.stock, p.strikeX8, p.tradingDay, mintAmount, address(this));
        series = address(s);

        CallbackData memory d = CallbackData({
            series: series,
            stock: p.stock,
            floorLeg: address(s.floorToken()),
            turboLeg: address(s.turboToken()),
            legAmount: mintAmount,
            floorShareX18: floorShareX18,
            turboShareX18: turboShareX18
        });

        poolManager.unlock(abi.encode(Op.Seed, abi.encode(d)));

        Launch storage l = launches[series];
        l.series = series;
        l.launcher = msg.sender;
        allLaunches.push(series);

        // A full-range position is sized by whichever side binds first, so the pool takes less than
        // the deposit on the other side. What never entered the pool is not locked principal, it is
        // the launcher's own stock and legs, and leaving it here would strand it forever: this
        // contract has no withdrawal path by design. Returned in the same transaction so no balance
        // ever sits around to be swept by the next caller's launch.
        _refund(p.stock, msg.sender);
        _refund(address(s.floorToken()), msg.sender);
        _refund(address(s.turboToken()), msg.sender);

        emit Launched(
            series, msg.sender, p.stock, l.floorKey.toId(), l.turboKey.toId(), l.floorLiquidity, l.turboLiquidity
        );
    }

    /// @dev Return whatever of `token` this contract still holds to `to`.
    function _refund(address token, address to) internal {
        uint256 balance = IERC20Minimal(token).balanceOf(address(this));
        if (balance != 0) token.safeTransfer(to, balance);
    }

    /// @dev FLOOR's share of a share is `min(P,K)/P`; TURBO's is the remainder. They sum to WAD.
    function _parityShares(uint256 strikeX8, uint256 priceX8) internal pure returns (uint256, uint256) {
        if (priceX8 == 0) revert OpeningPriceOutOfBand(0, 0);
        uint256 claim = strikeX8 < priceX8 ? strikeX8 : priceX8;
        uint256 floorShare = (claim * WAD) / priceX8;
        return (floorShare, WAD - floorShare);
    }

    /// @dev The reference price must match what the settlement source says the share is worth.
    /// Otherwise a launcher could seed at a price of their own invention and sell the mispriced leg.
    ///
    /// Reads the live `referencePrice`, not a recorded close, for the same reason creation does: a
    /// launch must not be blocked by a gap in a recorded history.
    function _requireReferenceIsHonest(address stock, uint256 referencePriceX8) internal view {
        (uint256 refX8,) = settlementSource.referencePrice(stock);
        uint256 lo = (refX8 * (BPS - MAX_OPENING_DEVIATION_BPS)) / BPS;
        uint256 hi = (refX8 * (BPS + MAX_OPENING_DEVIATION_BPS)) / BPS;
        if (referencePriceX8 < lo || referencePriceX8 > hi) {
            revert OpeningPriceOutOfBand(refX8, referencePriceX8);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Pool creation, inside the unlock
    // ------------------------------------------------------------------------------------------

    struct CallbackData {
        address series;
        address stock;
        address floorLeg;
        address turboLeg;
        uint256 legAmount;
        uint256 floorShareX18;
        uint256 turboShareX18;
    }

    /// @dev One unlock entry point serves both paths. The tag is decided here, never by the
    /// caller's payload shape, so a launch payload cannot be replayed down the collection path.
    enum Op {
        Seed,
        Collect,
        Withdraw
    }

    function unlockCallback(bytes calldata raw) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Op op, bytes memory payload) = abi.decode(raw, (Op, bytes));
        if (op == Op.Collect) {
            _collect(abi.decode(payload, (address)));
            return "";
        }
        if (op == Op.Withdraw) {
            _withdraw(abi.decode(payload, (address)));
            return "";
        }
        CallbackData memory d = abi.decode(payload, (CallbackData));
        Launch storage l = launches[d.series];

        (l.tickLower, l.tickUpper) = _fullRange();

        // The legs were minted 1:1 against the deposit, so each pool's base side is the whole leg
        // supply and the quote side is the leg's parity share of one deposit's worth of stock. In
        // practice the launcher is seeding "one share split into its two halves, each half quoted
        // against the share it came from".
        (l.floorKey, l.floorLiquidity) = _openPool(
            d.floorLeg, d.stock, d.legAmount, FixedPointMathLib.mulDiv(d.legAmount, d.floorShareX18, WAD), l.tickLower, l.tickUpper
        );
        (l.turboKey, l.turboLiquidity) = _openPool(
            d.turboLeg, d.stock, d.legAmount, FixedPointMathLib.mulDiv(d.legAmount, d.turboShareX18, WAD), l.tickLower, l.tickUpper
        );

        return "";
    }

    /// @dev Full range, snapped to the tick spacing. A dated series lives for days and its legs can
    /// travel the whole range between them, so a concentrated band would be a band the instrument
    /// walks straight out of.
    function _fullRange() internal pure returns (int24 lower, int24 upper) {
        lower = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        upper = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
    }

    function _openPool(
        address base,
        address quote,
        uint256 baseAmount,
        uint256 quoteAmount,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (PoolKey memory key, uint128 liquidity) {
        (Currency c0, Currency c1) = base < quote
            ? (Currency.wrap(base), Currency.wrap(quote))
            : (Currency.wrap(quote), Currency.wrap(base));

        key = PoolKey({currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(0))});

        (uint256 amount0, uint256 amount1) =
            base < quote ? (baseAmount, quoteAmount) : (quoteAmount, baseAmount);

        uint160 sqrtPriceX96 = _sqrtPriceX96(amount0, amount1);
        poolManager.initialize(key, sqrtPriceX96);

        liquidity = _liquidityFor(amount0, amount1, tickLower, tickUpper, sqrtPriceX96);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        _settle(key.currency0, uint256(uint128(-delta.amount0())));
        _settle(key.currency1, uint256(uint128(-delta.amount1())));
    }

    /// @dev sqrt(amount1 / amount0) * 2**96.
    function _sqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        uint256 ratioX128 = FixedPointMathLib.mulDiv(amount1, 1 << 128, amount0);
        uint256 sqrtX64 = FixedPointMathLib.sqrt(ratioX128);
        return uint160(sqrtX64 << 32);
    }

    /// @dev Liquidity a full-range position supports for the smaller of the two sides, so the
    /// deposit is never over-committed on either currency.
    function _liquidityFor(uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint128)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // amount0 = L * (sqrtUpper - sqrtPrice) / (sqrtPrice * sqrtUpper) * 2^96
        uint256 l0 = FixedPointMathLib.mulDiv(
            FixedPointMathLib.mulDiv(amount0, sqrtPriceX96, 1 << 96), sqrtUpper, sqrtUpper - sqrtPriceX96
        );
        // amount1 = L * (sqrtPrice - sqrtLower) / 2^96
        uint256 l1 = FixedPointMathLib.mulDiv(amount1, 1 << 96, sqrtPriceX96 - sqrtLower);

        uint256 l = l0 < l1 ? l0 : l1;
        return uint128(l > type(uint128).max ? type(uint128).max : l);
    }

    function _settle(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(currency);
        Currency.unwrap(currency).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    // ------------------------------------------------------------------------------------------
    // Fees
    // ------------------------------------------------------------------------------------------

    /// @notice Sweep accrued swap fees on both legs to the launcher.
    ///
    /// Callable by anyone, always paying the recorded launcher, so the fee stream does not depend on
    /// the launcher staying online and cannot be redirected.
    function collectFees(address series) external nonReentrant {
        Launch storage l = launches[series];
        if (l.series == address(0)) revert UnknownSeries();
        poolManager.unlock(abi.encode(Op.Collect, abi.encode(series)));
    }

    /// @notice When `withdrawPrincipal` becomes callable for a launch.
    function unlockedAt(address series) public view returns (uint256) {
        return uint256(Series(series).maturity()) + LIQUIDITY_UNLOCK_DELAY;
    }

    /// @notice Return the seeded liquidity to the launcher, once the instrument is long over.
    ///
    /// Only the launcher may call it, and only after `unlockedAt`. Fees accrued up to that point
    /// come out with it, since removing the position settles them in the same delta.
    function withdrawPrincipal(address series) external nonReentrant {
        Launch storage l = launches[series];
        if (l.series == address(0)) revert UnknownSeries();
        if (msg.sender != l.launcher) revert NotLauncher();

        uint256 unlocked = unlockedAt(series);
        if (block.timestamp < unlocked) revert StillLocked(unlocked);
        if (l.floorLiquidity == 0 && l.turboLiquidity == 0) revert AlreadyWithdrawn();

        poolManager.unlock(abi.encode(Op.Withdraw, abi.encode(series)));
    }

    /// @dev Removes both positions in full and pays everything out to the launcher. The recorded
    /// liquidity is zeroed first, so a re-entrant or repeated call has nothing left to remove.
    function _withdraw(address series) internal {
        Launch storage l = launches[series];
        uint128 floorLiquidity = l.floorLiquidity;
        uint128 turboLiquidity = l.turboLiquidity;
        l.floorLiquidity = 0;
        l.turboLiquidity = 0;

        if (floorLiquidity != 0) {
            _removeAll(l.floorKey, l.tickLower, l.tickUpper, floorLiquidity, l.launcher);
        }
        if (turboLiquidity != 0) {
            _removeAll(l.turboKey, l.tickLower, l.tickUpper, turboLiquidity, l.launcher);
        }
        emit PrincipalWithdrawn(series, l.launcher, floorLiquidity, turboLiquidity);
    }

    function _removeAll(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity, address to)
        internal
    {
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        // `delta` is the principal returned; `fees` is what had accrued. Both are owed to the
        // launcher, and both are positive here because the position is only ever being reduced.
        _take(key.currency0, to, uint256(uint128(delta.amount0() + fees.amount0())));
        _take(key.currency1, to, uint256(uint128(delta.amount1() + fees.amount1())));
    }

    /// @dev A liquidity delta of zero returns the fees owed and cannot move principal. This is what
    /// locks the position for the life of the instrument: the only other call site that passes a
    /// delta is `_withdraw`, and it is gated on `unlockedAt`.
    function _collect(address series) internal {
        Launch storage l = launches[series];
        (BalanceDelta floorFees,) = poolManager.modifyLiquidity(
            l.floorKey,
            ModifyLiquidityParams({
                tickLower: l.tickLower,
                tickUpper: l.tickUpper,
                liquidityDelta: 0,
                salt: bytes32(0)
            }),
            ""
        );
        (BalanceDelta turboFees,) = poolManager.modifyLiquidity(
            l.turboKey,
            ModifyLiquidityParams({
                tickLower: l.tickLower,
                tickUpper: l.tickUpper,
                liquidityDelta: 0,
                salt: bytes32(0)
            }),
            ""
        );

        _take(l.floorKey.currency0, l.launcher, uint256(uint128(floorFees.amount0())));
        _take(l.floorKey.currency1, l.launcher, uint256(uint128(floorFees.amount1())));
        _take(l.turboKey.currency0, l.launcher, uint256(uint128(turboFees.amount0())));
        _take(l.turboKey.currency1, l.launcher, uint256(uint128(turboFees.amount1())));

        emit FeesCollected(
            series,
            l.launcher,
            uint256(uint128(floorFees.amount0())) + uint256(uint128(floorFees.amount1())),
            uint256(uint128(turboFees.amount0())) + uint256(uint128(turboFees.amount1()))
        );
    }

    function _take(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.take(currency, to, amount);
    }
}
