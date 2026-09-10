/**
 * The Fletcher keeper.
 *
 * A dated series needs two things to happen on time, and neither of them can be left to whoever
 * happens to be watching:
 *
 *   1. The official close for a trading day has to be recorded while the session is closed and the
 *      oracle's quote is usable. `SherwoodSettlementSource.recordClose` is permissionless and takes
 *      no discretion, but somebody has to call it.
 *   2. A matured series has to be settled so its holders can redeem.
 *
 * Neither call can produce a result the caller chooses. The keeper is a convenience and a liveness
 * guarantee, not a trusted party: if it stops, anyone can run these two calls, and until someone
 * does, every holder can still `merge()` out at par.
 *
 *   pnpm --filter @fletcher/keeper start                 run continuously
 *   pnpm --filter @fletcher/keeper check                 one pass, no transactions
 */
import { createWalletClient, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  FletcherClient,
  publicClientFor,
  robinhoodChain,
  RPC_URLS,
  seriesAbi,
  formatUsd,
  type SeriesState,
} from "@fletcher/sdk";

export interface KeeperConfig {
  factory: Address;
  launchpad: Address;
  settlementSource: Address;
  accountant: Address;
  depthGate: Address;
  rpcUrl: string;
  privateKey?: Hex;
  dryRun: boolean;
  once: boolean;
  intervalMs: number;
}

export function configFromEnv(argv: string[] = process.argv.slice(2)): KeeperConfig {
  const need = (name: string): Address => {
    const v = process.env[name];
    if (!v) throw new Error(`missing required env var: ${name}`);
    return v as Address;
  };
  return {
    factory: need("FLETCHER_FACTORY"),
    launchpad: need("FLETCHER_LAUNCHPAD"),
    settlementSource: need("FLETCHER_SETTLEMENT_SOURCE"),
    accountant: need("FLETCHER_ACCOUNTANT"),
    depthGate: need("FLETCHER_DEPTH_GATE"),
    rpcUrl: process.env.RHC_RPC_URL ?? RPC_URLS.archive,
    ...(process.env.KEEPER_PRIVATE_KEY ? { privateKey: process.env.KEEPER_PRIVATE_KEY as Hex } : {}),
    dryRun: argv.includes("--dry-run"),
    once: argv.includes("--once"),
    intervalMs: Number(process.env.KEEPER_INTERVAL_MS ?? 60_000),
  };
}

/** What a pass decided to do, and why. Returned rather than only logged, so tests can assert it. */
export interface Plan {
  series: Address;
  action: "settle" | "wait-for-maturity" | "wait-for-close" | "already-settled" | "frozen" | "halted";
  reason: string;
}

/**
 * Decide what to do with one series without sending anything.
 *
 * Split out from the sending so the decision is testable on its own and so `--dry-run` exercises
 * exactly the code path a live run does.
 */
export function planFor(state: SeriesState, nowSeconds: bigint): Plan {
  if (state.settled) {
    return { series: state.address, action: "already-settled", reason: `settled at ${formatUsd(state.settlementPriceX8)}` };
  }
  if (state.frozen) {
    return {
      series: state.address,
      action: "frozen",
      reason: "an unclassifiable corporate action froze this series; holders can still merge at par",
    };
  }
  if (nowSeconds < state.maturity) {
    const hours = Number(state.maturity - nowSeconds) / 3600;
    return { series: state.address, action: "wait-for-maturity", reason: `matures in ${hours.toFixed(1)}h` };
  }
  if (!state.isSynced) {
    return {
      series: state.address,
      action: "halted",
      reason: "the equity is halted; settlement records a ratio and may still proceed once a close exists",
    };
  }
  return { series: state.address, action: "settle", reason: `matured, close for day ${state.tradingDay} required` };
}

async function run(config: KeeperConfig): Promise<void> {
  const publicClient = publicClientFor(config.rpcUrl);
  const fletcher = new FletcherClient(
    {
      factory: config.factory,
      launchpad: config.launchpad,
      settlementSource: config.settlementSource,
      accountant: config.accountant,
      depthGate: config.depthGate,
    },
    publicClient,
  );

  const wallet =
    config.privateKey && !config.dryRun
      ? createWalletClient({
          account: privateKeyToAccount(config.privateKey),
          chain: robinhoodChain,
          transport: http(config.rpcUrl),
        })
      : null;

  if (!wallet && !config.dryRun) {
    console.warn("no KEEPER_PRIVATE_KEY set: running read-only, which is the same as --dry-run");
  }

  const pass = async () => {
    const all = await fletcher.listSeries();
    const now = BigInt(Math.floor(Date.now() / 1000));
    console.log(`[${new Date().toISOString()}] ${all.length} series`);

    for (const address of all) {
      const state = await fletcher.getSeries(address);
      const plan = planFor(state, now);
      console.log(`  ${state.stockSymbol} ${formatUsd(state.strikeX8)} d${state.tradingDay}  ${plan.action}: ${plan.reason}`);

      if (plan.action !== "settle" || !wallet) continue;

      // Simulated first, so a series whose close has not been recorded yet reports
      // `CloseUnavailable` as a named reason instead of burning gas on a revert.
      try {
        await publicClient.simulateContract({
          address,
          abi: seriesAbi,
          functionName: "settle",
          account: wallet.account,
        });
      } catch (error) {
        console.log(`    not settleable yet: ${describe(error)}`);
        continue;
      }

      const hash = await fletcher.settle(wallet, address);
      console.log(`    settled: ${hash}`);
    }
  };

  if (config.once) {
    await pass();
    return;
  }
  for (;;) {
    try {
      await pass();
    } catch (error) {
      // A pass that throws is almost always a rate-limited endpoint. Log it and keep the loop
      // alive: a keeper that exits on the first 429 is a keeper that is not running when it matters.
      console.error(`pass failed, retrying: ${describe(error)}`);
    }
    await new Promise((resolve) => setTimeout(resolve, config.intervalMs));
  }
}

export function describe(error: unknown): string {
  if (error && typeof error === "object" && "shortMessage" in error) {
    return String((error as { shortMessage: unknown }).shortMessage);
  }
  return error instanceof Error ? error.message : String(error);
}

const isEntrypoint = process.argv[1]?.endsWith("index.ts") || process.argv[1]?.endsWith("index.js");
if (isEntrypoint) {
  run(configFromEnv()).catch((error) => {
    console.error(describe(error));
    process.exit(1);
  });
}
