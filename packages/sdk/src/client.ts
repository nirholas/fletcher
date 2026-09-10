/**
 * Reading and writing Fletcher from TypeScript.
 *
 * Reads work against any endpoint with no key and no account. Writes take a viem wallet client and
 * are otherwise the same calls; nothing here holds a key or signs on your behalf.
 */
import {
  createPublicClient,
  http,
  type Address,
  type PublicClient,
  type WalletClient,
  type Hex,
} from "viem";
import { robinhoodChain, RPC_URLS } from "./chain.js";
import { fletcherfactoryAbi, seriesAbi, seriestokenAbi, istocktokenAbi, fletcherlaunchpadAbi } from "./abis.js";
import {
  quoteLegs,
  settlementShares,
  turboLeverage,
  maturityFor,
  type SettlementShares,
} from "./math.js";

export interface FletcherAddresses {
  factory: Address;
  launchpad: Address;
  settlementSource: Address;
  accountant: Address;
  depthGate: Address;
}

/** Everything about one series, in one read. */
export interface SeriesState {
  address: Address;
  stock: Address;
  stockSymbol: string;
  floorToken: Address;
  turboToken: Address;
  strikeX8: bigint;
  maturity: bigint;
  tradingDay: bigint;
  observedMultiplier: bigint;
  settled: boolean;
  settlementPriceX8: bigint;
  shares: SettlementShares | null;
  frozen: boolean;
  /** False when the equity is halted or an unclassifiable corporate action froze the series. */
  isSynced: boolean;
  collateralRaw: bigint;
  floorSupply: bigint;
  turboSupply: bigint;
}

export function publicClientFor(rpcUrl: string = RPC_URLS.archive): PublicClient {
  return createPublicClient({ chain: robinhoodChain, transport: http(rpcUrl) });
}

export class FletcherClient {
  constructor(
    readonly addresses: FletcherAddresses,
    readonly publicClient: PublicClient = publicClientFor(),
  ) {}

  // --- reads ---------------------------------------------------------------------------------

  /** Every series ever created, in creation order. */
  async listSeries(): Promise<Address[]> {
    const count = await this.publicClient.readContract({
      address: this.addresses.factory,
      abi: fletcherfactoryAbi,
      functionName: "seriesCount",
    });
    const calls = Array.from({ length: Number(count) }, (_, i) => ({
      address: this.addresses.factory,
      abi: fletcherfactoryAbi,
      functionName: "allSeries" as const,
      args: [BigInt(i)] as const,
    }));
    const results = await this.publicClient.multicall({ contracts: calls, allowFailure: false });
    return results as Address[];
  }

  /**
   * Full state of one series in a single multicall.
   *
   * Batched deliberately: a UI that fires fourteen sequential reads per series renders a table of
   * ten series with a hundred and forty round trips, and Robinhood Chain's public endpoints rate
   * limit well before that.
   */
  async getSeries(address: Address): Promise<SeriesState> {
    const s = { address, abi: seriesAbi } as const;
    const [
      stock,
      floorToken,
      turboToken,
      strikeX8,
      maturity,
      tradingDay,
      observedMultiplier,
      settled,
      settlementPriceX8,
      floorPerUnit,
      turboPerUnit,
      frozen,
      isSynced,
    ] = await this.publicClient.multicall({
      contracts: [
        { ...s, functionName: "stock" },
        { ...s, functionName: "floorToken" },
        { ...s, functionName: "turboToken" },
        { ...s, functionName: "strikeX8" },
        { ...s, functionName: "maturity" },
        { ...s, functionName: "tradingDay" },
        { ...s, functionName: "observedMultiplier" },
        { ...s, functionName: "settled" },
        { ...s, functionName: "settlementPriceX8" },
        { ...s, functionName: "floorPerUnit1e18" },
        { ...s, functionName: "turboPerUnit1e18" },
        { ...s, functionName: "frozen" },
        { ...s, functionName: "isSynced" },
      ],
      allowFailure: false,
    });

    const [stockSymbol, collateralRaw, floorSupply, turboSupply] = await this.publicClient.multicall({
      contracts: [
        { address: stock as Address, abi: istocktokenAbi, functionName: "symbol" },
        { address: stock as Address, abi: istocktokenAbi, functionName: "balanceOf", args: [address] },
        { address: floorToken as Address, abi: seriestokenAbi, functionName: "totalSupply" },
        { address: turboToken as Address, abi: seriestokenAbi, functionName: "totalSupply" },
      ],
      allowFailure: false,
    });

    return {
      address,
      stock: stock as Address,
      stockSymbol: stockSymbol as string,
      floorToken: floorToken as Address,
      turboToken: turboToken as Address,
      strikeX8: strikeX8 as bigint,
      maturity: maturity as bigint,
      tradingDay: tradingDay as bigint,
      observedMultiplier: observedMultiplier as bigint,
      settled: settled as boolean,
      settlementPriceX8: settlementPriceX8 as bigint,
      shares: (settled as boolean)
        ? { floorPerUnit: floorPerUnit as bigint, turboPerUnit: turboPerUnit as bigint }
        : null,
      frozen: frozen as boolean,
      isSynced: isSynced as boolean,
      collateralRaw: collateralRaw as bigint,
      floorSupply: floorSupply as bigint,
      turboSupply: turboSupply as bigint,
    };
  }

