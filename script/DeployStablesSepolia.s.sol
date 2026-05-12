// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GrowfiCampaignFactory} from "../src/GrowfiCampaignFactory.sol";
import {MockStablecoin} from "../src/mocks/MockStablecoin.sol";
import {MockOracle} from "../test/helpers/MockOracle.sol";

/// @title DeployStablesSepolia
/// @notice Deploys MockUSDT + MockDAI on Sepolia ETH and adds them to
///         the GROW Treasury allowlist with $1 pegged feeds.
///         USDC (mUSDC) was already deployed by DeployTestnetSepolia.
contract DeployStablesSepolia is Script {
    function run() public {
        require(block.chainid == 11_155_111, "Sepolia only");
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        GrowfiCampaignFactory factory = GrowfiCampaignFactory(vm.envAddress("FACTORY_ADDRESS"));

        vm.startBroadcast(deployerPk);

        // 6-dec USDT (Tether shape)
        MockStablecoin usdt = new MockStablecoin("Mock Tether USD", "mUSDT", 6);
        usdt.mint(deployer, 10_000_000e6);

        // 18-dec DAI (Maker shape)
        MockStablecoin dai = new MockStablecoin("Mock Dai", "mDAI", 18);
        dai.mint(deployer, 10_000_000e18);

        // $1 pegged oracles (could share one feed across both, but having
        // distinct mocks lets us simulate depegs independently in future smokes)
        MockOracle usdtFeed = new MockOracle(int256(1e8), 8);
        MockOracle daiFeed = new MockOracle(int256(1e8), 8);

        // Add to Treasury allowlist via factory forwarder. Scale = 10^(18-decimals).
        factory.addGrowfiTreasuryStablecoin(address(usdt), 1e12, address(usdtFeed), 24 hours, 9_500, 10_500);
        factory.addGrowfiTreasuryStablecoin(address(dai), 1, address(daiFeed), 24 hours, 9_500, 10_500);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Sepolia stablecoins ===");
        console.log("MockUSDT (6-dec): ", address(usdt));
        console.log("MockDAI  (18-dec):", address(dai));
        console.log("USDT feed:        ", address(usdtFeed));
        console.log("DAI feed:         ", address(daiFeed));
        console.log("");
        console.log("Frontend env (append to .env.sepolia.local):");
        console.log("  NEXT_PUBLIC_USDT_ADDRESS=", address(usdt));
        console.log("  NEXT_PUBLIC_DAI_ADDRESS=", address(dai));
    }
}
