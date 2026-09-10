/**
 * Wallet connection, over the injected EIP-1193 provider.
 *
 * No connector library: the app needs an account, a chain check, and a viem wallet client, and
 * every wallet on this chain injects a provider that answers all three. A modal framework would be
 * more dependency than feature.
 */
import { createWalletClient, custom, type Address, type WalletClient, type EIP1193Provider } from "viem";
import { robinhoodChain, CHAIN_ID } from "@fletcher/sdk";

export interface WalletState {
  account: Address | null;
  chainId: number | null;
  client: WalletClient | null;
  error: string | null;
}

export const NO_WALLET: WalletState = { account: null, chainId: null, client: null, error: null };

function provider(): EIP1193Provider | null {
  const injected = (globalThis as { ethereum?: EIP1193Provider }).ethereum;
  return injected ?? null;
}

export function hasWallet(): boolean {
  return provider() !== null;
}

/** Hex chain id for 4663, as `wallet_switchEthereumChain` wants it. */
const CHAIN_ID_HEX = `0x${CHAIN_ID.toString(16)}` as const;

export async function connect(): Promise<WalletState> {
  const injected = provider();
  if (!injected) {
    return { ...NO_WALLET, error: "No wallet found. Install one that supports Robinhood Chain." };
  }

  try {
    const accounts = (await injected.request({ method: "eth_requestAccounts" })) as Address[];
    const account = accounts[0];
    if (!account) return { ...NO_WALLET, error: "The wallet returned no account." };

    const current = Number(await injected.request({ method: "eth_chainId" }));
    if (current !== CHAIN_ID) {
      await switchChain(injected);
    }

    return {
      account,
      chainId: CHAIN_ID,
      client: createWalletClient({ account, chain: robinhoodChain, transport: custom(injected) }),
      error: null,
    };
  } catch (error) {
    return { ...NO_WALLET, error: describeWalletError(error) };
  }
}

/**
 * Switch to 4663, adding it first if the wallet has never seen it.
 *
 * 4902 is "unrecognised chain", which is the normal first-run answer rather than a failure: most
 * wallets do not ship Robinhood Chain, so the add is part of connecting, not a fallback.
 */
async function switchChain(injected: EIP1193Provider): Promise<void> {
  try {
    await injected.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: CHAIN_ID_HEX }],
    });
  } catch (error) {
    const code = (error as { code?: number }).code;
    if (code !== 4902) throw error;
    await injected.request({
      method: "wallet_addEthereumChain",
      params: [
        {
          chainId: CHAIN_ID_HEX,
          chainName: robinhoodChain.name,
          nativeCurrency: robinhoodChain.nativeCurrency,
          rpcUrls: [...robinhoodChain.rpcUrls.default.http],
          blockExplorerUrls: [robinhoodChain.blockExplorers.default.url],
        },
      ],
    });
  }
}

/** Re-read an already-authorised connection without prompting. */
export async function restore(): Promise<WalletState> {
  const injected = provider();
  if (!injected) return NO_WALLET;
  try {
    const accounts = (await injected.request({ method: "eth_accounts" })) as Address[];
    const account = accounts[0];
    if (!account) return NO_WALLET;
    const chainId = Number(await injected.request({ method: "eth_chainId" }));
    return {
      account,
      chainId,
      client: createWalletClient({ account, chain: robinhoodChain, transport: custom(injected) }),
      error: null,
    };
  } catch {
    return NO_WALLET;
  }
}

/** Fires when the user switches account or network in the wallet itself. */
export function onWalletChange(handler: () => void): void {
  const injected = provider();
  if (!injected) return;
  injected.on("accountsChanged", handler);
  injected.on("chainChanged", handler);
}

export function describeWalletError(error: unknown): string {
  const code = (error as { code?: number }).code;
  // 4001 is the user declining, which is an outcome rather than a fault and should not read like one.
  if (code === 4001) return "Connection declined.";
  if (error && typeof error === "object" && "shortMessage" in error) {
    return String((error as { shortMessage: unknown }).shortMessage);
  }
  return error instanceof Error ? error.message : String(error);
}