  /**
   * What the two legs are worth at a given share price, and TURBO's leverage there.
   *
   * Computed locally from the series' own terms rather than read back from the chain, so a UI can
   * redraw a payoff curve at sixty frames a second without touching an RPC.
   */
  quote(series: Pick<SeriesState, "strikeX8" | "observedMultiplier">, priceX8: bigint) {
    return {
      ...quoteLegs(priceX8, series.strikeX8, series.observedMultiplier),
      leverage: turboLeverage(priceX8, series.strikeX8),
      shares: settlementShares(priceX8, series.strikeX8),
    };
  }

  /** True once the series may be settled, whether or not a close has been recorded yet. */
  isMature(series: Pick<SeriesState, "maturity">, now = Date.now()): boolean {
    return BigInt(Math.floor(now / 1000)) >= series.maturity;
  }

  // --- writes --------------------------------------------------------------------------------

  /**
   * Create a series and mint into it. The caller must have approved the factory for `rawStock`.
   *
   * Simulated before it is sent, so a refusal (illiquid name, halted equity, strike outside the
   * band, notional past the cap) surfaces as that named error rather than as a failed transaction.
   */
  async createSeries(
    wallet: WalletClient,
    params: {
      stock: Address;
      strikeX8: bigint;
      tradingDay: bigint;
      rawStock: bigint;
      to?: Address;
    },
  ): Promise<Hex> {
    const account = wallet.account;
    if (!account) throw new Error("wallet client has no account");
    const { request } = await this.publicClient.simulateContract({
      address: this.addresses.factory,
      abi: fletcherfactoryAbi,
      functionName: "createSeries",
      args: [
        params.stock,
        params.strikeX8,
        params.tradingDay,
        params.rawStock,
        params.to ?? account.address,
      ],
      account,
    });
    return wallet.writeContract(request);
  }

  /** Deposit stock into an existing series and receive both legs. */
  async mint(wallet: WalletClient, series: Address, rawStock: bigint, to?: Address): Promise<Hex> {
    const account = wallet.account;
    if (!account) throw new Error("wallet client has no account");
    const { request } = await this.publicClient.simulateContract({
      address: series,
      abi: seriesAbi,
      functionName: "mint",
      args: [to ?? account.address, rawStock],
      account,
    });
    return wallet.writeContract(request);
  }

  /** Burn both legs and take the stock back. Free, and available for the life of the series. */
  async merge(wallet: WalletClient, series: Address, amount: bigint, to?: Address): Promise<Hex> {
    const account = wallet.account;
    if (!account) throw new Error("wallet client has no account");
    const { request } = await this.publicClient.simulateContract({
      address: series,
      abi: seriesAbi,
      functionName: "merge",
      args: [to ?? account.address, amount],
      account,
    });
    return wallet.writeContract(request);
  }

  /** Settle a matured series. Permissionless: it can only produce the published close. */
  async settle(wallet: WalletClient, series: Address): Promise<Hex> {
    const account = wallet.account;
    if (!account) throw new Error("wallet client has no account");
    const { request } = await this.publicClient.simulateContract({
      address: series,
      abi: seriesAbi,
      functionName: "settle",
      account,
    });
    return wallet.writeContract(request);
  }

  /** After settlement, burn whatever legs you hold for the stock they are owed. */
  async redeem(
    wallet: WalletClient,
    series: Address,
    floorAmount: bigint,
    turboAmount: bigint,
    to?: Address,
  ): Promise<Hex> {
    const account = wallet.account;
    if (!account) throw new Error("wallet client has no account");
    const { request } = await this.publicClient.simulateContract({
      address: series,
      abi: seriesAbi,
      functionName: "redeem",
      args: [to ?? account.address, floorAmount, turboAmount],
      account,
    });
    return wallet.writeContract(request);
  }

  /** Open a series and seed both books in one transaction. */
  async launch(
    wallet: WalletClient,
    params: {
      stock: Address;
      strikeX8: bigint;
      tradingDay: bigint;
      rawStock: bigint;
      referencePriceX8: bigint;
    },
  ): Promise<Hex> {
    const account = wallet.account;
    if (!account) throw new Error("wallet client has no account");
    const { request } = await this.publicClient.simulateContract({
      address: this.addresses.launchpad,
      abi: fletcherlaunchpadAbi,
      functionName: "launch",
      args: [params],
      account,
    });
    return wallet.writeContract(request);
  }

  /** Sweep a launch's accrued swap fees to its launcher. Callable by anyone. */
  async collectFees(wallet: WalletClient, series: Address): Promise<Hex> {
    const account = wallet.account;
    if (!account) throw new Error("wallet client has no account");
    const { request } = await this.publicClient.simulateContract({
      address: this.addresses.launchpad,
      abi: fletcherlaunchpadAbi,
      functionName: "collectFees",
      args: [series],
      account,
    });
    return wallet.writeContract(request);
  }
}

export { maturityFor };
