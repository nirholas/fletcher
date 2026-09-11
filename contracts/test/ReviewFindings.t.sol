// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Series} from "../src/Series.sol";
import {DepthGate} from "../src/DepthGate.sol";
import {MultiplierAccountant} from "../src/MultiplierAccountant.sol";
import {IMultiplierAccountant} from "../src/interfaces/IMultiplierAccountant.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {ISettlementSource} from "../src/interfaces/ISettlementSource.sol";
import {
    SherwoodSettlementSource,
    ISherwoodOracle,
    SherwoodSession,
    SherwoodPriceStatus
} from "../src/adapters/SherwoodSettlementSource.sol";
import {StockHarness} from "./harness/StockHarness.sol";
import {SettlementSourceHarness} from "./harness/SettlementSourceHarness.sol";
import {SherwoodOracleHarness} from "./harness/SherwoodOracleHarness.sol";
import {UniswapV3Harness, V3PoolHarness} from "./harness/UniswapV3Harness.sol";

/// @notice Regression tests for the defects an external review of this implementation found on
/// 10 September 2026.
///
/// Each one is written to fail against the code as it stood when the review was run, so the test is
/// evidence the defect was real rather than a restatement of the fix. The review is the reason
/// several of these exist at all; the findings were reduced to proofs-of-concept against the
/// unmodified contracts before anything here changed.
contract ReviewFindingsTest is Test {
    StockHarness internal nvda;
    SettlementSourceHarness internal source;
    MultiplierAccountant internal accountant;

    address internal alice = address(0xA11CE);
    uint256 internal constant STRIKE = 170e8;
    uint64 internal tradingDay;
    uint64 internal maturity;

    function setUp() public {
        vm.warp(1_789_000_000);
        tradingDay = uint64(block.timestamp / 1 days);
        maturity = uint64(block.timestamp + 2 days);

        nvda = new StockHarness("NVDA");
        source = new SettlementSourceHarness();
        accountant = new MultiplierAccountant();
        nvda.mint(alice, 1000e18);
    }

    function _series() internal returns (Series s) {
        s = new Series(
            IStockToken(address(nvda)),
            STRIKE,
            maturity,
            tradingDay,
            IMultiplierAccountant(address(accountant)),
            ISettlementSource(address(source)),
            "F",
            "F",
            "T",
            "T"
        );
        vm.startPrank(alice);
        nvda.approve(address(s), type(uint256).max);
        s.mint(alice, 100e18);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------
    // Finding 1: the settlement price was choosable by whoever recorded it first.
    // ------------------------------------------------------------------------------------------

    /// @notice After-hours is a LIVE session: the price still moves. Accepting it meant the first
    /// caller to `recordClose` chose which after-hours print became the settlement price for every
    /// series dated to that day, which is the caller choosing the number.
    function test_recordCloseRefusesALiveAfterHoursSession() public {
        SherwoodOracleHarness oracle = new SherwoodOracleHarness();
        SherwoodSettlementSource live = new SherwoodSettlementSource(ISherwoodOracle(address(oracle)));

        oracle.set(address(nvda), 200e8, SherwoodSession.Post, SherwoodPriceStatus.OK);
        vm.warp((uint256(tradingDay) + 1) * 1 days + 1 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                SherwoodSettlementSource.SessionNotClosed.selector, address(nvda), uint8(SherwoodSession.Post)
            )
        );
        live.recordClose(address(nvda), tradingDay);

        // The same price, once the session is genuinely closed, records fine.
        oracle.set(address(nvda), 200e8, SherwoodSession.Closed, SherwoodPriceStatus.OK);
        assertEq(live.recordClose(address(nvda), tradingDay), 200e8);
    }

    function test_recordCloseRefusesAHaltedListing() public {
        SherwoodOracleHarness oracle = new SherwoodOracleHarness();
        SherwoodSettlementSource live = new SherwoodSettlementSource(ISherwoodOracle(address(oracle)));
        oracle.set(address(nvda), 200e8, SherwoodSession.Halted, SherwoodPriceStatus.OK);
        vm.warp((uint256(tradingDay) + 1) * 1 days + 1 hours);

        vm.expectRevert();
        live.recordClose(address(nvda), tradingDay);
    }

    /// @notice And it stays write-once, so a later caller cannot revise a settled day.
    function test_aRecordedCloseCannotBeRevised() public {
        SherwoodOracleHarness oracle = new SherwoodOracleHarness();
        SherwoodSettlementSource live = new SherwoodSettlementSource(ISherwoodOracle(address(oracle)));
        oracle.set(address(nvda), 200e8, SherwoodSession.Closed, SherwoodPriceStatus.OK);
        vm.warp((uint256(tradingDay) + 1) * 1 days + 1 hours);
        live.recordClose(address(nvda), tradingDay);

        oracle.set(address(nvda), 900e8, SherwoodSession.Closed, SherwoodPriceStatus.OK);
        vm.expectRevert();
        live.recordClose(address(nvda), tradingDay);

        (uint256 priceX8,) = live.officialClose(address(nvda), tradingDay);
        assertEq(priceX8, 200e8, "the first honest recording stands");
    }

    // ------------------------------------------------------------------------------------------
    // Finding 6: a pending corporate action blocked settlement forever.
    // ------------------------------------------------------------------------------------------

    /// @notice The issuer schedules corporate actions and nothing obliges them to apply one. A
    /// scheduled action left pending forever used to block settlement forever, leaving holders with
    /// merge as their only exit for the rest of time.
    function test_aNeverAppliedCorporateActionStopsBlockingSettlementAfterTheGrace() public {
        Series s = _series();
        nvda.scheduleMultiplier(2e18, maturity - 1);
        source.setClose(address(nvda), tradingDay, 200e8);

        vm.warp(maturity);
        vm.expectRevert(Series.CorporateActionPending.selector);
        s.settle();

        // Still blocked one second before the grace expires.
        vm.warp(uint256(maturity) + s.PENDING_ACTION_GRACE() - 1);
        vm.expectRevert(Series.CorporateActionPending.selector);
        s.settle();

        // And settles after it, on the terms it can actually observe.
        vm.warp(uint256(maturity) + s.PENDING_ACTION_GRACE());
        s.settle();
        assertTrue(s.settled(), "a dated series must eventually resolve");
    }

    /// @notice The grace must not let a series settle in front of an action that DOES land on time.
    function test_theGraceDoesNotWeakenTheNormalCase() public {
        Series s = _series();
        nvda.scheduleMultiplier(2e18, maturity - 1);
        source.setClose(address(nvda), tradingDay, 200e8);

        vm.warp(maturity);
        vm.expectRevert(Series.CorporateActionPending.selector);
        s.settle();

        nvda.applyScheduled();
        s.settle();
        assertEq(s.strikeX8(), 85e8, "the split still halved the split point");
    }

    // ------------------------------------------------------------------------------------------
    // Finding 3: the depth gate was a single flash-manipulable read.
    // ------------------------------------------------------------------------------------------

    address internal constant QUOTE = address(0xC0FFEE);

    function _gate() internal returns (DepthGate gate, UniswapV3Harness uni, address pool) {
        uni = new UniswapV3Harness();
        gate = new DepthGate(address(uni), QUOTE, 1e15);
        pool = uni.setPool(address(nvda), QUOTE, 500, 1e18);
    }

    /// @notice A book that exists only in the calling block must never qualify a name. Otherwise:
    /// flash-mint liquidity, create the series, withdraw, and a name with no book carries a live
    /// leveraged instrument.
    function test_aSingleBlockOfLiquidityNeverQualifiesAName() public {
        (DepthGate gate,,) = _gate();

        gate.checkpoint(address(nvda));
        assertFalse(gate.qualifies(address(nvda)), "one observation is not a sustained book");

        // Nor can the window be filled inside one block, or a flash position would clear it.
        vm.expectRevert();
        gate.checkpoint(address(nvda));
    }

    /// @notice Liquidity held across the whole window qualifies. This is the honest path.
    function test_sustainedLiquidityQualifies() public {
        (DepthGate gate,,) = _gate();

        for (uint256 i = 0; i < 3; ++i) {
            gate.checkpoint(address(nvda));
            skip(gate.MIN_CHECKPOINT_INTERVAL());
        }
        skip(gate.DEPTH_WINDOW());
        assertTrue(gate.qualifies(address(nvda)));
    }

    /// @notice A book that was deep and then left must stop qualifying the name.
    function test_liquidityThatLeavesDisqualifiesTheName() public {
        (DepthGate gate, UniswapV3Harness uni,) = _gate();

        for (uint256 i = 0; i < 3; ++i) {
            gate.checkpoint(address(nvda));
            skip(gate.MIN_CHECKPOINT_INTERVAL());
        }
        skip(gate.DEPTH_WINDOW());
        assertTrue(gate.qualifies(address(nvda)));

        // The book drains, and the next observation records it.
        uni.setPool(address(nvda), QUOTE, 500, 1);
        gate.checkpoint(address(nvda));
        assertFalse(gate.qualifies(address(nvda)), "every retained observation must clear the floor");
    }

    /// @notice An ERC-20 transfer to the pool address raises its balance and adds nothing tradeable.
    /// The gate reads in-range liquidity precisely so that donation buys nothing.
    function test_donatingTokensToAPoolDoesNotCreateDepth() public {
        UniswapV3Harness uni = new UniswapV3Harness();
        DepthGate gate = new DepthGate(address(uni), QUOTE, 1e15);
        address pool = uni.setPool(address(nvda), QUOTE, 500, 0);

        vm.prank(alice);
        nvda.transfer(pool, 500e18);

        (uint128 depth,) = gate.currentLiquidity(address(nvda));
        assertEq(depth, 0, "a balance is not a book");
    }
}
