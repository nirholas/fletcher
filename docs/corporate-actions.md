# Corporate actions

The hardest problem in Fletcher, and the one place a wrong answer moves real money between two
cohorts of holders.

## One number, two opposite events

Robinhood Chain's tokenized equities carry corporate actions in a single ERC-8056 field,
`uiMultiplier()`. A raw ERC-20 balance never changes on a dividend or a split; the multiplier does.
A position's value is:

```
raw * uiMultiplier / 1e18 * pricePerShare
```

Two completely different events move that number:

- A **distribution** raises it by a fraction of a percent. Nothing about the company changed.
- A **split** multiplies it by a clean ratio and divides the share price by the same ratio. Nothing
  about the company changed either, but the share price moved.

They need opposite treatment.

## Why a distribution must not move the split point

FLOOR's claim at settlement is `multiplier × min(price, strike)`.

Leave the strike alone and a risen multiplier makes FLOOR's claim strictly larger, while TURBO's
claim above the strike is untouched. **That is the dividend accrual, and leaving the strike alone is
exactly how FLOOR gets it.** It is not a separate distribution mechanism bolted on; it falls out of
the arithmetic.

This is what makes FLOOR a savings instrument rather than a zero-coupon claim: a FLOOR holder is
lending against the stock *and* collecting its dividends.

## Why a split must move the split point

Consider a $170 split point on a share trading at $178.50, and a 2:1 split. The multiplier doubles
and the share price halves to $89.25.

Leave the strike at $170:

```
FLOOR = 2 × min($89.25, $170) = 2 × $89.25 = $178.50     the entire vault
TURBO = 2 × max($89.25 - $170, 0) = 0                    wiped out
```

TURBO is destroyed by an event that changed nothing about the company. Divide the strike by the
ratio instead, to $85:

```
FLOOR = 2 × min($89.25, $85) = 2 × $85 = $170            unchanged
TURBO = 2 × ($89.25 - $85) = $8.50                       unchanged
```

Both legs are exactly where they were. Listed options adjust contract terms on a split for precisely
this reason.

## How they are told apart

`MultiplierAccountant` classifies by shape, with no feed and no privileged reporter.

### Distribution

A rise of at most **3%** (`DIVIDEND_MAX_BPS`). Real distributions on the 254 equities are basis
points. NVDA's live multiplier moved from exactly `1e18` to `1.000775159164630595e18` on
10 September 2026, a 7.75 basis point accrual effective `2026-09-10T00:00:30Z`.

Result: `Dividend`. The strike is untouched.

### Split

The ratio `to / from` lands on a clean integer or clean simple fraction, at least **20%**
(`SPLIT_MIN_BPS`) away from 1, within **5 basis points** (`RATIO_TOLERANCE_BPS`) of exact, with both
terms at most **50** (`MAX_RATIO_TERM`).

The search runs by increasing denominator and skips ratios not in lowest terms, so a doubling is
reported as `2:1` rather than `4:2` and `ratioNum`/`ratioDen` read as the announced corporate action.

The tolerance exists only because a multiplier is a 1e18 fixed-point number and a 3:2 split is not
exactly representable. Demanding a clean ratio is not a heuristic tightened until the tests passed;
it is the actual shape of the event. Splits are announced as ratios, never as arbitrary reals.

Result: `Split`. The strike is divided by the ratio, using **exact ratio arithmetic**
(`strike × ratioDen / ratioNum`) rather than a 1e18 reciprocal, because rounding a strike is
rounding real money between two cohorts.

Reverse splits move the multiplier down and are classified the same way: a clean inverse ratio is a
reverse split, and it raises the strike. The live `Stock` implementation has only ever raised the
multiplier, but nothing in ERC-8056 forbids a fall.

### Anything else

`Unknown`. **The series freezes into merge-only, permanently.**

This is a first-class answer, not a failure mode. The two costs are wildly asymmetric:

- A **false `Split`** collapses FLOOR's strike and hands TURBO value it never bought.
- A **false `Unknown`** stops a series from settling, and everyone merges out at par.

So anything ambiguous resolves to `Unknown`. Nobody is liquidated, nobody is settled at a strike
nobody can defend, and every holder can still recombine the two halves and walk out with the stock.

## When classification runs

`syncMultiplier()` is permissionless and idempotent, and runs automatically inside `mint`, `merge`
and `settle`. No keeper is load-bearing; calling it directly only makes the adjustment visible
earlier.

## Scheduled actions

The live `Stock` contract schedules corporate actions in advance: `newUIMultiplier()` and
`effectiveAt()` are readable before the change lands, and `newUIMultiplier() == uiMultiplier()` when
nothing is pending.

`settle()` reads both. **A pending action with `effectiveAt <= maturity` blocks settlement** with
`CorporateActionPending`, because settling in front of it would settle the wrong terms. Once it
lands and `syncMultiplier` folds it in, settlement proceeds on the adjusted strike.

## Consuming a different accountant

`IMultiplierAccountant` is the seam. `FletcherFactory` takes an accountant at construction and every
series it deploys is built with it, so pointing a deployment at a different classifier is a
constructor argument, not a fork.

`classify` is pure: the same pair always classifies the same way, so an integrator can check a
classification before trusting it and a series can re-derive its own history.

## Reference

| Constant | Value | Meaning |
|---|---|---|
| `DIVIDEND_MAX_BPS` | 300 | a rise at or below 3% is a distribution |
| `SPLIT_MIN_BPS` | 2000 | a ratio must sit at least 20% from 1 to be a split |
| `RATIO_TOLERANCE_BPS` | 5 | how close to a clean ratio the multiplier must land |
| `MAX_RATIO_TERM` | 50 | largest numerator or denominator considered |

| From | To | Result | $170 strike becomes |
|---|---|---|---|
| 1.0 | 1.000775159164630595 | `Dividend` | $170.00 |
| 1.0 | 1.03 | `Dividend` | $170.00 |
| 1.0 | 1.0301 | `Unknown` | $170.00, frozen |
| 1.0 | 2.0 | `Split` 2:1 | $85.00 |
| 1.0 | 1.5 | `Split` 3:2 | $113.33 |
| 1.0 | 0.1 | `Split` 1:10 | $1,700.00 |
| 1.0 | 1.373 | `Unknown` | $170.00, frozen |
| 1.0 | 51.0 | `Unknown` | $170.00, frozen |

Every row is a test in `contracts/test/MultiplierAccountant.t.sol` and a parity case in
`packages/sdk/test/fixtures.json`.
