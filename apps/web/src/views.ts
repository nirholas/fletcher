/**
 * The views, as functions from state to HTML.
 *
 * Every view renders each of its states explicitly. A loading table is a skeleton with the right
 * number of columns, an empty protocol says what to do next, and a failed read names the endpoint
 * and offers a retry. None of them is a spinner over a blank page.
 */
import {
  formatUsd,
  formatLeverage,
  turboLeverage,
  settlementShares,
  floorDiscountBps,
  annualisedFundingBps,
  parseUsd,
  strikeForLeverage,
  WAD,
  type SeriesState,
} from "@fletcher/sdk";
import { renderPayoff, describeOutcome } from "./payoff.js";
import { formatUnits18, formatTradingDay, formatCountdown, shortAddress, formatPercent, formatBps } from "./format.js";
import { EXPLORER } from "./config.js";

export type Tab = "series" | "launch" | "how";

export function shell(tab: Tab, body: string, account: string | null): string {
  const tabButton = (id: Tab, label: string) =>
    `<button type="button" data-tab="${id}"${tab === id ? ' aria-current="page"' : ""}>${label}</button>`;
  const wallet = account
    ? `<span class="pill live" title="${escape(account)}">${escape(shortAddress(account))}</span>`
    : "";
  return `
    <div class="shell">
      <header class="top">
        <div class="brand">Fletcher <span class="tag">turbos and floors for tokenized stocks</span></div>
        <div style="display:flex;align-items:center;gap:12px">
          ${wallet}
          <nav class="tabs" aria-label="Sections">
            ${tabButton("series", "Series")}
            ${tabButton("launch", "Launch")}
            ${tabButton("how", "How it works")}
          </nav>
        </div>
      </header>
      <main id="main">${body}</main>
    </div>`;
}

// --- states ------------------------------------------------------------------------------------

export function loadingTable(): string {
  const row = `<tr>${Array.from({ length: 7 }, () => '<td><div class="skeleton"></div></td>').join("")}</tr>`;
  return `<div class="panel">
    <h2>Live series</h2>
    <p class="sub">Reading the factory.</p>
    <div class="table-scroll"><table class="series"><tbody>${row.repeat(4)}</tbody></table></div>
  </div>`;
}

export function errorState(message: string, rpcUrl: string): string {
  return `<div class="error" role="alert">
    <h3>Could not read the chain</h3>
    <p>${escape(message)}</p>
    <p style="margin-top:10px">
      Endpoint: <code>${escape(rpcUrl)}</code>. Robinhood Chain's public endpoints rate limit, and only
      the archive endpoint serves historical state.
    </p>
    <p style="margin-top:14px"><button class="primary" style="max-width:200px" data-action="retry">Try again</button></p>
  </div>`;
}

/**
 * The honest state for an undeployed protocol. It still teaches the instrument, using the same
 * arithmetic the contracts use, so the page is worth loading before anything is on chain.
 */
