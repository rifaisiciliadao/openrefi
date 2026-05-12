// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GrowfiCampaignFactory} from "../../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../../src/GrowfiCampaign.sol";
import {CampaignStorage} from "../../src/host/CampaignStorage.sol";
import {IGrowfiCampaignFull} from "../../src/interfaces/IGrowfiCampaignFull.sol";
import {SaleClassicModule} from "../../src/modules/SaleClassicModule.sol";
import {CollateralModule} from "../../src/modules/CollateralModule.sol";
import {GrowfiCampaignToken} from "../../src/GrowfiCampaignToken.sol";
import {GrowfiYieldToken} from "../../src/GrowfiYieldToken.sol";
import {GrowfiStakingVault} from "../../src/GrowfiStakingVault.sol";
import {GrowfiHarvestManager} from "../../src/GrowfiHarvestManager.sol";
import {Deployer} from "../helpers/Deployer.sol";

abstract contract ForkBase is Test {
    GrowfiCampaignFactory factory;
    address campaignAddr;
    IGrowfiCampaignFull campaign;
    GrowfiCampaignToken campaignToken;
    GrowfiYieldToken yieldToken;
    GrowfiStakingVault stakingVault;
    GrowfiHarvestManager harvestManager;

    address protocolOwner = makeAddr("protocolOwner");
    address feeRecipient = makeAddr("feeRecipient");
    address producer = makeAddr("producer");
    address alice = makeAddr("alice");

    bool internal _forkReady;

    function _rpcUrl() internal view virtual returns (string memory);
    function _usdc() internal view virtual returns (address);
    function _ethUsdFeed() internal view virtual returns (address);
    function _weth() internal view virtual returns (address);
    function _chainName() internal view virtual returns (string memory);

    function _sequencerUptimeFeed() internal view virtual returns (address) {
        return address(0);
    }

    function setUp() public virtual {
        string memory rpc = _rpcUrl();
        try vm.createSelectFork(rpc) {
            _forkReady = true;
        } catch {
            emit log_named_string("SKIP: fork unavailable for", _chainName());
            return;
        }

        factory = Deployer.deployProtocol(protocolOwner, feeRecipient, _usdc(), _sequencerUptimeFeed());

        vm.prank(producer);
        campaignAddr = factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                campaignTokenName: "Olive",
                campaignTokenSymbol: "OLIVE",
                yieldTokenName: "oY",
                yieldTokenSymbol: "oY",
                minProductClaim: 5e18,
                sale: SaleClassicModule.InitParams({
                    pricePerToken: 0.144e18,
                    minCap: 10_000e18,
                    maxCap: 100_000e18,
                    fundingDeadline: block.timestamp + 90 days,
                    seasonDuration: 365 days,
                    fundingFeeBps: 0,
                    sequencerUptimeFeed: _sequencerUptimeFeed(),
                    growMinter: address(0)
                }),
                collateral: CollateralModule.InitParams({
                    expectedAnnualHarvestUsd: 5_000e18,
                    expectedAnnualHarvest: 1_000e18,
                    firstHarvestYear: 2030,
                    coverageHarvests: 0
                })
            })
        );

        campaign = IGrowfiCampaignFull(payable(campaignAddr));
        campaignToken = GrowfiCampaignToken(campaign.campaignToken());
        yieldToken = GrowfiYieldToken(campaign.yieldToken());
        stakingVault = GrowfiStakingVault(campaign.stakingVault());
        harvestManager = GrowfiHarvestManager(campaign.harvestManager());

        vm.startPrank(producer);
        campaign.addAcceptedToken(_usdc(), SaleClassicModule.PricingMode.Fixed, 144_000, address(0));
        campaign.addAcceptedToken(_weth(), SaleClassicModule.PricingMode.Oracle, 0, _ethUsdFeed());
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!_forkReady) return;
        _;
    }

    function test_fork_buyWithRealUSDC() public onlyFork {
        uint256 payment = 10_000 * 144_000;
        deal(_usdc(), alice, payment);

        vm.startPrank(alice);
        IERC20(_usdc()).approve(campaignAddr, type(uint256).max);
        campaign.buy(_usdc(), payment);
        vm.stopPrank();

        assertEq(campaignToken.balanceOf(alice), 10_000e18, "10k OLIVE minted");
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Active), "auto-activated");
    }

    function test_fork_realChainlinkPrice() public view onlyFork {
        uint256 price = campaign.getPrice(_weth(), 1e18);
        assertGt(price, 0, "oracle returned zero");
        assertLt(price, 1e18, "oracle result implausible (>1 ETH per OLIVE)");
    }

    function test_fork_fullLifecycle() public onlyFork {
        uint256 payment = 10_000 * 144_000;
        deal(_usdc(), alice, payment);

        vm.startPrank(alice);
        IERC20(_usdc()).approve(campaignAddr, type(uint256).max);
        campaign.buy(_usdc(), payment);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        vm.stopPrank();

        vm.prank(producer);
        campaign.startSeason();

        vm.prank(alice);
        uint256 pos = stakingVault.stake(10_000e18);

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        stakingVault.claimYield(pos);
        assertGt(yieldToken.balanceOf(alice), 0, "yield accrued");

        vm.prank(producer);
        campaign.endSeason();

        vm.prank(producer);
        harvestManager.reportHarvest(1, 14_000e18, bytes32(0), 2000e18);

        uint256 aliceYield = yieldToken.balanceOf(alice);
        vm.prank(alice);
        harvestManager.redeemUSDC(1, aliceYield);

        (,,,,,,,, uint256 owed18,,,) = harvestManager.seasonHarvests(1);
        uint256 owed6 = owed18 / 1e12;
        deal(_usdc(), producer, owed6);
        vm.startPrank(producer);
        IERC20(_usdc()).approve(campaignAddr, type(uint256).max);
        campaign.depositUSDC(1, owed6);
        vm.stopPrank();

        uint256 aliceUsdcBefore = IERC20(_usdc()).balanceOf(alice);
        vm.prank(alice);
        harvestManager.claimUSDC(1);
        assertGt(IERC20(_usdc()).balanceOf(alice) - aliceUsdcBefore, 0, "alice claimed USDC");
    }
}
