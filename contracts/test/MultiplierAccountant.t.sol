// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MultiplierAccountant} from "../src/MultiplierAccountant.sol";
import {IMultiplierAccountant} from "../src/interfaces/IMultiplierAccountant.sol";

contract MultiplierAccountantTest is Test {
    MultiplierAccountant internal acc;

    /// @dev NVDA's live `uiMultiplier()` on chain 4663, read at block 59698078 on 10 September 2026.
    /// It had been exactly 1e18 three days earlier, so this pair is a real distribution as it
    /// actually landed: a 7.75 basis point rise, effective 2026-09-10T00:00:30Z.
    uint256 internal constant NVDA_LIVE_MULTIPLIER = 1_000_775_159_164_630_595;

    function setUp() public {
        acc = new MultiplierAccountant();
    }

    // --- dividends ---------------------------------------------------------------------------

    function test_liveNvidiaAccrualIsADividend() public view {
        IMultiplierAccountant.Classification memory c = acc.classify(1e18, NVDA_LIVE_MULTIPLIER);
        assertEq(uint8(c.kind), uint8(IMultiplierAccountant.Kind.Dividend), "live NVDA accrual must read as a dividend");
        assertEq(c.strikeFactor1e18, 1e18, "a dividend must not move the strike");
    }

    function test_dividendLeavesStrikeUntouched() public view {
        IMultiplierAccountant.Classification memory c = acc.classify(1e18, NVDA_LIVE_MULTIPLIER);
        // A $170.00 split point stays a $170.00 split point.
        assertEq(acc.adjustStrike(170e8, c), 170e8);
    }

    function test_dividendBandBoundary() public view {
        // 3.00% exactly is still a dividend; 3.01% is not.
        assertEq(uint8(acc.classify(1e18, 1.03e18).kind), uint8(IMultiplierAccountant.Kind.Dividend));
        assertEq(uint8(acc.classify(1e18, 1.0301e18).kind), uint8(IMultiplierAccountant.Kind.Unknown));
    }

    function test_noChangeIsNone() public view {
        assertEq(uint8(acc.classify(1e18, 1e18).kind), uint8(IMultiplierAccountant.Kind.None));
    }

    // --- splits ------------------------------------------------------------------------------

    function test_twoForOneSplitHalvesTheStrike() public view {
        IMultiplierAccountant.Classification memory c = acc.classify(1e18, 2e18);
        assertEq(uint8(c.kind), uint8(IMultiplierAccountant.Kind.Split));
        assertEq(c.ratioNum, 2, "reported as 2:1, not 4:2");
        assertEq(c.ratioDen, 1);
        assertEq(acc.adjustStrike(170e8, c), 85e8);
    }

    function test_tenForOneSplit() public view {
        IMultiplierAccountant.Classification memory c = acc.classify(1e18, 10e18);
        assertEq(uint8(c.kind), uint8(IMultiplierAccountant.Kind.Split));
        assertEq(c.ratioNum, 10);
        assertEq(c.ratioDen, 1);
        assertEq(acc.adjustStrike(1200e8, c), 120e8);
    }

    function test_threeForTwoSplitUsesExactRatioArithmetic() public view {
        IMultiplierAccountant.Classification memory c = acc.classify(1e18, 1.5e18);
        assertEq(uint8(c.kind), uint8(IMultiplierAccountant.Kind.Split));
        assertEq(c.ratioNum, 3);
        assertEq(c.ratioDen, 2);
        // 1.5 is not exactly representable as a reciprocal in 1e18, so the strike is adjusted from
        // the ratio terms rather than from `strikeFactor1e18`.
        assertEq(acc.adjustStrike(150e8, c), 100e8);
    }

    function test_splitOnTopOfAnAlreadyAccruedMultiplier() public view {
        // The realistic case: a name that has paid dividends for months, then splits 2:1.
        uint256 from = NVDA_LIVE_MULTIPLIER;
        uint256 to = from * 2;
        IMultiplierAccountant.Classification memory c = acc.classify(from, to);
        assertEq(uint8(c.kind), uint8(IMultiplierAccountant.Kind.Split));
        assertEq(c.ratioNum, 2);
        assertEq(acc.adjustStrike(170e8, c), 85e8);
    }

    function test_reverseSplitRaisesTheStrike() public view {
        // 1:10 reverse split: multiplier falls to a tenth, price multiplies by ten.
        IMultiplierAccountant.Classification memory c = acc.classify(1e18, 0.1e18);
        assertEq(uint8(c.kind), uint8(IMultiplierAccountant.Kind.Split));
        assertEq(c.ratioNum, 1);
        assertEq(c.ratioDen, 10);
        assertEq(acc.adjustStrike(12e8, c), 120e8);
    }

    // --- the unknowns ------------------------------------------------------------------------

    function test_dirtyRatioIsUnknownRatherThanGuessed() public view {
        // A 37.3% rise is neither a distribution nor any clean ratio. Guessing here would move real
        // money between two cohorts, so it must refuse.
        assertEq(uint8(acc.classify(1e18, 1.373e18).kind), uint8(IMultiplierAccountant.Kind.Unknown));
    }

    function test_smallFallIsUnknown() public view {
        // Multipliers do not fall on distributions. A 1% fall is not a reverse split either.
        assertEq(uint8(acc.classify(1e18, 0.99e18).kind), uint8(IMultiplierAccountant.Kind.Unknown));
    }

    function test_zeroIsUnknown() public view {
        assertEq(uint8(acc.classify(0, 1e18).kind), uint8(IMultiplierAccountant.Kind.Unknown));
        assertEq(uint8(acc.classify(1e18, 0).kind), uint8(IMultiplierAccountant.Kind.Unknown));
    }

    function test_ratioBeyondSearchRangeIsUnknown() public view {
        // 51:1 is past MAX_RATIO_TERM. Refusing is correct: a series frozen by a 51:1 split still
        // lets every holder merge out at par.
        assertEq(uint8(acc.classify(1e18, 51e18).kind), uint8(IMultiplierAccountant.Kind.Unknown));
    }

    // --- invariants --------------------------------------------------------------------------

    /// @notice A split must preserve `multiplier * min(price, strike)` for a FLOOR that is in the
    /// money, which is the economic content of "the strike adjustment is not a re-strike".
    function testFuzz_splitPreservesFloorValue(uint256 strikeX8, uint8 ratio) public view {
        strikeX8 = bound(strikeX8, 1e8, 100_000e8);
        uint256 num = bound(uint256(ratio), 2, 20);

        IMultiplierAccountant.Classification memory c = acc.classify(1e18, num * 1e18);
        assertEq(uint8(c.kind), uint8(IMultiplierAccountant.Kind.Split));

        uint256 adjusted = acc.adjustStrike(strikeX8, c);
        // Pre-split FLOOR value at a price above the strike: 1 * strike.
        // Post-split: num * (strike / num). Equal up to the rounding of one wei of strike.
        assertApproxEqAbs(adjusted * num, strikeX8, num, "split must not re-strike the series");
    }

    /// @notice Classification is a pure function of the pair, so a series can always re-derive its
    /// own history and an integrator can check a classification before trusting it.
    function testFuzz_classificationIsDeterministic(uint256 from, uint256 to) public view {
        from = bound(from, 1, 1e30);
        to = bound(to, 1, 1e30);
        IMultiplierAccountant.Classification memory a = acc.classify(from, to);
        IMultiplierAccountant.Classification memory b = acc.classify(from, to);
        assertEq(uint8(a.kind), uint8(b.kind));
        assertEq(a.strikeFactor1e18, b.strikeFactor1e18);
    }

    /// @notice Nothing outside the two named shapes may ever silently move a strike.
    function testFuzz_onlySplitsMoveTheStrike(uint256 from, uint256 to, uint256 strikeX8) public view {
        from = bound(from, 1e17, 1e21);
        to = bound(to, 1e17, 1e21);
        strikeX8 = bound(strikeX8, 1e8, 100_000e8);
        IMultiplierAccountant.Classification memory c = acc.classify(from, to);
        if (c.kind != IMultiplierAccountant.Kind.Split) {
            assertEq(acc.adjustStrike(strikeX8, c), strikeX8, "only a split may move a strike");
        }
    }
}