export function notDeployedState(): string {
  const strike = parseUsd("170.00");
  const spot = parseUsd("178.50");
  return `
  <div class="grid two">
    <div class="panel">
      <h2>One share, split in two</h2>
      <p class="sub">
        Deposit a tokenized stock and the contract mints two tradeable halves against it. The two
        together are always exactly the share, so nothing is ever under-collateralised.
      </p>
      ${renderPayoff({ strikeX8: strike, spotX8: spot })}
      <div style="display:flex;gap:16px;margin-top:12px;flex-wrap:wrap">
        <span class="leg-badge floor">Floor</span>
        <span style="font-size:13px;color:var(--text-dim)">first claim up to the split point, plus the dividend accrual</span>
      </div>
      <div style="display:flex;gap:16px;margin-top:8px;flex-wrap:wrap">
        <span class="leg-badge turbo">Turbo</span>
        <span style="font-size:13px;color:var(--text-dim)">everything above the split point, and nothing below it</span>
      </div>
    </div>
    <div>
      <div class="panel">
        <h2>An NVDA series at ${formatUsd(strike)}</h2>
        <p class="sub">With the share at ${formatUsd(spot)}.</p>
        ${statRow([
          ["Turbo leverage", formatLeverage(turboLeverage(spot, strike)), "turbo"],
          ["Floor claim", formatUsd(strike), "floor"],
          ["Collateral", "100%", ""],
        ])}
        <p class="note">
          Fully collateralised at mint. No liquidation engine, no margin call, no protocol balance
          sheet, and no bad debt: the vault divides into two shares that sum to one at every possible
          close, so it can never owe more than it holds.
        </p>
      </div>
      <div class="panel" style="margin-top:16px">
        <h2>Not deployed yet</h2>
        <p class="sub">The contracts are written, tested and ready. Nothing is live on chain 4663.</p>
        <p style="font-size:13px;color:var(--text-dim);margin:0 0 12px">
          To point this app at a deployment, set these in <code>apps/web/.env.local</code> and restart:
        </p>
        <pre style="font-family:var(--mono);font-size:11.5px;background:var(--bg-inset);padding:12px;border-radius:var(--radius-sm);overflow-x:auto;margin:0;color:var(--text-dim)">VITE_FLETCHER_FACTORY=0x...
VITE_FLETCHER_LAUNCHPAD=0x...
VITE_FLETCHER_SETTLEMENT_SOURCE=0x...
VITE_FLETCHER_ACCOUNTANT=0x...
VITE_FLETCHER_DEPTH_GATE=0x...</pre>
        <p class="note">
          Deploy with <code>forge script script/Deploy.s.sol</code>. It needs a
          <code>SHERWOOD_ORACLE</code>: Fletcher settles against Sherwood's reporter quorum rather
          than shipping a second oracle with a second reporter set.
        </p>
      </div>
    </div>
  </div>`;
}

export function emptyState(): string {
  return `<div class="panel">
    <h2>Live series</h2>
    <p class="sub">Reading the factory.</p>
    <div class="empty">
      <h3>No series yet</h3>
      <p>
        Nobody has opened one. Creation is permissionless: pick a ticker with measured depth, a split
        point, and a maturity inside ninety days, then deposit. The market decides which split points
        survive, not a listing committee.
      </p>
      <p style="margin-top:14px">
        <button class="primary" style="max-width:220px" data-tab="launch">Open the first series</button>
      </p>
    </div>
  </div>`;
}

// --- the series table --------------------------------------------------------------------------

export function seriesTable(list: SeriesState[], selected: string | null, spotPrices: Map<string, bigint>): string {
  const rows = list
    .map((s) => {
      const spot = spotPrices.get(s.stock.toLowerCase()) ?? s.strikeX8;
      const leverage = turboLeverage(spot, s.strikeX8);
      return `<tr data-series="${s.address}" tabindex="0" role="button"
        ${selected === s.address ? 'aria-selected="true"' : ""}>
        <td><strong>${escape(s.stockSymbol)}</strong></td>
        <td class="num">${formatUsd(s.strikeX8)}</td>
        <td>${formatTradingDay(s.tradingDay)}</td>
        <td class="num">${s.settled ? "settled" : formatCountdown(s.maturity)}</td>
        <td class="num turbo-cell">${leverage === 0n ? "—" : formatLeverage(leverage)}</td>
        <td class="num">${formatUnits18(s.collateralRaw, 2)}</td>
        <td>${statusPill(s)}</td>
      </tr>`;
    })
    .join("");

  return `<div class="panel">
    <h2>Live series</h2>
    <p class="sub">${list.length} series. Select one to see its payoff and act on it.</p>
    <div class="table-scroll">
      <table class="series">
        <thead><tr>
          <th scope="col">Ticker</th>
          <th scope="col" class="num">Split point</th>
          <th scope="col">Settles</th>
          <th scope="col" class="num">Maturity</th>
          <th scope="col" class="num">Turbo leverage</th>
          <th scope="col" class="num">Collateral</th>
          <th scope="col">Status</th>
        </tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>
  </div>`;
}

function statusPill(s: SeriesState): string {
  if (s.settled) return '<span class="pill settled">Settled</span>';
  if (s.frozen) return '<span class="pill frozen" title="An unclassifiable corporate action froze this series. Merge still works at par.">Frozen</span>';
  if (!s.isSynced) return '<span class="pill halted" title="The equity is halted. Transfers revert until it lifts.">Halted</span>';
  return '<span class="pill live">Live</span>';
}

// --- series detail -----------------------------------------------------------------------------

