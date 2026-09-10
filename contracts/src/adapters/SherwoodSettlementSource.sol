// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISettlementSource} from "../interfaces/ISettlementSource.sol";

enum SherwoodPriceStatus {
    OK,
    NoConfig,
    NoQuote,
    QuoteStale,
    TokenPaused,
    IssuerOraclePaused,
    TwapUnavailable,
    TwapDeviation,
    MultiplierTransition,
    BasketDegraded
}

enum SherwoodSession {
    Closed,
    Pre,
    Regular,
    Post,
    Halted
}

interface ISherwoodOracle {
    function peek(address asset) external view returns (uint256 rawX26, SherwoodPriceStatus status);
    function pricePerShare1e8(address asset) external view returns (uint256);
    function sessionOf(address asset) external view returns (SherwoodSession);
}

/// @title SherwoodSettlementSource
/// @notice Turns Sherwood's live attested quote into the dated close print a series settles on.
///
/// Sherwood answers "what is NVDA worth right now", carried by a quorum of signed reporter quotes
/// and cross-checked against a Uniswap TWAP so neither source can move the price alone. That is the
/// right shape for a lending market, which only ever cares about now. A dated series cares about
/// exactly one instant instead: the official close of one trading day, fixed forever.
///
/// So this adapter records rather than computes. `recordClose` is permissionless, may be called
/// only once per (equity, day), and only while Sherwood itself reports the session closed and the
/// price usable. After that the number is immutable and every series dated to that day settles on
/// the same print.
///
/// What it deliberately does not do is read a pool. On 30 August a PAIR-launched AMC pair traded
/// 35x above the real equity across a weekend, with the exchange shut and nobody able to arbitrage
/// it closed. That pool price was real, on-chain, and completely wrong, and a series that settled
/// against it would have handed TURBO the entire vault. The pool is where the legs trade. It is
/// never what they settle against.
contract SherwoodSettlementSource is ISettlementSource {
    ISherwoodOracle public immutable oracle;

    struct Close {
        uint128 priceX8;
        uint64 observedAt;
        bool recorded;
    }

    /// @notice `closes[stock][tradingDay]`.
    mapping(address => mapping(uint64 => Close)) internal closes;

    event CloseRecorded(address indexed stock, uint64 indexed tradingDay, uint256 priceX8, address indexed by);

    error AlreadyRecorded(address stock, uint64 tradingDay);
    error SessionOpen(address stock);
    error PriceUnusable(address stock, SherwoodPriceStatus status);
    error DayNotOver(uint64 tradingDay);
    error NoClose(address stock, uint64 tradingDay);
    error PriceOutOfRange(uint256 priceX8);

    constructor(ISherwoodOracle oracle_) {
        oracle = oracle_;
    }

    /// @notice Freeze the official close for `stock` on `tradingDay`.
    ///
    /// Permissionless because it takes no discretion: the caller cannot choose the number, only the
    /// moment it is read, and the session gate means every valid moment carries the same close.
    function recordClose(address stock, uint64 tradingDay) external returns (uint256 priceX8) {
        if (closes[stock][tradingDay].recorded) revert AlreadyRecorded(stock, tradingDay);

        // The day must actually be over. Recording "today's close" at noon would record a mid-session
        // print under a name that claims otherwise.
        if (block.timestamp < (uint256(tradingDay) + 1) * 1 days) revert DayNotOver(tradingDay);

        SherwoodSession session = oracle.sessionOf(stock);
        if (session == SherwoodSession.Regular || session == SherwoodSession.Pre) revert SessionOpen(stock);

        (, SherwoodPriceStatus status) = oracle.peek(stock);
        if (status != SherwoodPriceStatus.OK) revert PriceUnusable(stock, status);

        priceX8 = oracle.pricePerShare1e8(stock);
        if (priceX8 == 0) revert PriceUnusable(stock, SherwoodPriceStatus.NoQuote);
        // Bounded rather than cast blindly: a price that does not fit is a broken feed, and
        // truncating it would record a number the oracle never reported.
        if (priceX8 > type(uint128).max) revert PriceOutOfRange(priceX8);

        // casting to 'uint128' is safe because the bound above rejects anything that would truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 stored = uint128(priceX8);
        closes[stock][tradingDay] = Close({priceX8: stored, observedAt: uint64(block.timestamp), recorded: true});
        emit CloseRecorded(stock, tradingDay, priceX8, msg.sender);
    }

    /// @inheritdoc ISettlementSource
    function officialClose(address stock, uint64 tradingDay)
        external
        view
        override
        returns (uint256 priceX8, uint64 observedAt)
    {
        Close memory c = closes[stock][tradingDay];
        if (!c.recorded) revert NoClose(stock, tradingDay);
        return (c.priceX8, c.observedAt);
    }

    /// @inheritdoc ISettlementSource
    function hasClose(address stock, uint64 tradingDay) external view override returns (bool) {
        return closes[stock][tradingDay].recorded;
    }

    /// @inheritdoc ISettlementSource
    function sessionOf(address stock) external view override returns (ISettlementSource.Session) {
        SherwoodSession s = oracle.sessionOf(stock);
        if (s == SherwoodSession.Pre) return ISettlementSource.Session.PreMarket;
        if (s == SherwoodSession.Regular) return ISettlementSource.Session.Regular;
        if (s == SherwoodSession.Post) return ISettlementSource.Session.AfterHours;
        if (s == SherwoodSession.Closed) return ISettlementSource.Session.Closed;
        return ISettlementSource.Session.Unknown;
    }
}
