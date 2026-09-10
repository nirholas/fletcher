// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Classifies a change in a stock token's ERC-8056 `uiMultiplier()` and says what it does
/// to a dated series' split point.
///
/// This is the one piece of Fletcher that is genuinely hard, and it is hard because a single
/// number carries two economically opposite events:
///
///   - A **dividend** raises the multiplier by a fraction of a percent. Nothing about the company
///     changed, so a series' split point must NOT move. FLOOR's claim is
///     `multiplier * min(price, strike)`, so leaving the strike alone is exactly what hands the
///     dividend accrual to FLOOR. That is the FLOOR holder's coupon.
///   - A **split** multiplies the multiplier by a clean ratio and divides the share price by the
///     same ratio. The company is unchanged, so the split point MUST move by the inverse or the
///     series silently re-strikes: a 2:1 split on a $170 strike would leave FLOOR claiming
///     `2 * min($85, $170) = $170`, the entire vault, and zero TURBO. Listed options adjust
///     contract terms for exactly this reason.
///
/// A classifier that guesses wrong on either one moves real money between two cohorts. So the
/// third outcome is a first-class answer rather than a failure: an `Unknown` change freezes the
/// series into merge-only. Nobody is liquidated, nobody is settled at a strike nobody can defend,
/// and every holder can still recombine the two halves and walk out with the stock.
interface IMultiplierAccountant {
    enum Kind {
        /// @dev No change since the last observation.
        None,
        /// @dev A small rise consistent with a distribution. Strike is untouched; FLOOR accrues it.
        Dividend,
        /// @dev A clean ratio. Strike divides by the ratio so the economics survive.
        Split,
        /// @dev Neither shape. The series stops settling and allows only `merge()`.
        Unknown
    }

    struct Classification {
        Kind kind;
        /// @dev The strike multiplier to apply, 1e18-scaled. `1e18` for Dividend and None.
        uint256 strikeFactor1e18;
        /// @dev Human-readable ratio numerator/denominator for a Split, e.g. 1/2 for a 2:1 split.
        uint256 ratioNum;
        uint256 ratioDen;
    }

    /// @notice Classify the move from `fromMultiplier` to `toMultiplier`.
    /// @dev Pure: the same pair always classifies the same way, so a series can re-derive its own
    /// history and an integrator can check a classification before trusting it.
    function classify(uint256 fromMultiplier, uint256 toMultiplier)
        external
        view
        returns (Classification memory);

    /// @notice Apply a classification to a strike.
    function adjustStrike(uint256 strikeX8, Classification memory c) external pure returns (uint256);
}
