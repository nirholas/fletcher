# The protocol

Fletcher splits one tokenized equity into two dated ERC-20s and settles them against one number.
This document is the complete specification of that: the arithmetic, the state machine, and every
invariant the contracts hold.

## The instrument

A **series** is named by three terms, and those three terms are its identity forever:

| Term | Meaning |
|---|---|
| `stock` | the tokenized equity held as collateral |
| `strikeX8` | the **split point**, 1e8-scaled USD per share |
| `tradingDay` | days since the Unix epoch; the day whose official close settles the series |

`FletcherFactory` deploys each series with CREATE2 over those three terms, so
`(stock, strike, tradingDay)` names exactly one address. Two callers racing to open the same series
cannot fragment one instrument into two half-liquid copies, and an integrator can compute the
address before it exists with `computeSeriesAddress`.

Maturity is `tradingDay * 1 days + 22 hours`. The offset exists because an official close is not
printed at the instant the bell rings.

## The four operations

```
mint    R raw stock in         →  R FLOOR + R TURBO out
merge   R FLOOR + R TURBO in   →  R raw stock out
settle  once, at maturity, against the official close
redeem  each leg claims its share of the same vault
```

Nothing else has state. There is no owner, no upgrade path, no pause, no fee, and no governance.

### mint

Deposits `R` raw stock and mints `R` of each leg. The vault's stock balance is exactly the supply of
each leg, so the series is fully collateralised at mint by construction rather than by a check.

Refused when the series has settled, when the equity is halted, or when an unclassifiable corporate
action has frozen the series.

### merge

Burns equal amounts of both legs and returns the stock, one for one, with no fee and no deadline.

This is the mechanism that **caps the two legs' combined price at parity**: any premium on the pair
is an arbitrage that ends with someone merging. It is also the escape hatch that makes freezing a
safe response to an unclassifiable corporate action, which is why `merge` deliberately does *not*
check the `frozen` flag, and why it stays open while a series is past maturity but not yet settled.

Merging needs both legs. A holder who sold their TURBO cannot merge, which is the point: the merge
right belongs to whoever holds both halves.

### settle

Runs once, at or after maturity, and records a ratio. Permissionless, because it can only ever
produce the number the settlement source already published.

Four gates, in order:

1. Not already settled.
2. `block.timestamp >= maturity`.
3. No unclassifiable corporate action (`frozen`).
4. No corporate action **scheduled** to land at or before maturity that has not been folded in yet.
   Settling in front of one settles the wrong terms.
5. An official close exists for the series' trading day.

Deliberately **not** gated on the equity being unhalted. A halted equity is exactly when holders
most need the series to resolve, and settlement moves no stock: it only records the ratio.
Redemption transfers, and reverts on its own while transfers are paused.

### redeem

After settlement, burns whatever legs the caller holds and transfers the stock they are owed. The
two legs are independent after settlement; either amount may be zero.

## The settlement arithmetic

With close `P`, split point `K` and vault holding `R` raw stock:

```
floorClaim  = min(P, K)
floorPerUnit = floorClaim * 1e18 / P
turboPerUnit = 1e18 - floorPerUnit
```

A holder of `f` FLOOR and `t` TURBO receives `f * floorPerUnit / 1e18 + t * turboPerUnit / 1e18`.

**The two shares sum to exactly `1e18` for every `P > 0`.** `turboPerUnit` is defined by subtraction
rather than computed independently, which is what makes that exact rather than approximate.

### Worked examples

A series on NVDA struck at $170, with 100 shares deposited:

| Close | FLOOR share | TURBO share | FLOOR gets | TURBO gets |
|---|---|---|---|---|
| $120 | 100% | 0% | 100 NVDA | nothing, and owes nothing |
| $170 | 100% | 0% | 100 NVDA | nothing |
| $178.50 | 95.24% | 4.76% | 95.24 NVDA | 4.76 NVDA |
| $200 | 85% | 15% | 85 NVDA | 15 NVDA |
| $1,000 | 17% | 83% | 17 NVDA | 83 NVDA |

