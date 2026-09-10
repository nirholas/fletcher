# Fletcher

**Turbos and floors for tokenized stocks, on Robinhood Chain.**

Deposit one tokenized share. The contract mints two ERC-20s against it:

- **FLOOR** takes the first claim on the share, up to a split point, plus the dividend accrual.
- **TURBO** takes everything above the split point, and nothing below it. Roughly 20x leverage at mint.

The two together are always exactly the share, so the vault is fully collateralised at every
possible settlement price. There is no liquidation engine, no margin call, no protocol balance
sheet and no bad debt. Merge both halves back into the stock, free, any time.

```
mint    R stock in         →  R FLOOR + R TURBO out
merge   R FLOOR + R TURBO  →  R stock out            free, any time
settle  once, at maturity, against the official close print
redeem  each leg claims its share of the same vault
```

---

## Why this shape

**0DTE is Robinhood's volume engine, and turbos are the instrument that survives outside the US.**
ESMA killed binaries and capped CFDs; knock-out certificates remain securities and are already a
large retail product in Germany, the Netherlands and the Nordics. This is that instrument, dated
daily, on chain.

**The structure has forty years of precedent.** Canadian split-share corporations do exactly this:
one underlying, a preferred share taking a capped first claim and a capital share taking the
residual. Fletcher is that, with a public split point and a free merge.

**Two retail cohorts underwrite each other.** FLOOR is a fixed-term savings buyer. TURBO is a
leverage buyer. Neither is quoted a rate by the protocol: the funding rate is whatever discount
FLOOR trades at, set by the two books clearing against each other. Nothing is published, nothing is
governed.

**Liquidity concentrates instead of fragmenting.** Each series is a single ERC-20 per leg, so a
name's leverage demand lands in two tradeable tokens rather than spreading across an option grid of
dozens of shallow strikes.

No options venue is live on Robinhood Chain. Fletcher is the first dated, leveraged instrument on
the chain that settles against the real equity rather than against a pool.

---

## Why there is no liquidation engine

At settlement with close `P` and split point `K`, the vault's raw stock `R` divides as:

```
floorStock = R * min(P, K) / P
turboStock = R - floorStock
```

Those sum to `R` for every `P > 0`: `P` far above `K`, `P` collapsing toward zero, `P` exactly at
`K`. TURBO's leverage comes from the split point sitting just under the share price, not from
borrowing, so there is nothing to margin call.

