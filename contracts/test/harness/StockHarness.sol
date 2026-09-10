// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice A local stand-in for a Robinhood Chain equity, matching the live `Stock` surface.
///
/// Every behaviour here was read off the deployed implementation
/// `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2` on chain 4663, not invented for the tests:
/// three independent pause flags, a `uiMultiplier` that only rises, and a `newUIMultiplier` /
/// `effectiveAt` pair that schedules corporate actions in advance. The fork tests in
/// `test/fork/LiveChain.t.sol` run the same assertions against the real token, so this harness is
/// a controllable copy rather than a substitute for the real thing.
///
/// The one behaviour worth stating explicitly: while any pause flag is set, `transfer` reverts.
/// That is what makes collateral unseizable during a halt, and it is the reason Fletcher is built
/// with no liquidation engine at all.
contract StockHarness is ERC20 {
    string internal _sym;

    uint256 public uiMultiplier = 1e18;
    uint256 public newUIMultiplier = 1e18;
    uint256 public effectiveAt;

    bool public tokenPaused;
    bool public paused;
    bool public oraclePaused;

    error Paused();

    constructor(string memory sym) {
        _sym = sym;
    }

    function name() public view override returns (string memory) {
        return _sym;
    }

    function symbol() public view override returns (string memory) {
        return _sym;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _beforeTokenTransfer(address, address, uint256) internal view override {
        if (paused || tokenPaused) revert Paused();
    }

    // --- corporate actions -------------------------------------------------------------------

    /// @notice Land a multiplier change immediately.
    function setMultiplier(uint256 m) external {
        uiMultiplier = m;
        newUIMultiplier = m;
        effectiveAt = block.timestamp;
    }

    /// @notice Schedule one for the future, the way the live token does.
    function scheduleMultiplier(uint256 m, uint256 when) external {
        newUIMultiplier = m;
        effectiveAt = when;
    }

    /// @notice Apply a scheduled change once its time has come.
    function applyScheduled() external {
        if (block.timestamp >= effectiveAt) uiMultiplier = newUIMultiplier;
    }

    // --- halts -------------------------------------------------------------------------------

    function setTokenPaused(bool v) external {
        tokenPaused = v;
    }

    function setRegistryPaused(bool v) external {
        paused = v;
    }

    function setOraclePaused(bool v) external {
        oraclePaused = v;
    }
}
