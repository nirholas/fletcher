// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice A Uniswap v3 pool whose in-range liquidity the test sets directly.
contract V3PoolHarness {
    uint128 internal current;

    constructor(uint128 liquidity_) {
        current = liquidity_;
    }

    function setLiquidity(uint128 liquidity_) external {
        current = liquidity_;
    }

    function liquidity() external view returns (uint128) {
        return current;
    }
}

/// @notice A Uniswap v3 factory that deploys those pools on demand.
///
/// `DepthGate` asks two questions of Uniswap: which pool exists for a pair and fee tier, and how
/// much in-range liquidity that pool holds. Driving the second one directly is what lets a test
/// show that liquidity present for a single block never qualifies a name, which is the property
/// that matters. The pool has to be a real separate contract, because the gate calls
/// `liquidity()` on the address the factory hands back.
contract UniswapV3Harness {
    mapping(bytes32 => address) internal pools;

    function setPool(address tokenA, address tokenB, uint24 fee, uint128 liquidity_) external returns (address pool) {
        bytes32 key = _key(tokenA, tokenB, fee);
        pool = pools[key];
        if (pool == address(0)) {
            pool = address(new V3PoolHarness(liquidity_));
            pools[key] = pool;
        } else {
            V3PoolHarness(pool).setLiquidity(liquidity_);
        }
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_key(tokenA, tokenB, fee)];
    }

    /// @dev Pools are looked up by an unordered pair, the way the real factory does it.
    function _key(address a, address b, uint24 fee) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b, fee)) : keccak256(abi.encode(b, a, fee));
    }
}
