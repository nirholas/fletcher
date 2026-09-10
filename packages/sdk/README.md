# `@fletcher/sdk`

TypeScript for Fletcher. Reads need no key and no account.

```bash
pnpm add @fletcher/sdk viem
```

```ts
import { FletcherClient, parseUsd, strikeForLeverage, formatLeverage, WAD } from "@fletcher/sdk";

// Pick a leverage, not a strike.
const spot = parseUsd("178.50");
const strike = strikeForLeverage(spot, 20n * WAD);        // 169.57

const fletcher = new FletcherClient(addresses);
const series = await fletcher.getSeries("0x...");
const { floorValueX8, turboValueX8, leverage } = fletcher.quote(series, spot);
formatLeverage(leverage);                                  // "20.0x"
```

## What is in it

- **`math.ts`** the settlement split, leg valuation, leverage, the funding rate, and the
  corporate-action classifier. All pure, so a UI can redraw a payoff curve without an RPC round trip
  per frame.
- **`client.ts`** `FletcherClient`, batching a series' reads into one multicall and simulating every
  write before it sends.
- **`chain.ts`** the verified Robinhood Chain address book, and which endpoint serves archive state.
- **`abis.ts`** generated from the Foundry artifacts by `scripts/extract-abis.mjs`, never hand-written.

## Parity with the contracts

`math.ts` reimplements arithmetic that also exists in Solidity. Two implementations of one
calculation drift, and the drift would surface as a quoted payout the contract will not pay.

So the contracts are the source of truth: `contracts/test/Fixtures.t.sol` generates the answers and
`test/math.test.ts` asserts the TypeScript reproduces them exactly. Both directions are gated, so a
contract change that moves a number fails the Solidity suite too.

```bash
pnpm test                                                    # 47 tests, 17 parity cases
FLETCHER_WRITE_FIXTURES=1 forge test --root ../../contracts --match-path 'test/Fixtures.t.sol'
```

Full reference: [`../../docs/sdk.md`](../../docs/sdk.md).