export function seriesDetail(s: SeriesState, spotX8: bigint | null): string {
  const spot = spotX8 ?? s.strikeX8;
  const shares = settlementShares(spot, s.strikeX8);
  const leverage = turboLeverage(spot, s.strikeX8);

  const settledBlock = s.settled && s.shares
    ? `<p class="note">${escape(describeOutcome(s.shares, s.settlementPriceX8, s.strikeX8))}</p>`
    : "";

  const frozenBlock = s.frozen
    ? `<p class="note" style="border-left-color:var(--warn)">
        A corporate action on ${escape(s.stockSymbol)} could not be classified as either a
        distribution or a clean split ratio, so this series stopped settling rather than moving its
        split point on a guess. Merging still works at par: burn equal amounts of both legs and take
        the stock back.
      </p>`
    : "";

  return `<div class="grid two">
    <div class="panel">
      <h2>${escape(s.stockSymbol)} · ${formatUsd(s.strikeX8)} · ${formatTradingDay(s.tradingDay)}</h2>
      <p class="sub">
        ${s.settled ? `Settled at ${formatUsd(s.settlementPriceX8)}.` : `Settles ${formatCountdown(s.maturity)} against the official close.`}
      </p>
      ${renderPayoff({ strikeX8: s.strikeX8, spotX8: spot, multiplier: s.observedMultiplier })}
      ${settledBlock}
      ${frozenBlock}
    </div>
    <div>
      <div class="panel">
        <h2>Where it stands</h2>
        <p class="sub">At a ${formatUsd(spot)} share.</p>
        ${statRow([
          ["Floor share", formatPercent(shares.floorPerUnit), "floor"],
          ["Turbo share", formatPercent(shares.turboPerUnit), "turbo"],
          ["Turbo leverage", leverage === 0n ? "—" : formatLeverage(leverage), "turbo"],
        ])}
        <div style="height:12px"></div>
        ${statRow([
          ["Collateral", formatUnits18(s.collateralRaw, 2), ""],
          ["Floor supply", formatUnits18(s.floorSupply, 2), "floor"],
          ["Turbo supply", formatUnits18(s.turboSupply, 2), "turbo"],
        ])}
        <p class="note">
          Multiplier ${(Number(s.observedMultiplier) / 1e18).toFixed(6)}. A distribution raises it and
          leaves the split point alone, which is how Floor accrues the dividend. A split divides the
          split point by the same ratio, so Turbo's leverage survives it.
        </p>
      </div>
      <div class="panel" style="margin-top:16px">
        <h2>Contracts</h2>
        <p class="sub">Everything is verifiable on the explorer.</p>
        ${addressRow("Series", s.address)}
        ${addressRow("Floor", s.floorToken)}
        ${addressRow("Turbo", s.turboToken)}
        ${addressRow("Underlying", s.stock)}
      </div>
    </div>
  </div>`;
}

function addressRow(label: string, address: string): string {
  return `<div style="display:flex;justify-content:space-between;align-items:center;padding:7px 0;border-bottom:1px solid var(--border);font-size:13px">
    <span style="color:var(--text-dim)">${escape(label)}</span>
    <a href="${EXPLORER}/address/${address}" target="_blank" rel="noopener noreferrer"
       style="font-family:var(--mono);color:var(--floor);text-decoration:none">${shortAddress(address)}</a>
  </div>`;
}

function statRow(stats: [string, string, string][]): string {
  return `<dl class="stat-row">${stats
    .map(
      ([label, value, tone]) =>
        `<div class="stat"><dt>${escape(label)}</dt><dd class="${tone}">${escape(value)}</dd></div>`,
    )
    .join("")}</dl>`;
}

// --- launch ------------------------------------------------------------------------------------

export interface LaunchFormState {
  symbol: string;
  spotInput: string;
  leverageInput: string;
  depositInput: string;
  daysInput: string;
}

export interface LaunchChrome {
  connected: boolean;
  hasWallet: boolean;
  deployed: boolean;
  pending: boolean;
  message: string | null;
}

