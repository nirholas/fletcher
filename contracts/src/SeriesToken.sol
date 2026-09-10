// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice One leg of a dated series: a plain ERC-20 whose supply only its `Series` can move.
///
/// Both legs are ordinary tokens on purpose. A series is a single ERC-20 per leg rather than a
/// position NFT or an option grid, so all of a name's leverage demand concentrates into two
/// tradeable tokens instead of fragmenting across dozens of strikes that each carry their own
/// shallow book. That concentration is the whole liquidity argument for this shape.
contract SeriesToken is ERC20 {
    /// @notice The series that mints and burns this leg. Immutable, set at construction.
    address public immutable series;

    string internal _name;
    string internal _symbol;

    error OnlySeries();

    constructor(string memory name_, string memory symbol_) {
        series = msg.sender;
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @dev Legs inherit the underlying equity's 18 decimals so one leg unit corresponds to one raw
    /// unit of deposited stock and no conversion is needed anywhere in the protocol.
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != series) revert OnlySeries();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != series) revert OnlySeries();
        _burn(from, amount);
    }
}
