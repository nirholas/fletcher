/**
 * The series arithmetic, in the same fixed-point the contracts use.
 *
 * Every function here mirrors a function in `Series.sol` or `MultiplierAccountant.sol` and is
 * covered by a test that asserts the two agree. That parity matters more than it looks: a UI that
 * quotes a payout the contract will not pay is a UI that lies to a leveraged holder at exactly the
 * moment they can least afford it.
 *
 * Scales, kept deliberately distinct so a mismatch is a type error rather than a silent 1e10:
 *   - `X8`   USD per share, 1e8. Every price and split point.
 *   - `WAD`  1e18. Every ratio, share and multiplier.
 *   - raw    Token base units. Equities are 18 decimals, USDG is 6.
 */

export const WAD = 10n ** 18n;
export const X8 = 10n ** 8n;
export const BPS = 10_000n;

/** How the vault divides at settlement, per unit of each leg. The two always sum to WAD. */
export interface SettlementShares {
  /** Raw stock owed per unit of FLOOR, 1e18. */
  floorPerUnit: bigint;
  /** Raw stock owed per unit of TURBO, 1e18. */
  turboPerUnit: bigint;
}

/**
 * The whole protocol, in one function.
 *
 * FLOOR claims `min(close, strike)` of a `close`-priced share and TURBO claims the rest, so the
 * vault divides into two shares that sum to exactly one. Full collateralisation is a property of
 * this arithmetic, not a parameter anyone maintains.
 *
 * Mirrors `Series.settle()`.
 */
export function settlementShares(closeX8: bigint, strikeX8: bigint): SettlementShares {
  if (closeX8 <= 0n) throw new RangeError("close price must be positive");
  const floorClaim = closeX8 < strikeX8 ? closeX8 : strikeX8;
  const floorPerUnit = (floorClaim * WAD) / closeX8;
  return { floorPerUnit, turboPerUnit: WAD - floorPerUnit };
}

/** Raw stock a holding redeems for after settlement. Mirrors `Series.redeem()`. */
export function redeemValue(
  shares: SettlementShares,
  floorAmount: bigint,
  turboAmount: bigint,
): bigint {
  return (floorAmount * shares.floorPerUnit) / WAD + (turboAmount * shares.turboPerUnit) / WAD;
}

/**
 * What each leg is worth right now, in 1e8 USD per unit.
 *
 * This is intrinsic value, not a market price. A dated TURBO trades above intrinsic for the same
 * reason any option does, and the gap is the market's own funding rate: it is never published by
 * the protocol, it is read off FLOOR's discount. Mirrors `Series.quoteLegs()`.
 */
export function quoteLegs(
  priceX8: bigint,
  strikeX8: bigint,
  multiplier = WAD,
): { floorValueX8: bigint; turboValueX8: bigint } {
  const floorClaim = priceX8 < strikeX8 ? priceX8 : strikeX8;
  return {
    floorValueX8: (floorClaim * multiplier) / WAD,
    turboValueX8: ((priceX8 - floorClaim) * multiplier) / WAD,
  };
}

/**
 * TURBO's leverage against the underlying, 1e18.
 *
 * `price / (price - strike)`. Returns 0 at or below the strike, where TURBO has no delta and
 * leverage is undefined rather than infinite. Mirrors `Series.turboLeverage1e18()`.
 */
export function turboLeverage(priceX8: bigint, strikeX8: bigint): bigint {
  if (priceX8 <= strikeX8) return 0n;
  return (priceX8 * WAD) / (priceX8 - strikeX8);
}

/**
 * The split point that produces a target leverage at a given spot.
 *
 * `k = p * (1 - 1/L)`. This is the function a launcher actually wants: nobody picks a strike, they
 * pick "20x" and let the strike follow.
 */
export function strikeForLeverage(priceX8: bigint, leverageWad: bigint): bigint {
  if (leverageWad <= WAD) throw new RangeError("leverage must exceed 1x");
  return priceX8 - (priceX8 * WAD) / leverageWad;
}

/**
 * FLOOR's discount to its own claim, in basis points.
 *
 * This is the funding rate, and it is the number that decides whether a series is worth opening.
 * FLOOR buyers are lending; TURBO buyers are borrowing. Neither side is quoted a rate by the
 * protocol, so the rate is whatever discount clears the two books against each other.
 */
export function floorDiscountBps(floorMarketPriceX8: bigint, strikeX8: bigint): bigint {
  if (strikeX8 <= 0n) throw new RangeError("strike must be positive");
  if (floorMarketPriceX8 >= strikeX8) return 0n;
  return ((strikeX8 - floorMarketPriceX8) * BPS) / strikeX8;
}

/**
 * That discount annualised, so two series with different maturities can be compared.
 *
 * Simple rather than compounded: these are dated instruments measured in days, and a compounded
 * figure would imply a rollover that the holder has to actually achieve.
 */
