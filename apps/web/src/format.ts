/** Presentation helpers. Every number the UI shows goes through one of these. */
import { formatUsd, formatLeverage, dateForTradingDay, WAD } from "@fletcher/sdk";

export { formatUsd, formatLeverage };

/** Raw 18-decimal token units as a human quantity. */
export function formatUnits18(raw: bigint, dp = 4): string {
  const whole = raw / WAD;
  const frac = ((raw % WAD) * 10n ** BigInt(dp)) / WAD;
  return `${whole.toLocaleString("en-US")}.${frac.toString().padStart(dp, "0")}`;
}

/** A trading day as a date a person reads. */
export function formatTradingDay(day: bigint): string {
  return dateForTradingDay(day).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    timeZone: "UTC",
  });
}

/** Time until a maturity, or how long ago it passed. */
export function formatCountdown(maturity: bigint, now = Date.now()): string {
  const seconds = Number(maturity) - Math.floor(now / 1000);
  const abs = Math.abs(seconds);
  const unit = abs < 3600 ? `${Math.round(abs / 60)}m` : abs < 86400 ? `${(abs / 3600).toFixed(1)}h` : `${(abs / 86400).toFixed(1)}d`;
  return seconds >= 0 ? `in ${unit}` : `${unit} ago`;
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

/** A percentage from a 1e18 ratio. */
export function formatPercent(wad: bigint, dp = 1): string {
  return `${((Number(wad) / 1e18) * 100).toFixed(dp)}%`;
}

/** Basis points as a percentage. */
export function formatBps(bps: bigint, dp = 2): string {
  return `${(Number(bps) / 100).toFixed(dp)}%`;
}
