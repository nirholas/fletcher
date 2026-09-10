/**
 * Checks every claim in the docs that a machine can check.
 *
 * Docs rot silently, and a stale one reads as an instruction rather than as stale. This covers the
 * parts that mechanically can be: relative links resolving, referenced files and npm scripts
 * existing, and the test counts quoted in prose matching what the suites actually contain.
 *
 *   node scripts/check-docs.mjs
 */
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, dirname, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const failures = [];

function markdownFiles(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    if (["node_modules", "lib", "out", "dist", ".git", "cache"].includes(entry)) continue;
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) out.push(...markdownFiles(full));
    else if (entry.endsWith(".md")) out.push(full);
  }
  return out;
}

// --- relative links resolve ---------------------------------------------------------------------

for (const file of markdownFiles(root)) {
  const text = readFileSync(file, "utf8");
  for (const match of text.matchAll(/\[[^\]]*\]\(([^)#\s]+)(?:#[^)]*)?\)/g)) {
    const target = match[1];
    if (/^(https?:|mailto:)/.test(target)) continue;
    const resolved = resolve(dirname(file), target);
    if (!existsSync(resolved)) {
      failures.push(`${relative(root, file)}: dead link -> ${target}`);
    }
  }
}

// --- quoted test counts match the suites --------------------------------------------------------

/** Counts `function test...` and `function testFuzz...` declarations in a Foundry suite. */
function solidityTestCount(path) {
  const text = readFileSync(join(root, path), "utf8");
  return [...text.matchAll(/function\s+(test|testFuzz)[A-Za-z0-9_]*\s*\(/g)].length;
}

const suites = {
  "contracts/test/MultiplierAccountant.t.sol": 16,
  "contracts/test/Series.t.sol": 24,
  "contracts/test/FletcherFactory.t.sol": 14,
  "contracts/test/Launchpad.t.sol": 7,
  "contracts/test/fork/LiveChain.t.sol": 10,
  "contracts/test/Fixtures.t.sol": 1,
};

let solidityTotal = 0;
for (const [path, claimed] of Object.entries(suites)) {
  const actual = solidityTestCount(path);
  solidityTotal += actual;
  if (actual !== claimed) {
    failures.push(`${path}: docs claim ${claimed} tests, file declares ${actual}`);
  }
}

const forkCount = solidityTestCount("contracts/test/fork/LiveChain.t.sol");
const readme = readFileSync(join(root, "README.md"), "utf8");

if (!readme.includes(`${solidityTotal} tests`)) {
  failures.push(`README.md: does not state the real Solidity total of ${solidityTotal} tests`);
}
if (!readme.includes(`${solidityTotal - forkCount} tests`)) {
  failures.push(
    `README.md: quick start should state ${solidityTotal - forkCount} tests (total minus the ${forkCount} fork tests that skip)`,
  );
}

// --- the fixture's parity cases -----------------------------------------------------------------

const fixtures = JSON.parse(readFileSync(join(root, "packages/sdk/test/fixtures.json"), "utf8"));
for (const file of ["README.md", "docs/security.md"]) {
  const text = readFileSync(join(root, file), "utf8");
  if (/(\d+)\s+(?:of them\s+)?parity/.test(text)) {
    const claimed = Number(/(\d+)\s+(?:of them\s+)?parity/.exec(text)[1]);
    if (claimed !== fixtures.length) {
      failures.push(`${file}: claims ${claimed} parity cases, fixture holds ${fixtures.length}`);
    }
  }
}

// --- referenced npm scripts exist ---------------------------------------------------------------

const manifests = new Map();
for (const path of ["package.json", "packages/sdk/package.json", "apps/web/package.json", "apps/keeper/package.json"]) {
  const pkg = JSON.parse(readFileSync(join(root, path), "utf8"));
  manifests.set(pkg.name, new Set(Object.keys(pkg.scripts ?? {})));
}

for (const file of markdownFiles(root)) {
  const text = readFileSync(file, "utf8");
  for (const match of text.matchAll(/pnpm --filter (\S+) (\S+)/g)) {
    const [, pkg, script] = match;
    const scripts = manifests.get(pkg);
    if (!scripts) {
      failures.push(`${relative(root, file)}: unknown package ${pkg}`);
    } else if (!scripts.has(script)) {
      failures.push(`${relative(root, file)}: ${pkg} has no script "${script}"`);
    }
  }
}

if (failures.length > 0) {
  console.error(`${failures.length} documentation problem(s):\n`);
  for (const f of failures) console.error(`  ${f}`);
  process.exit(1);
}
console.log(`Docs check passed: ${solidityTotal} Solidity tests, ${fixtures.length} parity cases, all links resolve.`);
