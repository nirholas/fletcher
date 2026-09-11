// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

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
    mapping(address => uint256) public referenceOf;

    error NoClose();
    error NoReference();

    function setClose(address stock, uint64 day, uint256 priceX8) external {
        prices[stock][day] = priceX8;
        recorded[stock][day] = true;
        // A recorded close also makes a sensible default reference, so a test that only cares about
        // settlement does not have to set both.
        if (referenceOf[stock] == 0) referenceOf[stock] = priceX8;
    }

    function setReference(address stock, uint256 priceX8) external {
        referenceOf[stock] = priceX8;
    }

    function clearReference(address stock) external {
        referenceOf[stock] = 0;
    }

    function referencePrice(address stock) external view returns (uint256, uint64) {
        uint256 p = referenceOf[stock];
        if (p == 0) revert NoReference();
        return (p, uint64(block.timestamp));
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
