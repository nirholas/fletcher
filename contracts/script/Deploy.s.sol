// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {MultiplierAccountant} from "../src/MultiplierAccountant.sol";
import {IMultiplierAccountant} from "../src/interfaces/IMultiplierAccountant.sol";
import {DepthGate} from "../src/DepthGate.sol";
import {FletcherFactory} from "../src/FletcherFactory.sol";
import {FletcherLaunchpad} from "../src/FletcherLaunchpad.sol";
import {SherwoodSettlementSource, ISherwoodOracle} from "../src/adapters/SherwoodSettlementSource.sol";
import {ISettlementSource} from "../src/interfaces/ISettlementSource.sol";

/// @notice Deploys Fletcher to Robinhood Chain.
///
///   forge script script/Deploy.s.sol --rpc-url $RHC_RPC_URL --broadcast
///
/// Nothing here is owned, upgradeable, or pausable, so there is no admin step after it and no key
/// to hold afterwards. The one external dependency is the settlement oracle: Fletcher consumes
/// Sherwood's reporter-quorum price rather than shipping its own, because a second oracle with a
/// second reporter set would be a second thing to get wrong.
///
/// Required:
///   SHERWOOD_ORACLE   address of a deployed SherwoodOracle.
///
/// Optional, defaulting to the verified Robinhood Chain addresses:
///   UNISWAP_V3_FACTORY, UNISWAP_V4_POOL_MANAGER, QUOTE_TOKEN
///   MIN_LIQUIDITY      floor on a name's in-range pool liquidity, held across the depth window.
contract Deploy is Script {
    address internal constant DEFAULT_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant DEFAULT_V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant DEFAULT_QUOTE = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // USDG

    /// @dev Floor on the in-range liquidity a name must hold across the whole depth window. A
    /// judgement about how thin a book may be before an instrument on it cannot be exited, not a
    /// value anyone tunes for yield.
    uint128 internal constant DEFAULT_MIN_LIQUIDITY = 1e15;

    function run() external {
        address sherwoodOracle = vm.envAddress("SHERWOOD_ORACLE");
        address v3Factory = vm.envOr("UNISWAP_V3_FACTORY", DEFAULT_V3_FACTORY);
        address poolManager = vm.envOr("UNISWAP_V4_POOL_MANAGER", DEFAULT_V4_POOL_MANAGER);
        address quote = vm.envOr("QUOTE_TOKEN", DEFAULT_QUOTE);
        uint128 minLiquidity = uint128(vm.envOr("MIN_LIQUIDITY", uint256(DEFAULT_MIN_LIQUIDITY)));

        require(sherwoodOracle.code.length > 0, "SHERWOOD_ORACLE holds no code");
        require(poolManager.code.length > 0, "UNISWAP_V4_POOL_MANAGER holds no code");
        require(v3Factory.code.length > 0, "UNISWAP_V3_FACTORY holds no code");

        vm.startBroadcast();

        MultiplierAccountant accountant = new MultiplierAccountant();
        SherwoodSettlementSource source = new SherwoodSettlementSource(ISherwoodOracle(sherwoodOracle));
        DepthGate gate = new DepthGate(v3Factory, quote, minLiquidity);
        FletcherFactory factory = new FletcherFactory(
            IMultiplierAccountant(address(accountant)), ISettlementSource(address(source)), gate
        );
        FletcherLaunchpad launchpad = new FletcherLaunchpad(
            IPoolManager(poolManager), factory, ISettlementSource(address(source))
        );

        vm.stopBroadcast();

        console2.log("MultiplierAccountant     ", address(accountant));
        console2.log("SherwoodSettlementSource ", address(source));
        console2.log("DepthGate                ", address(gate));
        console2.log("FletcherFactory          ", address(factory));
        console2.log("FletcherLaunchpad        ", address(launchpad));
    }
}
