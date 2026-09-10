// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Series} from "../src/Series.sol";
import {SeriesToken} from "../src/SeriesToken.sol";
import {MultiplierAccountant} from "../src/MultiplierAccountant.sol";
import {IMultiplierAccountant} from "../src/interfaces/IMultiplierAccountant.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {ISettlementSource} from "../src/interfaces/ISettlementSource.sol";
import {StockHarness} from "./harness/StockHarness.sol";
import {SettlementSourceHarness} from "./harness/SettlementSourceHarness.sol";

contract SeriesTest is Test {
    StockHarness internal nvda;
    SettlementSourceHarness internal source;
    MultiplierAccountant internal accountant;
    Series internal series;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    /// @dev The series is struck at $170 against a $178.50 reference, which is where the product
    /// actually lives: FLOOR takes the first 95.2% of the stock and TURBO takes the rest, so TURBO
    /// opens at roughly 21x delta.
    uint256 internal constant STRIKE = 170e8;
    uint256 internal constant SPOT = 178.5e8;

    uint64 internal tradingDay;
    uint64 internal maturity;

    function setUp() public {
        // Anchor the clock somewhere real rather than at block zero, so trading-day arithmetic is
        // meaningful. 1789000000 is 10 September 2026.
        vm.warp(1_789_000_000);
        tradingDay = uint64(block.timestamp / 1 days);
        maturity = uint64(block.timestamp + 2 days);

        nvda = new StockHarness("NVDA");
        source = new SettlementSourceHarness();
        accountant = new MultiplierAccountant();

        series = new Series(
            IStockToken(address(nvda)),
            STRIKE,
            maturity,
            tradingDay,
            IMultiplierAccountant(address(accountant)),
            ISettlementSource(address(source)),
            "Fletcher FLOOR NVDA-170",
            "fNVDA-170",
            "Fletcher TURBO NVDA-170",
            "tNVDA-170"
        );

        nvda.mint(alice, 1000e18);
        nvda.mint(bob, 1000e18);
        vm.prank(alice);
        nvda.approve(address(series), type(uint256).max);
        vm.prank(bob);
        nvda.approve(address(series), type(uint256).max);
    }

    function _mint(address who, uint256 amount) internal {
        vm.prank(who);
        series.mint(who, amount);
    }

    // --- mint and merge ----------------------------------------------------------------------

    function test_mintIssuesBothLegsAndIsFullyCollateralised() public {
        _mint(alice, 100e18);
        assertEq(series.floorToken().balanceOf(alice), 100e18);
        assertEq(series.turboToken().balanceOf(alice), 100e18);
        assertEq(nvda.balanceOf(address(series)), 100e18);
        assertEq(series.collateralisation1e18(), 1e18, "fully collateralised at mint");
    }

    function test_mergeIsFreeAndExact() public {
        _mint(alice, 100e18);
        uint256 before = nvda.balanceOf(alice);
        vm.prank(alice);
        series.merge(alice, 100e18);
        assertEq(nvda.balanceOf(alice) - before, 100e18, "merge returns the deposit exactly, no fee");
        assertEq(series.floorToken().totalSupply(), 0);
        assertEq(series.turboToken().totalSupply(), 0);
    }

    function test_partialMergeLeavesTheRestCollateralised() public {
        _mint(alice, 100e18);
        vm.prank(alice);
        series.merge(alice, 40e18);
        assertEq(series.collateralisation1e18(), 1e18);
        assertEq(nvda.balanceOf(address(series)), 60e18);
    }

    function test_cannotMergeWithoutBothLegs() public {
        _mint(alice, 100e18);
        // Alice sells her TURBO. She can no longer merge, which is the point: the merge right is
        // what caps the pair at parity, and it belongs to whoever holds both halves.
        SeriesToken turbo = series.turboToken();
        vm.prank(alice);
        turbo.transfer(bob, 100e18);
        vm.prank(alice);
        vm.expectRevert();
        series.merge(alice, 100e18);
    }

    // --- settlement --------------------------------------------------------------------------

    function _settleAt(uint256 priceX8) internal {
        source.setClose(address(nvda), tradingDay, priceX8);
        vm.warp(maturity);
        series.settle();
    }

    function test_settlesAboveStrike_turboTakesTheUpside() public {
        _mint(alice, 100e18);
        _settleAt(200e8);

        // FLOOR claims min(200, 170) = 170 of a 200 print: 85% of the vault.
        assertEq(series.floorPerUnit1e18(), (170e18 * 1e18) / 200e18);
        assertEq(series.turboPerUnit1e18(), 1e18 - (170e18 * 1e18) / 200e18);
        assertEq(series.floorPerUnit1e18() + series.turboPerUnit1e18(), 1e18, "the vault is exactly divided");
    }

    function test_settlesBelowStrike_floorTakesEverything() public {
        _mint(alice, 100e18);
        _settleAt(120e8);
        assertEq(series.floorPerUnit1e18(), 1e18, "below the split point FLOOR owns the whole vault");
        assertEq(series.turboPerUnit1e18(), 0, "TURBO expires worthless, and owes nothing");
    }

    function test_settlesExactlyAtStrike() public {
        _mint(alice, 100e18);
        _settleAt(STRIKE);
        assertEq(series.floorPerUnit1e18(), 1e18);
        assertEq(series.turboPerUnit1e18(), 0);
    }

    function test_redeemPaysTheSettledShare() public {
        _mint(alice, 100e18);
        _settleAt(200e8);

        uint256 before = nvda.balanceOf(alice);
        vm.prank(alice);
        series.redeem(alice, 100e18, 0);
        // 100 * 170/200 = 85 raw stock.
        assertEq(nvda.balanceOf(alice) - before, 85e18);
    }

    function test_bothLegsRedeemedDrainTheVaultExactly() public {
        _mint(alice, 100e18);
        SeriesToken turbo = series.turboToken();
        vm.prank(alice);
        turbo.transfer(bob, 100e18);
        _settleAt(200e8);

        vm.prank(alice);
        series.redeem(alice, 100e18, 0);
        vm.prank(bob);
        series.redeem(bob, 0, 100e18);

        assertEq(nvda.balanceOf(address(series)), 0, "no stock is stranded in the vault");
    }

    function test_cannotSettleBeforeMaturity() public {
        _mint(alice, 100e18);
        source.setClose(address(nvda), tradingDay, 200e8);
        vm.expectRevert(Series.NotMature.selector);
        series.settle();
    }

    function test_cannotSettleWithoutAnOfficialClose() public {
        _mint(alice, 100e18);
        vm.warp(maturity);
        vm.expectRevert(Series.CloseUnavailable.selector);
        series.settle();
    }

    function test_cannotSettleTwice() public {
        _mint(alice, 100e18);
        _settleAt(200e8);
        vm.expectRevert(Series.AlreadySettled.selector);
        series.settle();
    }

    function test_mintAndMergeStopAtSettlement() public {
        _mint(alice, 100e18);
        _settleAt(200e8);
        vm.prank(alice);
        vm.expectRevert(Series.AlreadySettled.selector);
        series.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(Series.AlreadySettled.selector);
        series.merge(alice, 1e18);
    }

    /// @notice A corporate action scheduled to land on or before maturity must be folded in before
    /// the series settles, or the series settles the wrong terms.
    function test_refusesToSettleInFrontOfAScheduledCorporateAction() public {
        _mint(alice, 100e18);
        nvda.scheduleMultiplier(2e18, maturity - 1);
        source.setClose(address(nvda), tradingDay, 200e8);
        vm.warp(maturity);
        vm.expectRevert(Series.CorporateActionPending.selector);
        series.settle();

        // Once it lands and is accounted for, settlement proceeds on the adjusted strike.
        nvda.applyScheduled();
        series.settle();
        assertEq(series.strikeX8(), 85e8, "2:1 split halved the split point");
    }

    // --- corporate actions -------------------------------------------------------------------

    function test_dividendAccruesToFloor() public {
        _mint(alice, 100e18);
        uint256 strikeBefore = series.strikeX8();

        // The live NVDA accrual: +7.75bp.
        nvda.setMultiplier(1_000_775_159_164_630_595);
        series.syncMultiplier();

        assertEq(series.strikeX8(), strikeBefore, "a dividend does not move the split point");

        // FLOOR's claim is `multiplier * min(price, strike)`, so an unchanged strike against a risen
        // multiplier is strictly more value to FLOOR, and TURBO is untouched.
        (uint256 floorValue, uint256 turboValue) = series.quoteLegs(SPOT);
        assertGt(floorValue, STRIKE, "FLOOR captured the distribution");
        assertEq(turboValue, ((SPOT - STRIKE) * 1_000_775_159_164_630_595) / 1e18);
    }

    function test_splitPreservesTurboLeverage() public {
        _mint(alice, 100e18);
        uint256 leverageBefore = series.turboLeverage1e18(SPOT);

        // 2:1 split: multiplier doubles, share price halves.
        nvda.setMultiplier(2e18);
        series.syncMultiplier();

        assertEq(series.strikeX8(), 85e8);
        uint256 leverageAfter = series.turboLeverage1e18(SPOT / 2);
        assertEq(leverageAfter, leverageBefore, "a split must not change TURBO's leverage");
    }

    function test_leverageAtMintIsAboutTwentyX() public view {
        // 178.50 / (178.50 - 170) = 21.0x
        assertApproxEqRel(series.turboLeverage1e18(SPOT), 21e18, 0.01e18);
    }

    function test_unknownActionFreezesButMergeStillWorks() public {
        _mint(alice, 100e18);
        nvda.setMultiplier(1.373e18); // neither a distribution nor a clean ratio
        series.syncMultiplier();

        assertTrue(series.frozen(), "an unclassifiable action freezes the series");
        assertFalse(series.isSynced());

        // Settlement is refused permanently...
        source.setClose(address(nvda), tradingDay, 200e8);
        vm.warp(maturity);
        vm.expectRevert(Series.SeriesFrozen.selector);
        series.settle();

        // ...but every holder can still take their stock back at par.
        uint256 before = nvda.balanceOf(alice);
        vm.prank(alice);
        series.merge(alice, 100e18);
        assertEq(nvda.balanceOf(alice) - before, 100e18, "a frozen series still lets holders leave whole");
    }

    // --- halts -------------------------------------------------------------------------------

    function test_haltBlocksMintAndTransfersButNotSettlement() public {
        _mint(alice, 100e18);
        nvda.setTokenPaused(true);

        vm.prank(alice);
        vm.expectRevert();
        series.mint(alice, 1e18);

        // Settlement records a ratio and moves no stock, so a halted equity can still resolve. That
        // is exactly when holders most need it to.
        source.setClose(address(nvda), tradingDay, 200e8);
        vm.warp(maturity);
        series.settle();
        assertTrue(series.settled());

        // Redemption transfers, so it waits for the halt to lift, as it must.
        vm.prank(alice);
        vm.expectRevert();
        series.redeem(alice, 100e18, 0);

        nvda.setTokenPaused(false);
        vm.prank(alice);
        series.redeem(alice, 100e18, 0);
        assertEq(nvda.balanceOf(alice), 900e18 + 85e18);
    }

    function test_registryWideHaltIsHonoured() public {
        _mint(alice, 100e18);
        nvda.setRegistryPaused(true);
        assertFalse(series.isSynced());
        vm.prank(alice);
        vm.expectRevert();
        series.mint(alice, 1e18);
    }

    // --- invariants --------------------------------------------------------------------------

    /// @notice The property the whole design rests on: whatever the print, the two legs divide the
    /// vault exactly. Never more (bad debt) and never less (stranded collateral).
    function testFuzz_vaultIsAlwaysExactlyDivided(uint256 priceX8, uint256 amount) public {
        priceX8 = bound(priceX8, 1, 1_000_000e8);
        amount = bound(amount, 1e12, 1000e18);

        _mint(alice, amount);
        _settleAt(priceX8);

        assertEq(series.floorPerUnit1e18() + series.turboPerUnit1e18(), 1e18, "shares must sum to one");

        uint256 owedFloor = (amount * series.floorPerUnit1e18()) / 1e18;
        uint256 owedTurbo = (amount * series.turboPerUnit1e18()) / 1e18;
        assertLe(owedFloor + owedTurbo, nvda.balanceOf(address(series)), "the vault can never owe more than it holds");
    }

    /// @notice No print, however extreme, leaves the vault unable to pay both legs in full.
    function testFuzz_bothLegsAlwaysRedeemFully(uint256 priceX8, uint256 amount) public {
        priceX8 = bound(priceX8, 1, 1_000_000e8);
        amount = bound(amount, 1e12, 1000e18);

        _mint(alice, amount);
        SeriesToken turbo = series.turboToken();
        vm.prank(alice);
        turbo.transfer(bob, amount);
        _settleAt(priceX8);

        vm.prank(alice);
        series.redeem(alice, amount, 0);
        vm.prank(bob);
        series.redeem(bob, 0, amount);

        assertEq(nvda.balanceOf(address(series)), 0, "vault fully drained, no dust retained");
    }

    /// @notice Merging is always available at par before settlement, for any mint size and any
    /// intervening dividend. This is what caps the pair's combined price at parity.
    function testFuzz_mergeAlwaysReturnsTheDepositAtPar(uint256 amount, uint256 multiplier) public {
        amount = bound(amount, 1e12, 1000e18);
        multiplier = bound(multiplier, 1e18, 1.03e18);

        _mint(alice, amount);
        nvda.setMultiplier(multiplier);

        uint256 before = nvda.balanceOf(alice);
        vm.prank(alice);
        series.merge(alice, amount);
        assertEq(nvda.balanceOf(alice) - before, amount);
    }

    /// @notice The two legs' values always sum to the multiplier-adjusted share price, at any price
    /// and after any distribution. Fully collateralised is a property of the arithmetic, not a
    /// parameter someone has to keep tuned.
    function testFuzz_legValuesSumToTheUnderlying(uint256 priceX8, uint256 multiplier) public {
        priceX8 = bound(priceX8, 1e6, 1_000_000e8);
        multiplier = bound(multiplier, 1e18, 1.03e18);
        nvda.setMultiplier(multiplier);

        (uint256 floorValue, uint256 turboValue) = series.quoteLegs(priceX8);
        assertApproxEqAbs(floorValue + turboValue, (priceX8 * multiplier) / 1e18, 1, "legs must sum to the underlying");
    }
}
