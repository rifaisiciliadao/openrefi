// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {CampaignToken} from "./CampaignToken.sol";
import {YieldToken} from "./YieldToken.sol";
import {Campaign} from "./Campaign.sol";
import {StakingVault} from "./StakingVault.sol";
import {HarvestManager} from "./HarvestManager.sol";

/// @title CampaignFactory — deployer & registry for upgradeable campaigns
/// @notice Each campaign is a bundle of 5 `TransparentUpgradeableProxy` contracts,
///         one per core contract type (Campaign, CampaignToken, StakingVault,
///         YieldToken, HarvestManager). The producer of the campaign is set as
///         the `initialOwner` of each proxy's auto-deployed `ProxyAdmin`, so the
///         producer has full upgrade authority over ONLY their campaign.
/// @dev    The factory itself is Initializable + Ownable2StepUpgradeable and is
///         intended to be deployed behind its own TransparentUpgradeableProxy.
///         The factory owner can swap implementation addresses for FUTURE
///         campaigns via `setXxxImpl`; existing campaigns are unaffected.
contract CampaignFactory is Initializable, Ownable2StepUpgradeable {
    // --- Constants ---

    uint256 public constant PROTOCOL_FEE_BPS = 200; // 2% on depositUSDC (yield-side)
    uint256 public constant FUNDING_FEE_BPS = 300; // 3% on buy() gross inflow (funding-side)

    // --- Structs ---

    struct CampaignContracts {
        address campaign;
        address campaignToken;
        address yieldToken;
        address stakingVault;
        address harvestManager;
        address producer;
        uint256 createdAt;
    }

    // --- State ---

    address public protocolFeeRecipient;
    address public usdc;
    /// @notice Chainlink L2 sequencer-uptime feed; `address(0)` on L1.
    address public sequencerUptimeFeed;

    // Implementation addresses — settable by owner to change behavior for FUTURE campaigns.
    address public campaignImpl;
    address public campaignTokenImpl;
    address public stakingVaultImpl;
    address public yieldTokenImpl;
    address public harvestManagerImpl;

    CampaignContracts[] public campaigns;
    mapping(address => bool) public isCampaign;

    /// @notice Minimum `seasonDuration` accepted by `createCampaign`.
    ///         Owner-settable so testnets can relax to minutes while mainnet enforces
    ///         a months-long floor. Defaults to 30 days on fresh deployments; existing
    ///         pre-V2 deployments set it via `initializeV2()` during the upgrade call.
    /// @dev    Added in V2 — appended to preserve storage layout.
    uint256 public minSeasonDuration;

    /// @notice Set of taken `tokenName` slugs, keccak-keyed.
    ///         Populated on every successful `createCampaign` and checked on entry —
    ///         prevents duplicate campaign names cluttering the discovery list.
    ///         Strict-equal hash (no normalisation) so producers can still pick
    ///         "Olive Sicily" and "olive sicily" as distinct, but they obviously
    ///         shouldn't. The frontend trims + case-folds for UX symmetry; the
    ///         contract is the hard guarantee.
    /// @dev    Appended to preserve storage layout.
    mapping(bytes32 => bool) public nameTaken;

    // --- Events ---

    event CampaignCreated(
        address indexed campaign,
        address indexed producer,
        address campaignToken,
        address yieldToken,
        address stakingVault,
        address harvestManager,
        uint256 pricePerToken,
        uint256 minCap,
        uint256 maxCap,
        uint256 fundingDeadline,
        uint256 seasonDuration,
        uint256 minProductClaim,
        uint256 createdAt,
        uint256 expectedAnnualHarvestUsd,
        uint256 expectedAnnualHarvest,
        uint256 firstHarvestYear,
        uint256 coverageHarvests
    );

    event ProtocolFeeRecipientUpdated(address oldRecipient, address newRecipient);
    event ImplementationUpdated(bytes32 indexed kind, address oldImpl, address newImpl);
    event MinSeasonDurationUpdated(uint256 oldValue, uint256 newValue);

    // --- Struct for createCampaign args (unchanged ABI) ---

    struct CreateCampaignParams {
        address producer;
        string tokenName;
        string tokenSymbol;
        string yieldName;
        string yieldSymbol;
        uint256 pricePerToken;
        uint256 minCap;
        uint256 maxCap;
        uint256 fundingDeadline;
        uint256 seasonDuration;
        uint256 minProductClaim;
        // v3 — productive-asset metadata + collateral coverage commitment.
        // Set once at creation; immutable for the life of the campaign.
        uint256 expectedAnnualHarvestUsd; // USD/yr, 1e18 (e.g. 5_000e18 = $5,000/yr)
        uint256 expectedAnnualHarvest; // product units/yr, 1e18 (e.g. 1_000e18 = 1,000 L)
        uint256 firstHarvestYear; // calendar year (e.g. 2030)
        uint256 coverageHarvests; // 0 ≤ n; recommended ≤ harvestsToRepay
    }

    // --- Init ---

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param owner_              Factory admin — controls implementation pointers and emergency pause.
    /// @param protocolFeeRecipient_ Immutable-per-campaign fee sink (snapshotted at campaign create).
    /// @param usdc_               USDC on target chain.
    /// @param sequencerUptimeFeed_ Chainlink sequencer feed on L2; address(0) on L1.
    /// @param impls               [campaign, campaignToken, stakingVault, yieldToken, harvestManager]
    function initialize(
        address owner_,
        address protocolFeeRecipient_,
        address usdc_,
        address sequencerUptimeFeed_,
        address[5] calldata impls
    ) external initializer {
        __Ownable_init(owner_);
        require(protocolFeeRecipient_ != address(0), "Zero feeRecipient");
        require(usdc_ != address(0), "Zero usdc");
        protocolFeeRecipient = protocolFeeRecipient_;
        usdc = usdc_;
        sequencerUptimeFeed = sequencerUptimeFeed_;
        minSeasonDuration = 30 days;
        _setImpls(impls);
    }

    /// @notice One-shot reinitializer for existing pre-V2 deployments being upgraded.
    ///         Seeds `minSeasonDuration = 30 days` so the behavior matches pre-upgrade.
    function initializeV2() external reinitializer(2) {
        minSeasonDuration = 30 days;
    }

    // --- Campaign Creation ---

    /// @notice Deploy a full upgradeable campaign suite. Permissionless — caller is producer.
    /// @dev    Each of the 5 deployed proxies gets `params.producer` as its ProxyAdmin owner.
    ///         Proxies are initialized inline (OZ 5.6+ requires non-empty initData) in
    ///         dependency order: Campaign → CampaignToken → StakingVault → HarvestManager → YieldToken.
    function createCampaign(CreateCampaignParams calldata params) external returns (address) {
        require(params.producer != address(0), "Zero producer");
        require(params.producer == msg.sender, "producer must be caller");
        require(params.pricePerToken > 0, "Zero price");
        require(params.maxCap > 0, "Zero maxCap");
        require(params.minCap <= params.maxCap, "minCap > maxCap");
        require(params.fundingDeadline > block.timestamp, "Deadline in past");
        require(params.seasonDuration >= minSeasonDuration, "Season too short");
        require(params.expectedAnnualHarvestUsd > 0, "Zero expected annual harvest USD");
        require(params.expectedAnnualHarvest > 0, "Zero expected annual harvest qty");
        require(params.firstHarvestYear > 0, "Zero firstHarvestYear");
        require(bytes(params.tokenName).length > 0, "Empty tokenName");
        // coverageHarvests is allowed to be 0 (= producer publishes targets but
        // doesn't pre-fund any seasons). Upper bound is harvestsToRepay; we don't
        // enforce on-chain (frontend warns) — over-coverage just over-locks USDC.

        // Hard-block duplicate campaign names. Frontend has its own
        // pre-flight against the subgraph for instant feedback (no wasted
        // signature) but the contract is the source of truth — direct
        // factory.createCampaign callers and stuck-popup multi-fire bugs
        // both bounce here.
        bytes32 nameHash = keccak256(bytes(params.tokenName));
        require(!nameTaken[nameHash], "tokenName already taken");
        nameTaken[nameHash] = true;

        // 1. Campaign (no cross-contract deps at init).
        address campaignAddr = address(
            new TransparentUpgradeableProxy(
                campaignImpl,
                params.producer,
                abi.encodeCall(
                    Campaign.initialize,
                    (Campaign.InitParams({
                            producer: params.producer,
                            factory: address(this),
                            pricePerToken: params.pricePerToken,
                            minCap: params.minCap,
                            maxCap: params.maxCap,
                            fundingDeadline: params.fundingDeadline,
                            seasonDuration: params.seasonDuration,
                            protocolFeeBps: PROTOCOL_FEE_BPS,
                            fundingFeeBps: FUNDING_FEE_BPS,
                            expectedAnnualHarvestUsd: params.expectedAnnualHarvestUsd,
                            expectedAnnualHarvest: params.expectedAnnualHarvest,
                            firstHarvestYear: params.firstHarvestYear,
                            coverageHarvests: params.coverageHarvests,
                            protocolFeeRecipient: protocolFeeRecipient,
                            sequencerUptimeFeed: sequencerUptimeFeed,
                            usdc: usdc
                        }))
                )
            )
        );

        // 2. CampaignToken (needs campaign address).
        address campaignTokenAddr = address(
            new TransparentUpgradeableProxy(
                campaignTokenImpl,
                params.producer,
                abi.encodeCall(CampaignToken.initialize, (params.tokenName, params.tokenSymbol, campaignAddr))
            )
        );

        // 3. StakingVault (needs campaignToken + campaign).
        address stakingVaultAddr = address(
            new TransparentUpgradeableProxy(
                stakingVaultImpl,
                params.producer,
                abi.encodeCall(
                    StakingVault.initialize,
                    (campaignTokenAddr, campaignAddr, address(this), params.maxCap, params.seasonDuration)
                )
            )
        );

        // 4. HarvestManager (no cross-contract deps at init).
        address harvestManagerAddr = address(
            new TransparentUpgradeableProxy(
                harvestManagerImpl,
                params.producer,
                abi.encodeCall(
                    HarvestManager.initialize,
                    (
                        usdc,
                        params.producer,
                        address(this),
                        protocolFeeRecipient,
                        PROTOCOL_FEE_BPS,
                        params.minProductClaim
                    )
                )
            )
        );

        // 5. YieldToken (needs stakingVault + harvestManager).
        address yieldTokenAddr = address(
            new TransparentUpgradeableProxy(
                yieldTokenImpl,
                params.producer,
                abi.encodeCall(
                    YieldToken.initialize, (params.yieldName, params.yieldSymbol, stakingVaultAddr, harvestManagerAddr)
                )
            )
        );

        // 6. Wire cross-references via the existing onlyFactory setters.
        Campaign(campaignAddr).setCampaignToken(campaignTokenAddr);
        Campaign(campaignAddr).setStakingVault(stakingVaultAddr); // delegates to CampaignToken.setStakingVault
        Campaign(campaignAddr).setHarvestManager(harvestManagerAddr); // for shortfall draws
        HarvestManager(harvestManagerAddr).setYieldToken(yieldTokenAddr);
        HarvestManager(harvestManagerAddr).setStakingVault(stakingVaultAddr);
        HarvestManager(harvestManagerAddr).setCampaign(campaignAddr); // depositFromCollateral access
        Campaign(campaignAddr).setYieldToken(yieldTokenAddr); // delegates to StakingVault.setYieldToken

        // 4. Register
        campaigns.push(
            CampaignContracts({
                campaign: campaignAddr,
                campaignToken: campaignTokenAddr,
                yieldToken: yieldTokenAddr,
                stakingVault: stakingVaultAddr,
                harvestManager: harvestManagerAddr,
                producer: params.producer,
                createdAt: block.timestamp
            })
        );
        isCampaign[campaignAddr] = true;

        emit CampaignCreated(
            campaignAddr,
            params.producer,
            campaignTokenAddr,
            yieldTokenAddr,
            stakingVaultAddr,
            harvestManagerAddr,
            params.pricePerToken,
            params.minCap,
            params.maxCap,
            params.fundingDeadline,
            params.seasonDuration,
            params.minProductClaim,
            block.timestamp,
            params.expectedAnnualHarvestUsd,
            params.expectedAnnualHarvest,
            params.firstHarvestYear,
            params.coverageHarvests
        );

        return campaignAddr;
    }

    // --- Admin ---

    function setProtocolFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Zero address");
        emit ProtocolFeeRecipientUpdated(protocolFeeRecipient, newRecipient);
        protocolFeeRecipient = newRecipient;
    }

    function setCampaignImpl(address impl) external onlyOwner {
        require(impl != address(0), "Zero impl");
        emit ImplementationUpdated("campaign", campaignImpl, impl);
        campaignImpl = impl;
    }

    function setCampaignTokenImpl(address impl) external onlyOwner {
        require(impl != address(0), "Zero impl");
        emit ImplementationUpdated("campaignToken", campaignTokenImpl, impl);
        campaignTokenImpl = impl;
    }

    function setStakingVaultImpl(address impl) external onlyOwner {
        require(impl != address(0), "Zero impl");
        emit ImplementationUpdated("stakingVault", stakingVaultImpl, impl);
        stakingVaultImpl = impl;
    }

    function setYieldTokenImpl(address impl) external onlyOwner {
        require(impl != address(0), "Zero impl");
        emit ImplementationUpdated("yieldToken", yieldTokenImpl, impl);
        yieldTokenImpl = impl;
    }

    function setHarvestManagerImpl(address impl) external onlyOwner {
        require(impl != address(0), "Zero impl");
        emit ImplementationUpdated("harvestManager", harvestManagerImpl, impl);
        harvestManagerImpl = impl;
    }

    function setSequencerUptimeFeed(address feed) external onlyOwner {
        sequencerUptimeFeed = feed;
    }

    function setMinSeasonDuration(uint256 value) external onlyOwner {
        emit MinSeasonDurationUpdated(minSeasonDuration, value);
        minSeasonDuration = value;
    }

    function getCampaignCount() external view returns (uint256) {
        return campaigns.length;
    }

    // --- Emergency ---

    /// @notice Pause all contracts for a specific campaign.
    /// @dev    This is the factory-level pause (code defect / protocol-wide incident).
    ///         It is separate from any pauses the producer may implement via upgrades.
    function pauseCampaign(uint256 campaignIndex) external onlyOwner {
        CampaignContracts storage c = campaigns[campaignIndex];
        Campaign(c.campaign).emergencyPause();
        StakingVault(c.stakingVault).emergencyPause();
        HarvestManager(c.harvestManager).emergencyPause();
    }

    /// @notice Unpause all contracts for a specific campaign.
    function unpauseCampaign(uint256 campaignIndex) external onlyOwner {
        CampaignContracts storage c = campaigns[campaignIndex];
        Campaign(c.campaign).emergencyUnpause();
        StakingVault(c.stakingVault).emergencyUnpause();
        HarvestManager(c.harvestManager).emergencyUnpause();
    }

    // --- Internal ---

    function _setImpls(address[5] calldata impls) internal {
        require(
            impls[0] != address(0) && impls[1] != address(0) && impls[2] != address(0) && impls[3] != address(0)
                && impls[4] != address(0),
            "Zero impl"
        );
        campaignImpl = impls[0];
        campaignTokenImpl = impls[1];
        stakingVaultImpl = impls[2];
        yieldTokenImpl = impls[3];
        harvestManagerImpl = impls[4];
    }
}
