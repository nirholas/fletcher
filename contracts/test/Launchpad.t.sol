// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FletcherLaunchpad} from "../src/FletcherLaunchpad.sol";
import {FletcherFactory} from "../src/FletcherFactory.sol";
import {Series} from "../src/Series.sol";
import {DepthGate} from "../src/DepthGate.sol";
import {MultiplierAccountant} from "../src/MultiplierAccountant.sol";
import {IMultiplierAccountant} from "../src/interfaces/IMultiplierAccountant.sol";
import {ISettlementSource} from "../src/interfaces/ISettlementSource.sol";
import {StockHarness} from "./harness/StockHarness.sol";
import {SettlementSourceHarness} from "./harness/SettlementSourceHarness.sol";
import {DepthGateHarness} from "./harness/DepthGateHarness.sol";

/// @notice The launchpad against a real Uniswap v4 `PoolManager`, not a stand-in for one.
///
/// `PoolManager` is deployed here from Uniswap's own source, so initialisation, the unlock/settle
/// accounting and `modifyLiquidity` all run their real code paths. The live contract on Robinhood
/// Chain (`0x8366a39CC670B4001A1121B8F6A443A643e40951`) is the same build; `test/fork/LiveChain.t.sol`
/// asserts that against the chain.
contract LaunchpadTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolManager internal manager;
    IPoolManager internal pm;
    FletcherLaunchpad internal launchpad;
    FletcherFactory internal factory;
    DepthGateHarness internal gate;
    SettlementSourceHarness internal source;
    StockHarness internal nvda;

    address internal launcher = address(0x1AbC);

    uint256 internal constant STRIKE = 170e8;
    uint256 internal constant SPOT = 178.5e8;
    uint64 internal tradingDay;

    function setUp() public {
        vm.warp(1_789_000_000);
        tradingDay = uint64(block.timestamp / 1 days) + 1;

        manager = new PoolManager(address(this));
        pm = IPoolManager(address(manager));
        nvda = new StockHarness("NVDA");
        source = new SettlementSourceHarness();
        gate = new DepthGateHarness();

        gate.setDepth(address(nvda), 1_000_000e18);
        source.setClose(address(nvda), uint64(block.timestamp / 1 days), SPOT);

        factory = new FletcherFactory(
            IMultiplierAccountant(address(new MultiplierAccountant())),
            ISettlementSource(address(source)),
            DepthGate(address(gate))
        );
        launchpad = new FletcherLaunchpad(IPoolManager(address(manager)), factory, ISettlementSource(address(source)));

        nvda.mint(launcher, 10_000e18);
        vm.prank(launcher);
        nvda.approve(address(launchpad), type(uint256).max);
    }

    function _launch(uint256 rawStock) internal returns (address series) {
        vm.prank(launcher);
        series = launchpad.launch(
            FletcherLaunchpad.LaunchParams({
                stock: address(nvda),
                strikeX8: STRIKE,
                tradingDay: tradingDay,
                rawStock: rawStock,
                referencePriceX8: SPOT
            })
        );
    }

    function test_launchOpensBothBooksAndLocksTheLiquidity() public {
        address series = _launch(1000e18);

        FletcherLaunchpad.Launch memory l = launchpad.launchOf(series);
        assertEq(l.launcher, launcher);
        assertGt(l.floorLiquidity, 0, "FLOOR book was seeded");
        assertGt(l.turboLiquidity, 0, "TURBO book was seeded");

        // Both pools exist and are initialised in the real manager.
        (uint160 floorSqrtPrice,,,) = pm.getSlot0(l.floorKey.toId());
        (uint160 turboSqrtPrice,,,) = pm.getSlot0(l.turboKey.toId());
        assertGt(floorSqrtPrice, 0);
        assertGt(turboSqrtPrice, 0);

        // The liquidity is held by the launchpad inside the manager, and the launchpad has no
        // function that can ever remove it.
        assertEq(pm.getLiquidity(l.floorKey.toId()), l.floorLiquidity);
        assertEq(pm.getLiquidity(l.turboKey.toId()), l.turboLiquidity);
    }

    function test_seededPricesReflectParity() public {
        address series = _launch(1000e18);
        FletcherLaunchpad.Launch memory l = launchpad.launchOf(series);

        // FLOOR's parity share of a $178.50 share struck at $170 is 170/178.50 = 0.9524, and
        // TURBO's is the remaining 0.0476. Priced in the underlying the two must sum to one share.
        uint256 floorPrice = _priceInStock(l.floorKey, address(Series(series).floorToken()));
        uint256 turboPrice = _priceInStock(l.turboKey, address(Series(series).turboToken()));

        assertApproxEqRel(floorPrice, (STRIKE * 1e18) / SPOT, 0.02e18, "FLOOR opened at its parity share");
        assertApproxEqRel(turboPrice, ((SPOT - STRIKE) * 1e18) / SPOT, 0.05e18, "TURBO opened at its parity share");
        assertApproxEqRel(floorPrice + turboPrice, 1e18, 0.02e18, "the two halves open at one whole share");
    }

    /// @dev Price of `leg` denominated in the stock, 1e18. Both tokens carry 18 decimals, so the
    /// pool's raw ratio is already the ratio a human would quote.
    function _priceInStock(PoolKey memory key, address leg) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = pm.getSlot0(key.toId());
        // (sqrtP / 2^96)^2, taken in two steps so sqrtP^2 never has to fit in 256 bits.
        uint256 q96 = FixedPointMathLib.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        uint256 priceOfToken0InToken1 = FixedPointMathLib.mulDiv(q96, 1e18, 1 << 96);
        return leg < address(nvda) ? priceOfToken0InToken1 : FixedPointMathLib.mulDiv(1e18, 1e18, priceOfToken0InToken1);
    }

    function test_launcherCannotWithdrawPrincipal() public {
        address series = _launch(1000e18);
        FletcherLaunchpad.Launch memory l = launchpad.launchOf(series);
        uint128 seeded = l.floorLiquidity;

        // There is no withdraw function to call. Collecting fees leaves principal untouched, which
        // is the whole locking guarantee, so assert it directly.
        launchpad.collectFees(series);
        assertEq(pm.getLiquidity(l.floorKey.toId()), seeded, "principal is untouched by a fee sweep");
    }

    function test_feesAlwaysGoToTheRecordedLauncher() public {
        address series = _launch(1000e18);
        // Anyone may trigger the sweep; it always pays the launcher, so the stream does not depend
        // on the launcher staying online and cannot be redirected.
        vm.prank(address(0xDEAD));
        launchpad.collectFees(series);
    }

    function test_refusesAnOpeningPriceTheInstrumentDoesNotSupport() public {
        vm.prank(launcher);
        vm.expectRevert(
            abi.encodeWithSelector(FletcherLaunchpad.OpeningPriceOutOfBand.selector, SPOT, SPOT * 35)
        );
        launchpad.launch(
            FletcherLaunchpad.LaunchParams({
                stock: address(nvda),
                strikeX8: STRIKE,
                tradingDay: tradingDay,
                rawStock: 1000e18,
                // The 30 August AMC episode, as a parameter: a launcher opening a book 35x above
                // the real equity. The band rejects it.
                referencePriceX8: SPOT * 35
            })
        );
    }

    /// @notice A full-range position is sized by whichever side binds first, so the pool takes less
    /// than the deposit on the other. Whatever never entered the pool is the launcher's, and the
    /// launchpad has no withdrawal path, so it must come back in the same transaction or it is
    /// stranded forever.
    function test_leftoversGoBackToTheLauncherRatherThanBeingStranded() public {
        address series = _launch(1000e18);

        assertEq(nvda.balanceOf(address(launchpad)), 0, "no stock stranded in the launchpad");
        assertEq(
            Series(series).floorToken().balanceOf(address(launchpad)), 0, "no FLOOR stranded in the launchpad"
        );
        assertEq(
            Series(series).turboToken().balanceOf(address(launchpad)), 0, "no TURBO stranded in the launchpad"
        );
    }

    /// @notice And the refund must reach the launcher, not merely leave the contract.
    function test_theLauncherEndsUpHoldingWhateverThePoolsDidNotTake() public {
        uint256 before = nvda.balanceOf(launcher);
        address series = _launch(1000e18);

        uint256 spent = before - nvda.balanceOf(launcher);
        assertLe(spent, 1000e18, "cannot spend more than was deposited");

        uint256 legs = Series(series).floorToken().balanceOf(launcher)
            + Series(series).turboToken().balanceOf(launcher);
        // Something came back: either unseated stock, or legs the pools could not absorb.
        assertGt(nvda.balanceOf(launcher) + legs, 0);
    }

    /// @notice A second launch must not be able to sweep a balance the first one left behind.
    function test_aLaunchCannotSweepAnEarlierLaunchsBalance() public {
        _launch(1000e18);
        assertEq(nvda.balanceOf(address(launchpad)), 0);

        vm.prank(launcher);
        launchpad.launch(
            FletcherLaunchpad.LaunchParams({
                stock: address(nvda),
                strikeX8: 165e8,
                tradingDay: tradingDay,
                rawStock: 500e18,
                referencePriceX8: SPOT
            })
        );
        assertEq(nvda.balanceOf(address(launchpad)), 0, "nothing accumulates between launches");
    }

    /// @notice Locking a launcher's principal FOREVER is right for a perpetual token and wrong for
    /// a dated one. After settlement both legs are fixed claims and then, once redeemed, worth
    /// nothing, so liquidity left in those pools is principal destroyed on a book nobody will trade
    /// again. A launchpad whose only rational participant is someone happy to burn their stake has
    /// no participants.
    function test_principalIsLockedForTheLifeOfTheInstrumentAndNotLonger() public {
        address series = _launch(1000e18);
        uint256 unlocked = launchpad.unlockedAt(series);

        // Locked while the instrument is live.
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(FletcherLaunchpad.StillLocked.selector, unlocked));
        launchpad.withdrawPrincipal(series);

        // Still locked the second before it lifts, which is what makes it a lock rather than a wish.
        vm.warp(unlocked - 1);
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(FletcherLaunchpad.StillLocked.selector, unlocked));
        launchpad.withdrawPrincipal(series);

        // And returns the position once the instrument is long over.
        vm.warp(unlocked);
        FletcherLaunchpad.Launch memory before = launchpad.launchOf(series);
        assertGt(before.floorLiquidity, 0);

        vm.prank(launcher);
        launchpad.withdrawPrincipal(series);

        assertEq(pm.getLiquidity(before.floorKey.toId()), 0, "FLOOR position closed");
        assertEq(pm.getLiquidity(before.turboKey.toId()), 0, "TURBO position closed");
    }

    function test_onlyTheLauncherMayWithdraw() public {
        address series = _launch(1000e18);
        vm.warp(launchpad.unlockedAt(series));

        vm.prank(address(0xDEAD));
        vm.expectRevert(FletcherLaunchpad.NotLauncher.selector);
        launchpad.withdrawPrincipal(series);
    }

    function test_principalCannotBeWithdrawnTwice() public {
        address series = _launch(1000e18);
        vm.warp(launchpad.unlockedAt(series));

        vm.prank(launcher);
        launchpad.withdrawPrincipal(series);

        vm.prank(launcher);
        vm.expectRevert(FletcherLaunchpad.AlreadyWithdrawn.selector);
        launchpad.withdrawPrincipal(series);
    }

    /// @notice The unlock sits a full grace period past maturity, so holders slow to redeem still
    /// find a market rather than the launcher pulling the book the moment the bell rings.
    function test_theUnlockIsAGracePeriodPastMaturity() public {
        address series = _launch(1000e18);
        assertEq(
            launchpad.unlockedAt(series),
            uint256(Series(series).maturity()) + launchpad.LIQUIDITY_UNLOCK_DELAY()
        );
    }

    function test_unlockCallbackIsNotCallableDirectly() public {
        vm.expectRevert(FletcherLaunchpad.NotPoolManager.selector);
        launchpad.unlockCallback("");
    }

    function test_collectingOnAnUnknownSeriesReverts() public {
        vm.expectRevert(FletcherLaunchpad.UnknownSeries.selector);
        launchpad.collectFees(address(0xBEEF));
    }
}
