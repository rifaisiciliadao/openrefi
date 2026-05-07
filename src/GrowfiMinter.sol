// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GrowfiToken} from "./GrowfiToken.sol";
import {IGrowfiMinter} from "./interfaces/IGrowfiMinter.sol";
import {IGrowfiCampaignView} from "./interfaces/IGrowfiCampaignView.sol";

/**
 * GrowfiMinter — gates GROW emission via the bonding curve, escrow, and per-campaign status.
 *
 * Lifecycle per campaign:
 *   NotRegistered → (factory.registerCampaign) → Pending
 *   Pending       → (Campaign._activate / onSoftCapReached) → Active
 *   Pending       → (Campaign.triggerBuyback / onBuyback)   → Failed
 *
 * Mint policy:
 * - Pre-softcap (Pending): GROW per buy is escrowed per (campaign, user). Pull-claimed once
 *   the campaign reaches Active.
 * - Post-softcap (Active): GROW per buy is minted directly to the buyer.
 * - Buyback (Failed): all escrows are voided. No further claim possible.
 *
 * Bonding curve (3-tier step function tied to softcap):
 *   Tier 1 — cumulative buy volume in [0, softcap_USD]:                 rate1 (default 1.0×)
 *   Tier 2 — cumulative buy volume in [softcap_USD, threshold2_USD]:    rate2 (default 0.7×)
 *   Tier 3 — cumulative buy volume above threshold2_USD:                rate3 (default 0.4×)
 *
 *   Where threshold2_USD = (softcap + (maxcap - softcap) × thresholdBps / BPS) × pricePerToken.
 *
 * Anti-farm design:
 * - Bonding curve is computed against `cumBuyVolumeUsd`, which only grows. Sellback does NOT
 *   reduce it, so a buy → sellback → buy loop earns less GROW with each iteration (the curve
 *   keeps stepping forward).
 * - Pre-softcap escrow + buyback void: a campaign that fails to reach softcap awards no GROW
 *   to anyone, even if intermediate buys happened.
 *
 * Excluded buyers:
 * - Addresses in `excludedFromMint` (e.g. GrowfiTreasury) bypass GROW emission entirely on
 *   their buys. Their volume does NOT advance the bonding curve either — they "donate"
 *   momentum without consuming the discount tiers, so real participants stay rewarded.
 *
 * INVARIANT: `growToken.minter == address(this)` MUST hold for emission to work. Set by
 * factory via `growToken.setMinter()` immediately after Minter deploy.
 */
