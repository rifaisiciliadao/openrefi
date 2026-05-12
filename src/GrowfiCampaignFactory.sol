// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ModuleRegistry} from "./host/ModuleRegistry.sol";
import {GrowfiCampaign} from "./GrowfiCampaign.sol";
import {GrowfiCampaignToken} from "./GrowfiCampaignToken.sol";
import {GrowfiYieldToken} from "./GrowfiYieldToken.sol";
import {GrowfiStakingVault} from "./GrowfiStakingVault.sol";
import {GrowfiHarvestManager} from "./GrowfiHarvestManager.sol";

import {SaleClassicModule} from "./modules/SaleClassicModule.sol";
import {CollateralModule} from "./modules/CollateralModule.sol";

import {GrowfiToken} from "./GrowfiToken.sol";
import {GrowfiTreasury} from "./GrowfiTreasury.sol";
import {GrowfiMinter} from "./GrowfiMinter.sol";
import {GrowfiFeeSplitter} from "./GrowfiFeeSplitter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev GROW Minter sub-interface used by the factory to register a
///      freshly deployed Campaign so its hook calls pass the Minter's
///      `onlyRegisteredCampaign` gate.
interface IGrowfiMinterRegister {
    function registerCampaign(address campaign) external;
}

/// @title  GrowfiCampaignFactory (v4)
/// @notice Deploys the per-campaign proxy stack and auto-injects the
///         default modules (sale + collateral) at boot. Inherits
///         ModuleRegistry so the Campaign host can read the whitelist
///         + selector set from a single contract.
///
///         The public createCampaign signature mirrors the v3 factory's
///         flat-struct shape so existing tests and scripts can use the
///         same call surface; internally the flat fields are split into
///         the nested module InitParams expected by v4 modules.
contract GrowfiCampaignFactory is Initializable, ModuleRegistry {
    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    bytes32 public constant KIND_SALE_CLASSIC_V1 = keccak256("growfi.sale.classic.v1");
    bytes32 public constant KIND_COLLATERAL_V1 = keccak256("growfi.collateral.v1");
    uint256 public constant FUNDING_FEE_BPS = 300; // 3%
    uint256 public constant HARVEST_PROTOCOL_FEE_BPS = 200; // 2%

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    struct CampaignContracts {
        address campaign;
        address campaignToken;
        address yieldToken;
        address stakingVault;
        address harvestManager;
        address producer;
        uint256 createdAt;
    }

    address public protocolFeeRecipient;
    address public usdc;
    address public sequencerUptimeFeed;
    address public growfiToken;
    address public growfiMinter;
    address public growfiTreasury;
    address public growfiFeeSplitter;

    address public campaignImpl;
    address public campaignTokenImpl;
    address public stakingVaultImpl;
    address public yieldTokenImpl;
    address public harvestManagerImpl;

    address public proxyAdminOwner;
    uint256 public minSeasonDuration;

    CampaignContracts[] public campaigns;
    mapping(address => bool) public isCampaign;
    mapping(bytes32 => bool) public nameTaken;
    mapping(address => bool) public hiddenCampaigns;

    // ------------------------------------------------------------------
    // Events / errors
    // ------------------------------------------------------------------

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
    event ImplsUpdated(address campaign, address campaignToken, address stakingVault, address yieldToken, address harvestManager);
    event ProxyAdminOwnerSet(address admin);
    event MinSeasonDurationSet(uint256 seconds_);
    event ProtocolFeeRecipientSet(address recipient);
    event GrowfiMinterSet(address minter);
    event GrowfiContractsSet(
        address indexed growfiToken,
        address indexed growfiMinter,
        address indexed growfiTreasury,
        address growfiFeeSplitter
    );
    event CampaignHiddenSet(address indexed campaign, bool hidden);

    error ImplsNotSet();
    error NameTakenError();
    error EmptyName();
    error MinSeasonTooShort();
    error ProducerMismatch();
    error UnknownCampaign();

    // ------------------------------------------------------------------
    // Initializer
    // ------------------------------------------------------------------

    constructor() {
        _disableInitializers();
    }

    /// @notice v3-compatible initializer signature for drop-in usage.
    /// @param owner          Factory owner (protocol multisig).
    /// @param feeRecipient   Protocol fee sink (paid out by the sale module's funding fee + HM's yield-side fee).
    /// @param usdc_          Canonical USDC address used by collateral flows.
    /// @param seqFeed        Chainlink L2 sequencer-uptime feed (zero on L1/testnet).
    /// @param impls          5-element array: [campaign, campaignToken, stakingVault, yieldToken, harvestManager].
    function initialize(
        address owner,
        address feeRecipient,
        address usdc_,
        address seqFeed,
        address[5] calldata impls
    ) external initializer {
        __ModuleRegistry_init(owner);
        usdc = usdc_;
        protocolFeeRecipient = feeRecipient;
        sequencerUptimeFeed = seqFeed;
        campaignImpl = impls[0];
        campaignTokenImpl = impls[1];
        stakingVaultImpl = impls[2];
        yieldTokenImpl = impls[3];
        harvestManagerImpl = impls[4];
        minSeasonDuration = 30 days;
        proxyAdminOwner = owner;
    }

    // ------------------------------------------------------------------
    // Owner admin
    // ------------------------------------------------------------------

    function setCampaignImpl(address impl) external onlyOwner { campaignImpl = impl; }
    function setCampaignTokenImpl(address impl) external onlyOwner { campaignTokenImpl = impl; }
    function setStakingVaultImpl(address impl) external onlyOwner { stakingVaultImpl = impl; }
    function setYieldTokenImpl(address impl) external onlyOwner { yieldTokenImpl = impl; }
    function setHarvestManagerImpl(address impl) external onlyOwner { harvestManagerImpl = impl; }

    function setProxyAdminOwner(address newAdmin) external onlyOwner {
        proxyAdminOwner = newAdmin;
        emit ProxyAdminOwnerSet(newAdmin);
    }

    function setMinSeasonDuration(uint256 seconds_) external onlyOwner {
        minSeasonDuration = seconds_;
        emit MinSeasonDurationSet(seconds_);
    }

    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        require(recipient != address(0), "Zero address");
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientSet(recipient);
    }

    function setGrowfiMinter(address minter) external onlyOwner {
        growfiMinter = minter;
        emit GrowfiMinterSet(minter);
    }

    /// @notice Wire all four GROW contracts in one call. Mirrors the v3
    ///         initializer-style helper.
    function setGrowfiContracts(
        address token_,
        address minter_,
        address treasury_,
        address feeSplitter_
    ) external onlyOwner {
        require(
            token_ != address(0) && minter_ != address(0) && treasury_ != address(0)
                && feeSplitter_ != address(0),
            "Zero address"
        );
        growfiToken = token_;
        growfiMinter = minter_;
        growfiTreasury = treasury_;
        growfiFeeSplitter = feeSplitter_;
        emit GrowfiContractsSet(token_, minter_, treasury_, feeSplitter_);
    }

    // --- GROW system forwarding admin ---

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

    function mintGrowfiTokenTreasuryGenesis(uint256 amount) external onlyOwner {
        GrowfiToken(growfiToken).mintTreasuryGenesis(amount);
    }

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

    function allocateGrowfiTreasury(address campaign, address paymentToken, uint256 amount)
        external
        onlyOwner
    {
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

    function stakeGrowfiTreasury(address campaign, uint256 amount)
        external
        onlyOwner
        returns (uint256 positionId)
    {
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

    function getCampaignCount() external view returns (uint256) {
        return campaigns.length;
    }

    /// @notice Owner-only emergency pause for a deployed Campaign. Pauses
    ///         both the host (which the sale module reads) and the
    ///         HarvestManager (which has its own pause state).
    function pauseCampaign(uint256 idx) external onlyOwner {
        CampaignContracts memory cc = campaigns[idx];
        GrowfiCampaign(payable(cc.campaign)).factorySetPaused(true);
        GrowfiHarvestManager(cc.harvestManager).emergencyPause();
    }

    /// @notice Owner-only unpause.
    function unpauseCampaign(uint256 idx) external onlyOwner {
        CampaignContracts memory cc = campaigns[idx];
        GrowfiCampaign(payable(cc.campaign)).factorySetPaused(false);
        GrowfiHarvestManager(cc.harvestManager).emergencyUnpause();
    }

    function setCampaignHidden(address campaign, bool hidden) external onlyOwner {
        if (!isCampaign[campaign]) revert UnknownCampaign();
        hiddenCampaigns[campaign] = hidden;
        emit CampaignHiddenSet(campaign, hidden);
    }

    // ------------------------------------------------------------------
    // Create campaign — v3-compatible flat-struct surface
    // ------------------------------------------------------------------

    struct CreateCampaignParams {
        address producer;
        string campaignTokenName;
        string campaignTokenSymbol;
        string yieldTokenName;
        string yieldTokenSymbol;
        uint256 minProductClaim;
        SaleClassicModule.InitParams sale;
        CollateralModule.InitParams collateral;
    }

    function createCampaign(CreateCampaignParams calldata p) external returns (address campaignProxy) {
        require(p.producer == msg.sender, "producer must be caller");
        require(bytes(p.campaignTokenName).length > 0, "Empty tokenName");
        bytes32 nameKey = keccak256(bytes(p.campaignTokenName));
        require(!nameTaken[nameKey], "tokenName already taken");
        require(p.sale.pricePerToken > 0, "Zero price");
        require(p.sale.minCap <= p.sale.maxCap, "minCap > maxCap");
        require(p.sale.fundingDeadline > block.timestamp, "Deadline in past");
        require(p.sale.seasonDuration >= minSeasonDuration, "Season too short");
        if (campaignImpl == address(0)) revert ImplsNotSet();
        nameTaken[nameKey] = true;

        // Deploy Campaign host first (no cross-contract deps).
        campaignProxy = _deployCampaignHost(p.producer);

        // Deploy 4 satellites.
        (address ctAddr, address ytAddr, address svAddr, address hmAddr) = _deploySatellites(p, campaignProxy);

        // Wire satellites (host setters are onlyFactory).
        GrowfiCampaign(payable(campaignProxy)).setCampaignToken(ctAddr);
        GrowfiCampaign(payable(campaignProxy)).setStakingVault(svAddr);
        GrowfiCampaign(payable(campaignProxy)).setHarvestManager(hmAddr);
        GrowfiCampaign(payable(campaignProxy)).setYieldToken(ytAddr);

        // Cross-wire HarvestManager (the CT staking-vault wiring fires
        // automatically inside Campaign.setStakingVault).
        GrowfiHarvestManager(hmAddr).setYieldToken(ytAddr);
        GrowfiHarvestManager(hmAddr).setStakingVault(svAddr);
        GrowfiHarvestManager(hmAddr).setCampaign(campaignProxy);

        // Bootstrap default modules + their init params.
        _bootstrapDefaultModules(GrowfiCampaign(payable(campaignProxy)), p);

        // Register with GROW Minter so its hooks pass `onlyRegisteredCampaign`.
        if (growfiMinter != address(0)) {
            IGrowfiMinterRegister(growfiMinter).registerCampaign(campaignProxy);
        }

        // Store record.
        campaigns.push(
            CampaignContracts({
                campaign: campaignProxy,
                campaignToken: ctAddr,
                yieldToken: ytAddr,
                stakingVault: svAddr,
                harvestManager: hmAddr,
                producer: p.producer,
                createdAt: block.timestamp
            })
        );
        isCampaign[campaignProxy] = true;

        emit CampaignCreated(
            campaignProxy,
            p.producer,
            ctAddr,
            ytAddr,
            svAddr,
            hmAddr,
            p.sale.pricePerToken,
            p.sale.minCap,
            p.sale.maxCap,
            p.sale.fundingDeadline,
            p.sale.seasonDuration,
            p.minProductClaim,
            block.timestamp,
            p.collateral.expectedAnnualHarvestUsd,
            p.collateral.expectedAnnualHarvest,
            p.collateral.firstHarvestYear,
            p.collateral.coverageHarvests
        );
    }

    function _deployCampaignHost(address producer) internal returns (address campaignProxy) {
        GrowfiCampaign.InitParams memory hostInit = GrowfiCampaign.InitParams({
            producer: producer,
            factory: address(this),
            usdc: usdc,
            protocolFeeRecipient: protocolFeeRecipient
        });
        bytes memory campInit = abi.encodeCall(GrowfiCampaign.initialize, (hostInit));
        campaignProxy = address(new TransparentUpgradeableProxy(campaignImpl, proxyAdminOwner, campInit));
    }

    function _deploySatellites(CreateCampaignParams calldata p, address campaignProxy)
        internal
        returns (address ctAddr, address ytAddr, address svAddr, address hmAddr)
    {
        bytes memory ctInit = abi.encodeCall(
            GrowfiCampaignToken.initialize, (p.campaignTokenName, p.campaignTokenSymbol, campaignProxy)
        );
        ctAddr = address(new TransparentUpgradeableProxy(campaignTokenImpl, proxyAdminOwner, ctInit));

        bytes memory svInit = abi.encodeCall(
            GrowfiStakingVault.initialize, (ctAddr, campaignProxy, address(this), p.sale.maxCap, p.sale.seasonDuration)
        );
        svAddr = address(new TransparentUpgradeableProxy(stakingVaultImpl, proxyAdminOwner, svInit));

        bytes memory hmInit = abi.encodeCall(
            GrowfiHarvestManager.initialize,
            (
                usdc,
                p.producer,
                address(this),
                protocolFeeRecipient,
                HARVEST_PROTOCOL_FEE_BPS,
                p.minProductClaim
            )
        );
        hmAddr = address(new TransparentUpgradeableProxy(harvestManagerImpl, proxyAdminOwner, hmInit));

        bytes memory ytInit =
            abi.encodeCall(GrowfiYieldToken.initialize, (p.yieldTokenName, p.yieldTokenSymbol, svAddr, hmAddr));
        ytAddr = address(new TransparentUpgradeableProxy(yieldTokenImpl, proxyAdminOwner, ytInit));
    }

    function _bootstrapDefaultModules(GrowfiCampaign campaign, CreateCampaignParams calldata p) internal {
        uint256 n = defaultModulesLength();
        for (uint256 i; i < n;) {
            ModuleRegistry.DefaultModule memory m = defaultModuleAt(i);
            campaign.attachModuleAsFactory(m.moduleType, m.kind, m.impl, m.metadataURI);
            if (m.kind == KIND_SALE_CLASSIC_V1) {
                SaleClassicModule.InitParams memory sp = p.sale;
                // Protocol-fixed parameters: producer cannot override.
                sp.sequencerUptimeFeed = sequencerUptimeFeed;
                sp.growMinter = growfiMinter;
                sp.fundingFeeBps = FUNDING_FEE_BPS;
                SaleClassicModule(payable(address(campaign))).initializeSaleClassic(sp);
            } else if (m.kind == KIND_COLLATERAL_V1) {
                CollateralModule(payable(address(campaign))).initializeCollateral(p.collateral);
            }
            unchecked {
                ++i;
            }
        }
        campaign.closeBootstrap();
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function campaignsLength() external view returns (uint256) {
        return campaigns.length;
    }
}
