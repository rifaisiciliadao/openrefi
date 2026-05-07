// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GrowfiCampaignFactory} from "../../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../../src/GrowfiCampaign.sol";
import {GrowfiCampaignToken} from "../../src/GrowfiCampaignToken.sol";
import {GrowfiYieldToken} from "../../src/GrowfiYieldToken.sol";
import {GrowfiStakingVault} from "../../src/GrowfiStakingVault.sol";
import {GrowfiHarvestManager} from "../../src/GrowfiHarvestManager.sol";
import {Deployer} from "../helpers/Deployer.sol";

/// @title ForkBase — shared fork-test logic
/// @notice Concrete child contracts override _rpcUrl() / _usdc() / _ethUsdFeed() to pin a chain.
///         All tests skip gracefully if the fork cannot be created (RPC down or env not set).
abstract contract ForkBase is Test {
    GrowfiCampaignFactory factory;
    GrowfiCampaign campaign;
    GrowfiCampaignToken campaignToken;
    GrowfiYieldToken yieldToken;
    GrowfiStakingVault stakingVault;
    GrowfiHarvestManager harvestManager;

    address protocolOwner = makeAddr("protocolOwner");
    address feeRecipient = makeAddr("feeRecipient");
    address producer = makeAddr("producer");
    address alice = makeAddr("alice");

    bool internal _forkReady;

    // Child must implement
    function _rpcUrl() internal view virtual returns (string memory);
    function _usdc() internal view virtual returns (address);
    function _ethUsdFeed() internal view virtual returns (address);
    function _weth() internal view virtual returns (address);
    function _chainName() internal view virtual returns (string memory);

    /// @dev Chain-specific L2 sequencer uptime feed. L1 children return address(0).
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
        factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "Olive",
                tokenSymbol: "OLIVE",
                yieldName: "oY",
                yieldSymbol: "oY",
                pricePerToken: 0.144e18,
                minCap: 10_000e18,
                maxCap: 100_000e18,
                fundingDeadline: block.timestamp + 90 days,
                seasonDuration: 365 days,
                minProductClaim: 5e18,
                expectedAnnualHarvestUsd: 5_000e18,
                expectedAnnualHarvest: 1_000e18,
                firstHarvestYear: 2030,
                coverageHarvests: 0
            })
        );
        (address c, address ct, address yt, address sv, address hm,,) = factory.campaigns(0);
        campaign = GrowfiCampaign(c);
        campaignToken = GrowfiCampaignToken(ct);
        yieldToken = GrowfiYieldToken(yt);
        stakingVault = GrowfiStakingVault(sv);
        harvestManager = GrowfiHarvestManager(hm);

        // Wire real USDC (fixed rate) and real ETH/USD oracle
        vm.startPrank(producer);
        campaign.addAcceptedToken(_usdc(), GrowfiCampaign.PricingMode.Fixed, 144_000, address(0));
        campaign.addAcceptedToken(_weth(), GrowfiCampaign.PricingMode.Oracle, 0, _ethUsdFeed());
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!_forkReady) return;
        _;
    }

    /// @dev Alice buys OLIVE with REAL USDC on the forked chain.
    ///      Uses `deal` to mint USDC locally without touching the real token contract's supply.
    function test_fork_buyWithRealUSDC() public onlyFork {
        uint256 payment = 10_000 * 144_000; // 10k tokens worth, 6 decimals
        deal(_usdc(), alice, payment);

        vm.startPrank(alice);
        IERC20(_usdc()).approve(address(campaign), type(uint256).max);
        campaign.buy(_usdc(), payment);
        vm.stopPrank();

        assertEq(campaignToken.balanceOf(alice), 10_000e18, "10k OLIVE minted");
        assertEq(uint8(campaign.state()), uint8(GrowfiCampaign.State.Active), "auto-activated");
    }

    /// @dev Oracle price fetch works against the real Chainlink feed.
    function test_fork_realChainlinkPrice() public view onlyFork {
        // getPrice reverts if oracle stale. Real feeds update every ~1h, so this may fail
        // if the pinned block is far from head — we pin to latest so it should be fresh.
        uint256 price = campaign.getPrice(_weth(), 1e18);
        assertGt(price, 0, "oracle returned zero");
        // Sanity: 1 OLIVE at $0.144 → should need ~$0.144 / ethPrice worth of ETH
        // Price of 1 OLIVE in ETH should be tiny (well under 1 ETH).
        assertLt(price, 1e18, "oracle result implausible (>1 ETH per OLIVE)");
    }

    /// @dev Full fork lifecycle: funding → activate → stake → warp → claim → redeem USDC.
    function test_fork_fullLifecycle() public onlyFork {
        uint256 payment = 10_000 * 144_000;
        deal(_usdc(), alice, payment);

        vm.startPrank(alice);
        IERC20(_usdc()).approve(address(campaign), type(uint256).max);
        campaign.buy(_usdc(), payment);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        vm.stopPrank();

        vm.prank(producer);
        campaign.startSeason(1);

        vm.prank(alice);
        uint256 pos = stakingVault.stake(10_000e18);

        // Skip a full season
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

        // Producer deposits real USDC
        (,,,,,,,, uint256 owed18,,,) = harvestManager.seasonHarvests(1);
        uint256 owed6 = owed18 / 1e12;
        deal(_usdc(), producer, owed6);
        vm.startPrank(producer);
        IERC20(_usdc()).approve(address(campaign), type(uint256).max);
        campaign.depositUSDC(1, owed6);
        vm.stopPrank();

        uint256 aliceUsdcBefore = IERC20(_usdc()).balanceOf(alice);
        vm.prank(alice);
        harvestManager.claimUSDC(1);
        assertGt(IERC20(_usdc()).balanceOf(alice) - aliceUsdcBefore, 0, "alice claimed USDC");
    }
}
