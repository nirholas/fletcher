# Fletcher keeper

Records official closes and settles matured series.

```bash
pnpm check     # one pass, no transactions, prints what it would do and why
pnpm start     # continuous
```

## What it is not

A trusted party. Neither call it makes can produce a result the caller chooses:

- `recordClose` only works while the trading day is over, the session is closed and the oracle's
  status is `OK`, and it can be called once per (equity, day).
- `settle` can only ever record the close the source already published.

Anyone can make both calls. Until someone does, every holder can still `merge()` out at par. The
keeper buys liveness, not trust.

## Configuration

```
FLETCHER_FACTORY=0x...
FLETCHER_LAUNCHPAD=0x...
FLETCHER_SETTLEMENT_SOURCE=0x...
FLETCHER_ACCOUNTANT=0x...
FLETCHER_DEPTH_GATE=0x...
RHC_RPC_URL=https://rpc-robinhood.blockmachine.io
KEEPER_PRIVATE_KEY=0x...        # omit to run read-only
KEEPER_INTERVAL_MS=60000
```

## Behaviour worth knowing

It **simulates before it sends**, so a series whose close has not been recorded yet reports
`CloseUnavailable` as a named reason instead of burning gas on a revert.

A pass that throws is logged and the loop continues. A keeper that exits on the first 429 is a
keeper that is not running when it matters.

It does not try to settle a **frozen** series, and says why: settlement there is refused
permanently by design and merging stays open, so there is nothing to drive.

`planFor` is exported and pure, so what the keeper decides is unit-tested separately from what it
sends. See [`../../docs/settlement.md`](../../docs/settlement.md).
