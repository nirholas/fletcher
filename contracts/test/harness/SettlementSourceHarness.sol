// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISettlementSource} from "../../src/interfaces/ISettlementSource.sol";

/// @notice A settlement source whose prints the test sets directly.
///
/// `SherwoodSettlementSource` is the production adapter and is covered by its own tests against a
/// Sherwood oracle harness. This one exists so a series test can put an exact close on the board
/// and assert the payout arithmetic against it, which is the thing those tests are actually about.
contract SettlementSourceHarness is ISettlementSource {
    mapping(address => mapping(uint64 => uint256)) public prices;
    mapping(address => mapping(uint64 => bool)) public recorded;
    mapping(address => Session) public sessions;

    error NoClose();

    function setClose(address stock, uint64 day, uint256 priceX8) external {
        prices[stock][day] = priceX8;
        recorded[stock][day] = true;
    }

    function clearClose(address stock, uint64 day) external {
        recorded[stock][day] = false;
    }

    function setSession(address stock, Session s) external {
        sessions[stock] = s;
    }

    function officialClose(address stock, uint64 day) external view returns (uint256, uint64) {
        if (!recorded[stock][day]) revert NoClose();
        return (prices[stock][day], uint64(block.timestamp));
    }

    function hasClose(address stock, uint64 day) external view returns (bool) {
        return recorded[stock][day];
    }

    function sessionOf(address stock) external view returns (Session) {
        return sessions[stock];
    }
}