export function launchView(state: LaunchFormState, chrome: LaunchChrome): string {
  const spot = safeParseUsd(state.spotInput);
  const leverage = safeLeverage(state.leverageInput);
  const strike = spot > 0n && leverage > WAD ? strikeForLeverage(spot, leverage) : 0n;
  const actual = strike > 0n ? turboLeverage(spot, strike) : 0n;
  // Illustrative, and scaled with the tenor: a flat half-percent discount would annualise to 182%
  // on a one-day series and 6% on a thirty-day one, which says nothing about either. Five basis
  // points per day is a realistic funding level that stays comparable across maturities.
  const exampleDiscountBps = 5n * BigInt(Math.max(1, Number(state.daysInput) || 1));
  const discount = strike > 0n ? exampleDiscountBps : 0n;
  const days = Number(state.daysInput) || 1;

  return `<div class="grid two">
    <div class="panel">
      <h2>What you would be opening</h2>
      <p class="sub">
        ${strike > 0n
          ? `${escape(state.symbol)} split at ${formatUsd(strike)}, settling in ${days} day${days === 1 ? "" : "s"}.`
          : "Enter a share price and a target leverage."}
      </p>
      ${strike > 0n ? renderPayoff({ strikeX8: strike, spotX8: spot }) : `<div class="empty"><h3>Nothing to draw yet</h3><p>The payoff curve appears once the terms are set.</p></div>`}
      ${strike > 0n
        ? statRow([
            ["Split point", formatUsd(strike), "floor"],
            ["Turbo leverage", formatLeverage(actual), "turbo"],
            ["Floor claim", formatUsd(strike), "floor"],
          ])
        : ""}
    </div>
    <div>
      <div class="panel">
        <h2>Terms</h2>
        <p class="sub">One transaction opens the series and seeds both books.</p>
        <label class="field">
          <span>Ticker</span>
          <input type="text" data-input="symbol" value="${escape(state.symbol)}" autocomplete="off" spellcheck="false" />
          <span class="hint">Must have measured depth in a quote-paired Uniswap v3 pool.</span>
        </label>
        <label class="field">
          <span>Share price (USD)</span>
          <input type="text" inputmode="decimal" data-input="spot" value="${escape(state.spotInput)}" />
          <span class="hint">Checked against the settlement source, never a pool price.</span>
        </label>
        <label class="field">
          <span>Target turbo leverage</span>
          <input type="text" inputmode="decimal" data-input="leverage" value="${escape(state.leverageInput)}" />
          <span class="hint">The split point follows from this: k = p × (1 − 1/L).</span>
        </label>
        <label class="field">
          <span>Days to settlement</span>
          <input type="text" inputmode="numeric" data-input="days" value="${escape(state.daysInput)}" />
          <span class="hint">Dated daily. Ninety days is the maximum tenor.</span>
        </label>
        <label class="field">
          <span>Deposit (shares)</span>
          <input type="text" inputmode="decimal" data-input="deposit" value="${escape(state.depositInput)}" />
          <span class="hint">Half is split into legs, half becomes the quote side of both books.</span>
        </label>
        ${launchButton(chrome, strike > 0n)}
        ${chrome.message ? `<p class="note" style="border-left-color:var(--warn)">${escape(chrome.message)}</p>` : ""}
        <p class="note">
          You keep the swap fees on both legs for as long as the series exists. The liquidity is
          locked: the launchpad has no function that removes principal, so nobody can pull it,
          including you.
        </p>
      </div>
      ${strike > 0n
        ? `<div class="panel" style="margin-top:16px">
            <h2>The funding rate</h2>
            <p class="sub">Set by the market, never published by the protocol.</p>
            <p style="font-size:13px;color:var(--text-dim);margin:0">
              Floor buyers are lending and Turbo buyers are borrowing. The rate is whatever discount
              clears the two books against each other, and it is read off Floor's price rather than
              set anywhere. A Floor trading ${formatBps(discount)} under its ${formatUsd(strike)}
              claim over ${days} day${days === 1 ? "" : "s"} is
              <strong style="color:var(--text)">${formatBps(annualisedFundingBps(discount, days))}</strong>
              annualised.
            </p>
          </div>`
        : ""}
    </div>
  </div>`;
}

/**
 * One button, four honest states. A control that is permanently disabled with no stated reason is
 * the dead path the rest of this app is built to avoid.
 */
function launchButton(chrome: LaunchChrome, termsReady: boolean): string {
  if (!chrome.deployed) {
    return `<button class="primary" disabled title="No factory address is configured for this build.">Not deployed on this network</button>`;
  }
  if (!chrome.hasWallet) {
    return `<button class="primary" disabled title="No injected EIP-1193 provider was found.">No wallet detected</button>`;
  }
  if (!chrome.connected) {
    return `<button class="primary" data-action="connect">Connect wallet</button>`;
  }
  if (!termsReady) {
    return `<button class="primary" disabled>Set a share price and a leverage</button>`;
  }
  return `<button class="primary" data-action="launch"${chrome.pending ? " disabled" : ""}>${
    chrome.pending ? "Confirm in your wallet…" : "Launch series"
  }</button>`;
}

