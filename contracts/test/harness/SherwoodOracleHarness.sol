// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SherwoodSession, SherwoodPriceStatus} from "../../src/adapters/SherwoodSettlementSource.sol";

/// @notice A Sherwood oracle whose price, session and status the test sets directly.
///
/// The real oracle lives in a separate repository and is not deployed. What
/// `SherwoodSettlementSource` needs from it is exactly three reads, and the adapter's whole job is
/// deciding which combinations of them may be recorded, so a harness that can produce every
/// combination is the right way to test that decision.
contract SherwoodOracleHarness {
    struct State {
        uint256 priceX8;
        SherwoodSession session;
        SherwoodPriceStatus status;
    }

    mapping(address => State) internal state;

    function set(address asset, uint256 priceX8, SherwoodSession session, SherwoodPriceStatus status) external {
        state[asset] = State({priceX8: priceX8, session: session, status: status});
    }

    function peek(address asset) external view returns (uint256, SherwoodPriceStatus) {
        State memory s = state[asset];
        return (s.priceX8 * 1e18, s.status);
    }

    function pricePerShare1e8(address asset) external view returns (uint256) {
        return state[asset].priceX8;
    }

    function sessionOf(address asset) external view returns (SherwoodSession) {
        return state[asset].session;
    }
}
