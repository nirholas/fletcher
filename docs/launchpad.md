# The launchpad

Opening a series the way a launchpad opens a coin, not the way a desk opens a book.

## The bootstrapping problem

The hard problem for an instrument like this is never pricing. It is liquidity.

A split point with no depth is a split point nobody can trade. A protocol that picks the menu
centrally ends up defending strikes the market did not want, and paying market makers to quote them.
Every option venue has this problem and solves it with designated market makers and listing
committees.

`FletcherLaunchpad` solves it the way launchpads do: **whoever seeds the book keeps the fees on it,
forever.** Seeding a real book becomes the profitable move, and listing a strike nobody trades wastes
the launcher's own stock. The market picks which split points survive.

## One transaction

```solidity
launchpad.launch(FletcherLaunchpad.LaunchParams({
    stock: NVDA,
    strikeX8: 169_57000000,     // $169.57
    tradingDay: 20344,
    rawStock: 100e18,           // 100 NVDA
    referencePriceX8: 178_50000000
}));
```

That call:

1. Splits the deposit in half.
2. Creates the series through `FletcherFactory` and mints both legs against one half.
3. Opens two Uniswap v4 pools, FLOOR against the stock and TURBO against the stock.
4. Seeds both with full-range liquidity at the parity-implied prices.
5. Records the caller as the launcher entitled to the fees.

### Why the deposit splits in half

Not a tunable ratio. It falls out of parity.

The two pools need `floorShare + turboShare == 1` share of stock per share that was split, so
quoting a mint of `M` costs exactly `M` of stock. Half becomes legs, half becomes the quote side.

### Why both legs are quoted in the underlying

FLOOR and TURBO are the two halves of one share, so priced *in that share* their prices sum to
exactly 1.

A FLOOR at 0.94 NVDA beside a TURBO at 0.06 NVDA visibly adds to one NVDA, and any deviation is an
arbitrage that ends in a `merge()`. Quoted in a stablecoin the same relationship exists but nobody
can see it.

The opening prices come from the instrument's own terms, not from the caller: FLOOR opens at
`min(P,K)/P` of a share and TURBO at the remainder.

## Locked liquidity

**There is no code path in `FletcherLaunchpad` that passes a non-zero liquidity delta.**

Locking here is not a timelock that expires, a vesting schedule, or an admin promise not to
withdraw. It is the absence of the function. `collectFees` runs `modifyLiquidity` with a delta of
zero, which returns accrued fees and cannot touch principal.

`test_launcherCannotWithdrawPrincipal` asserts the pool's liquidity is unchanged after a fee sweep,
against Uniswap's real `PoolManager`.

Liquidity is held by the launchpad inside the `PoolManager` keyed by owner and salt, rather than as
a position NFT. There is no token to transfer away, so there is nothing to rug even by mistake.

## The fees

`collectFees(series)` is callable by **anyone** and always pays the **recorded launcher**. The fee
stream does not depend on the launcher staying online and cannot be redirected.

Swap fee is 1% (`LP_FEE = 10_000`), with tick spacing 200. A dated, leveraged instrument does not
trade like a stable pair.

Liquidity is full-range, snapped to the tick spacing. A dated series lives for days and its legs can
travel the whole range between them, so a concentrated band would be a band the instrument walks
straight out of.

## What bounds a launch

Two gates, both checked on chain, both unmovable by a swap.

### Depth qualification

`DepthGate` reads the deepest quote-paired Uniswap v3 pool for the equity and measures that pool's
stock balance. A name must clear `minDepthRaw` to carry any series at all, and outstanding notional
across all live series for that name is capped at `capBps` of measured depth (15% by default).

Concentrated liquidity means a balance is not a complete picture of a book, but it **is** a hard
ceiling on what the pool can ever sell, which is the number a cap wants.

The binding constraint on this protocol is not demand for leverage. It is the depth of the AMM the
two legs must eventually be traded against and the vault must eventually be unwound into. A series
minted on a name with $40k of on-chain depth is a series whose holders cannot exit, however much
they wanted the exposure.

### Opening price bounds

The `referencePriceX8` a launcher supplies is checked against the settlement source's most recent
close and must sit within `MAX_OPENING_DEVIATION_BPS` (10%) of it.

This is the AMC weekend as a parameter. A launcher opening a book 35x above the real equity is
rejected with `OpeningPriceOutOfBand`.

## What the factory refuses, launchpad or not

| Refusal | Why |
|---|---|
| `NotDepthQualified` | the name has no measurable on-chain depth |
| `CapExceeded` | outstanding notional would pass the fraction of depth allowed |
| `StockHalted` | the equity, or the whole registry, is halted |
| `SeriesExists` | those exact terms already exist; two copies would fragment the liquidity this shape exists to concentrate |
| `BadMaturity` | in the past, or a tenor beyond 90 days |
| `BadStrike` | outside 10%–99% of the reference close |
| `ZeroAmount` | an empty series is a listing, and this protocol does not do listings |

Note what is **not** on that list: nothing about who the caller is. There is no allowlist, no
listing fee, and no committee.

## Prior art

Three protocols already running on Robinhood Chain shaped this design:

- **Pons** proved the creator fee share is the growth engine, with fair launches and fees flowing to
  the creator rather than to a treasury.
- **PAIR** proved the mechanics: no bonding curve, no migration step, permanently locked v4
  liquidity, and stock tokens as the quote asset. The launchpad proxy is live at
  `0x8660a7f019c7943b0b0a91b8e39aff3b6db6ae62`.
- **PARE** proved that corporate-action accounting is the hard part and worth isolating behind an
  interface, which is why `IMultiplierAccountant` is a seam rather than an internal function.

The AMC episode that motivates the opening-price band happened to a PAIR-launched pair. That is not
a criticism of PAIR: a launchpad has no business having an opinion about what a coin is worth. It is
a reason a launchpad for *dated equity derivatives* must have exactly that opinion.
