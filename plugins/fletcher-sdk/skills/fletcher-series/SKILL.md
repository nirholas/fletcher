---
name: fletcher-series
description: Quote and read Fletcher FLOOR/TURBO series on Robinhood Chain with the @fletcher/sdk TypeScript package. Use when the user wants leverage-to-strike math, settlement splits, leg values, funding rates or on-chain series state.
---

# Fletcher SDK

Fletcher splits a tokenized stock into a FLOOR leg (capped first claim) and a TURBO leg (the residual) for one dated series on Robinhood Chain (chain id 4663). `@fletcher/sdk` is a workspace package in https://github.com/nirholas/fletcher and is not published to npm, so use it from a clone.

## Setup

```bash
git clone https://github.com/nirholas/fletcher && cd fletcher
pnpm install
pnpm --filter @fletcher/sdk build      # emits packages/sdk/dist
pnpm --filter @fletcher/sdk test       # parity tests against the Solidity fixtures
```

Reads need no key and no account. The SDK depends on `viem`.

## Pure math (no RPC)

Exported from `packages/sdk/src/math.ts`: `settlementShares`, `redeemValue`, `quoteLegs`, `turboLeverage`, `strikeForLeverage`, `floorDiscountBps`, `annualisedFundingBps`, `classifyMultiplier`, `adjustStrike`, plus `parseUsd`, `formatUsd`, `formatLeverage`, `formatBps`, `WAD`.

```ts
import { parseUsd, formatUsd, formatLeverage, strikeForLeverage, turboLeverage, settlementShares, WAD } from "@fletcher/sdk";

const spot = parseUsd("178.50");
const strike = strikeForLeverage(spot, 20n * WAD);        // throws RangeError below 1x
formatUsd(strike);                                        // "169.57"
formatLeverage(turboLeverage(spot, strike));              // "20.0x"
const shares = settlementShares(parseUsd("200.00"), parseUsd("170.00"));
// shares.floorPerUnit = 85e16, shares.turboPerUnit = 15e16, always summing to 1e18
```

`turboLeverage` returns `0n` at or below the strike. `settlementShares` throws `RangeError` on a zero close. Values are intrinsic, not market prices.

## Reading series

```ts
import { FletcherClient, formatUsd } from "@fletcher/sdk";

const fletcher = new FletcherClient({ factory, launchpad, settlementSource, accountant, depthGate }); // addresses from the deployment
for (const address of await fletcher.listSeries()) {          // iterate sequentially, public RPCs rate limit
  const s = await fletcher.getSeries(address);                // one multicall
  console.log(s.stockSymbol, formatUsd(s.strikeX8), s.settled ? "settled" : "live");
}
const { floorValueX8, turboValueX8, leverage } = fletcher.quote(s, parseUsd("185.00"));
```

`SeriesState` includes `strikeX8`, `maturity`, `settled`, `settlementPriceX8`, `shares` (null until settled), `frozen` and `isSynced`. `chain.ts` exports `CHAIN_ID`, `RPC_URLS`, `EXPLORER_URL`, `robinhoodChain`, and `publicClientFor(rpcUrl)`.

## Writes

`createSeries`, `mint`, `merge`, `settle`, `redeem`, `launch` and `collectFees` take a viem `WalletClient` and simulate before sending. They sign real transactions: show the user the series, amount and chain and get an explicit yes before calling any of them.

## Other parts of the repo

- `contracts/`: Foundry project. `pnpm test:contracts` runs `forge test --root contracts`.
- `apps/keeper`: records official closes and settles matured series. `pnpm --filter @fletcher/keeper check` is a dry run (`tsx src/index.ts --dry-run --once`).
- `docs/sdk.md` is the full reference.