contract GrowfiMinter is Initializable, IGrowfiMinter, ReentrancyGuard {
    enum CampaignStatus {
        NotRegistered,
        Pending,
        Active,
        Failed
    }

    struct CampaignState {
        CampaignStatus status;
        uint256 cumBuyVolumeUsd; // monotonic, USD-18-dec
        uint256 totalEscrowed; // sum of all GROW promised pre-softcap
        uint256 totalMinted; // sum of all GROW minted to wallets (claim + post-softcap mints)
    }

    struct BondingCurveParams {
        uint256 tier1RateBps; // ≤ BPS
        uint256 tier2RateBps; // ≤ BPS
        uint256 tier3RateBps; // ≤ BPS
        uint256 tier2to3ThresholdBps; // ≤ BPS — fraction of (maxcap - softcap) that ends tier 2
    }

    uint256 public constant BPS = 10_000;

    address public factory;
    GrowfiToken public growToken;

    BondingCurveParams public params;

    mapping(address => CampaignState) public campaignStates;
    mapping(address => mapping(address => uint256)) public escrows;
    mapping(address => bool) public excludedFromMint;

    error NotFactory();
    error NotCampaign();
    error AlreadyRegistered();
    error CampaignAlreadyFailed();
    error NotActive();
    error NoEscrow();
    error InvalidParams();
    error ZeroAddress();

    event CampaignRegistered(address indexed campaign);
    event GrowEscrowed(address indexed campaign, address indexed buyer, uint256 amount);
    event GrowMinted(address indexed campaign, address indexed buyer, uint256 amount);
    event SoftCapReached(address indexed campaign, uint256 totalEscrowed);
    event CampaignBuyback(address indexed campaign, uint256 voidedEscrow);
    event EscrowClaimed(address indexed campaign, address indexed user, uint256 amount);
    event BondingCurveUpdated(uint256 tier1RateBps, uint256 tier2RateBps, uint256 tier3RateBps, uint256 thresholdBps);
    event ExcludedFromMintUpdated(address indexed addr, bool excluded);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address factory_, address growToken_, BondingCurveParams memory initialParams)
        external
        initializer
    {
        if (factory_ == address(0) || growToken_ == address(0)) revert ZeroAddress();
        _validateParams(initialParams);

        factory = factory_;
        growToken = GrowfiToken(growToken_);
        params = initialParams;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyRegisteredCampaign() {
        if (campaignStates[msg.sender].status == CampaignStatus.NotRegistered) revert NotCampaign();
        _;
    }

    // ---------- factory admin ----------

    function registerCampaign(address campaign) external onlyFactory {
        if (campaign == address(0)) revert ZeroAddress();
        CampaignState storage cs = campaignStates[campaign];
        if (cs.status != CampaignStatus.NotRegistered) revert AlreadyRegistered();
        cs.status = CampaignStatus.Pending;
        emit CampaignRegistered(campaign);
    }

    function setBondingCurveParams(BondingCurveParams memory newParams) external onlyFactory {
        _validateParams(newParams);
        params = newParams;
        emit BondingCurveUpdated(
            newParams.tier1RateBps,
            newParams.tier2RateBps,
            newParams.tier3RateBps,
            newParams.tier2to3ThresholdBps
        );
    }

    function setExcludedFromMint(address addr, bool excluded) external onlyFactory {
        excludedFromMint[addr] = excluded;
        emit ExcludedFromMintUpdated(addr, excluded);
    }

    function _validateParams(BondingCurveParams memory p) internal pure {
        if (
            p.tier1RateBps > BPS || p.tier2RateBps > BPS || p.tier3RateBps > BPS
                || p.tier2to3ThresholdBps > BPS
        ) revert InvalidParams();
    }

    // ---------- hooks (called by GrowfiCampaign) ----------

    function recordBuy(address buyer, uint256 supplyBefore, uint256 supplyAfter)
        external
        nonReentrant
        onlyRegisteredCampaign
    {
        CampaignState storage cs = campaignStates[msg.sender];
        if (cs.status == CampaignStatus.Failed) revert CampaignAlreadyFailed();

        // Excluded buyers (e.g. Treasury) — neither earn GROW nor advance the curve.
        if (excludedFromMint[buyer]) return;

        if (supplyAfter <= supplyBefore) return; // dust safety

        IGrowfiCampaignView c = IGrowfiCampaignView(msg.sender);
        uint256 pricePerToken = c.pricePerToken();
        uint256 amountBought = supplyAfter - supplyBefore;
        uint256 usdValue = (amountBought * pricePerToken) / 1e18;
        if (usdValue == 0) return;

        uint256 growAmount =
            _computeGrowForBuy(cs.cumBuyVolumeUsd, usdValue, c.minCap(), c.maxCap(), pricePerToken);
        cs.cumBuyVolumeUsd += usdValue;

        if (growAmount == 0) return;

        if (cs.status == CampaignStatus.Pending) {
            escrows[msg.sender][buyer] += growAmount;
            cs.totalEscrowed += growAmount;
            emit GrowEscrowed(msg.sender, buyer, growAmount);
        } else {
            // Active
            cs.totalMinted += growAmount;
            growToken.mint(buyer, growAmount);
            emit GrowMinted(msg.sender, buyer, growAmount);
        }
    }

    function onSoftCapReached() external onlyRegisteredCampaign {
        CampaignState storage cs = campaignStates[msg.sender];
        if (cs.status == CampaignStatus.Pending) {
            cs.status = CampaignStatus.Active;
            emit SoftCapReached(msg.sender, cs.totalEscrowed);
        }
        // Idempotent: if already Active or Failed, silently no-op.
    }

    function onBuyback() external onlyRegisteredCampaign {
        CampaignState storage cs = campaignStates[msg.sender];
        if (cs.status == CampaignStatus.Pending) {
            cs.status = CampaignStatus.Failed;
            emit CampaignBuyback(msg.sender, cs.totalEscrowed);
        }
        // Idempotent. Active campaigns shouldn't reach buyback by protocol design;
        // if somehow they do, we silently keep them Active.
    }

    // ---------- escrow claim ----------

    function claimEscrow(address campaign) external nonReentrant returns (uint256 amount) {
        CampaignState storage cs = campaignStates[campaign];
        if (cs.status != CampaignStatus.Active) revert NotActive();

        amount = escrows[campaign][msg.sender];
        if (amount == 0) revert NoEscrow();

        escrows[campaign][msg.sender] = 0;
        cs.totalMinted += amount;

        growToken.mint(msg.sender, amount);
        emit EscrowClaimed(campaign, msg.sender, amount);
    }

    // ---------- bonding curve math ----------

    function _computeGrowForBuy(
        uint256 vBefore,
        uint256 usdValue,
        uint256 minCap_,
        uint256 maxCap_,
        uint256 pricePerToken_
    ) internal view returns (uint256 totalGrow) {
        uint256 vAfter = vBefore + usdValue;

        // USD-18-dec thresholds. T1 = softcap value. T2 = T1 + thresholdFraction × (maxcap - softcap) × price.
        uint256 t1 = (minCap_ * pricePerToken_) / 1e18;
        uint256 t2 = t1;
        if (maxCap_ > minCap_) {
            uint256 deltaCap = maxCap_ - minCap_;
            uint256 tierDelta = (deltaCap * params.tier2to3ThresholdBps) / BPS;
            t2 += (tierDelta * pricePerToken_) / 1e18;
        }

        BondingCurveParams memory p = params;

        // Tier 1: [0, t1]
        if (vBefore < t1) {
            uint256 cap = vAfter < t1 ? vAfter : t1;
            totalGrow += ((cap - vBefore) * p.tier1RateBps) / BPS;
        }

        // Tier 2: [t1, t2]
        uint256 t2Start = vBefore < t1 ? t1 : vBefore;
        if (t2Start < t2) {
            uint256 cap = vAfter < t2 ? vAfter : t2;
            if (cap > t2Start) {
                totalGrow += ((cap - t2Start) * p.tier2RateBps) / BPS;
            }
        }

        // Tier 3: [t2, ∞)
        uint256 t3Start = vBefore < t2 ? t2 : vBefore;
        if (t3Start < vAfter) {
            totalGrow += ((vAfter - t3Start) * p.tier3RateBps) / BPS;
        }
    }

    // ---------- views ----------

    function getCampaignState(address campaign)
        external
        view
        returns (CampaignStatus status, uint256 cumBuyVolumeUsd, uint256 totalEscrowed, uint256 totalMinted)
    {
        CampaignState memory cs = campaignStates[campaign];
        return (cs.status, cs.cumBuyVolumeUsd, cs.totalEscrowed, cs.totalMinted);
    }

    function getEscrow(address campaign, address user) external view returns (uint256) {
        return escrows[campaign][user];
    }

    function previewGrowForBuy(address campaign, uint256 supplyBefore, uint256 supplyAfter)
        external
        view
        returns (uint256)
    {
        CampaignState storage cs = campaignStates[campaign];
        if (cs.status == CampaignStatus.NotRegistered || cs.status == CampaignStatus.Failed) {
            return 0;
        }
        if (supplyAfter <= supplyBefore) return 0;

        IGrowfiCampaignView c = IGrowfiCampaignView(campaign);
        uint256 pricePerToken = c.pricePerToken();
        uint256 amountBought = supplyAfter - supplyBefore;
        uint256 usdValue = (amountBought * pricePerToken) / 1e18;
        return _computeGrowForBuy(cs.cumBuyVolumeUsd, usdValue, c.minCap(), c.maxCap(), pricePerToken);
    }
}
