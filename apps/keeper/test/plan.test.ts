import { describe, it, expect } from "vitest";
import { planFor } from "../src/index.js";
import type { SeriesState } from "@fletcher/sdk";

const base: SeriesState = {
  address: "0x0000000000000000000000000000000000000001",
  stock: "0x0000000000000000000000000000000000000002",
  stockSymbol: "NVDA",
  floorToken: "0x0000000000000000000000000000000000000003",
  turboToken: "0x0000000000000000000000000000000000000004",
  strikeX8: 17000000000n,
  maturity: 1_000_000n,
  tradingDay: 11n,
  observedMultiplier: 10n ** 18n,
  settled: false,
  settlementPriceX8: 0n,
  shares: null,
  frozen: false,
  isSynced: true,
  collateralRaw: 0n,
  floorSupply: 0n,
  turboSupply: 0n,
};

describe("what the keeper decides", () => {
  it("settles a matured, live series", () => {
    expect(planFor(base, 1_000_000n).action).toBe("settle");
  });

  it("waits while a series is still dated forward", () => {
    const plan = planFor(base, 999_999n);
    expect(plan.action).toBe("wait-for-maturity");
    expect(plan.reason).toContain("matures in");
  });

  it("leaves a settled series alone", () => {
    expect(planFor({ ...base, settled: true, settlementPriceX8: 20000000000n }, 2_000_000n).action).toBe(
      "already-settled",
    );
  });

  /**
   * A frozen series is the one case where doing nothing is the correct action rather than a
   * deferral. Settlement is refused permanently and merge stays open, so there is nothing for a
   * keeper to drive and the reason has to say so.
   */
  it("does not try to settle a frozen series, and says why", () => {
    const plan = planFor({ ...base, frozen: true }, 2_000_000n);
    expect(plan.action).toBe("frozen");
    expect(plan.reason).toContain("merge at par");
  });

  it("reports a halted equity rather than treating it as settleable", () => {
    expect(planFor({ ...base, isSynced: false }, 2_000_000n).action).toBe("halted");
  });

  it("checks settlement before the halt, since a settled series is done either way", () => {
    expect(planFor({ ...base, settled: true, isSynced: false }, 2_000_000n).action).toBe("already-settled");
  });
});
