// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ChainIntegrationDataService} from "../src/ChainIntegrationDataService.sol";

/// @notice Deploy ChainIntegrationDataService (UUPS) behind an ERC1967 proxy.
///
/// Usage (Arbitrum Sepolia — start here, always):
///   forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia \
///     --private-key $PRIVATE_KEY --broadcast --verify -vvvv
///
/// Required env:
///   PRIVATE_KEY          deployer key (hex, 0x-prefixed)
///   OWNER                governance address. A Safe on mainnet; never an EOA you would not
///                        hand the upgrade key to, because this is UUPS and the owner can upgrade.
///   GRAPH_CONTROLLER     Graph Protocol Controller
///   RECURRING_COLLECTOR  RecurringCollector — NOT GraphTallyCollector. See docs/design.md.
///   PAUSE_GUARDIAN       address allowed to pause
///
/// Canonical addresses, read from graphprotocol/contracts `packages/*/addresses.json`
/// and confirmed against chain on 2026-08-28:
///   RecurringCollector  Arbitrum One     0xff0dc7310fbfbcc2524dae230cd4f34727eb84ee
///                       Arbitrum Sepolia 0x0b18befc60455121ad66ae6e4a647955fcde3900
///   Controller          Arbitrum One     0x0a8491544221dd212964fbb96487467291b2C97e
///                       Arbitrum Sepolia 0x9DB3ee191681f092607035d9BDA6e59FbEaCa695
///
/// After deploying, enable at least one chain or the service accepts nothing:
///   cast send $PROXY "enableChain(string,uint256)" "eip155:42161" 0 --private-key $PRIVATE_KEY
contract Deploy is Script {
    function run() external {
        address owner = vm.envAddress("OWNER");
        address controller = vm.envAddress("GRAPH_CONTROLLER");
        address recurringCollector = vm.envAddress("RECURRING_COLLECTOR");
        address pauseGuardian = vm.envAddress("PAUSE_GUARDIAN");

        vm.startBroadcast();

        ChainIntegrationDataService impl = new ChainIntegrationDataService(controller, recurringCollector);

        // Initialise atomically in the proxy constructor. A proxy deployed uninitialised is
        // front-runnable, and the window is however long it takes you to send the second tx.
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(ChainIntegrationDataService.initialize, (owner, pauseGuardian))
        );

        vm.stopBroadcast();

        console2.log("implementation:", address(impl));
        console2.log("proxy:         ", address(proxy));
        console2.log("owner:         ", owner);
        console2.log("collector:     ", recurringCollector);
        console2.log("");
        console2.log("Next: enableChain(caip2, minProvisionTokens) or nothing can be integrated.");
    }
}
