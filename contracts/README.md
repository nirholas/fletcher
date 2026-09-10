# Fletcher contracts

Foundry. No owner, no upgrade path, no pause, no fee.

```bash
forge build --root .
forge test --root .                       # 65 tests; the 10 fork tests skip without an endpoint
RHC_RPC_URL=https://rpc-robinhood.blockmachine.io forge test --root . --match-path 'test/fork/*'
```

## What each contract is

| Contract | Responsibility |
|---|---|
| [`Series.sol`](src/Series.sol) | One dated split of one equity. Holds the collateral, mints and burns both legs, settles once, pays redemptions. The whole protocol is four functions here. |
| [`SeriesToken.sol`](src/SeriesToken.sol) | One leg, as a plain ERC-20 whose supply only its `Series` can move. |
| [`FletcherFactory.sol`](src/FletcherFactory.sol) | Permissionless creation. CREATE2 over `(stock, strike, tradingDay)`, so terms name exactly one address. Enforces depth qualification, the strike band, the tenor limit and the notional cap. |
| [`MultiplierAccountant.sol`](src/MultiplierAccountant.sol) | Tells a dividend from a split by shape, and refuses on anything else. The hardest piece. |
| [`DepthGate.sol`](src/DepthGate.sol) | Reads the deepest quote-paired Uniswap v3 pool and decides which names may carry a series, and how large. |
| [`FletcherLaunchpad.sol`](src/FletcherLaunchpad.sol) | Opens a series and seeds both legs into locked Uniswap v4 pools, paying the launcher the swap fees forever. |
| [`adapters/SherwoodSettlementSource.sol`](src/adapters/SherwoodSettlementSource.sol) | Freezes Sherwood's live quote into a write-once dated close per trading day. |

Two interfaces are deliberately seams rather than internals, so a deployment can point at a
different implementation without a fork: [`IMultiplierAccountant`](src/interfaces/IMultiplierAccountant.sol)
and [`ISettlementSource`](src/interfaces/ISettlementSource.sol).

## Build notes

Pinned to **solc 0.8.26** and the **legacy pipeline** (`via_ir = false`), both inherited from
Uniswap v4-core: `PoolManager.sol` requires exactly 0.8.26, the launchpad links against it in one
compilation unit, and that contract does not fit through the IR pipeline's stack allocator. Nothing
in Fletcher needs a later compiler, so matching means the v4 code runs at the version Uniswap
audited rather than one it was forced onto.

`src` is held to a zero-warning lint standard; tests are excluded, because the linter fires on casts
whose inputs came from `bound()` and cannot truncate, and annotating each one buries the signal.

## Deploying

```bash
SHERWOOD_ORACLE=0x... forge script script/Deploy.s.sol --rpc-url $RHC_RPC_URL --broadcast
```

Optional overrides, all defaulting to verified Robinhood Chain addresses: `UNISWAP_V3_FACTORY`,
`UNISWAP_V4_POOL_MANAGER`, `QUOTE_TOKEN`, `MIN_DEPTH_RAW`, `DEPTH_CAP_BPS`.

Full documentation: [`../docs/protocol.md`](../docs/protocol.md).
