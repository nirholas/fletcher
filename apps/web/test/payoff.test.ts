import { describe, it, expect } from "vitest";
import { payoffSeries, renderPayoff, describeOutcome } from "../src/payoff.js";
import { parseUsd, settlementShares, quoteLegs, WAD } from "@fletcher/sdk";
import { formatCountdown, formatUnits18, shortAddress, formatBps } from "../src/format.js";

const STRIKE = parseUsd("170.00");

describe("the payoff curve", () => {
  const points = payoffSeries(STRIKE, STRIKE * 2n);

  it("has FLOOR rise with the stock and then flatten at the split point", () => {
    const below = points.filter((p) => p.priceX8 < STRIKE);
    const above = points.filter((p) => p.priceX8 > STRIKE);

    // Below the split point FLOOR is the whole share.
    for (const p of below) expect(p.floorX8).toBe(p.priceX8);
    // Above it, FLOOR is pinned at the split point and stops moving.
    for (const p of above) expect(p.floorX8).toBe(STRIKE);
  });

  it("has TURBO worthless below the split point and rising one for one above it", () => {
    for (const p of points) {
      if (p.priceX8 <= STRIKE) expect(p.turboX8).toBe(0n);
      else expect(p.turboX8).toBe(p.priceX8 - STRIKE);
    }
  });

  it("has the two curves stack to the share at every point", () => {
    for (const p of points) {
      expect(p.floorX8 + p.turboX8).toBe(p.priceX8);
    }
  });

  it("scales the accrual into both legs when the multiplier has risen", () => {
    const multiplier = 1_010_000_000_000_000_000n;
    const risen = payoffSeries(STRIKE, STRIKE * 2n, 8, multiplier);
    for (const p of risen) {
      const expected = quoteLegs(p.priceX8, STRIKE, multiplier);
      expect(p.floorX8).toBe(expected.floorValueX8);
      expect(p.turboX8).toBe(expected.turboValueX8);
    }
  });
});

describe("the rendered chart", () => {
  const svg = renderPayoff({ strikeX8: STRIKE, spotX8: parseUsd("178.50") });

  it("is a labelled SVG rather than a decorative one", () => {
    expect(svg).toContain("<svg");
    expect(svg).toContain('role="img"');
    expect(svg).toContain("aria-label=");
    // The label has to describe the shape, since it is the only thing a screen reader gets.
    expect(svg).toContain("flattens at the 170.00 split point");
  });

  it("draws both legs", () => {
    expect(svg).toContain('class="floor-line"');
    expect(svg).toContain('class="turbo-line"');
  });

  /**
   * A regression: the x-axis ticks were briefly computed from the vertical scale, which reads as
   * plausible numbers on a completely wrong axis. The horizontal axis is the share price.
   */
  it("labels the horizontal axis with prices, not leg values", () => {
    const rendered = renderPayoff({ strikeX8: STRIKE, spotX8: parseUsd("178.50"), maxX8: parseUsd("340.00") });
    // Quarters of the 0..340 price range.
    for (const tick of ["85", "170", "255", "340"]) {
      expect(rendered).toContain(`>${tick}</text>`);
    }
  });

  it("labels the split point at the precision the rest of the page shows", () => {
    expect(renderPayoff({ strikeX8: parseUsd("170.00") })).toContain("split 170");
    expect(renderPayoff({ strikeX8: parseUsd("169.57") })).toContain("split 169.57");
  });

  it("renders without a spot marker when there is no spot", () => {
    const bare = renderPayoff({ strikeX8: STRIKE });
    expect(bare).toContain("<svg");
    expect(bare).not.toContain("cursor-line");
  });
});

describe("the settled outcome, in words", () => {
  it("says FLOOR took everything below the split point", () => {
    const shares = settlementShares(parseUsd("120.00"), STRIKE);
    const text = describeOutcome(shares, parseUsd("120.00"), STRIKE);
    expect(text).toContain("FLOOR takes the whole vault");
    expect(text).toContain("owes nothing");
  });

  it("splits the vault in words above the split point", () => {
    const shares = settlementShares(parseUsd("200.00"), STRIKE);
    const text = describeOutcome(shares, parseUsd("200.00"), STRIKE);
    expect(text).toContain("85.0%");
    expect(text).toContain("15.0%");
  });

  it("treats a close exactly at the split point as FLOOR's", () => {
    const shares = settlementShares(STRIKE, STRIKE);
    expect(describeOutcome(shares, STRIKE, STRIKE)).toContain("FLOOR takes the whole vault");
  });
});

describe("formatting", () => {
  it("counts down before maturity and up after it", () => {
    const now = 1_700_000_000_000;
    expect(formatCountdown(BigInt(now / 1000) + 7200n, now)).toBe("in 2.0h");
    expect(formatCountdown(BigInt(now / 1000) - 7200n, now)).toBe("2.0h ago");
    expect(formatCountdown(BigInt(now / 1000) + 600n, now)).toBe("in 10m");
  });

  it("renders raw 18-decimal amounts as quantities", () => {
    expect(formatUnits18(123n * WAD, 2)).toBe("123.00");
    expect(formatUnits18(WAD / 2n, 2)).toBe("0.50");
  });

  it("shortens an address without losing either end", () => {
    expect(shortAddress("0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC")).toBe("0xd060…9EEC");
  });

  it("renders basis points as a percentage", () => {
    expect(formatBps(1216n)).toBe("12.16%");
    expect(formatBps(5n)).toBe("0.05%");
  });
});
