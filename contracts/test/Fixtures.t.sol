// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MultiplierAccountant} from "../src/MultiplierAccountant.sol";
import {IMultiplierAccountant} from "../src/interfaces/IMultiplierAccountant.sol";

/// @notice Writes the fixture the SDK's math is tested against.
///
/// `packages/sdk/src/math.ts` reimplements `Series` and `MultiplierAccountant` so a UI can redraw a
/// payoff curve without an RPC round trip per frame. Two implementations of the same arithmetic
/// drift, and the drift shows up as a quoted payout the contract will not pay, at exactly the moment
/// a leveraged holder can least afford it.
///
/// So the Solidity is the source of truth and the TypeScript is tested against its output:
///
///   FLETCHER_WRITE_FIXTURES=1 forge test --root contracts --match-path 'test/Fixtures.t.sol'
///   pnpm --filter fletcher-sdk test
///
/// Without the environment variable this asserts the committed fixture still matches, so a contract
/// change that moves a number fails here rather than silently invalidating the fixture.
contract FixturesTest is Test {
    MultiplierAccountant internal acc;

    string internal constant PATH = "../packages/sdk/test/fixtures.json";

    uint256 internal constant WAD = 1e18;

    function setUp() public {
        acc = new MultiplierAccountant();
    }

    function test_fixturesMatchTheContracts() public {
        string memory json = _build();

        if (vm.envOr("FLETCHER_WRITE_FIXTURES", false)) {
            vm.writeFile(PATH, json);
            return;
        }

        string memory existing = vm.readFile(PATH);
        assertEq(
            keccak256(bytes(existing)),
            keccak256(bytes(json)),
            "fixture is stale: rerun with FLETCHER_WRITE_FIXTURES=1 and check what moved"
        );
    }

    function _build() internal view returns (string memory) {
        string memory out = "[\n";
        out = string.concat(out, _settlementCases());
        out = string.concat(out, _classificationCases());
        return string.concat(out, "]\n");
    }

    /// @dev The settlement split at prices spanning far below the strike to far above it.
    function _settlementCases() internal pure returns (string memory) {
        uint256[9] memory prices =
            [uint256(1e8), 50e8, 169e8, 170e8, 171e8, 178.5e8, 200e8, 1000e8, 100000e8];
        uint256 strike = 170e8;

        string memory out = "";
        for (uint256 i = 0; i < prices.length; ++i) {
            uint256 p = prices[i];
            uint256 claim = p < strike ? p : strike;
            uint256 fpu = (claim * WAD) / p;
            out = string.concat(
                out,
                '  {"kind":"settlement","closeX8":"',
                vm.toString(p),
                '","strikeX8":"',
                vm.toString(strike),
                '","floorPerUnit":"',
                vm.toString(fpu),
                '","turboPerUnit":"',
                vm.toString(WAD - fpu),
                '"},\n'
            );
        }
        return out;
    }

    /// @dev Every classification branch, including the live NVDA accrual and the refusals.
    function _classificationCases() internal view returns (string memory) {
        uint256[8] memory tos = [
            uint256(1e18), // none
            1_000_775_159_164_630_595, // the live NVDA accrual
            1.03e18, // dividend, at the band edge
            1.0301e18, // unknown, just past it
            2e18, // 2:1
            1.5e18, // 3:2
            0.1e18, // 1:10 reverse
            1.373e18 // unknown, a dirty ratio
        ];

        string memory out = "";
        for (uint256 i = 0; i < tos.length; ++i) {
            IMultiplierAccountant.Classification memory c = acc.classify(1e18, tos[i]);
            out = string.concat(
                out,
                '  {"kind":"classification","from":"',
                vm.toString(uint256(1e18)),
                '","to":"',
                vm.toString(tos[i]),
                '","result":"',
                _kindName(c.kind),
                '","ratioNum":"',
                vm.toString(c.ratioNum),
                '","ratioDen":"',
                vm.toString(c.ratioDen),
                '","adjusted170":"',
                vm.toString(acc.adjustStrike(170e8, c)),
                '"}',
                i + 1 == tos.length ? "\n" : ",\n"
            );
        }
        return out;
    }

    function _kindName(IMultiplierAccountant.Kind k) internal pure returns (string memory) {
        if (k == IMultiplierAccountant.Kind.None) return "none";
        if (k == IMultiplierAccountant.Kind.Dividend) return "dividend";
        if (k == IMultiplierAccountant.Kind.Split) return "split";
        return "unknown";
    }
}