That matters more on this chain than on most. While a tokenized equity is halted its `transfer`
reverts outright, so a protocol that *needed* to seize collateral could not do it at any incentive,
at any price. Fletcher never needs to. This is the same halt problem
[Sherwood](https://github.com/nirholas/sherwood) and [TECHDOLLAR](https://github.com/nirholas/techdollar)
are built around, answered by removing the seizure rather than pricing it.

---

## Why it never settles against a pool

On 30 August a launchpad-created AMC pair traded **35x above the real equity** across a weekend,
with the equity market shut and no arbitrageur able to close it. That price was real, on chain, and
completely wrong. A protocol that settled against it would have handed TURBO the entire vault on a
print that never existed.

A series settles on an **official close carried by a quorum of signed reporter quotes**, and refuses
to settle at all unless the session is closed and the quote is usable. The pool is where the legs
trade. It is never what they settle against.

Fletcher consumes [Sherwood's oracle](https://github.com/nirholas/sherwood) rather than shipping a
second one: a second oracle with a second reporter set is a second thing to get wrong.
`SherwoodSettlementSource` freezes that live quote into a dated, write-once close per trading day.

---

## Corporate actions, and the one genuinely hard problem

A tokenized equity carries dividends and splits in a single ERC-8056 number, `uiMultiplier()`. Those
two events need **opposite** treatment, and telling them apart is the hardest thing in this
protocol:

| Event | Shape | What happens to the split point | Why |
|---|---|---|---|
| **Distribution** | a rise of a few basis points | nothing | FLOOR's claim is `multiplier × min(price, strike)`, so leaving the strike alone is exactly what hands the accrual to FLOOR |
| **Split** | a clean ratio, 20%+ from 1 | divided by the ratio | a 2:1 on a $170 strike would otherwise leave FLOOR claiming `2 × min($85, $170)`, the whole vault, and zero TURBO |
| **Anything else** | neither shape | series freezes | see below |

This is not theoretical. NVDA's live multiplier on 4663 read exactly `1e18` on 7 September 2026 and
`1.000775159164630595e18` on 10 September: a 7.75 basis point distribution, effective
`2026-09-10T00:00:30Z`. `contracts/test/fork/LiveChain.t.sol` asserts that real accrual classifies as
a dividend against the live chain.

**The third outcome is a first-class answer, not a failure.** A change that is neither a small rise
nor a clean ratio freezes the series into merge-only. Nobody is liquidated, nobody is settled at a
strike nobody can defend, and every holder can still recombine the two halves and walk out with the
stock. A classifier that guesses wrong moves real money between two cohorts, so anything ambiguous
refuses.

---

## Launch it like a launchpad, not a desk

Series creation is permissionless: pick a ticker, a split point and a maturity, deposit, one
transaction. `FletcherLaunchpad` goes further and leaves two live markets behind:

- Both legs are seeded into **Uniswap v4 pools quoted in the underlying**, so a FLOOR at 0.94 NVDA
  and a TURBO at 0.06 NVDA visibly add to one NVDA. Any deviation is an arbitrage that ends in a
  `merge()`.
- **Liquidity is locked by the absence of a withdraw path.** No call site passes a non-zero
  liquidity delta. `collectFees` runs `modifyLiquidity` at zero, which returns fees and cannot touch
  principal. It is not a timelock that expires or an admin promise; the function does not exist.
- **The launcher earns the swap fees on both legs, forever.** Seeding a real book is the profitable
  move, and listing a strike nobody trades wastes the launcher's own stock. The market picks which
  split points survive.

Two things bound it, both checked on chain:

- **Depth qualification.** A name must have measured Uniswap v3 depth, and outstanding notional per
  name is capped at a fraction of it (15% by default). The book size this protocol can carry is set
  by the AMM it unwinds into, not by demand for leverage.
- **Opening price bounds.** The seeded price is checked against the settlement source, so a book
  cannot open 35x away from the instrument it splits.

---

## What is in the box

| Package | What |
|---|---|
| [`contracts`](contracts) | Foundry. `Series`, `FletcherFactory`, `MultiplierAccountant`, `DepthGate`, `FletcherLaunchpad`, `SherwoodSettlementSource`. No owner, no upgrade path, no pause. 75 tests including fuzz invariants, a launchpad suite against Uniswap's real `PoolManager`, and 10 fork tests against live chain 4663. |
| [`packages/sdk`](packages/sdk) | `@fletcher/sdk`. Address book, the series arithmetic reimplemented in TypeScript, and a client that batches a series' reads into one multicall. 47 tests, 17 of them asserting parity against a fixture generated by the contracts themselves. |
| [`apps/web`](apps/web) | The interface. A payoff chart that explains the instrument in a glance, a series table, and a launch form that derives the split point from a target leverage. 16 tests. |
| [`apps/keeper`](apps/keeper) | Records official closes and settles matured series. A liveness convenience, not a trusted party. 6 tests. |

---

## Quick start

```bash
pnpm install
pnpm test                              # everything: 144 tests across contracts, SDK, web and keeper
pnpm dev                               # the interface, on :5273
```

Or a piece at a time:

```bash
forge test --root contracts            # 65 tests, fork tests skip without an endpoint
pnpm --filter @fletcher/sdk test       # 47 tests, 17 parity cases against the contracts
pnpm check:docs                        # links resolve, and quoted test counts are real
```

Fork tests need an archive endpoint. The official RPC and publicnode answer current reads but
reject historical state, which makes them unusable as a fork source:

```bash
RHC_RPC_URL=https://rpc-robinhood.blockmachine.io forge test --root contracts --match-path 'test/fork/*'
```

---

## Using the SDK

```ts
import { FletcherClient, parseUsd, strikeForLeverage, formatLeverage, WAD } from "@fletcher/sdk";

// Pick a leverage, not a strike. Nobody thinks in strikes.
const spot = parseUsd("178.50");
const strike = strikeForLeverage(spot, 20n * WAD);   // 169.57

const fletcher = new FletcherClient(addresses);
const series = await fletcher.getSeries("0x...");
const { floorValueX8, turboValueX8, leverage } = fletcher.quote(series, spot);

console.log(formatLeverage(leverage));               // "20.0x"
```

Full reference: [`docs/sdk.md`](docs/sdk.md).

---

## Deploying

```bash
SHERWOOD_ORACLE=0x... forge script script/Deploy.s.sol \
  --root contracts --rpc-url $RHC_RPC_URL --broadcast
```

Nothing is owned, upgradeable or pausable, so there is no admin step after it and no key to hold.
The Uniswap and USDG addresses default to the verified Robinhood Chain deployments.

**Fletcher is not deployed to mainnet.** Neither is Sherwood, whose oracle it settles against. The
contracts are complete and tested; the remaining step is a deployed oracle to point at.

---

## Documentation

- [`docs/protocol.md`](docs/protocol.md) the instrument, the arithmetic, and every invariant
- [`docs/corporate-actions.md`](docs/corporate-actions.md) how dividends and splits are told apart
- [`docs/settlement.md`](docs/settlement.md) where the close comes from and why it is never a pool
- [`docs/launchpad.md`](docs/launchpad.md) permissionless series creation and locked liquidity
- [`docs/sdk.md`](docs/sdk.md) the TypeScript reference
- [`docs/security.md`](docs/security.md) the trust model, what can go wrong, and what cannot
- [`docs/addresses.md`](docs/addresses.md) every Robinhood Chain address, and how it was verified

---

## Related work

Fletcher is the fourth protocol in a series built on Robinhood Chain's tokenized equities:

- [Loxley](https://github.com/nirholas/loxley) the x402 payment rail
- [Quiver](https://github.com/nirholas/quiver) intent-based swap aggregation
- [Sherwood](https://github.com/nirholas/sherwood) halt-aware lending, and the oracle Fletcher settles against
- [TECHDOLLAR](https://github.com/nirholas/techdollar) a CDP against tokenized equities

## License

All rights reserved. Copyright (c) 2026 nirholas. This is proprietary source: reading it here
grants no license to use, copy, modify, or distribute it. See [`LICENSE`](LICENSE).
