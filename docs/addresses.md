# Addresses

Every Robinhood Chain address Fletcher depends on, and how each was verified.

Chain: **`eip155:4663`**. Explorer: [robinhoodchain.blockscout.com](https://robinhoodchain.blockscout.com).

## Endpoints

| Endpoint | Current reads | Historical state |
|---|---|---|
| `https://rpc-robinhood.blockmachine.io` | yes | **yes** |
| `https://rpc.mainnet.chain.robinhood.com` | yes | no |
| `https://robinhood-rpc.publicnode.com` | yes | no |
| `https://robinhood.drpc.org` | partial | no |

Only the first serves archive queries. The others reject them with `metadata` or `historical`
errors that read like an outage, which makes them unusable as an anvil fork source and for any
backfill that walks logs. `drpc` additionally refuses `eth_blockNumber` and
`eth_getTransactionCount`, so `cast` calls against it fail before they reach a contract.

All of them rate limit. Fletcher's UI reads series sequentially rather than concurrently for this
reason.

## Tokenized equities

| What | Address |
|---|---|
| Shared `Stock` implementation | `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2` |
| Registry / beacon (`AccessControlsRegistry`) | `0xe10b6f6B275de231345c20D14Ab812db62151b00` |
| NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` |
| SPY | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` |

All 254 equities are beacon proxies onto **one** implementation, so the surface is uniform across
every name Fletcher could list, and one upgrade moves all of them.

Verified at block 59,698,078 (10 September 2026), and re-checked on every fork-test run:

```
NVDA symbol          "NVDA"
NVDA decimals        18
NVDA uiMultiplier    1000775159164630595   (1.000775e18)
NVDA newUIMultiplier 1000775159164630595   (nothing pending)
NVDA effectiveAt     1788998430            (2026-09-10T00:00:30Z)
NVDA tokenPaused     false
NVDA paused          false
NVDA oraclePaused    false
```

That multiplier read exactly `1e18` on 7 September, so the 7.75 basis point rise is a real
distribution captured live. `contracts/test/fork/LiveChain.t.sol` asserts it classifies as a
dividend.

### The surface Fletcher reads

| Function | Why |
|---|---|
| `uiMultiplier()` | ERC-8056 corporate-action accounting |
| `newUIMultiplier()`, `effectiveAt()` | scheduled actions, readable before they land |
| `tokenPaused()` | this equity is halted |
| `paused()` | registry-wide halt, all 254 at once |
| `oraclePaused()` | the issuer's own feed is halted |

Note `isSynced()` does **not** exist on the token or the registry; both revert. `Series.isSynced()`
is Fletcher's own view over the pause flags and its freeze state, named for the vocabulary the rest
of the ecosystem uses.

## Quote asset

| What | Address | Decimals |
|---|---|---|
| USDG (Global Dollar) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | **6** |

Six, not eighteen. Nothing in Fletcher may assume the quote and the equity share a scale; the fork
tests assert the difference.

USDG has **no EIP-3009 and no EIP-2612**. It is Permit2-only. The `Stock` tokens *do* have EIP-2612
permit.

## Uniswap

| What | Address |
|---|---|
| v3 factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| v3 QuoterV2 | `0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7` |
| v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| v4 PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| v4 StateView | `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b` |
| v4 Quoter | `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` |

The v3 factory and v4 PoolManager are asserted to hold code by the fork tests, and the launchpad
suite runs against a `PoolManager` deployed from Uniswap's own source.

**A trap inherited from [Quiver](https://github.com/nirholas/quiver):** Robinhood Chain's
`UniversalRouter` is a modified build whose `V2_SWAP_EXACT_IN` and `V3_SWAP_EXACT_IN` inputs take a
sixth argument, `uint256[] minHopPriceX36`. Standard encodings revert with `SliceOutOfBounds()`
(`0x3b99b53d`). Fletcher does not use `UniversalRouter`, but anything built beside it should know.

## Verified pools

| Pair | Address | Fee | Notes |
|---|---|---|---|
| NVDA/USDG | `0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3` | 0.05% | USDG is token0 |
| SPY/USDG | `0xa7Bb1AC63BBaB0C44316E6c8C455213441689167` | 0.05% | observation cardinality 1801, so TWAPs work |

`DepthGate` finds the NVDA pool by searching fee tiers against the live v3 factory; the fork test
asserts it lands on exactly this address rather than on a hardcoded value.

## Launchpads

| What | Address |
|---|---|
| PAIR V5 | `0x8660a7f019c7943b0b0a91b8e39aff3b6db6ae62` |
| Pons V2 | `0xe33E9E479dF8802cb0866d5d05258bEc4cF62948` |

Prior art rather than dependencies. Fletcher calls neither. See [`launchpad.md`](launchpad.md).

## Fletcher

**Not deployed.** No mainnet addresses exist yet, and the Sherwood oracle it settles against is not
deployed either.

Deployment writes them to stdout:

```bash
SHERWOOD_ORACLE=0x... forge script script/Deploy.s.sol \
  --root contracts --rpc-url $RHC_RPC_URL --broadcast
```

`FletcherFactory` deploys each series with CREATE2 over `(stock, strike, tradingDay)`, so a series
address is computable from its terms before it exists via `computeSeriesAddress`.

## How to re-verify any of this

```bash
export RHC_RPC_URL=https://rpc-robinhood.blockmachine.io
forge test --root contracts --match-path 'test/fork/*' -vv
```

Ten tests, pinned to block 59,698,078. They skip with no endpoint set and fail on a broken one.
Check the gas figures: `test_depthGateMeasuresRealLiquidity` burns roughly 465k gas doing real chain
reads, and a suite that silently degraded to asserting nothing would show a few thousand.
