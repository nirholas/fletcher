# Security and the trust model

What Fletcher assumes, what it cannot do, and what would actually go wrong.

## The trust model in one table

| Party | What they can do | What they cannot do |
|---|---|---|
| **Anyone** | create a series, mint, merge, settle, record a close, collect a launch's fees to its launcher | choose a settlement price, move a split point, withdraw seeded liquidity |
| **A launcher** | choose terms, seed a book, collect that book's swap fees forever | withdraw the principal they seeded, or redirect the fee stream |
| **The keeper** | call `recordClose` and `settle` earlier than someone else would | produce a different answer than any other caller would |
| **Sherwood's reporters** | at quorum, set the price every series settles against | settle a series, or move a price past the TWAP deviation bound |
| **Robinhood (the issuer)** | halt an equity, halt all 254 at once, schedule a corporate action, upgrade the shared `Stock` implementation | reach anything in Fletcher directly |
| **A Fletcher admin** | — | — there is no owner, no upgrade path and no pause anywhere in the deployment |

## What has no admin

Every contract in `script/Deploy.s.sol` is deployed once and never touched again. There is no
`Ownable`, no proxy, no `pause()`, no fee switch and no parameter setter. `DepthGate`'s thresholds
and the strike band are constructor arguments and constants, not governance.

The consequence is worth stating plainly: **a bug cannot be patched in place.** That is a deliberate
trade, and it is why the surface is as small as it is. Four operations, one number to settle
against, and no balance sheet.

## The one genuine external dependency

Fletcher settles against **Sherwood's oracle**. If that oracle's reporter quorum is compromised, a
series can be settled at a price the market never printed, and the split between FLOOR and TURBO
follows that price.

Nothing in Fletcher can detect or prevent this. It is the trust assumption, stated rather than
engineered around, and it is why the same oracle is reused instead of a second reporter set being
stood up. See [`settlement.md`](settlement.md).

Bounded by:

- Sherwood cross-checks each quote against a Uniswap v3 TWAP and refuses on deviation, so a quorum
  cannot move a price arbitrarily far without the pool agreeing.
- `recordClose` requires the session closed and status `OK`.
- A recorded close is **write-once**. A later compromise cannot revise a settled day.

## What cannot go wrong

These are structural, not defended:

**Bad debt.** The vault divides into two shares that sum to exactly `1e18` at every close.
`turboPerUnit` is defined by subtraction rather than computed independently. There is no price at
which the vault owes more than it holds.

**Undercollateralisation.** Minting takes the stock before it mints the legs, and the vault's balance
is exactly each leg's supply.

**A liquidation cascade.** There are no liquidations. TURBO's leverage comes from where the split
point sits, not from borrowing.

**A stuck holder.** `merge` has no deadline, no fee, and does not check `frozen`. Before settlement,
anyone holding both legs can always leave at par.

**Liquidity rug.** No call site in the launchpad passes a non-zero liquidity delta.

## What can go wrong, and what happens

### The equity halts

While any of the three pause flags is set, `transfer` reverts, so `mint`, `merge` and `redeem` all
revert. Settlement still works, because it moves no stock.

Nothing is liquidated, because there are no liquidations. Positions are frozen exactly as long as
the equity is, which is the same exposure a holder of the underlying has. This is the failure mode
[Sherwood](https://github.com/nirholas/sherwood) and
[TECHDOLLAR](https://github.com/nirholas/techdollar) have to price and Fletcher does not.

### A corporate action cannot be classified

The series freezes into merge-only, permanently. Settlement is refused; merging is not. Every holder
can recombine and walk out with the stock.

The asymmetry is deliberate: a false `Split` collapses FLOOR's strike and hands TURBO value it never
bought, while a false `Unknown` costs everyone a settlement they can replace by merging.

### No close is ever recorded

The series never settles. `merge` stays open indefinitely, so holders leave at par. There is no
fallback to a pool price, a TWAP, or a stale record, and that absence is the design.

### The equity's shared implementation is upgraded

All 254 equities are beacon proxies onto one implementation. An upgrade that changed `uiMultiplier`
semantics, removed a pause flag, or altered transfer behaviour would reach every series at once.

Fletcher reads `paused()`, `tokenPaused()`, `uiMultiplier()`, `newUIMultiplier()` and `effectiveAt()`.
A removal breaks reads and reverts loudly. A **semantic** change to `uiMultiplier` is the dangerous
case: it would be classified by shape as usual, and a shape that no longer means what it meant would
either freeze the series or adjust a strike wrongly.

This is unmitigated and unmitigable from inside a contract. It is the issuer's chain.

### A launcher opens a series on a thin name

Bounded, not prevented. `DepthGate` refuses a name with no measurable depth and caps outstanding
notional at a fraction of it. Within that cap, a launcher can still open a series nobody wants;
they lose their own fees and their own seeded stock.

### An endpoint lies to a UI

The web app and SDK read from a single RPC. A malicious endpoint can display anything.

Every write **simulates against the same endpoint before sending**, and the wallet shows the real
call. A user who checks the transaction sees the truth regardless of what the page rendered.

## Rounding

Both legs round down independently, so a redemption can leave a wei in the vault. The last redeemer
receives the vault's whole remaining balance, so nothing is stranded and no earlier redeemer can
take more than they are owed.

The direction is what matters: the sum of claims is never above the vault's balance. Asserted by
fuzz over the full price and size range.

## What has been tested

| Suite | Count | What |
|---|---|---|
| `MultiplierAccountant.t.sol` | 16 | every classification branch, plus fuzz that only splits move strikes and that a split never re-strikes |
| `Series.t.sol` | 24 | mint, merge, settle, redeem, halts, freezes, and four fuzz invariants over the full price range |
| `FletcherFactory.t.sol` | 14 | every refusal |
| `Launchpad.t.sol` | 7 | against Uniswap's **real** `PoolManager`, including that a fee sweep leaves principal untouched |
| `fork/LiveChain.t.sol` | 10 | every chain assumption, against live 4663 |
| `Fixtures.t.sol` | 1 | the SDK's arithmetic has not drifted from the contracts |
| SDK | 44 | 17 of them parity cases generated by the contracts |

Fork tests **skip** with no endpoint configured and **fail**, never skip, on one that is configured
and broken. A fork test that quietly swallows a broken endpoint reports green while asserting
nothing, and the only tell is the gas figure.

## What has not been done

**No external audit.** Nothing here has been reviewed by anyone but its authors.

**Not deployed.** No mainnet deployment exists, and the oracle it depends on is not deployed either.

**No formal verification** of the settlement invariant, though it is the obvious candidate: the
property is one line and fuzz already covers the full range.

## Reporting

Open an issue at [github.com/nirholas/fletcher](https://github.com/nirholas/fletcher). There is no
bug bounty, and with nothing deployed there are no funds at risk.
