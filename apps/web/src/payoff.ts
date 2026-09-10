/**
 * The payoff chart.
 *
 * This is the single most important thing on the site. A split-share instrument is completely
 * unintuitive described in words and completely obvious drawn: FLOOR rises with the stock and then
 * flattens at the split point, TURBO is flat at zero and then rises with slope one, and the two
 * curves stacked are the stock itself. Someone who has never heard of a turbo certificate
 * understands the product in about two seconds from this picture.
 *
 * Rendered as inline SVG with no charting dependency, because the shape is two polylines and a
 * dashed rule, and a library would be more code than the drawing.
 */
import { quoteLegs, formatUsd, WAD, type SettlementShares } from "@fletcher/sdk";

export interface PayoffOptions {
  strikeX8: bigint;
  /** Where the underlying is now, drawn as a marker. Omit to draw the curves alone. */
  spotX8?: bigint;
  multiplier?: bigint;
  width?: number;
  height?: number;
  /** Price range to draw. Defaults to 0 through twice the split point. */
  maxX8?: bigint;
}

const PAD_LEFT = 46;
const PAD_RIGHT = 14;
const PAD_TOP = 14;
const PAD_BOTTOM = 30;

/**
 * Both legs' intrinsic value across a price range.
 *
 * Intrinsic, not market: this draws what the contract will pay at settlement. A dated TURBO trades
 * above its intrinsic line for the same reason any option does, and the gap between the two is the
 * thing a buyer is actually deciding about.
 */
export function payoffSeries(
  strikeX8: bigint,
  maxX8: bigint,
  steps = 96,
  multiplier = WAD,
): { priceX8: bigint; floorX8: bigint; turboX8: bigint }[] {
  const points: { priceX8: bigint; floorX8: bigint; turboX8: bigint }[] = [];
  for (let i = 0; i <= steps; i++) {
    const priceX8 = (maxX8 * BigInt(i)) / BigInt(steps);
    const { floorValueX8, turboValueX8 } = quoteLegs(priceX8, strikeX8, multiplier);
    points.push({ priceX8, floorX8: floorValueX8, turboX8: turboValueX8 });
  }
  return points;
}