At $178.50 a TURBO holder put up 4.76% of a share's value and holds 100% of the delta above $170.
That is the 21x.

### Why the multiplier cancels

A position's value is `raw * uiMultiplier / 1e18 * pricePerShare`. Both legs redeem in raw stock out
of one vault, so the multiplier appears on both sides of the division and drops out of the
settlement arithmetic entirely.

It is not ignored. It is the reason the split point has to be carried through corporate actions,
which is [`corporate-actions.md`](corporate-actions.md).

### Rounding

Both legs round down independently, so a redemption can leave a wei of stock in the vault. `redeem`
pays the **last** redeemer the vault's whole remaining balance, so dust is never retained forever
and no earlier redeemer can take more than they are owed.

The direction is the part that matters: the sum of the two claims is never *above* what the vault
holds. A sum above would be bad debt.

## Leverage

```
leverage = P / (P - K)          for P > K
         = undefined            for P <= K
```

`turboLeverage1e18` returns `0` at or below the strike, where TURBO has no delta and leverage is
undefined rather than infinite.

Inverting it gives the function a launcher actually wants, since nobody picks a strike:

```
K = P * (1 - 1/L)
```

A 20x TURBO on a $178.50 share is struck at $169.57. `strikeForLeverage` in the SDK does this.

## The funding rate

Never published by the protocol, and not a parameter anywhere in the contracts.

FLOOR is a claim on `min(P, K)` at a known date. A FLOOR trading below that claim is being bought at
a discount, and that discount **is** the funding rate: FLOOR buyers are lending, TURBO buyers are
borrowing, and the rate is whatever level clears the two books against each other.

`floorDiscountBps` and `annualisedFundingBps` in the SDK read it off market prices. Annualised
simply rather than compounded, because these are dated instruments measured in days and a compounded
figure would imply a rollover the holder has to actually achieve.

## The state machine

```
                    ┌──────────────────────────────┐
                    │            LIVE              │
                    │  mint · merge · syncMultiplier│
                    └───────┬───────────────┬──────┘
        unclassifiable      │               │  maturity + a recorded close
        corporate action    │               │
                            ▼               ▼
                    ┌───────────────┐   ┌──────────────────┐
                    │    FROZEN     │   │     SETTLED      │
                    │  merge only   │   │  redeem only     │
                    │  forever      │   │                  │
                    └───────────────┘   └──────────────────┘
```

A halt is not a state: it is a condition that makes `mint` and every transfer revert while it lasts,
and lifts on its own. `isSynced()` reports both the halt and the freeze.

**FROZEN is terminal and safe.** Settlement is refused permanently, merge stays open, and every
holder can leave whole at par.

## Invariants

Each of these is asserted by a test, most of them by a fuzz test over the full input range.

1. **The vault is exactly divided.** `floorPerUnit + turboPerUnit == 1e18`, at every close.
2. **The vault can never owe more than it holds.** The sum of both legs' claims is at most the
   vault's balance, at every close and every mint size.
3. **Both legs always redeem fully.** After both are redeemed the vault holds exactly zero.
4. **Merge always returns the deposit at par**, for any mint size and after any intervening
   distribution.
5. **Leg values sum to the multiplier-adjusted share price**, within one wei, and never above it.
6. **Only a split may move a split point.** Nothing else, at any input, adjusts a strike.
7. **A split does not re-strike the series.** `adjustedStrike × ratio == originalStrike`, so
   `multiplier × min(price, strike)` is invariant across the event.
8. **Classification is deterministic.** The same multiplier pair always classifies the same way, so
   a series can re-derive its own history.

## What is deliberately absent

- **No liquidation engine.** Nothing to seize, so nothing to starve. See the README.
- **No oracle of its own.** Fletcher consumes Sherwood's. See [`settlement.md`](settlement.md).
- **No protocol fee.** Merge is free, mint is free, settlement is free. The launchpad's swap fees go
  to the launcher, not to a treasury.
- **No owner.** Nothing in the deployment is ownable, upgradeable or pausable.
- **No listing committee.** Depth qualification and the strike band are checked on chain; which
  split points deserve to exist is left to the market.
