/**
 * Fletcher: dated FLOOR/TURBO series on Robinhood Chain's tokenized equities.
 *
 * ```ts
 * import { FletcherClient, parseUsd, strikeForLeverage, WAD } from "@fletcher/sdk";
 *
 * const fletcher = new FletcherClient(addresses);
 * const strike = strikeForLeverage(parseUsd("178.50"), 20n * WAD);
 * const series = await fletcher.getSeries("0x...");
 * const { floorValueX8, turboValueX8, leverage } = fletcher.quote(series, parseUsd("185.00"));
 * ```
 */
export * from "./chain.js";
export * from "./math.js";
export * from "./client.js";
export * from "./abis.js";