export function renderPayoff(options: PayoffOptions): string {
  const {
    strikeX8,
    spotX8,
    multiplier = WAD,
    width = 560,
    height = 300,
    maxX8 = strikeX8 * 2n,
  } = options;

  const points = payoffSeries(strikeX8, maxX8, 96, multiplier);

  // The vertical range is the largest value either leg reaches, not the price range. FLOOR tops out
  // at the split point and TURBO at `max - strike`, so scaling to the price would leave the curves
  // in the bottom half of a plot the reader is looking at the middle of.
  const maxLegX8 = points.reduce((m, p) => {
    const hi = p.floorX8 > p.turboX8 ? p.floorX8 : p.turboX8;
    return hi > m ? hi : m;
  }, 1n);
  const maxY = (Number(maxLegX8) / 1e8) * 1.08;

  const plotW = width - PAD_LEFT - PAD_RIGHT;
  const plotH = height - PAD_TOP - PAD_BOTTOM;

  const x = (priceX8: bigint) => PAD_LEFT + (Number(priceX8) / Number(maxX8)) * plotW;
  const y = (valueX8: bigint) => PAD_TOP + plotH - (Number(valueX8) / 1e8 / maxY) * plotH;

  const path = (pick: (p: (typeof points)[number]) => bigint) =>
    points.map((p, i) => `${i === 0 ? "M" : "L"}${x(p.priceX8).toFixed(1)},${y(pick(p)).toFixed(1)}`).join(" ");

  const ticks = 4;
  const gridlines = Array.from({ length: ticks + 1 }, (_, i) => {
    const value = (maxY * i) / ticks;
    const yy = PAD_TOP + plotH - (i / ticks) * plotH;
    return `<line class="gridline" x1="${PAD_LEFT}" y1="${yy.toFixed(1)}" x2="${width - PAD_RIGHT}" y2="${yy.toFixed(1)}" />
      <text class="tick" x="${PAD_LEFT - 8}" y="${(yy + 3.5).toFixed(1)}" text-anchor="end">${value.toFixed(0)}</text>`;
  }).join("");

  const maxPrice = Number(maxX8) / 1e8;
  const xTicks = Array.from({ length: ticks + 1 }, (_, i) => {
    // The horizontal axis is the share price. It is NOT `maxY`, which scales to the largest leg
    // value and is a different quantity entirely.
    const value = (maxPrice * i) / ticks;
    const xx = PAD_LEFT + (i / ticks) * plotW;
    return `<text class="tick" x="${xx.toFixed(1)}" y="${height - PAD_BOTTOM + 15}" text-anchor="middle">${value.toFixed(0)}</text>`;
  }).join("");

  const strikeX = x(strikeX8);
  const labelRight = strikeX < PAD_LEFT + plotW * 0.7;
  // Whole dollars when the split point is a whole dollar, two places when it is not: a label
  // reading "split 169" beside a panel reading 169.57 looks like one of the two is wrong.
  const labelText = `split ${formatUsd(strikeX8, strikeX8 % 100000000n === 0n ? 0 : 2)}`;
  const labelWidth = labelText.length * 6.2 + 8;
  const labelX = labelRight ? strikeX + 6 : strikeX - 6 - labelWidth;
  const strikeMark = `
    <line class="strike-line" x1="${strikeX.toFixed(1)}" y1="${PAD_TOP}" x2="${strikeX.toFixed(1)}" y2="${PAD_TOP + plotH}" />
    <rect x="${labelX.toFixed(1)}" y="${PAD_TOP + 2}" width="${labelWidth.toFixed(1)}" height="15" rx="3" fill="var(--bg-raised)" />
    <text class="strike-label" x="${(labelX + 4).toFixed(1)}" y="${PAD_TOP + 13}">${labelText}</text>`;

  const spotMark =
    spotX8 === undefined
      ? ""
      : `<line class="cursor-line" x1="${x(spotX8).toFixed(1)}" y1="${PAD_TOP}" x2="${x(spotX8).toFixed(1)}" y2="${PAD_TOP + plotH}" />
         <circle cx="${x(spotX8).toFixed(1)}" cy="${y(quoteLegs(spotX8, strikeX8, multiplier).floorValueX8).toFixed(1)}" r="3.5" fill="var(--floor)" />
         <circle cx="${x(spotX8).toFixed(1)}" cy="${y(quoteLegs(spotX8, strikeX8, multiplier).turboValueX8).toFixed(1)}" r="3.5" fill="var(--turbo)" />`;

  return `<svg class="chart" viewBox="0 0 ${width} ${height}" role="img"
    aria-label="Payoff at settlement. FLOOR rises with the share price and flattens at the ${formatUsd(strikeX8)} split point. TURBO is worthless below the split point and rises one for one above it. The two together always equal the share.">
    ${gridlines}
    ${xTicks}
    ${strikeMark}
    <line class="axis" x1="${PAD_LEFT}" y1="${PAD_TOP + plotH}" x2="${width - PAD_RIGHT}" y2="${PAD_TOP + plotH}" />
    <line class="axis" x1="${PAD_LEFT}" y1="${PAD_TOP}" x2="${PAD_LEFT}" y2="${PAD_TOP + plotH}" />
    <path class="floor-line" d="${path((p) => p.floorX8)}" />
    <path class="turbo-line" d="${path((p) => p.turboX8)}" />
    ${spotMark}
    <text class="tick axis-caption" x="${PAD_LEFT + plotW / 2}" y="${height - 3}" text-anchor="middle">share price at settlement (USD)</text>
  </svg>`;
}

/** A one-line plain-English reading of where a holder stands. */
export function describeOutcome(shares: SettlementShares, closeX8: bigint, strikeX8: bigint): string {
  if (shares.turboPerUnit === 0n) {
    return `Closed at ${formatUsd(closeX8)}, at or below the ${formatUsd(strikeX8)} split point. FLOOR takes the whole vault; TURBO expires worthless and owes nothing.`;
  }
  const floorPct = (Number(shares.floorPerUnit) / 1e18) * 100;
  return `Closed at ${formatUsd(closeX8)}, above the ${formatUsd(strikeX8)} split point. FLOOR takes ${floorPct.toFixed(1)}% of the vault and TURBO takes the remaining ${(100 - floorPct).toFixed(1)}%.`;
}
