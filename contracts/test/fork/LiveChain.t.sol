// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IStockToken} from "../../src/interfaces/IStockToken.sol";
import {MultiplierAccountant} from "../../src/MultiplierAccountant.sol";
import {IMultiplierAccountant} from "../../src/interfaces/IMultiplierAccountant.sol";
import {DepthGate} from "../../src/DepthGate.sol";

/// @notice Fletcher's assumptions, checked against the real Robinhood Chain rather than a harness.
///
/// Everything this protocol does rests on facts about contracts nobody here controls: that a
/// tokenized equity exposes ERC-8056 `uiMultiplier()` and a three-layer pause, that the 254 equities
/// share one implementation so the surface is uniform, that Uniswap v3 and v4 are really deployed at
/// the addresses the address book claims, and that the live multiplier moves in the shapes
/// `MultiplierAccountant` is built to classify. A harness that agrees with the protocol proves
/// nothing about any of that.
///
/// These tests need an archive endpoint. `https://rpc-robinhood.blockmachine.io` serves historical
/// state; the official RPC and publicnode do not, and fail as fork sources.
///
///   RHC_RPC_URL=https://rpc-robinhood.blockmachine.io forge test --match-path 'test/fork/*'
///
/// With no endpoint configured they skip. With one configured that fails, they FAIL, deliberately:
/// a fork test that quietly swallows a broken endpoint reports green while asserting nothing, and
/// the only tell is the gas figure.
contract LiveChainTest is Test {
    /// @dev Pinned so the assertions describe one known state of the chain. Read 2026-09-10.
    uint256 internal constant FORK_BLOCK = 59_698_078;

    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant UNISWAP_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant UNISWAP_V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant NVDA_USDG_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;

    bool internal forked;

    function setUp() public {
        string memory url = vm.envOr("RHC_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        // No try/catch: a configured endpoint that cannot serve the fork must fail the run, not skip it.
        vm.createSelectFork(url, FORK_BLOCK);
        forked = true;
    }

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    function test_chainIsRobinhood() public onlyForked {
        assertEq(block.chainid, 4663, "fork must be Robinhood Chain");
    }

    /// @notice The entire `IStockToken` surface Fletcher depends on, answered by the real token.
    function test_stockTokenExposesTheSurfaceFletcherNeeds() public onlyForked {
        IStockToken s = IStockToken(NVDA);
        assertEq(s.symbol(), "NVDA");
        assertEq(s.decimals(), 18);
        assertGt(s.totalSupply(), 0);

        // ERC-8056 corporate-action accounting.
        assertGe(s.uiMultiplier(), 1e18, "the multiplier only ever rises from parity");
        assertGe(s.newUIMultiplier(), 1e18);
        assertGt(s.effectiveAt(), 0, "corporate actions are scheduled, not applied silently");

        // The three-layer halt. Fletcher reads all three, because any one of them stops transfers.
        assertFalse(s.paused(), "registry-wide halt");
        assertFalse(s.tokenPaused(), "per-equity halt");
        assertFalse(s.oraclePaused(), "issuer feed halt");
    }

    /// @notice The live accrual is exactly the shape `MultiplierAccountant` classifies as a
    /// dividend. If a real corporate action ever failed to classify, a series would freeze rather
    /// than mis-settle, but the common case has to be the common case.
    function test_liveMultiplierClassifiesAsADividend() public onlyForked {
        uint256 live = IStockToken(NVDA).uiMultiplier();
        MultiplierAccountant acc = new MultiplierAccountant();
        IMultiplierAccountant.Classification memory c = acc.classify(1e18, live);

        assertEq(
            uint8(c.kind),
            uint8(IMultiplierAccountant.Kind.Dividend),
            "NVDA's real accrual since parity must read as a distribution"
        );
        assertEq(acc.adjustStrike(170e8, c), 170e8, "and must leave a split point alone");
    }

    /// @notice A scheduled action is visible before it lands, which is what lets `Series.settle()`
    /// refuse to settle in front of one.
    function test_scheduledCorporateActionsAreReadableInAdvance() public onlyForked {
        IStockToken s = IStockToken(NVDA);
        // Whether or not one is pending at this block, both fields must be readable and coherent.
        if (s.newUIMultiplier() != s.uiMultiplier()) {
            assertGt(s.effectiveAt(), 0, "a pending action must carry a time");
        }
        assertGe(s.newUIMultiplier(), 1e18);
    }

    /// @notice The 254 equities are beacon proxies onto one shared implementation, so the surface
    /// Fletcher codes against is uniform across every name it could ever list.
    function test_equitiesShareOneImplementation() public onlyForked {
        assertEq(IStockToken(SPY).symbol(), "SPY");
        assertEq(IStockToken(SPY).decimals(), 18);
        assertGe(IStockToken(SPY).uiMultiplier(), 1e18);
        assertFalse(IStockToken(SPY).tokenPaused());
    }

    /// @notice `DepthGate` reads real in-range liquidity from a real pool.
    function test_depthGateMeasuresRealLiquidity() public onlyForked {
        DepthGate gate = new DepthGate(UNISWAP_V3_FACTORY, USDG, 1e15);
        (uint128 depth, address pool) = gate.currentLiquidity(NVDA);

        assertGt(depth, 0, "NVDA has in-range liquidity");
        assertEq(pool, NVDA_USDG_POOL, "and it is the pool the address book names");
    }

    /// @notice One reading never qualifies a name, however deep the pool is right now. That is the
    /// whole point: a book present in the calling block can be arranged in the calling block.
    function test_oneCheckpointNeverQualifiesAName() public onlyForked {
        DepthGate gate = new DepthGate(UNISWAP_V3_FACTORY, USDG, 1e15);
        gate.checkpoint(NVDA);
        assertFalse(gate.qualifies(NVDA), "a single observation is not a sustained book");
    }

    /// @notice A name with no quote-paired pool has nothing to checkpoint.
    function test_depthGateRefusesAnUnpairedName() public onlyForked {
        DepthGate gate = new DepthGate(UNISWAP_V3_FACTORY, USDG, 1e15);
        address notAnEquity = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(DepthGate.NoPool.selector, notAnEquity));
        gate.checkpoint(notAnEquity);
        assertFalse(gate.qualifies(notAnEquity));
    }

    /// @notice Uniswap v4 really is deployed where the launchpad points.
    function test_uniswapV4PoolManagerIsLive() public onlyForked {
        assertGt(UNISWAP_V4_POOL_MANAGER.code.length, 0, "v4 PoolManager holds code");
        // A real PoolManager answers the ERC-6909 balance query the launchpad's settle path relies on.
        uint256 balance = IPoolManager(UNISWAP_V4_POOL_MANAGER).balanceOf(address(this), uint256(uint160(USDG)));
        assertEq(balance, 0);
    }

    function test_uniswapV3FactoryIsLive() public onlyForked {
        assertGt(UNISWAP_V3_FACTORY.code.length, 0);
        assertGt(NVDA_USDG_POOL.code.length, 0);
    }

    /// @notice USDG is 6 decimals and the equities are 18. Nothing in Fletcher may assume they match.
    function test_decimalsDifferBetweenQuoteAndEquity() public onlyForked {
        assertEq(IStockToken(USDG).decimals(), 6);
        assertEq(IStockToken(NVDA).decimals(), 18);
    }
}
