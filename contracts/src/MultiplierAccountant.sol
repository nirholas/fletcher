// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMultiplierAccountant} from "./interfaces/IMultiplierAccountant.sol";

/// @title MultiplierAccountant
/// @notice Tells a dividend from a split by shape alone, with no feed and no privileged reporter.
///
/// The classification rules are deliberately narrow, because the cost of a false `Split` is that
/// FLOOR's strike collapses and TURBO is handed value it never bought, while the cost of a false
/// `Unknown` is only that a series stops settling and everyone merges out at par. Those are not
/// symmetric, so anything ambiguous resolves to `Unknown`.
///
/// A rise is a **dividend** when it is at most `DIVIDEND_MAX_BPS` (3%). Real distributions on the
/// 254 equities are basis points: NVDA's live multiplier moved to 1.000775e18 on 10 September 2026,
/// a 7.75bp accrual.
///
/// A rise is a **split** when the ratio `to/from` lands on a clean integer or a clean simple
/// fraction at least `SPLIT_MIN_BPS` (20%) away from 1, within `RATIO_TOLERANCE_BPS` of exact.
/// Splits are announced as ratios (2:1, 3:1, 3:2, 10:1), never as arbitrary reals, so demanding a
/// clean ratio is not a heuristic tightened until the tests passed; it is the actual shape of the
/// event. The tolerance exists only because a multiplier is a 1e18 fixed-point number and a 3:2
/// split is not exactly representable.
///
/// Reverse splits move the multiplier DOWN. The live `Stock` implementation has only ever raised
/// it, but nothing in ERC-8056 forbids a fall, so falls are classified too: a clean inverse ratio
/// is a reverse split, and any other fall is `Unknown`.
contract MultiplierAccountant is IMultiplierAccountant {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @notice A rise no larger than this is a distribution, not a split. 3%.
    uint256 public constant DIVIDEND_MAX_BPS = 300;

    /// @notice A ratio must sit at least this far from 1 to be considered a split. 20%.
    uint256 public constant SPLIT_MIN_BPS = 2_000;

    /// @notice How close to a clean ratio a multiplier must land. 5bp.
    uint256 public constant RATIO_TOLERANCE_BPS = 5;

    /// @notice Largest split numerator or denominator considered, e.g. 50:1.
    uint256 public constant MAX_RATIO_TERM = 50;

    /// @inheritdoc IMultiplierAccountant
    function classify(uint256 fromMultiplier, uint256 toMultiplier)
        external
        pure
        override
        returns (Classification memory)
    {
        return _classify(fromMultiplier, toMultiplier);
    }

    function _classify(uint256 from, uint256 to) internal pure returns (Classification memory c) {
        if (from == 0 || to == 0) {
            return Classification(Kind.Unknown, WAD, 0, 0);
        }
        if (from == to) {
            return Classification(Kind.None, WAD, 1, 1);
        }

        if (to > from) {
            // A rise inside the distribution band is a dividend. The strike does not move, which is
            // precisely how FLOOR ends up owning the accrual.
            uint256 riseBps = ((to - from) * BPS) / from;
            if (riseBps <= DIVIDEND_MAX_BPS) {
                return Classification(Kind.Dividend, WAD, 1, 1);
            }
        }

        // Forward split: to/from is a clean ratio num/den with num > den (multiplier rises).
        // Reverse split: the same search with the roles swapped.
        (bool ok, uint256 num, uint256 den) = _findRatio(from, to);
        if (!ok) {
            return Classification(Kind.Unknown, WAD, 0, 0);
        }

        // Strike divides by the same ratio the multiplier multiplied by, so
        // `multiplier * min(price, strike)` is invariant across the event.
        uint256 factor = (den * WAD) / num;
        return Classification(Kind.Split, factor, num, den);
    }

    /// @dev Search for the simplest `num/den` with `to/from ~= num/den`, both terms bounded by
    /// `MAX_RATIO_TERM` and the ratio at least `SPLIT_MIN_BPS` away from 1. Searching by increasing
    /// denominator returns 2/1 rather than 4/2 for a doubling, so `ratioNum`/`ratioDen` read as the
    /// announced corporate action.
    function _findRatio(uint256 from, uint256 to) internal pure returns (bool, uint256, uint256) {
        // ratio = to/from in WAD.
        uint256 ratio = (to * WAD) / from;

        uint256 distanceBps = ratio > WAD ? ((ratio - WAD) * BPS) / WAD : ((WAD - ratio) * BPS) / WAD;
        if (distanceBps < SPLIT_MIN_BPS) {
            return (false, 0, 0);
        }

        for (uint256 den = 1; den <= MAX_RATIO_TERM; ++den) {
            // num that would make num/den closest to ratio, rounded to nearest.
            uint256 num = (ratio * den + WAD / 2) / WAD;
            if (num == 0 || num > MAX_RATIO_TERM || num == den) continue;
            if (_gcd(num, den) != 1) continue; // not in lowest terms; a smaller den already covered it

            uint256 candidate = (num * WAD) / den;
            uint256 diff = candidate > ratio ? candidate - ratio : ratio - candidate;
            if ((diff * BPS) / WAD <= RATIO_TOLERANCE_BPS) {
                return (true, num, den);
            }
        }
        return (false, 0, 0);
    }

    function _gcd(uint256 a, uint256 b) internal pure returns (uint256) {
        while (b != 0) {
            (a, b) = (b, a % b);
        }
        return a;
    }

    /// @inheritdoc IMultiplierAccountant
    function adjustStrike(uint256 strikeX8, Classification memory c) external pure override returns (uint256) {
        return _adjustStrike(strikeX8, c);
    }

    function _adjustStrike(uint256 strikeX8, Classification memory c) internal pure returns (uint256) {
        if (c.kind == Kind.Split) {
            // Exact ratio arithmetic rather than the WAD factor: a 3:2 split is not representable
            // in 1e18 and rounding the strike is rounding real money between two cohorts.
            return (strikeX8 * c.ratioDen) / c.ratioNum;
        }
        return strikeX8;
    }
}
