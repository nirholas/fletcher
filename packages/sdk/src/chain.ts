/**
 * Robinhood Chain (`eip155:4663`) constants.
 *
 * Every address here was read from the chain and asserted to hold code. The fork tests in
 * `contracts/test/fork/LiveChain.t.sol` re-check the load-bearing ones on every run, so this file
 * cannot drift from the chain without the test suite saying so.
 */
import { defineChain } from "viem";

export const CHAIN_ID = 4663;

/**
 * Read endpoints, in preference order.
 *
 * Only the first serves historical state. The official RPC and publicnode answer current reads but
 * reject archive queries, which makes them unusable as a fork source and unusable for any backfill
 * that walks logs. That is a real distinction, not a ranking: a tool that needs history and picks
 * the wrong one fails with `metadata` or `historical` errors that read like an outage.
 */
export const RPC_URLS = {
  archive: "https://rpc-robinhood.blockmachine.io",
  official: "https://rpc.mainnet.chain.robinhood.com",
  publicnode: "https://robinhood-rpc.publicnode.com",
} as const;

export const EXPLORER_URL = "https://robinhoodchain.blockscout.com";

export const robinhoodChain = defineChain({
  id: CHAIN_ID,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [RPC_URLS.archive, RPC_URLS.official] },
  },
  blockExplorers: {
    default: { name: "Blockscout", url: EXPLORER_URL },
  },
});

/** The Global Dollar. Six decimals, unlike the eighteen every equity carries. */
export const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168" as const;
export const USDG_DECIMALS = 6;

/** Uniswap, verified live on 4663. */
export const UNISWAP_V3_FACTORY = "0x1f7d7550B1b028f7571E69A784071F0205FD2EfA" as const;
export const UNISWAP_V4_POOL_MANAGER = "0x8366a39CC670B4001A1121B8F6A443A643e40951" as const;
export const UNISWAP_V4_STATE_VIEW = "0xF3334192D15450CdD385c8B70e03f9A6bD9E673b" as const;

/**
 * The shared `Stock` implementation behind all 254 tokenized equities, and the registry proxying
 * onto it. One upgrade moves every equity, and the registry's own `paused()` halts all of them at
 * once, which is why `Series` reads it alongside the per-equity flag.
 */
export const STOCK_IMPLEMENTATION = "0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2" as const;
export const STOCK_REGISTRY = "0xe10b6f6B275de231345c20D14Ab812db62151b00" as const;

/** Equities with verified pools, as a starting universe. `discoverEquities` finds the rest. */
export const EQUITIES = {
  NVDA: { address: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", decimals: 18 },
  SPY: { address: "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C", decimals: 18 },
} as const;

/** The deepest verified quote pools, by equity. */
export const VERIFIED_POOLS = {
  NVDA: { pool: "0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3", fee: 500, usdgIsToken0: true },
  SPY: { pool: "0xa7Bb1AC63BBaB0C44316E6c8C455213441689167", fee: 500, usdgIsToken0: false },
} as const;

export type EquitySymbol = keyof typeof EQUITIES;
