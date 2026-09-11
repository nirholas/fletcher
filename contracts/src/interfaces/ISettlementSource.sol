// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice Where a dated series learns the one number it settles against.
///
/// Robinhood Chain carries no price oracle of any kind, and the pool price is not a substitute. On
/// 30 August a PAIR-launched AMC pair traded 35x above the real equity for an entire weekend, with
/// the exchange shut and no arbitrageur able to close it. A protocol that had settled against that
/// pool would have paid TURBO the whole vault on a print that never existed.
///
/// So settlement takes an off-chain official close, carried on chain by a quorum of signed
/// reporter quotes, and it refuses to settle at all unless the session is closed and the quote is
/// fresh. `SherwoodSettlementSource` is the live adapter; this interface is what a series consumes.
interface ISettlementSource {
    enum Session {
        Unknown,
        PreMarket,
        Regular,
        AfterHours,
        Closed
    }

    /// @notice The official close for `stock`, 1e8-scaled USD per share.
    /// @dev MUST revert rather than return a stale, unsigned, or quorum-less price.
    /// @return priceX8 USD per share, 1e8.
    /// @return observedAt Unix timestamp the print was taken at.
    function officialClose(address stock, uint64 tradingDay)
        external
        view
        returns (uint256 priceX8, uint64 observedAt);

    /// @notice Whether an official close for `tradingDay` is available and settleable right now.
    function hasClose(address stock, uint64 tradingDay) external view returns (bool);

    /// @notice The venue session the source believes `stock` is in.
    function sessionOf(address stock) external view returns (Session);

    /// @notice A live reference price for `stock`, 1e8-scaled USD per share.
    ///
    /// Deliberately separate from `officialClose`. A series SETTLES on a dated, write-once close,
    /// which must never be substitutable. Creation only needs to know roughly where the share
    /// trades, so that a split point cannot be struck at a number the market never saw.
    ///
    /// Answering the second question from the first was a real defect: creation walked back through
    /// recorded closes, so a lapse in recording (a long holiday, a keeper outage) eventually ran
    /// past the lookback and bricked creation for every name, with no path back except recording a
    /// close nobody could still record. A live quote has no such history to lapse.
    ///
    /// MUST revert rather than return a stale or unusable price.
    function referencePrice(address stock) external view returns (uint256 priceX8, uint64 observedAt);
}
