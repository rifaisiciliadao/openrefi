// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * IGrowfiCampaignFactoryView — minimum surface a campaign needs to read from the factory at init.
 *
 * Used by GrowfiCampaign.initialize() to snapshot the protocol-level GROW system addresses.
 * If `growfiMinter()` returns address(0), the campaign runs without GROW emission (legacy path
 * for tests + bootstrap windows where the GROW system isn't wired yet).
 */
interface IGrowfiCampaignFactoryView {
    function growfiMinter() external view returns (address);
    function usdc() external view returns (address);
}
