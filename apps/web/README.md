# Fletcher web

The interface. Vite, TypeScript, no framework.

```bash
pnpm dev        # :5273
pnpm build
```

## What it does

Three views over one state object:

- **Series** every live series, with its split point, maturity, leverage and collateral, and a
  detail pane with the payoff curve and the contract addresses.
- **Launch** derives a split point from a target leverage, draws what you would be opening, and
  shows the funding rate the terms imply.
- **How it works** the instrument, explained with the same chart.

The **payoff chart** is the point. A split-share instrument is unintuitive described in words and
obvious drawn: FLOOR rises with the stock and flattens at the split point, TURBO is flat at zero and
then rises with slope one, and the two stacked are the stock itself. Rendered as inline SVG, scaled
to the largest leg value so the curves fill the plot, with no charting dependency.

## Pointing it at a deployment

Fletcher is not deployed. With no addresses configured the app renders that as a designed state that
still teaches the instrument from its own arithmetic, rather than failing on the first read.

Create `.env.local`:

```
VITE_FLETCHER_FACTORY=0x...
VITE_FLETCHER_LAUNCHPAD=0x...
VITE_FLETCHER_SETTLEMENT_SOURCE=0x...
VITE_FLETCHER_ACCOUNTANT=0x...
VITE_FLETCHER_DEPTH_GATE=0x...
VITE_RHC_RPC_URL=https://rpc-robinhood.blockmachine.io
```

## Notes

Wallet connection is the injected EIP-1193 provider directly, including adding chain 4663 when the
wallet has never seen it. No connector library: the app needs an account, a chain check and a viem
client, and a modal framework would be more dependency than feature.

Series are read **sequentially**, not with `Promise.all`. Every public endpoint on this chain rate
limits, and a table of thirty series firing thirty concurrent multicalls gets 429ed into a false
error state that looks like the protocol is down.