function safeParseUsd(s: string): bigint {
  try {
    const v = parseUsd(s);
    return v > 0n ? v : 0n;
  } catch {
    return 0n;
  }
}

function safeLeverage(s: string): bigint {
  const n = Number(s);
  if (!Number.isFinite(n) || n <= 1) return 0n;
  return BigInt(Math.round(n * 1e6)) * 10n ** 12n;
}

// --- how it works ------------------------------------------------------------------------------

export function howView(): string {
  const strike = parseUsd("170.00");
  return `<div class="grid two">
    <div class="panel">
      <h2>The whole protocol</h2>
      <p class="sub">Four operations. Nothing else has state.</p>
      <pre style="font-family:var(--mono);font-size:12.5px;background:var(--bg-inset);padding:16px;border-radius:var(--radius-sm);overflow-x:auto;color:var(--text-dim);margin:0 0 18px">mint    R stock in        →  R FLOOR + R TURBO out
merge   R FLOOR + R TURBO  →  R stock out    (free, any time)
settle  once, at maturity, against the official close
redeem  each leg claims its share of the same vault</pre>
      ${renderPayoff({ strikeX8: strike, spotX8: parseUsd("178.50") })}
    </div>
    <div>
      <div class="panel">
        <h2>Why there is no liquidation engine</h2>
        <p style="font-size:13.5px;color:var(--text-dim);margin:0 0 12px">
          At settlement with close <em>P</em> and split point <em>K</em>, the vault's stock divides as
          <code>min(P,K)/P</code> to Floor and the rest to Turbo. Those two sum to one for every
          <em>P</em>, including a Turbo far in the money and a Floor far out of it.
        </p>
        <p style="font-size:13.5px;color:var(--text-dim);margin:0 0 12px">
          Turbo's leverage comes from the split point sitting just under the share price, not from
          borrowing. There is nothing to margin call and no bad debt to socialise.
        </p>
        <p style="font-size:13.5px;color:var(--text-dim);margin:0">
          That matters more on this chain than most. While a tokenized equity is halted its
          <code>transfer</code> reverts outright, so a protocol that needed to seize collateral could
          not do it at any incentive. Fletcher never needs to.
        </p>
      </div>
      <div class="panel" style="margin-top:16px">
        <h2>Why it never settles against a pool</h2>
        <p style="font-size:13.5px;color:var(--text-dim);margin:0 0 12px">
          On 30 August a launchpad-created AMC pair traded 35× above the real equity across a
          weekend, with the exchange shut and nobody able to arbitrage it closed. That price was
          real, on chain, and completely wrong.
        </p>
        <p style="font-size:13.5px;color:var(--text-dim);margin:0">
          A series settles on an official close carried by a reporter quorum, and refuses to settle
          at all unless the session is closed and the quote is usable. The pool is where the legs
          trade. It is never what they settle against.
        </p>
      </div>
      <div class="panel" style="margin-top:16px">
        <h2>Corporate actions</h2>
        <p style="font-size:13.5px;color:var(--text-dim);margin:0 0 12px">
          A tokenized equity carries its dividends and splits in one number, <code>uiMultiplier()</code>.
          A distribution raises it a few basis points; a split multiplies it by a clean ratio.
        </p>
        <p style="font-size:13.5px;color:var(--text-dim);margin:0 0 12px">
          Those need opposite treatment. A distribution leaves the split point alone, which is exactly
          what hands the accrual to Floor. A split divides the split point by the ratio, or a 2:1
          would silently hand Floor the entire vault.
        </p>
        <p style="font-size:13.5px;color:var(--text-dim);margin:0">
          Anything that is neither shape freezes the series into merge-only rather than moving a
          split point on a guess. Nobody is liquidated and every holder can still leave whole.
        </p>
      </div>
    </div>
  </div>`;
}

// --- utilities ---------------------------------------------------------------------------------

/** Escapes text before it reaches innerHTML. Every interpolated value goes through it. */
export function escape(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
