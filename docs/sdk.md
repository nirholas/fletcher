# `@fletcher/sdk`

TypeScript for reading and writing Fletcher. Reads need no key and no account.

```bash
pnpm add @fletcher/sdk viem
```

## The arithmetic, without a chain

Every payoff function is pure and runs locally, so a UI can redraw a curve at sixty frames a second
without touching an RPC.

These are not approximations of the contracts. `contracts/test/Fixtures.t.sol` generates the answers
from the contracts themselves, and `packages/sdk/test/math.test.ts` asserts the TypeScript
reproduces them exactly. A contract change that moves a number fails both suites.

```ts
import {
  settlementShares, redeemValue, quoteLegs, turboLeverage, strikeForLeverage,
  floorDiscountBps, annualisedFundingBps, parseUsd, formatUsd, formatLeverage, WAD,
} from "@fletcher/sdk";
```

### Picking terms

Nobody thinks in strikes. They think in leverage.

```ts
const spot = parseUsd("178.50");
const strike = strikeForLeverage(spot, 20n * WAD);
formatUsd(strike);                          // "169.57"
formatLeverage(turboLeverage(spot, strike)); // "20.0x"
```

`turboLeverage` returns `0n` at or below the strike, where TURBO has no delta and leverage is
undefined rather than infinite. `strikeForLeverage` throws `RangeError` below 1x.

### The settlement split

```ts
const shares = settlementShares(parseUsd("200.00"), parseUsd("170.00"));
shares.floorPerUnit;  //  850000000000000000n   85%
shares.turboPerUnit;  //  150000000000000000n   15%
// always exactly 1e18 together

redeemValue(shares, 100n * WAD, 0n);  // 85e18 raw stock for 100 FLOOR
```

Throws `RangeError` on a zero close rather than dividing by it.

### Leg values now

```ts
const { floorValueX8, turboValueX8 } = quoteLegs(spot, strike, multiplier);
```

Intrinsic value, not market price. A dated TURBO trades above its intrinsic line for the same reason
any option does, and the gap is the thing a buyer is actually deciding about.

The two sum to `price × multiplier / 1e18`, within one wei from independent flooring, and never
above it.

### Reading the funding rate

Not published anywhere. Read it off FLOOR's market price:

```ts
const discount = floorDiscountBps(floorMarketPrice, strike);
formatBps(annualisedFundingBps(discount, 30));   // "12.16%"
```

Annualised simply, not compounded: these are dated instruments measured in days, and a compounded
figure would imply a rollover the holder has to actually achieve.

### Corporate actions

```ts
classifyMultiplier(WAD, 1_000_775_159_164_630_595n);  // { kind: "dividend", ... }
classifyMultiplier(WAD, 2n * WAD);                    // { kind: "split", ratioNum: 2n, ratioDen: 1n }
classifyMultiplier(WAD, 1_373_000_000_000_000_000n);  // { kind: "unknown", ... }

adjustStrike(parseUsd("170.00"), classifyMultiplier(WAD, 2n * WAD));  // 85e8
```

Mirrors `MultiplierAccountant` exactly, including the refusal. See
[`corporate-actions.md`](corporate-actions.md).

## Reading the chain

```ts
import { FletcherClient, publicClientFor } from "@fletcher/sdk";

const fletcher = new FletcherClient({
  factory: "0x...",
  launchpad: "0x...",
  settlementSource: "0x...",
  accountant: "0x...",
  depthGate: "0x...",
});

for (const address of await fletcher.listSeries()) {
  const s = await fletcher.getSeries(address);
  console.log(s.stockSymbol, formatUsd(s.strikeX8), s.settled ? "settled" : "live");
}
```

`getSeries` batches a series' reads into **one multicall**. A UI that fires fourteen sequential
reads per series renders a table of ten with a hundred and forty round trips, and this chain's
public endpoints rate limit well before that. For the same reason, iterate series sequentially
rather than with `Promise.all`.

### `SeriesState`

| Field | Meaning |
|---|---|
| `stock`, `stockSymbol` | the underlying equity |
| `floorToken`, `turboToken` | the two legs |
| `strikeX8` | current split point, after any split adjustments |
| `maturity`, `tradingDay` | when and against which day's close |
| `observedMultiplier` | the equity's `uiMultiplier()` as of the last sync |
| `settled`, `settlementPriceX8`, `shares` | `shares` is `null` until settled |
| `frozen` | an unclassifiable corporate action stopped settlement permanently |
| `isSynced` | false when halted **or** frozen |
| `collateralRaw`, `floorSupply`, `turboSupply` | the vault and both legs |

### Quoting a live series

```ts
const { floorValueX8, turboValueX8, leverage, shares } = fletcher.quote(series, parseUsd("185.00"));
```

Computed locally from the series' own terms.

## Writing

Every write **simulates before it sends**, so a refusal the contracts define arrives as that named
error rather than as a failed transaction.

```ts
import { createWalletClient, custom } from "viem";
import { robinhoodChain } from "@fletcher/sdk";

const wallet = createWalletClient({ account, chain: robinhoodChain, transport: custom(window.ethereum) });

await fletcher.createSeries(wallet, { stock, strikeX8, tradingDay, rawStock });
await fletcher.mint(wallet, series, rawStock);
await fletcher.merge(wallet, series, amount);
await fletcher.settle(wallet, series);
await fletcher.redeem(wallet, series, floorAmount, turboAmount);
await fletcher.launch(wallet, { stock, strikeX8, tradingDay, rawStock, referencePriceX8 });
await fletcher.collectFees(wallet, series);
```

`createSeries`, `mint` and `launch` need the caller to have approved the relevant contract for the
stock first.

## Chain constants

```ts
import { robinhoodChain, CHAIN_ID, RPC_URLS, USDG, UNISWAP_V4_POOL_MANAGER, EQUITIES } from "@fletcher/sdk";
```

`RPC_URLS.archive` is the only endpoint that serves **historical** state. The official RPC and
publicnode answer current reads but reject archive queries, which makes them unusable as a fork
source and for any backfill that walks logs. A tool that needs history and picks the wrong one fails
with `metadata` or `historical` errors that read like an outage. See
[`addresses.md`](addresses.md).

## Formatting

```ts
parseUsd("178.50");          // 17850000000n, tolerates thousands separators
formatUsd(17850000000n);     // "178.50"
formatUsd(17850000000n, 0);  // "178", no trailing dot
formatLeverage(21n * WAD);   // "21.0x"
tradingDayFor(new Date());   // days since the epoch
maturityFor(20344n);         // the series' maturity timestamp
```

## Scales

Kept deliberately distinct so a mismatch is a type error rather than a silent 1e10:

| Scale | Used for |
|---|---|
| `X8` (1e8) | USD per share. Every price and split point. |
| `WAD` (1e18) | every ratio, share and multiplier |
| raw | token base units. Equities are 18 decimals, **USDG is 6**. |
