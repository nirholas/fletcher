/**
 * The app.
 *
 * A small hand-rolled render loop rather than a framework: the whole surface is three views over
 * one state object, and the payoff chart is the only thing that redraws often. Adding a framework
 * here would be more code than the app.
 */
import {
  FletcherClient,
  publicClientFor,
  parseUsd,
  strikeForLeverage,
  tradingDayFor,
  WAD,
  type SeriesState,
} from "@fletcher/sdk";
import { parseEther } from "viem";
import { ADDRESSES, RPC_URL } from "./config.js";
import { connect, restore, hasWallet, onWalletChange, describeWalletError, NO_WALLET, type WalletState } from "./wallet.js";
import {
  shell,
  seriesTable,
  seriesDetail,
  launchView,
  howView,
  loadingTable,
  emptyState,
  errorState,
  notDeployedState,
  type Tab,
} from "./views.js";

interface AppState {
  tab: Tab;
  loading: boolean;
  error: string | null;
  series: SeriesState[];
  selected: string | null;
  spotPrices: Map<string, bigint>;
  launch: {
    symbol: string;
    spotInput: string;
    leverageInput: string;
    depositInput: string;
    daysInput: string;
  };
  wallet: WalletState;
  pending: boolean;
  message: string | null;
}

const state: AppState = {
  tab: "series",
  loading: false,
  error: null,
  series: [],
  selected: null,
  spotPrices: new Map(),
  launch: {
    symbol: "NVDA",
    spotInput: "178.50",
    leverageInput: "20",
    depositInput: "10",
    daysInput: "1",
  },
  wallet: NO_WALLET,
  pending: false,
  message: null,
};

const root = document.getElementById("app");
if (!root) throw new Error("#app is missing from the document");

function body(): string {
  if (state.tab === "how") return howView();
  if (state.tab === "launch") {
    return launchView(state.launch, {
      connected: state.wallet.account !== null,
      hasWallet: hasWallet(),
      deployed: ADDRESSES !== null,
      pending: state.pending,
      message: state.message ?? state.wallet.error,
    });
  }

  if (!ADDRESSES) return notDeployedState();
  if (state.error) return errorState(state.error, RPC_URL);
  if (state.loading) return loadingTable();
  if (state.series.length === 0) return emptyState();

  const selected = state.series.find((s) => s.address === state.selected) ?? state.series[0];
  const table = seriesTable(state.series, selected?.address ?? null, state.spotPrices);
  const detail = selected
    ? seriesDetail(selected, state.spotPrices.get(selected.stock.toLowerCase()) ?? null)
    : "";
  return `${table}<div style="height:16px"></div>${detail}`;
}

function render(): void {
  // Focus is restored by identity rather than preserved by diffing: the app re-renders whole views,
  // and a launch form that loses the caret every keystroke is unusable.
  const active = document.activeElement as HTMLElement | null;
  const activeKey = active?.dataset?.["input"] ?? null;
  const caret = active instanceof HTMLInputElement ? active.selectionStart : null;

  root!.innerHTML = shell(state.tab, body(), state.wallet.account);

  if (activeKey) {
    const restored = root!.querySelector<HTMLInputElement>(`[data-input="${activeKey}"]`);
    if (restored) {
      restored.focus();
      if (caret !== null) restored.setSelectionRange(caret, caret);
    }
  }
}

async function load(): Promise<void> {
  if (!ADDRESSES) return;
  state.loading = true;
  state.error = null;
  render();

  try {
    const client = new FletcherClient(ADDRESSES, publicClientFor(RPC_URL));
    const addresses = await client.listSeries();
    // Sequential rather than a Promise.all storm: every public endpoint on this chain rate limits,
    // and a table of thirty series firing thirty concurrent multicalls gets 429ed into a false error
    // state that looks like the protocol is down.
    const series: SeriesState[] = [];
    for (const address of addresses) {
      series.push(await client.getSeries(address));
    }
    state.series = series;
    state.selected = series[0]?.address ?? null;
    state.error = null;
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error);
  } finally {
    state.loading = false;
    render();
  }
}

/**
 * Open a series and seed both books.
 *
 * The SDK simulates before it sends, so a refusal the contracts define (an illiquid name, a strike
 * outside the band, notional past the depth cap, a halted equity) arrives here as that named error
 * and is shown as-is. Guessing at a friendlier wording would hide which gate actually fired.
 */
async function doLaunch(): Promise<void> {
  if (!ADDRESSES || !state.wallet.client) return;
  const spot = parseUsd(state.launch.spotInput);
  const leverage = BigInt(Math.round(Number(state.launch.leverageInput) * 1e6)) * 10n ** 12n;
  if (spot <= 0n || leverage <= WAD) {
    state.message = "Enter a positive share price and a leverage above 1x.";
    render();
    return;
  }

  state.pending = true;
  state.message = null;
  render();

  try {
    const client = new FletcherClient(ADDRESSES, publicClientFor(RPC_URL));
    const days = Math.max(1, Number(state.launch.daysInput) || 1);
    const tradingDay = tradingDayFor(new Date(Date.now() + days * 86_400_000));
    const hash = await client.launch(state.wallet.client, {
      stock: state.launch.symbol as `0x${string}`,
      strikeX8: strikeForLeverage(spot, leverage),
      tradingDay,
      rawStock: parseEther(state.launch.depositInput || "0"),
      referencePriceX8: spot,
    });
    state.message = `Submitted: ${hash}`;
    state.tab = "series";
    await load();
  } catch (error) {
    state.message = describeWalletError(error);
  } finally {
    state.pending = false;
    render();
  }
}

// --- events ------------------------------------------------------------------------------------

root.addEventListener("click", (event) => {
  const target = event.target as HTMLElement;

  const tab = target.closest<HTMLElement>("[data-tab]")?.dataset["tab"] as Tab | undefined;
  if (tab) {
    state.tab = tab;
    render();
    if (tab === "series" && ADDRESSES && state.series.length === 0 && !state.loading) void load();
    return;
  }

  if (target.closest('[data-action="retry"]')) {
    void load();
    return;
  }

  if (target.closest('[data-action="connect"]')) {
    void (async () => {
      state.message = null;
      state.wallet = await connect();
      render();
    })();
    return;
  }

  if (target.closest('[data-action="launch"]')) {
    void doLaunch();
    return;
  }

  const row = target.closest<HTMLElement>("[data-series]");
  if (row) {
    state.selected = row.dataset["series"] ?? null;
    render();
  }
});

// Rows are buttons, so they answer the keyboard the way buttons do.
root.addEventListener("keydown", (event) => {
  if (event.key !== "Enter" && event.key !== " ") return;
  const row = (event.target as HTMLElement).closest<HTMLElement>("[data-series]");
  if (!row) return;
  event.preventDefault();
  state.selected = row.dataset["series"] ?? null;
  render();
});

root.addEventListener("input", (event) => {
  const input = event.target as HTMLInputElement;
  const key = input.dataset["input"];
  if (!key) return;
  const map: Record<string, keyof AppState["launch"]> = {
    symbol: "symbol",
    spot: "spotInput",
    leverage: "leverageInput",
    deposit: "depositInput",
    days: "daysInput",
  };
  const field = map[key];
  if (!field) return;
  state.launch[field] = input.value;
  render();
});

// A wallet the user already authorised should not need a second click on every reload, and a switch
// of account or network inside the wallet has to reach the page.
onWalletChange(() => {
  void restore().then((w) => {
    state.wallet = w;
    render();
  });
});

render();
void restore().then((w) => {
  state.wallet = w;
  render();
});
if (ADDRESSES) void load();
