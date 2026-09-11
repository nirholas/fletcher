// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3PoolMinimal {
    function liquidity() external view returns (uint128);
}

/// @title DepthGate
/// @notice Decides which equities may carry a series, from a book that was there for a while rather
/// than a book that is there right now.
///
/// The binding constraint on this protocol is not demand for leverage, it is the depth of the AMM
/// the two legs are eventually traded against and the vault eventually unwound into. A series
/// minted on a name with no book is a series whose holders cannot exit, however much they wanted
/// the exposure.
///
/// # Why this is not one read
///
/// An earlier version answered `qualifies` from a single call: the deepest pool's **token balance**,
/// read in the calling block. Both halves of that were wrong.
///
///   - **A balance is not a book.** ERC-20 balances can be raised by a plain transfer to the pool
///     address, which adds nothing tradeable. Even honestly, a v3 pool's balance includes liquidity
///     parked far out of range that no swap at the current price can ever touch.
///   - **One block is not a while.** Anything read in the calling block can be arranged in the
///     calling block. Flash-mint liquidity, create the series, withdraw, and a name with no book
///     has a live instrument on it.
///
/// So depth is `liquidity()`, the in-range liquidity a swap at the current price actually consumes,
/// and it has to hold across `REQUIRED_CHECKPOINTS` observations spanning `DEPTH_WINDOW`. Capital
/// held in range for eight hours is capital genuinely committed to the book, and no flash loan
/// survives a block boundary, let alone three of them.
///
/// Checkpointing is permissionless and takes no discretion: the caller chooses when to observe, not
/// what is observed, and a name only qualifies if **every** retained observation clears the floor.
/// Choosing the moment can therefore only ever make a name look worse.
contract DepthGate {
    /// @notice Uniswap v3 factory on Robinhood Chain.
    IUniswapV3Factory public immutable v3Factory;

    /// @notice The asset equities are quoted in. USDG on 4663.
    address public immutable quote;

    /// @notice Fee tiers searched for the deepest pool.
    uint24[4] public feeTiers = [uint24(100), 500, 3000, 10000];

    /// @notice Minimum in-range liquidity for a name to carry a series.
    uint128 public immutable minLiquidity;

    /// @notice Observations that must all clear the floor.
    uint256 public constant REQUIRED_CHECKPOINTS = 3;

    /// @notice The span the retained observations must cover.
    uint256 public constant DEPTH_WINDOW = 8 hours;

    /// @notice Minimum spacing between observations, so the window cannot be filled in one block.
    uint256 public constant MIN_CHECKPOINT_INTERVAL = 2 hours;

    struct Observation {
        uint64 at;
        uint128 liquidity;
    }

    /// @dev A ring of the last `REQUIRED_CHECKPOINTS` observations per name.
    mapping(address => Observation[REQUIRED_CHECKPOINTS]) internal ring;
    mapping(address => uint256) internal ringNext;

    event Checkpointed(address indexed stock, uint128 liquidity, address pool, uint256 at);

    error TooSoon(address stock, uint256 nextAllowedAt);
    error NoPool(address stock);

    constructor(address v3Factory_, address quote_, uint128 minLiquidity_) {
        v3Factory = IUniswapV3Factory(v3Factory_);
        quote = quote_;
        minLiquidity = minLiquidity_;
    }

    /// @notice In-range liquidity of the deepest quote-paired pool for `stock`, right now.
    /// @dev A point reading. It is what `checkpoint` records; it is NOT what `qualifies` answers
    /// from, precisely because a point reading is arrangeable.
    function currentLiquidity(address stock) public view returns (uint128 depth, address deepestPool) {
        for (uint256 i = 0; i < 4; ++i) {
            address pool = v3Factory.getPool(stock, quote, feeTiers[i]);
            if (pool == address(0)) continue;
            uint128 liquidity = IUniswapV3PoolMinimal(pool).liquidity();
            if (liquidity > depth) {
                depth = liquidity;
                deepestPool = pool;
            }
        }
    }

    /// @notice Record one observation of `stock`'s depth. Permissionless.
    function checkpoint(address stock) external returns (uint128 depth) {
        uint256 last = _lastAt(stock);
        if (last != 0 && block.timestamp < last + MIN_CHECKPOINT_INTERVAL) {
            revert TooSoon(stock, last + MIN_CHECKPOINT_INTERVAL);
        }

        address pool;
        (depth, pool) = currentLiquidity(stock);
        if (pool == address(0)) revert NoPool(stock);

        uint256 slot = ringNext[stock];
        ring[stock][slot] = Observation({at: uint64(block.timestamp), liquidity: depth});
        ringNext[stock] = (slot + 1) % REQUIRED_CHECKPOINTS;
        emit Checkpointed(stock, depth, pool, block.timestamp);
    }

    /// @notice Whether `stock` may carry a series.
    ///
    /// Every retained observation must clear the floor and the oldest must be at least
    /// `DEPTH_WINDOW` old, so a name qualifies on a book that was there for the whole window rather
    /// than one that appeared for a block.
    function qualifies(address stock) external view returns (bool) {
        uint256 oldest = type(uint256).max;
        for (uint256 i = 0; i < REQUIRED_CHECKPOINTS; ++i) {
            Observation memory o = ring[stock][i];
            if (o.at == 0) return false;
            if (o.liquidity < minLiquidity) return false;
            if (o.at < oldest) oldest = o.at;
        }
        return block.timestamp >= oldest + DEPTH_WINDOW;
    }

    /// @notice The retained observations for `stock`, oldest first by timestamp.
    /// @dev Exposed so a caller refused by `qualifies` can see which observation failed and when the
    /// name would next become listable, rather than being told only that it did not qualify.
    function observations(address stock) external view returns (Observation[REQUIRED_CHECKPOINTS] memory) {
        return ring[stock];
    }

    /// @notice When `checkpoint` may next be called for `stock`.
    function nextCheckpointAt(address stock) external view returns (uint256) {
        uint256 last = _lastAt(stock);
        return last == 0 ? block.timestamp : last + MIN_CHECKPOINT_INTERVAL;
    }

    function _lastAt(address stock) internal view returns (uint256 last) {
        for (uint256 i = 0; i < REQUIRED_CHECKPOINTS; ++i) {
            uint256 at = ring[stock][i].at;
            if (at > last) last = at;
        }
    }
}
