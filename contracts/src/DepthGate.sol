// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStockToken} from "./interfaces/IStockToken.sol";

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3PoolMinimal {
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

/// @title DepthGate
/// @notice Decides which equities may carry a series, and how large that series may get.
///
/// The binding constraint on this protocol is not demand for leverage, it is the depth of the
/// stock-token AMM the two legs must eventually be traded against and the vault must eventually be
/// unwound into. A series minted on a name with $40k of on-chain depth is a series whose holders
/// cannot exit, however much they wanted the exposure.
///
/// So creation is gated on measured depth and the outstanding notional per name is capped at a
/// fraction of it. This is also the menu discipline the launchpad needs: the market picks which
/// split points survive, but it does not get to pick which underlyings are liquid enough to carry
/// one.
///
/// Depth is read from the deepest Uniswap v3 pool the equity has against the quote asset, measured
/// as that pool's stock-token balance. Concentrated liquidity means a balance is not a complete
/// picture of a book, but it IS a hard ceiling on what the pool can ever sell, which is the number
/// a cap wants. `SherwoodOracle` already proved the observation cardinality on these pools supports
/// TWAPs; this contract needs only the reserve.
contract DepthGate {
    /// @notice Uniswap v3 factory on Robinhood Chain.
    IUniswapV3Factory public immutable v3Factory;

    /// @notice The asset equities are quoted in. USDG on 4663.
    address public immutable quote;

    /// @notice Fee tiers searched for the deepest pool.
    uint24[4] public feeTiers = [uint24(100), 500, 3000, 10000];

    /// @notice Minimum pool stock balance, in raw stock units, for a name to carry any series.
    uint256 public immutable minDepthRaw;

    /// @notice Outstanding series notional allowed per name, in basis points of measured depth.
    uint256 public immutable capBps;

    uint256 internal constant BPS = 10_000;

    constructor(address v3Factory_, address quote_, uint256 minDepthRaw_, uint256 capBps_) {
        v3Factory = IUniswapV3Factory(v3Factory_);
        quote = quote_;
        minDepthRaw = minDepthRaw_;
        capBps = capBps_;
    }

    /// @notice Raw stock held by the deepest quote-paired pool for `stock`, and that pool's address.
    function measuredDepth(address stock) public view returns (uint256 depthRaw, address deepestPool) {
        for (uint256 i = 0; i < 4; ++i) {
            address pool = v3Factory.getPool(stock, quote, feeTiers[i]);
            if (pool == address(0)) continue;
            // A pool that has never been initialised reports zero liquidity; skip it rather than
            // counting a balance nobody can trade against.
            if (IUniswapV3PoolMinimal(pool).liquidity() == 0) continue;
            uint256 bal = IStockToken(stock).balanceOf(pool);
            if (bal > depthRaw) {
                depthRaw = bal;
                deepestPool = pool;
            }
        }
    }

    /// @notice Whether `stock` may carry a series at all.
    function qualifies(address stock) external view returns (bool) {
        (uint256 depth,) = measuredDepth(stock);
        return depth >= minDepthRaw;
    }

    /// @notice The largest total raw stock all live series on `stock` may hold at once.
    function notionalCapRaw(address stock) external view returns (uint256) {
        (uint256 depth,) = measuredDepth(stock);
        if (depth < minDepthRaw) return 0;
        return (depth * capBps) / BPS;
    }
}
