# Settlement

Where a dated series learns the one number it settles against, and why that number is never a pool
price.

## The AMC weekend

On 30 August a launchpad-created AMC pair on Robinhood Chain traded **35x above the real equity**
for an entire weekend. The equity market was shut. No arbitrageur could close the gap, because
closing it would have meant selling a share nobody could buy at the real price until Monday.

That pool price was real, on chain, observable, and completely wrong.

A series that settled against it would have handed TURBO the entire vault on a print that never
existed, and FLOOR holders who believed they held a capped, first-claim savings instrument would
have been wiped out by an event that did not happen to the company.

**The pool is where the legs trade. It is never what they settle against.** Every design decision
below follows from that.

## The source

Robinhood Chain carries **no price oracle of any kind**. No Chainlink, nothing. That is the gap
[Sherwood](https://github.com/nirholas/sherwood) fills, and Fletcher consumes it rather than shipping
a second oracle with a second reporter set.

`SherwoodOracle` carries a price as a quorum of **signed reporter quotes**, cross-checked against a
Uniswap v3 TWAP, so neither source can move the price alone:

- Reporters sign an EIP-712 `PriceReport` with an asset, price, observed timestamp, session and a
  strictly increasing nonce. Replays and reorderings are rejected.
- A quote is accepted only at quorum.
- It is cross-checked against a TWAP, with a tighter tolerance while the US session is open than
  while it is closed.
- It reports a `PriceStatus` other than `OK` when the token is paused, the issuer's feed is paused,
  the quote is stale, the TWAP deviates, or a multiplier transition is in progress.

That shape is right for a lending market, which only ever cares about *now*. A dated series cares
about exactly one instant instead.

## Freezing a dated close

`SherwoodSettlementSource` records rather than computes.

`recordClose(stock, tradingDay)` is **permissionless**, may be called **once** per (equity, day), and
only when:

1. The trading day is actually over (`block.timestamp >= (tradingDay + 1) * 1 days`). Recording
   "today's close" at noon would record a mid-session print under a name that claims otherwise.
2. Sherwood reports the session is **not** `Regular` or `Pre`.
3. Sherwood's `peek` returns status `OK`.
4. The price is non-zero and fits.

After that the number is immutable and every series dated to that day settles on the same print.

The call takes no discretion: the caller cannot choose the number, only the moment it is read, and
the session gate means every valid moment carries the same close. That is why it can be
permissionless and why the keeper that calls it is a liveness convenience rather than a trusted
party.

## What a series does with it

`Series.settle()` runs once, at or after maturity, and records a ratio:

```
floorPerUnit = min(close, strike) * 1e18 / close
turboPerUnit = 1e18 - floorPerUnit
```

It reverts with `CloseUnavailable` if no close is recorded for its trading day. It never falls back
to a pool, a TWAP, a last-known price, or a stale record. There is no fallback, deliberately: a
series that cannot settle is a series whose holders merge out at par, which is a strictly better
outcome than settling on a number nobody can defend.

### Settlement is not blocked by a halt

`settle()` is deliberately **not** gated on the equity being unhalted.

A halted equity is exactly when holders most need the series to resolve, and settlement moves no
stock: it only records the ratio. `redeem` transfers, and reverts on its own while transfers are
paused, which is the correct place for that constraint to bite.

### Settlement is blocked by a pending corporate action

If `newUIMultiplier() != uiMultiplier()` and `effectiveAt <= maturity`, settlement reverts with
`CorporateActionPending`. Settling in front of a scheduled split would settle the wrong terms. See
[`corporate-actions.md`](corporate-actions.md).

## The keeper

`apps/keeper` records closes and settles matured series on a loop. It is a convenience, not a
dependency:

- Neither call can produce a result the caller chooses.
- Anyone can make both calls.
- Until someone does, every holder can still `merge()` out at par.

It simulates before it sends, so a series whose close has not been recorded yet reports
`CloseUnavailable` as a named reason instead of burning gas on a revert, and it keeps its loop alive
through a rate-limited endpoint rather than exiting on the first 429.

```bash
pnpm --filter @fletcher/keeper check    # one pass, no transactions, prints what it would do
pnpm --filter @fletcher/keeper start    # continuous
```

## Consuming a different source

`ISettlementSource` is the seam:

```solidity
function officialClose(address stock, uint64 tradingDay) external view returns (uint256 priceX8, uint64 observedAt);
function hasClose(address stock, uint64 tradingDay) external view returns (bool);
function sessionOf(address stock) external view returns (Session);
```

An implementation **must revert** rather than return a stale, unsigned or quorum-less price.
`officialClose` returning a bad number is indistinguishable, to a series, from a good one.

`FletcherFactory` and `FletcherLaunchpad` take a source at construction, so pointing a deployment at
a different one is a constructor argument rather than a fork.

## Where else the source is used

The settlement source is the reference price for two gates that would otherwise be manipulable by a
swap:

- **The strike band.** `FletcherFactory` checks a proposed split point sits between 10% and 99% of
  the source's most recent close. A caller who could pick the reference price could open a series
  struck at a number the market never traded at and mint TURBO already deep in the money.
- **The opening price.** `FletcherLaunchpad` bounds the seeded pool price to within 10% of the
  source's close. This is the AMC episode as a parameter: a launcher opening a book 35x away from
  the real equity is rejected.

Both walk back at most seven days to find a priced day, which covers a long weekend plus a holiday
and stops well short of pricing off a stale print.
