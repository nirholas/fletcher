// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice A depth gate whose measurement the test sets directly.
///
/// The real `DepthGate` reads Uniswap v3 pool reserves, and is covered against live pools in
/// `test/fork/LiveChain.t.sol`. These tests are about what the factory and launchpad do with a
/// qualification, not about how it is measured.
contract DepthGateHarness {
    mapping(address => uint256) public depth;
    uint256 public capBps = 10_000;

    function setDepth(address stock, uint256 d) external {
        depth[stock] = d;
    }

    function setCapBps(uint256 b) external {
        capBps = b;
    }

    function measuredDepth(address stock) external view returns (uint256, address) {
        return (depth[stock], address(0));
    }

    function qualifies(address stock) external view returns (bool) {
        return depth[stock] > 0;
    }

    function notionalCapRaw(address stock) external view returns (uint256) {
        return (depth[stock] * capBps) / 10_000;
    }
}
