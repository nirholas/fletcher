/**
 * Copies the ABIs the SDK needs out of the Foundry build artifacts.
 *
 * The SDK's ABIs are generated rather than hand-written so a contract change cannot leave the
 * client calling a signature that no longer exists. Run after `forge build`; `pnpm --filter
 * @fletcher/sdk build` runs it first.
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "contracts", "out");

const WANTED = [
  ["FletcherFactory", "FletcherFactory.sol"],
  ["Series", "Series.sol"],
  ["SeriesToken", "SeriesToken.sol"],
  ["MultiplierAccountant", "MultiplierAccountant.sol"],
  ["DepthGate", "DepthGate.sol"],
  ["FletcherLaunchpad", "FletcherLaunchpad.sol"],
  ["SherwoodSettlementSource", "SherwoodSettlementSource.sol"],
  ["IStockToken", "IStockToken.sol"],
];

const missing = WANTED.filter(([name, file]) => !existsSync(join(out, file, `${name}.json`)));
if (missing.length > 0) {
  console.error(
    `Missing build artifacts for: ${missing.map(([n]) => n).join(", ")}\nRun \`forge build --root contracts\` first.`,
  );
  process.exit(1);
}

const parts = [
  "/**",
  " * Contract ABIs, generated from the Foundry build artifacts by `scripts/extract-abis.mjs`.",
  " *",
  " * Do not edit by hand: run `node scripts/extract-abis.mjs` after `forge build`. Generating them",
  " * means the client cannot drift into calling a signature the contracts no longer expose.",
  " */",
  "",
];

for (const [name, file] of WANTED) {
  const artifact = JSON.parse(readFileSync(join(out, file, `${name}.json`), "utf8"));
  parts.push(`export const ${name.toLowerCase()}Abi = ${JSON.stringify(artifact.abi, null, 2)} as const;`);
  parts.push("");
}

const dest = join(root, "packages", "sdk", "src", "abis.ts");
writeFileSync(dest, parts.join("\n"));
console.log(`Wrote ${dest} (${WANTED.length} ABIs)`);
