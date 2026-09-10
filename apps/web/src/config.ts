/**
 * Where the app points.
 *
 * Fletcher is not deployed to Robinhood Chain mainnet. Rather than shipping a UI wired to a
 * placeholder address that would fail at the first read, the app treats "no deployment configured"
 * as a real, designed state: it explains what it is, draws the instrument from its own arithmetic,
 * and tells you exactly what to set to point it at one.
 *
 * Set these in `.env.local` (Vite reads `VITE_`-prefixed vars at build time):
 *
 *   VITE_FLETCHER_FACTORY=0x...
 *   VITE_FLETCHER_LAUNCHPAD=0x...
 *   VITE_FLETCHER_SETTLEMENT_SOURCE=0x...
 *   VITE_FLETCHER_ACCOUNTANT=0x...
 *   VITE_FLETCHER_DEPTH_GATE=0x...
 *   VITE_RHC_RPC_URL=https://rpc-robinhood.blockmachine.io
 */
import type { Address } from "viem";
import { RPC_URLS, type FletcherAddresses } from "@fletcher/sdk";

function readAddress(value: string | undefined): Address | null {
  if (!value || !/^0x[0-9a-fA-F]{40}$/.test(value)) return null;
  return value as Address;
}

export const RPC_URL = import.meta.env.VITE_RHC_RPC_URL ?? RPC_URLS.archive;

/** Null when no deployment is configured, which the UI renders as a designed state. */
export const ADDRESSES: FletcherAddresses | null = (() => {
  const factory = readAddress(import.meta.env.VITE_FLETCHER_FACTORY);
  const launchpad = readAddress(import.meta.env.VITE_FLETCHER_LAUNCHPAD);
  const settlementSource = readAddress(import.meta.env.VITE_FLETCHER_SETTLEMENT_SOURCE);
  const accountant = readAddress(import.meta.env.VITE_FLETCHER_ACCOUNTANT);
  const depthGate = readAddress(import.meta.env.VITE_FLETCHER_DEPTH_GATE);
  if (!factory || !launchpad || !settlementSource || !accountant || !depthGate) return null;
  return { factory, launchpad, settlementSource, accountant, depthGate };
})();

export const EXPLORER = "https://robinhoodchain.blockscout.com";
