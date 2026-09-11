// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FletcherFactory} from "../src/FletcherFactory.sol";
import {Series} from "../src/Series.sol";
import {DepthGate} from "../src/DepthGate.sol";
import {MultiplierAccountant} from "../src/MultiplierAccountant.sol";
import {IMultiplierAccountant} from "../src/interfaces/IMultiplierAccountant.sol";
import {ISettlementSource} from "../src/interfaces/ISettlementSource.sol";
import {StockHarness} from "./harness/StockHarness.sol";
import {SettlementSourceHarness} from "./harness/SettlementSourceHarness.sol";
import {DepthGateHarness} from "./harness/DepthGateHarness.sol";

/// @notice What the factory refuses, and why each refusal is the market's job rather than an admin's.
contract FletcherFactoryTest is Test {
    FletcherFactory internal factory;
    DepthGateHarness internal gate;
    SettlementSourceHarness internal source;
    StockHarness internal nvda;

    address internal alice = address(0xA11CE);

    uint256 internal constant STRIKE = 170e8;
    uint256 internal constant SPOT = 178.5e8;
    uint64 internal tradingDay;

    function setUp() public {
        vm.warp(1_789_000_000);
        tradingDay = uint64(block.timestamp / 1 days) + 1;

        nvda = new StockHarness("NVDA");
        source = new SettlementSourceHarness();
        gate = new DepthGateHarness();
        gate.setDepth(address(nvda), 1_000_000e18);
        source.setClose(address(nvda), uint64(block.timestamp / 1 days), SPOT);

        factory = new FletcherFactory(
            IMultiplierAccountant(address(new MultiplierAccountant())),
            ISettlementSource(address(source)),
            DepthGate(address(gate))
        );

        nvda.mint(alice, 10_000e18);
        vm.prank(alice);
        nvda.approve(address(factory), type(uint256).max);
    }

    function _create(uint256 strikeX8, uint64 day, uint256 amount) internal returns (Series) {
        vm.prank(alice);
        return factory.createSeries(address(nvda), strikeX8, day, amount, alice);
    }

    function test_anyoneMayOpenASeries() public {
        Series s = _create(STRIKE, tradingDay, 100e18);
        assertEq(factory.seriesCount(), 1);
        assertEq(factory.seriesFor(address(nvda), STRIKE, tradingDay), address(s));
        assertEq(s.floorToken().balanceOf(alice), 100e18);
        assertEq(s.turboToken().balanceOf(alice), 100e18);
    }

    function test_seriesAddressIsDeterministicAndPredictable() public {
        address predicted = factory.computeSeriesAddress(address(nvda), STRIKE, tradingDay);
        Series s = _create(STRIKE, tradingDay, 100e18);
        assertEq(address(s), predicted, "an integrator can name the series before it exists");
    }

    function test_legNamesCarryTheTerms() public {
        Series s = _create(STRIKE, tradingDay, 100e18);
        assertEq(s.floorToken().symbol(), string.concat("fNVDA-170-", vm.toString(uint256(tradingDay))));
        assertEq(s.turboToken().symbol(), string.concat("tNVDA-170-", vm.toString(uint256(tradingDay))));
    }

    /// @notice Two callers racing on the same terms cannot fragment one instrument into two
    /// half-liquid copies. Concentrating liquidity is the entire point of this shape.
    function test_duplicateTermsAreRefused() public {
        Series s = _create(STRIKE, tradingDay, 100e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FletcherFactory.SeriesExists.selector, address(s)));
        factory.createSeries(address(nvda), STRIKE, tradingDay, 100e18, alice);
    }

    function test_illiquidNameIsRefused() public {
        StockHarness thin = new StockHarness("THIN");
        thin.mint(alice, 1000e18);
        vm.prank(alice);
        thin.approve(address(factory), type(uint256).max);
        source.setClose(address(thin), uint64(block.timestamp / 1 days), 50e8);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FletcherFactory.NotDepthQualified.selector, address(thin)));
        factory.createSeries(address(thin), 45e8, tradingDay, 100e18, alice);
    }

    /// @notice There is deliberately no outstanding-notional cap. The earlier one accumulated per
    /// name and never decremented, so ordinary use walked a ticker to its ceiling and bricked it
    /// permanently, and it bound the wrong call anyway: `Series.mint` reaches any size without
    /// touching the factory. The depth gate gates listing, not size.
    function test_repeatedCreationDoesNotBrickATicker() public {
        gate.setDepth(address(nvda), 1000e18);

        // Well past what the old 15%-of-depth ceiling would have allowed, and past the measured
        // depth itself. None of it accumulates into a number that gates a later call.
        _create(STRIKE, tradingDay, 400e18);
        _create(165e8, tradingDay, 400e18);
        _create(STRIKE, tradingDay + 1, 400e18);

        assertEq(factory.seriesCount(), 3, "a name stays listable however much has been minted on it");
    }

    /// @notice And minting into a series directly is permissionless, which is exactly why a cap on
    /// creation could never have bound total size.
    function test_mintingIntoASeriesIsNotGatedByTheFactory() public {
        Series s = _create(STRIKE, tradingDay, 10e18);
        vm.startPrank(alice);
        nvda.approve(address(s), type(uint256).max);
        s.mint(alice, 5000e18);
        vm.stopPrank();
        assertEq(s.floorToken().balanceOf(alice), 5010e18);
    }

    function test_haltedNameIsRefused() public {
        nvda.setTokenPaused(true);
        vm.prank(alice);
        vm.expectRevert(FletcherFactory.StockHalted.selector);
        factory.createSeries(address(nvda), STRIKE, tradingDay, 100e18, alice);
    }

    function test_registryWideHaltIsRefused() public {
        nvda.setRegistryPaused(true);
        vm.prank(alice);
        vm.expectRevert(FletcherFactory.StockHalted.selector);
        factory.createSeries(address(nvda), STRIKE, tradingDay, 100e18, alice);
    }

    function test_pastMaturityIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(FletcherFactory.BadMaturity.selector);
        factory.createSeries(address(nvda), STRIKE, uint64(block.timestamp / 1 days) - 1, 100e18, alice);
    }

    function test_tenorBeyondNinetyDaysIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(FletcherFactory.BadMaturity.selector);
        factory.createSeries(address(nvda), STRIKE, tradingDay + 100, 100e18, alice);
    }

    /// @notice A strike far outside the band would be a leg that is dust at birth. The band is
    /// checked against the settlement source, never a pool, so it cannot be moved by a swap.
    function test_strikeOutsideTheBandIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(FletcherFactory.BadStrike.selector);
        factory.createSeries(address(nvda), SPOT * 2, tradingDay, 100e18, alice);

        vm.prank(alice);
        vm.expectRevert(FletcherFactory.BadStrike.selector);
        factory.createSeries(address(nvda), 1e8, tradingDay, 100e18, alice);
    }

    function test_emptySeriesIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(FletcherFactory.ZeroAmount.selector);
        factory.createSeries(address(nvda), STRIKE, tradingDay, 0, alice);
    }

    function test_manyStrikesAndDatesCoexist() public {
        _create(STRIKE, tradingDay, 100e18);
        _create(174e8, tradingDay, 100e18);
        _create(STRIKE, tradingDay + 1, 100e18);
        assertEq(factory.seriesCount(), 3, "the market picks the menu, not a listing committee");
    }

    /// @notice Leverage is `p / (p - k)`, so the ceiling on the strike IS the ceiling on leverage.
    /// A strike at 99% of spot is 100x on an instrument settling tomorrow, which is a coin flip
    /// rather than a leverage product: a 1% move against the holder takes the whole position.
    function test_strikeBandCapsLeverageAtFiftyX() public {
        // 98% of 178.50 is 174.93, which is 51x and must be refused.
        vm.prank(alice);
        vm.expectRevert(FletcherFactory.BadStrike.selector);
        factory.createSeries(address(nvda), 175e8, tradingDay, 100e18, alice);

        // Just inside the band is accepted, and lands under the stated ceiling.
        Series s = _create(174e8, tradingDay, 100e18);
        assertLe(s.turboLeverage1e18(SPOT), factory.MAX_TURBO_LEVERAGE(), "within the documented cap");
    }

    /// @notice Creation reads a live reference price, never a recorded close. An earlier version
    /// walked back through recorded closes, so a long enough gap in recording bricked creation for
    /// every name at once with no way back.
    function test_creationSurvivesAGapInRecordedCloses() public {
        // No close has ever been recorded for this day or any recent one.
        source.clearClose(address(nvda), uint64(block.timestamp / 1 days));
        assertFalse(source.hasClose(address(nvda), uint64(block.timestamp / 1 days)));

        // Creation still works, because it never depended on that history.
        Series s = _create(STRIKE, tradingDay, 100e18);
        assertEq(s.strikeX8(), STRIKE);
    }

    function test_maturityIsTheDayPlusTheSettlementOffset() public view {
        assertEq(factory.maturityFor(tradingDay), tradingDay * 1 days + factory.SETTLEMENT_OFFSET());
    }
}
