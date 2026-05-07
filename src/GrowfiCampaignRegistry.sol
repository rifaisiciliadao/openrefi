// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GrowfiCampaign} from "./GrowfiCampaign.sol";
import {GrowfiCampaignFactory} from "./GrowfiCampaignFactory.sol";

/// @title GrowfiCampaignRegistry
/// @notice Off-chain-to-on-chain bridge for campaign metadata (name, description,
///         cover image URL, location, product type). Producers write a JSON URI
///         here after `createCampaign`. Subgraph indexes the event.
///
///         One single, globally-shared registry contract per network. No upgrades,
///         no admin. A producer can only write for campaigns they actually own.
///         Version field lets producers rotate the metadata URL without losing
///         history (useful if the backend moves to a different CDN).
contract GrowfiCampaignRegistry {
    GrowfiCampaignFactory public immutable factory;

    /// @notice Current metadata URI per campaign (latest overwrite).
    mapping(address => string) public metadataURI;

    /// @notice Monotonically increasing version per campaign.
    mapping(address => uint256) public version;

    event MetadataSet(address indexed campaign, address indexed producer, uint256 indexed version, string uri);

    error NotCampaign();
    error NotProducer();
    error EmptyURI();

    constructor(GrowfiCampaignFactory factory_) {
        factory = factory_;
    }

    /// @notice Publish or update metadata for a campaign. Only the campaign's
    ///         producer can call this.
    /// @param campaign The campaign proxy address (must have been deployed by
    ///        `factory`, checked via `factory.isCampaign`).
    /// @param uri Fully-qualified URL to a JSON document (e.g.
    ///        `https://growfi-media.fra1.digitaloceanspaces.com/metadata/xyz.json`).
    function setMetadata(address campaign, string calldata uri) external {
        if (!factory.isCampaign(campaign)) revert NotCampaign();
        if (GrowfiCampaign(campaign).producer() != msg.sender) revert NotProducer();
        if (bytes(uri).length == 0) revert EmptyURI();

        uint256 newVersion = version[campaign] + 1;
        version[campaign] = newVersion;
        metadataURI[campaign] = uri;

        emit MetadataSet(campaign, msg.sender, newVersion, uri);
    }
}
