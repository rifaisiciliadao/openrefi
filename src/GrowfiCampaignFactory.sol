// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GrowfiCampaignToken} from "./GrowfiCampaignToken.sol";
import {GrowfiYieldToken} from "./GrowfiYieldToken.sol";
import {GrowfiCampaign} from "./GrowfiCampaign.sol";
import {GrowfiStakingVault} from "./GrowfiStakingVault.sol";
import {GrowfiHarvestManager} from "./GrowfiHarvestManager.sol";
import {GrowfiMinter} from "./GrowfiMinter.sol";
import {GrowfiTreasury} from "./GrowfiTreasury.sol";
import {GrowfiToken} from "./GrowfiToken.sol";
import {GrowfiFeeSplitter} from "./GrowfiFeeSplitter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title GrowfiCampaignFactory — deployer & registry for upgradeable campaigns
/// @notice Each campaign is a bundle of 5 `TransparentUpgradeableProxy` contracts,
///         one per core contract type (GrowfiCampaign, GrowfiCampaignToken, GrowfiStakingVault,
///         GrowfiYieldToken, GrowfiHarvestManager). The producer of the campaign is set as
///         the `initialOwner` of each proxy's auto-deployed `ProxyAdmin`, so the
///         producer has full upgrade authority over ONLY their campaign.
/// @dev    The factory itself is Initializable + Ownable2StepUpgradeable and is
///         intended to be deployed behind its own TransparentUpgradeableProxy.
///         The factory owner can swap implementation addresses for FUTURE
///         campaigns via `setXxxImpl`; existing campaigns are unaffected.
contract GrowfiCampaignFactory is Initializable, Ownable2StepUpgradeable {
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

    // --- Appended storage (v4 — GROW protocol-wide token system) ---

    /// @notice Per-campaign hidden flag. Pure UI convention: when true, the official
    ///         frontend / subgraph filters the campaign out of public discovery lists
    ///         (homepage, portfolio, etc). The campaign remains FULLY OPERATIONAL on-chain —
    ///         users with the direct address can still buy / stake / redeem normally.
    ///         No on-chain protocol effect; no impact on Treasury allocations or pricing.
    mapping(address => bool) public hiddenCampaigns;

    event CampaignHiddenSet(address indexed campaign, bool hidden);

    /// @notice GrowfiToken — the protocol's GROW utility ERC20.
    address public growfiToken;
    /// @notice GrowfiMinter — gates GROW emission on every campaign buy via bonding-curve hooks.
    address public growfiMinter;
    /// @notice GrowfiTreasury — holds the GROW backing (USDC, USDT, DAI, CampaignTokens).
    address public growfiTreasury;
    /// @notice GrowfiFeeSplitter — receives the protocol fee, splits 30/70 between Treasury/Operations.
    address public growfiFeeSplitter;

    event GrowfiContractsSet(
        address indexed growfiToken,
        address indexed growfiMinter,
        address indexed growfiTreasury,
        address growfiFeeSplitter
    );

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


    // --- GrowfiCampaign Creation ---

    /// @notice Deploy a full upgradeable campaign suite. Permissionless — caller is producer.
    /// @dev    Each of the 5 deployed proxies gets `params.producer` as its ProxyAdmin owner.
    ///         Proxies are initialized inline (OZ 5.6+ requires non-empty initData) in
    ///         dependency order: GrowfiCampaign → GrowfiCampaignToken → GrowfiStakingVault → GrowfiHarvestManager → GrowfiYieldToken.
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

        // 1. GrowfiCampaign (no cross-contract deps at init).
        address campaignAddr = address(
            new TransparentUpgradeableProxy(
                campaignImpl,
                params.producer,
                abi.encodeCall(
                    GrowfiCampaign.initialize,
                    (GrowfiCampaign.InitParams({
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

        // 2. GrowfiCampaignToken (needs campaign address).
        address campaignTokenAddr = address(
            new TransparentUpgradeableProxy(
                campaignTokenImpl,
                params.producer,
                abi.encodeCall(GrowfiCampaignToken.initialize, (params.tokenName, params.tokenSymbol, campaignAddr))
            )
        );

        // 3. GrowfiStakingVault (needs campaignToken + campaign).
        address stakingVaultAddr = address(
            new TransparentUpgradeableProxy(
                stakingVaultImpl,
                params.producer,
                abi.encodeCall(
                    GrowfiStakingVault.initialize,
                    (campaignTokenAddr, campaignAddr, address(this), params.maxCap, params.seasonDuration)
                )
            )
        );

        // 4. GrowfiHarvestManager (no cross-contract deps at init).
        address harvestManagerAddr = address(
            new TransparentUpgradeableProxy(
                harvestManagerImpl,
                params.producer,
                abi.encodeCall(
                    GrowfiHarvestManager.initialize,
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

        // 5. GrowfiYieldToken (needs stakingVault + harvestManager).
        address yieldTokenAddr = address(
            new TransparentUpgradeableProxy(
                yieldTokenImpl,
                params.producer,
                abi.encodeCall(
                    GrowfiYieldToken.initialize, (params.yieldName, params.yieldSymbol, stakingVaultAddr, harvestManagerAddr)
                )
            )
        );

        // 6. Wire cross-references via the existing onlyFactory setters.
        GrowfiCampaign(campaignAddr).setCampaignToken(campaignTokenAddr);
        GrowfiCampaign(campaignAddr).setStakingVault(stakingVaultAddr); // delegates to GrowfiCampaignToken.setStakingVault
        GrowfiCampaign(campaignAddr).setHarvestManager(harvestManagerAddr); // for shortfall draws
        GrowfiHarvestManager(harvestManagerAddr).setYieldToken(yieldTokenAddr);
        GrowfiHarvestManager(harvestManagerAddr).setStakingVault(stakingVaultAddr);
        GrowfiHarvestManager(harvestManagerAddr).setCampaign(campaignAddr); // depositFromCollateral access
        GrowfiCampaign(campaignAddr).setYieldToken(yieldTokenAddr); // delegates to GrowfiStakingVault.setYieldToken

        // 7. GROW Minter auto-registration: every campaign emits GROW for participants by default
        //    (preserves the permissionless incentive for users to back any campaign).
        if (growfiMinter != address(0)) {
            GrowfiMinter(growfiMinter).registerCampaign(campaignAddr);
        }

        // NOTE: Treasury tracking is INTENTIONALLY NOT auto-registered here. Treasury allocates
        // protocol-owned USDC into tracked campaigns; auto-tracking would expose the Treasury
        // to a drain vector via spammed/malicious campaigns. The multisig must explicitly call
        // `factory.addGrowfiTreasuryTrackedCampaign(addr)` after vetting each producer (KYC,
        // collateral lock, reputation). The Minter side stays open so participants always
        // earn GROW; only the Treasury side is gated.

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

    /// @notice Wire the four GROW protocol contracts in a single call. Owner-only.
    /// @dev Deploy script flow:
    ///      1. Deploy factory + campaign impls.
    ///      2. Deploy GrowfiToken (factory_=this).
    ///      3. Deploy GrowfiTreasury (factory_=this, growToken_=token).
    ///      4. Deploy GrowfiMinter (factory_=this, growToken_=token, params).
    ///      5. Deploy GrowfiFeeSplitter (factory_=this, treasury_=treasury, ops_=multisig, bps).
    ///      6. factory.setGrowfiContracts(token, minter, treasury, splitter).
    ///      7. factory.setProtocolFeeRecipient(splitter).
    ///      8. token.setMinter(minter), token.setTreasury(treasury) — via factory forwarder if needed.
    ///      9. treasury.addAcceptedStablecoin(usdc, 1e12), etc.
    ///      Now createCampaign auto-wires GROW for every new campaign.
    function setGrowfiContracts(address token_, address minter_, address treasury_, address feeSplitter_)
        external
        onlyOwner
    {
        require(
            token_ != address(0) && minter_ != address(0) && treasury_ != address(0) && feeSplitter_ != address(0),
            "Zero address"
        );
        growfiToken = token_;
        growfiMinter = minter_;
        growfiTreasury = treasury_;
        growfiFeeSplitter = feeSplitter_;
        emit GrowfiContractsSet(token_, minter_, treasury_, feeSplitter_);
    }

    // --- GROW system forwarding admin (factory.owner → GROW contracts via this factory) ---

    function setGrowfiTokenMinter(address newMinter) external onlyOwner {
        GrowfiToken(growfiToken).setMinter(newMinter);
    }

    function setGrowfiTokenTreasury(address newTreasury) external onlyOwner {
        GrowfiToken(growfiToken).setTreasury(newTreasury);
    }

    function setGrowfiTokenSaleActive(bool active) external onlyOwner {
        GrowfiToken(growfiToken).setSaleActive(active);
    }

    function setGrowfiTokenMarkup(uint256 newMarkupBps) external onlyOwner {
        GrowfiToken(growfiToken).setMarkup(newMarkupBps);
    }

    function setGrowfiTokenReferencePrice(uint256 newPrice) external onlyOwner {
        GrowfiToken(growfiToken).setReferencePrice(newPrice);
    }

    /// @notice Mint the team/DAO reserve allocation into the Treasury. One-shot.
    function mintGrowfiTokenTreasuryGenesis(uint256 amount) external onlyOwner {
        GrowfiToken(growfiToken).mintTreasuryGenesis(amount);
    }

    /// @notice Release part of the Treasury's GROW reserve to a recipient (e.g. team
    ///         vesting wallet, partner grant, ops multisig).
    function releaseGrowFromTreasury(address to, uint256 amount) external onlyOwner {
        GrowfiTreasury(growfiTreasury).releaseGrow(to, amount);
    }

    function addGrowfiTreasuryStablecoin(
        address token,
        uint256 scale,
        address priceFeed,
        uint64 heartbeat,
        uint16 minPriceBps,
        uint16 maxPriceBps
    ) external onlyOwner {
        GrowfiTreasury(growfiTreasury).addAcceptedStablecoin(
            token, scale, priceFeed, heartbeat, minPriceBps, maxPriceBps
        );
    }

    function removeGrowfiTreasuryStablecoin(address token) external onlyOwner {
        GrowfiTreasury(growfiTreasury).removeAcceptedStablecoin(token);
    }

    function allocateGrowfiTreasury(address campaign, address paymentToken, uint256 amount) external onlyOwner {
        GrowfiTreasury(growfiTreasury).allocateToCampaign(campaign, paymentToken, amount);
    }

    function setGrowfiMinterExcluded(address addr, bool excluded) external onlyOwner {
        GrowfiMinter(growfiMinter).setExcludedFromMint(addr, excluded);
    }

    function setGrowfiBondingCurve(GrowfiMinter.BondingCurveParams calldata p) external onlyOwner {
        GrowfiMinter(growfiMinter).setBondingCurveParams(p);
    }

    function setGrowfiFeeSplitterBps(uint256 newBps) external onlyOwner {
        GrowfiFeeSplitter(growfiFeeSplitter).setTreasuryBps(newBps);
    }

    function setGrowfiFeeSplitterTreasury(address newTreasury) external onlyOwner {
        GrowfiFeeSplitter(growfiFeeSplitter).setTreasury(newTreasury);
    }

    function setGrowfiFeeSplitterOperations(address newOps) external onlyOwner {
        GrowfiFeeSplitter(growfiFeeSplitter).setOperations(newOps);
    }

    function setGrowfiTreasuryStakingPool(address pool) external onlyOwner {
        GrowfiTreasury(growfiTreasury).setStakingPool(pool);
    }

    function setGrowfiTreasuryStakerRewardBps(uint256 bps) external onlyOwner {
        GrowfiTreasury(growfiTreasury).setStakerRewardBps(bps);
    }

    function setGrowfiTreasuryAutomationEnabled(bool enabled) external onlyOwner {
        GrowfiTreasury(growfiTreasury).setAutomationEnabled(enabled);
    }

    function allocateAcrossTrackedGrowfiTreasury(address paymentToken, uint256 totalAmount)
        external
        onlyOwner
    {
        GrowfiTreasury(growfiTreasury).allocateAcrossTracked(paymentToken, totalAmount);
    }

    function stakeGrowfiTreasury(address campaign, uint256 amount) external onlyOwner returns (uint256 positionId) {
        return GrowfiTreasury(growfiTreasury).stakeOnCampaign(campaign, amount);
    }

    function claimGrowfiTreasuryYield(address campaign, uint256 positionId) external onlyOwner {
        GrowfiTreasury(growfiTreasury).claimYieldFromCampaign(campaign, positionId);
    }

    function commitGrowfiTreasuryUsdcRedeem(address campaign, uint256 seasonId, uint256 yieldAmount)
        external
        onlyOwner
    {
        GrowfiTreasury(growfiTreasury).commitUsdcRedeem(campaign, seasonId, yieldAmount);
    }

    function addGrowfiTreasuryTrackedCampaign(address campaign) external onlyOwner {
        GrowfiTreasury(growfiTreasury).addTrackedCampaign(campaign);
    }

    function removeGrowfiTreasuryTrackedCampaign(address campaign) external onlyOwner {
        GrowfiTreasury(growfiTreasury).removeTrackedCampaign(campaign);
    }

    function rescueGrowfiTreasuryToken(address token, address to, uint256 amount) external onlyOwner {
        GrowfiTreasury(growfiTreasury).rescueToken(IERC20(token), to, amount);
    }

    function buybackGrowfiTreasury(address campaign, address paymentToken) external onlyOwner {
        GrowfiTreasury(growfiTreasury).buybackFromCampaign(campaign, paymentToken);
    }

    // --- Campaign visibility (hide) ---

    function setCampaignHidden(address campaign, bool hidden) external onlyOwner {
        require(isCampaign[campaign], "Not a campaign");
        hiddenCampaigns[campaign] = hidden;
        emit CampaignHiddenSet(campaign, hidden);
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
        GrowfiCampaign(c.campaign).emergencyPause();
        GrowfiStakingVault(c.stakingVault).emergencyPause();
        GrowfiHarvestManager(c.harvestManager).emergencyPause();
    }

    /// @notice Unpause all contracts for a specific campaign.
    function unpauseCampaign(uint256 campaignIndex) external onlyOwner {
        CampaignContracts storage c = campaigns[campaignIndex];
        GrowfiCampaign(c.campaign).emergencyUnpause();
        GrowfiStakingVault(c.stakingVault).emergencyUnpause();
        GrowfiHarvestManager(c.harvestManager).emergencyUnpause();
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
