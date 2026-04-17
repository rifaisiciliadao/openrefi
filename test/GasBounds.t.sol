// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CampaignFactory} from "../src/CampaignFactory.sol";
import {Campaign} from "../src/Campaign.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {Deployer} from "./helpers/Deployer.sol";

/// @title GasBounds — regression tests for unbounded-loop DoS vectors
contract GasBoundsTest is Test {
    CampaignFactory factory;
    Campaign campaign;
    MockERC20 usdc;
    address protocolOwner = makeAddr("protocolOwner");
    address feeRecipient = makeAddr("feeRecipient");
    address producer = makeAddr("producer");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        factory = Deployer.deployProtocol(protocolOwner, feeRecipient, address(usdc), address(0));
        vm.prank(producer);
        factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
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
                minProductClaim: 5e18
            })
        );
        (address c,,,,,,) = factory.campaigns(0);
        campaign = Campaign(c);
    }

    /// @dev The producer can add up to MAX_ACCEPTED_TOKENS (10) payment tokens.
    function test_addUpToCap() public {
        uint256 cap = campaign.MAX_ACCEPTED_TOKENS();
        vm.startPrank(producer);
        for (uint256 i = 0; i < cap; i++) {
            MockERC20 t = new MockERC20("T", "T", 18);
            campaign.addAcceptedToken(address(t), Campaign.PricingMode.Fixed, 1e18, address(0));
        }
        vm.stopPrank();
        assertEq(campaign.getAcceptedTokens().length, cap);
    }

    /// @dev Adding an 11th token must revert with TooManyAcceptedTokens.
    function test_cannotExceedCap() public {
        uint256 cap = campaign.MAX_ACCEPTED_TOKENS();
        vm.startPrank(producer);
        for (uint256 i = 0; i < cap; i++) {
            MockERC20 t = new MockERC20("T", "T", 18);
            campaign.addAcceptedToken(address(t), Campaign.PricingMode.Fixed, 1e18, address(0));
        }
        MockERC20 extra = new MockERC20("X", "X", 18);
        vm.expectRevert(Campaign.TooManyAcceptedTokens.selector);
        campaign.addAcceptedToken(address(extra), Campaign.PricingMode.Fixed, 1e18, address(0));
        vm.stopPrank();
    }

    /// @dev Activation with MAX_ACCEPTED_TOKENS entries must still fit in a sane gas budget.
    function test_activationGasBoundedAtMaxTokens() public {
        uint256 cap = campaign.MAX_ACCEPTED_TOKENS();

        // Register the campaign's own USDC as token 1
        vm.startPrank(producer);
        campaign.addAcceptedToken(address(usdc), Campaign.PricingMode.Fixed, 144_000, address(0));
        // Fill remaining slots with inert fixed-rate tokens (no balance → no transfer)
        for (uint256 i = 1; i < cap; i++) {
            MockERC20 t = new MockERC20("T", "T", 18);
            campaign.addAcceptedToken(address(t), Campaign.PricingMode.Fixed, 1e18, address(0));
        }
        vm.stopPrank();

        // Alice buys enough USDC to trigger auto-activation
        address alice = makeAddr("alice");
        uint256 payment = 10_000 * 144_000;
        usdc.mint(alice, payment);
        vm.startPrank(alice);
        usdc.approve(address(campaign), type(uint256).max);

        uint256 gasBefore = gasleft();
        campaign.buy(address(usdc), payment);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        // Sanity: under 1M gas even with the full loop. (In practice ~500-700k.)
        assertLt(gasUsed, 1_000_000, "activation gas explosion");
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active));
    }
}