export function annualisedFundingBps(discountBps: bigint, daysToMaturity: number): bigint {
  if (daysToMaturity <= 0) return 0n;
  return (discountBps * 365n) / BigInt(Math.round(daysToMaturity));
}

// ---------------------------------------------------------------------------------------------
// Corporate actions. Mirrors MultiplierAccountant.sol.
// ---------------------------------------------------------------------------------------------

export type ActionKind = "none" | "dividend" | "split" | "unknown";

export interface Classification {
  kind: ActionKind;
  /** Numerator and denominator of a split, in lowest terms. 1/1 when there is no split. */
  ratioNum: bigint;
  ratioDen: bigint;
}

export const DIVIDEND_MAX_BPS = 300n;
export const SPLIT_MIN_BPS = 2_000n;
export const RATIO_TOLERANCE_BPS = 5n;
export const MAX_RATIO_TERM = 50n;

function gcd(a: bigint, b: bigint): bigint {
  while (b !== 0n) [a, b] = [b, a % b];
  return a;
}

/**
 * Classify a change in `uiMultiplier()`. Mirrors `MultiplierAccountant.classify()` exactly,
 * including the refusal: anything that is neither a small rise nor a clean ratio is `unknown`, and
 * an unknown freezes a series into merge-only rather than moving a strike on a guess.
 */
export function classifyMultiplier(from: bigint, to: bigint): Classification {
  if (from <= 0n || to <= 0n) return { kind: "unknown", ratioNum: 0n, ratioDen: 0n };
  if (from === to) return { kind: "none", ratioNum: 1n, ratioDen: 1n };

  if (to > from) {
    const riseBps = ((to - from) * BPS) / from;
    if (riseBps <= DIVIDEND_MAX_BPS) return { kind: "dividend", ratioNum: 1n, ratioDen: 1n };
  }

  const ratio = (to * WAD) / from;
  const distanceBps = ratio > WAD ? ((ratio - WAD) * BPS) / WAD : ((WAD - ratio) * BPS) / WAD;
  if (distanceBps < SPLIT_MIN_BPS) return { kind: "unknown", ratioNum: 0n, ratioDen: 0n };

  for (let den = 1n; den <= MAX_RATIO_TERM; den++) {
    const num = (ratio * den + WAD / 2n) / WAD;
    if (num === 0n || num > MAX_RATIO_TERM || num === den) continue;
    if (gcd(num, den) !== 1n) continue;
    const candidate = (num * WAD) / den;
    const diff = candidate > ratio ? candidate - ratio : ratio - candidate;
    if ((diff * BPS) / WAD <= RATIO_TOLERANCE_BPS) {
      return { kind: "split", ratioNum: num, ratioDen: den };
    }
  }
  return { kind: "unknown", ratioNum: 0n, ratioDen: 0n };
}

/** Apply a classification to a split point. Mirrors `MultiplierAccountant.adjustStrike()`. */
export function adjustStrike(strikeX8: bigint, c: Classification): bigint {
  if (c.kind !== "split") return strikeX8;
  return (strikeX8 * c.ratioDen) / c.ratioNum;
}

// ---------------------------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------------------------

/** `17850000000n` becomes `"178.50"`, or `"178"` at `dp` 0. */
export function formatUsd(x8: bigint, dp = 2): string {
  const negative = x8 < 0n;
  const v = negative ? -x8 : x8;
  const whole = v / X8;
  const sign = negative ? "-" : "";
  // No decimal point at all when no decimals were asked for, rather than a bare trailing dot.
  if (dp <= 0) return `${sign}${whole}`;
  const scaled = ((v % X8) * 10n ** BigInt(dp)) / X8;
  return `${sign}${whole}.${scaled.toString().padStart(dp, "0")}`;
}

/** `"178.50"` becomes `17850000000n`. */
export function parseUsd(s: string): bigint {
  const [whole = "0", frac = ""] = s.trim().replace(/,/g, "").split(".");
  const padded = (frac + "00000000").slice(0, 8);
  return BigInt(whole) * X8 + BigInt(padded || "0");
}

/** `21000000000000000000n` becomes `"21.0x"`. */
export function formatLeverage(wad: bigint, dp = 1): string {
  const whole = wad / WAD;
  const frac = ((wad % WAD) * 10n ** BigInt(dp)) / WAD;
  return `${whole}.${frac.toString().padStart(dp, "0")}x`;
}

/** Days since the Unix epoch, which is how a series names its trading day. */
export function tradingDayFor(date: Date): bigint {
  return BigInt(Math.floor(date.getTime() / 86_400_000));
}

export function dateForTradingDay(day: bigint): Date {
  return new Date(Number(day) * 86_400_000);
}

/** Seconds after midnight UTC at which a dated series matures. Mirrors `FletcherFactory`. */
export const SETTLEMENT_OFFSET_SECONDS = 22n * 3600n;

export function maturityFor(tradingDay: bigint): bigint {
  return tradingDay * 86_400n + SETTLEMENT_OFFSET_SECONDS;
}
