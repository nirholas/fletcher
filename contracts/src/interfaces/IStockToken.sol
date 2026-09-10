// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice A Robinhood Chain tokenized equity.
///
/// Every one of the 254 equities on chain 4663 is a beacon proxy onto a single shared `Stock`
/// implementation, so this surface is identical for all of them. Only the parts Fletcher depends on
/// are declared here.
///
/// Two facts drive the whole protocol:
///
/// 1. `uiMultiplier()` is ERC-8056 corporate-action accounting. A raw ERC-20 balance never changes
///    on a dividend or a split; the multiplier does. Value of a position is
///    `raw * uiMultiplier / 1e18 * pricePerShare`, and the multiplier only ever rises.
/// 2. The pause surface is three-layered and, while any layer is engaged, `transfer` itself
///    reverts. Collateral cannot be moved at any price, which is why Fletcher has no liquidation
///    engine to be starved: it never needs to seize anything.
interface IStockToken {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Current corporate-action multiplier, 1e18-scaled. Monotonically non-decreasing.
    function uiMultiplier() external view returns (uint256);

    /// @notice The multiplier that takes effect at `effectiveAt()`. Equal to `uiMultiplier()` when
    /// nothing is scheduled, which is how a pending corporate action is detected before it lands.
    function newUIMultiplier() external view returns (uint256);

    /// @notice Unix timestamp at which `newUIMultiplier()` becomes `uiMultiplier()`.
    function effectiveAt() external view returns (uint256);

    /// @notice This equity is individually halted.
    function tokenPaused() external view returns (bool);

    /// @notice The registry-wide halt: true stops all 254 equities at once.
    function paused() external view returns (bool);

    /// @notice The equity's own price feed is halted while its transfers may still be live.
    function oraclePaused() external view returns (bool);
}
