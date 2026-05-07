// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {GrowfiToken} from "./GrowfiToken.sol";
import {IGrowfiTreasury} from "./interfaces/IGrowfiTreasury.sol";
import {IGrowfiCampaignView} from "./interfaces/IGrowfiCampaignView.sol";
import {IGrowfiCampaignFactoryView} from "./interfaces/IGrowfiCampaignFactoryView.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

interface IGrowfiCampaignBuyback {
    function buyback(address paymentToken) external;
}
import {IGrowfiStakingVaultMin} from "./interfaces/IGrowfiStakingVaultMin.sol";
import {IGrowfiHarvestManagerMin} from "./interfaces/IGrowfiHarvestManagerMin.sol";
import {IGrowfiStakingPool} from "./interfaces/IGrowfiStakingPool.sol";

/**
 * GrowfiTreasury — protocol-owned reserve backing the GROW token.
 *
 * Holds:
 * - Multiple accepted stablecoins (USDC, USDT, DAI, …) — multisig-controlled allowlist.
 * - CampaignTokens of campaigns the protocol has invested in.
 * - GROW that the treasury itself holds (excluded from circulating in floor calc).
 *
 * Provides:
 * - `intrinsicFloorPrice()` — sum of all stablecoin holdings (1:1 USD-peg assumption) plus
 *   CampaignTokens at pricePerToken, divided by circulating GROW.
 * - `redeem()` — holders burn GROW for pro-rata share of all stablecoins + all CampaignTokens.
 * - `allocateToCampaign()` — multisig spends a chosen stablecoin to buy CampaignTokens.
 * - `rescueToken()` — multisig recovery for ERC20s outside the allowlist; accepted
 *   stablecoins, GROW, and tracked CampaignTokens are protected.
 *
 * 1:1 PEG ASSUMPTION (v1):
 * - Each accepted stablecoin is treated as $1 = 1 unit at its native decimals (scaled up to
 *   USD-18-dec via `stablecoinScale`). If a stablecoin de-pegs, the multisig can remove it
 *   from the allowlist (circuit breaker). Future v2 may add Chainlink price feeds per token.
 */
contract GrowfiTreasury is Initializable, ReentrancyGuard, IGrowfiTreasury {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant BPS = 10_000;

    address public factory;
    GrowfiToken public growToken;

    /// @notice Canonical USDC used by the harvest payout path. Snapshotted from
    ///         `factory.usdc()` at init. Independent of the dynamic accepted-stablecoins
    ///         allowlist (which is for direct buys + floor calc): even if the multisig
    ///         revokes USDC from the allowlist (depeg circuit breaker), `claimUsdcAndDistribute`
    ///         still works because campaigns always pay harvest in this canonical token.
    IERC20 public canonicalUsdc;

    /// @notice Where 80% of harvest USDC is forwarded after `claimUsdcAndDistribute`.
    address public stakingPool;
    /// @notice Fraction (in BPS) of harvest USDC routed to stakers; remainder retained for compounding.
    uint256 public stakerRewardBps; // default 8_000 = 80%

    /// @notice Master switch for the multisig-triggered cross-tracked allocation. Default OFF.
    ///         When true, `allocateAcrossTracked` is callable by the factory; when false the
    ///         function reverts (kill switch). Manual `allocateToCampaign` always works.
    bool public automationEnabled;

    EnumerableSet.AddressSet private _acceptedStablecoins;
    EnumerableSet.AddressSet private _trackedCampaigns;

    /// @notice Per-stablecoin pricing config. Each accepted stablecoin MUST have a Chainlink
    ///         USD price feed wired at allowlist time so the floor calc + direct-buy path
    ///         protect against depeg events instead of trusting a 1:1 peg.
    /// @dev    `scale = 10^(18 - decimals)` converts raw token amount to 18-dec.
    ///         `priceFeed` returns `answer` in `feed.decimals()`-dec USD.
    ///         `heartbeat` is the maximum age of `updatedAt` we accept (e.g. 24h for USDC/USD).
    ///         `minPriceBps`/`maxPriceBps` define the depeg trip wire as bps of $1
    ///         (e.g. 9500/10500 = $0.95-$1.05). Outside the band → treated as depegged.
    struct StablecoinConfig {
        uint256 scale;
        address priceFeed;
        uint64 heartbeat;
        uint16 minPriceBps;
        uint16 maxPriceBps;
    }

    mapping(address => StablecoinConfig) public stablecoinConfigs;

    /// @notice Backward-compat shim — keeps `IGrowfiTreasury.stablecoinScale` working.
    function stablecoinScale(address token) external view returns (uint256) {
        return stablecoinConfigs[token].scale;
    }

    error NotFactory();
    error AlreadyTracked();
    error NotTracked();
    error AlreadyAccepted();
    error NotAccepted();
    error CannotRescueAcceptedStablecoin();
    error CannotRescueGrow();
    error CannotRescueCampaignToken();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidScale();
    error InvalidBps();
    error InvalidHeartbeat();
    error InvalidPriceBands();
    error StablecoinDepegged(address token);
    error InsufficientBalance();
    error AllocationFailed();
    error NoCirculatingSupply();
    error CampaignNotActive();
    error CampaignFull();
    error StakingPoolNotSet();
    error CanonicalUsdcNotSet();
    error AutomationDisabled();
    error NoActiveTrackedCampaigns();

    event StablecoinAccepted(
        address indexed token,
        uint256 scale,
        address priceFeed,
        uint64 heartbeat,
        uint16 minPriceBps,
        uint16 maxPriceBps
    );
    event StablecoinRevoked(address indexed token);
    event StablecoinExcludedFromFloor(address indexed token);
    event CampaignSkippedInFloor(address indexed campaign, uint8 state);
    event CampaignTracked(address indexed campaign);
    event CampaignUntracked(address indexed campaign);
    event Allocated(address indexed campaign, address indexed paymentToken, uint256 amount, uint256 campaignTokensReceived);
    event AcrossTrackedAllocated(address indexed paymentToken, uint256 totalAmount, uint256 perCampaign, uint256 campaignsReceived);
    event AutomationEnabledSet(bool enabled);
    event Redeemed(address indexed redeemer, uint256 growBurned);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event GrowReleased(address indexed to, uint256 amount);
    event StakingPoolUpdated(address indexed previous, address indexed current);
    event StakerRewardBpsUpdated(uint256 previous, uint256 current);
    event Staked(address indexed campaign, uint256 amount, uint256 positionId);
    event YieldClaimed(address indexed campaign, uint256 positionId);
    event UsdcRedeemCommitted(address indexed campaign, uint256 indexed seasonId, uint256 yieldAmount);
    event UsdcClaimed(address indexed campaign, uint256 indexed seasonId, uint256 received, uint256 toStakers, uint256 retained);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address factory_, address growToken_) external initializer {
        if (factory_ == address(0) || growToken_ == address(0)) revert ZeroAddress();
        factory = factory_;
        growToken = GrowfiToken(growToken_);

        // Snapshot the canonical USDC from the factory for the harvest payout path.
        // Guarded by a code-size check + try/catch so unit tests using a placeholder factory
        // address (EOA without code) still initialize cleanly. In production, the real factory
        // exposes `usdc()` so this always populates. If it doesn't, `claimUsdcAndDistribute`
        // reverts with CanonicalUsdcNotSet at call time.
        if (factory_.code.length > 0) {
            try IGrowfiCampaignFactoryView(factory_).usdc() returns (address u) {
                if (u != address(0)) canonicalUsdc = IERC20(u);
            } catch {}
        }

        // Sensible defaults; multisig can adjust later.
        stakerRewardBps = 8_000; // 80% to stakers, 20% retained
        // automationEnabled stays false by default — multisig must explicitly enable.
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    // ---------- accepted stablecoins (factory admin) ----------

    /// @notice Add a stablecoin to the allowlist with its Chainlink USD feed and depeg bands.
    /// @param token        ERC20 stablecoin address.
    /// @param scale        `10^(18 - decimals)` to convert raw → USD-18-dec.
    /// @param priceFeed    Chainlink AggregatorV3 USD feed for `token` (e.g. USDC/USD on Base).
    /// @param heartbeat    Maximum staleness for the feed's `updatedAt` (seconds).
    /// @param minPriceBps  Lower bound of the accepted price as bps of $1 (e.g. 9500 = $0.95).
    /// @param maxPriceBps  Upper bound (e.g. 10500 = $1.05). Must satisfy 0 < min ≤ max ≤ 20_000.
    function addAcceptedStablecoin(
        address token,
        uint256 scale,
        address priceFeed,
        uint64 heartbeat,
        uint16 minPriceBps,
        uint16 maxPriceBps
    ) external onlyFactory {
        if (token == address(0) || priceFeed == address(0)) revert ZeroAddress();
        if (scale == 0) revert InvalidScale();
        if (heartbeat == 0) revert InvalidHeartbeat();
        if (minPriceBps == 0 || maxPriceBps < minPriceBps || maxPriceBps > 20_000) {
            revert InvalidPriceBands();
        }
        if (!_acceptedStablecoins.add(token)) revert AlreadyAccepted();
        stablecoinConfigs[token] = StablecoinConfig({
            scale: scale,
            priceFeed: priceFeed,
            heartbeat: heartbeat,
            minPriceBps: minPriceBps,
            maxPriceBps: maxPriceBps
        });
        emit StablecoinAccepted(token, scale, priceFeed, heartbeat, minPriceBps, maxPriceBps);
    }

    function removeAcceptedStablecoin(address token) external onlyFactory {
        if (!_acceptedStablecoins.remove(token)) revert NotAccepted();
        delete stablecoinConfigs[token];
        emit StablecoinRevoked(token);
    }

    // ---------- price feed read ----------

    /// @dev Read & validate a stablecoin's live Chainlink USD price. Returns `(0, false)` on
    ///      stale, negative, malformed or out-of-band readings — caller decides what to do
    ///      with that signal (exclude from floor, revert direct buy, etc.).
    function _readStablecoinPrice(StablecoinConfig memory cfg)
        internal
        view
        returns (uint256 priceUsd18, bool ok)
    {
        if (cfg.priceFeed == address(0)) return (0, false);

        try AggregatorV3Interface(cfg.priceFeed).latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (answer <= 0) return (0, false);
            if (startedAt == 0) return (0, false);
            if (answeredInRound < roundId) return (0, false);
            if (updatedAt == 0) return (0, false);
            if (block.timestamp > updatedAt && block.timestamp - updatedAt > cfg.heartbeat) {
                return (0, false);
            }

            uint8 fdec;
            try AggregatorV3Interface(cfg.priceFeed).decimals() returns (uint8 d) {
                if (d > 18) return (0, false);
                fdec = d;
            } catch {
                return (0, false);
            }

            uint256 normalized = uint256(answer) * 10 ** (18 - fdec);

            uint256 minPrice = (1e18 * uint256(cfg.minPriceBps)) / BPS;
            uint256 maxPrice = (1e18 * uint256(cfg.maxPriceBps)) / BPS;
            if (normalized < minPrice || normalized > maxPrice) return (0, false);

            return (normalized, true);
        } catch {
            return (0, false);
        }
    }

    /// @notice Live USD price of an accepted stablecoin in 1e18 fixed-point. Reverts on
    ///         depeg / stale / borked feeds — used as the hard guard on `GrowfiToken.buy`.
    function getStablecoinPriceUsd18(address token) external view returns (uint256) {
        if (!_acceptedStablecoins.contains(token)) revert NotAccepted();
        (uint256 price, bool ok) = _readStablecoinPrice(stablecoinConfigs[token]);
        if (!ok) revert StablecoinDepegged(token);
        return price;
    }

    function isAcceptedStablecoin(address token) external view returns (bool) {
        return _acceptedStablecoins.contains(token);
    }

    function acceptedStablecoinsLength() external view returns (uint256) {
        return _acceptedStablecoins.length();
    }

    function acceptedStablecoinAt(uint256 i) external view returns (address) {
        return _acceptedStablecoins.at(i);
    }

    // ---------- tracked campaigns (factory admin) ----------

    function addTrackedCampaign(address campaign) external onlyFactory {
        if (campaign == address(0)) revert ZeroAddress();
        if (!_trackedCampaigns.add(campaign)) revert AlreadyTracked();
        emit CampaignTracked(campaign);
    }

    function removeTrackedCampaign(address campaign) external onlyFactory {
        if (!_trackedCampaigns.remove(campaign)) revert NotTracked();
        emit CampaignUntracked(campaign);
    }

    function isTrackedCampaign(address c) public view returns (bool) {
        return _trackedCampaigns.contains(c);
    }

    function trackedCampaignsLength() external view returns (uint256) {
        return _trackedCampaigns.length();
    }

    function trackedCampaignAt(uint256 i) external view returns (address) {
        return _trackedCampaigns.at(i);
    }

    // ---------- staking pool + auto-alloc config (factory admin) ----------

    function setStakingPool(address newPool) external onlyFactory {
        if (newPool == address(0)) revert ZeroAddress();
        emit StakingPoolUpdated(stakingPool, newPool);
        stakingPool = newPool;
    }

    function setStakerRewardBps(uint256 newBps) external onlyFactory {
        if (newBps > BPS) revert InvalidBps();
        emit StakerRewardBpsUpdated(stakerRewardBps, newBps);
        stakerRewardBps = newBps;
    }

    function setAutomationEnabled(bool enabled) external onlyFactory {
        automationEnabled = enabled;
        emit AutomationEnabledSet(enabled);
    }

    // ---------- intrinsic floor price ----------

    /// @notice Σ(stablecoin × scale × livePriceUsd / 1e18) + Σ(CampaignToken × pricePerToken),
    ///         divided by circulating GROW. Returns USD-18-dec per circulating GROW.
    /// @dev Two safety properties:
    ///      • Stablecoins: live Chainlink USD price applied. If a feed is stale, depegged,
    ///        or malformed, that stablecoin is silently excluded from the backing valuation
    ///        (conservative: floor goes DOWN, not up — protects against "fake $1" inflation).
    ///      • CampaignTokens: only count if the owning campaign is in Active state.
    ///        Buyback / Funding / Ended → excluded. Buyback CTs are recovered separately
    ///        via `buybackFromCampaign`; Ended/Funding shouldn't normally hold Treasury CT.
    function intrinsicFloorPrice() external view returns (uint256) {
        uint256 totalValue = 0;

        uint256 nStable = _acceptedStablecoins.length();
        for (uint256 i; i < nStable; ++i) {
            address tk = _acceptedStablecoins.at(i);
            uint256 bal = IERC20(tk).balanceOf(address(this));
            if (bal == 0) continue;
            StablecoinConfig memory cfg = stablecoinConfigs[tk];
            (uint256 priceUsd18, bool ok) = _readStablecoinPrice(cfg);
            if (!ok) continue; // depegged / stale → excluded (conservative)
            totalValue += (bal * cfg.scale * priceUsd18) / 1e18;
        }

        uint256 nCampaigns = _trackedCampaigns.length();
        for (uint256 i; i < nCampaigns; ++i) {
            IGrowfiCampaignView c = IGrowfiCampaignView(_trackedCampaigns.at(i));

            uint8 cState;
            try c.state() returns (uint8 s) {
                cState = s;
            } catch {
                continue;
            }
            if (cState != 1) continue; // 1 = Active. Funding/Buyback/Ended → excluded.

            uint256 bal = IERC20(c.campaignToken()).balanceOf(address(this));
            if (bal == 0) continue;

            try c.pricePerToken() returns (uint256 price) {
                totalValue += (bal * price) / 1e18;
            } catch {
                continue;
            }
        }

        if (totalValue == 0) return 0;

        uint256 totalSupply_ = growToken.totalSupply();
        uint256 treasuryGrow = growToken.balanceOf(address(this));
        if (totalSupply_ <= treasuryGrow) return 0;
        uint256 circulating = totalSupply_ - treasuryGrow;

        return (totalValue * 1e18) / circulating;
    }

    // ---------- allocation (factory admin) ----------

    function allocateToCampaign(address campaign, address paymentToken, uint256 amount)
        external
        onlyFactory
        nonReentrant
    {
        if (!_trackedCampaigns.contains(campaign)) revert NotTracked();
        if (!_acceptedStablecoins.contains(paymentToken)) revert NotAccepted();
        if (amount == 0) revert ZeroAmount();
        if (IERC20(paymentToken).balanceOf(address(this)) < amount) revert InsufficientBalance();

        IERC20 ct = IERC20(IGrowfiCampaignView(campaign).campaignToken());
        uint256 balBefore = ct.balanceOf(address(this));

        IERC20(paymentToken).forceApprove(campaign, amount);
        IGrowfiCampaignView(campaign).buy(paymentToken, amount);

        uint256 received = ct.balanceOf(address(this)) - balBefore;
        if (received == 0) revert AllocationFailed();

        emit Allocated(campaign, paymentToken, amount, received);
    }

    // ---------- multisig-triggered cross-tracked allocation ----------

    /// @notice Spread `totalAmount` of `paymentToken` equally across all tracked Active campaigns.
    /// @dev Callable by:
    ///      - `factory` — multisig manual trigger (the canonical admin path)
    ///      - `growToken` — auto-fired from `GrowfiToken.buy` when automation is on, so the
    ///        USDC just paid by a direct buyer immediately spreads to tracked campaigns
    ///        instead of sitting in the Treasury awaiting a manual call.
    ///      Both gated by `automationEnabled`. Caller specifies the total budget; the function
    ///      counts qualifying campaigns and divides equally. Per-campaign share is capped by
    ///      remaining mintable room. Dust (totalAmount % activeCount) stays in Treasury.
    function allocateAcrossTracked(address paymentToken, uint256 totalAmount)
        external
        nonReentrant
    {
        if (msg.sender != factory && msg.sender != address(growToken)) revert NotFactory();
        if (!automationEnabled) revert AutomationDisabled();
        if (!_acceptedStablecoins.contains(paymentToken)) revert NotAccepted();
        if (totalAmount == 0) revert ZeroAmount();
        if (IERC20(paymentToken).balanceOf(address(this)) < totalAmount) revert InsufficientBalance();

        // First pass: count Active campaigns with remaining mintable room.
        uint256 n = _trackedCampaigns.length();
        uint256 activeCount = 0;
        for (uint256 i; i < n; ++i) {
            IGrowfiCampaignView c = IGrowfiCampaignView(_trackedCampaigns.at(i));
            if (c.state() == 1 && c.currentSupply() < c.maxCap()) activeCount++;
        }
        if (activeCount == 0) revert NoActiveTrackedCampaigns();

        uint256 perCampaign = totalAmount / activeCount;
        if (perCampaign == 0) revert ZeroAmount();

        uint256 scale = stablecoinConfigs[paymentToken].scale;

        // Second pass: allocate. Wrap the per-campaign buy in try/catch so a single bad
        // campaign (paused, upgraded weirdly, etc.) doesn't DOS the whole batch.
        uint256 actuallyAllocated = 0;
        uint256 successCount = 0;
        for (uint256 i; i < n; ++i) {
            address camp = _trackedCampaigns.at(i);
            IGrowfiCampaignView c = IGrowfiCampaignView(camp);
            if (c.state() != 1) continue;

            uint256 currentSupply_ = c.currentSupply();
            uint256 maxCap_ = c.maxCap();
            if (currentSupply_ >= maxCap_) continue;

            // Cap by remaining mintable USD value of this campaign.
            uint256 remainingUsd18 = ((maxCap_ - currentSupply_) * c.pricePerToken()) / 1e18;
            uint256 remainingInToken = remainingUsd18 / scale;
            uint256 amount = perCampaign < remainingInToken ? perCampaign : remainingInToken;
            if (amount == 0) continue;

            IERC20 ct = IERC20(c.campaignToken());
            uint256 balBefore = ct.balanceOf(address(this));

            IERC20(paymentToken).forceApprove(camp, amount);
            try c.buy(paymentToken, amount) {
                uint256 received = ct.balanceOf(address(this)) - balBefore;
                if (received > 0) {
                    actuallyAllocated += amount;
                    successCount++;
                    emit Allocated(camp, paymentToken, amount, received);
                }
            } catch {
                // Reset approval to 0 to avoid stale allowance after revert
                IERC20(paymentToken).forceApprove(camp, 0);
                // Continue to next campaign
            }
        }

        emit AcrossTrackedAllocated(paymentToken, actuallyAllocated, perCampaign, successCount);
    }

    // ---------- harvest claim flow (factory admin) ----------

    /// @notice Stake the Treasury's CampaignTokens of `campaign` into its StakingVault.
    function stakeOnCampaign(address campaign, uint256 amount) external onlyFactory nonReentrant returns (uint256 positionId) {
        if (!_trackedCampaigns.contains(campaign)) revert NotTracked();
        if (amount == 0) revert ZeroAmount();

        IGrowfiCampaignView c = IGrowfiCampaignView(campaign);
        IERC20 ct = IERC20(c.campaignToken());
        if (ct.balanceOf(address(this)) < amount) revert InsufficientBalance();

        address vault = c.stakingVault();
        ct.forceApprove(vault, amount);
        positionId = IGrowfiStakingVaultMin(vault).stake(amount);

        emit Staked(campaign, amount, positionId);
    }

    /// @notice Claim accrued YIELD tokens for a Treasury position.
    function claimYieldFromCampaign(address campaign, uint256 positionId) external onlyFactory nonReentrant {
        if (!_trackedCampaigns.contains(campaign)) revert NotTracked();
        IGrowfiStakingVaultMin(IGrowfiCampaignView(campaign).stakingVault()).claimYield(positionId);
        emit YieldClaimed(campaign, positionId);
    }

    /// @notice Burn the Treasury's YIELD for a season and register the USDC commit.
    function commitUsdcRedeem(address campaign, uint256 seasonId, uint256 yieldAmount)
        external
        onlyFactory
        nonReentrant
    {
        if (!_trackedCampaigns.contains(campaign)) revert NotTracked();
        if (yieldAmount == 0) revert ZeroAmount();

        IGrowfiCampaignView c = IGrowfiCampaignView(campaign);
        address vault = c.stakingVault();
        address yt = IGrowfiStakingVaultMin(vault).yieldToken();
        address hm = c.harvestManager();

        IERC20(yt).forceApprove(hm, yieldAmount);
        IGrowfiHarvestManagerMin(hm).redeemUSDC(seasonId, yieldAmount);
        emit UsdcRedeemCommitted(campaign, seasonId, yieldAmount);
    }

    /// @notice Pull USDC from the campaign's HarvestManager and split per `stakerRewardBps`:
    ///         that fraction goes to the StakingPool, the rest is retained for compounding.
    /// @dev Permissionless — anyone can trigger to push yield through the system.
    ///      Uses `canonicalUsdc` (factory.usdc()) so it works even if the multisig has
    ///      revoked USDC from the dynamic allowlist (depeg circuit breaker).
    function claimUsdcAndDistribute(address campaign, uint256 seasonId) external nonReentrant {
        if (!_trackedCampaigns.contains(campaign)) revert NotTracked();

        IGrowfiCampaignView c = IGrowfiCampaignView(campaign);
        address hm = c.harvestManager();

        IERC20 usdc = canonicalUsdc;
        if (address(usdc) == address(0)) revert CanonicalUsdcNotSet();

        uint256 balBefore = usdc.balanceOf(address(this));
        IGrowfiHarvestManagerMin(hm).claimUSDC(seasonId);
        uint256 received = usdc.balanceOf(address(this)) - balBefore;

        uint256 toStakers = 0;
        uint256 retained = received;
        if (received > 0 && stakingPool != address(0) && stakerRewardBps > 0) {
            toStakers = (received * stakerRewardBps) / BPS;
            retained = received - toStakers;
            if (toStakers > 0) {
                usdc.safeTransfer(stakingPool, toStakers);
                IGrowfiStakingPool(stakingPool).notifyReward(toStakers);
            }
        }
        emit UsdcClaimed(campaign, seasonId, received, toStakers, retained);
    }

    /// @notice Recover USDC from a tracked campaign that entered Buyback (failed). Treasury
    ///         calls `Campaign.buyback(paymentToken)` which burns its CampaignTokens and
    ///         refunds the original NET payment in `paymentToken`.
    /// @dev Multisig-driven. Called once per (campaign, paymentToken) the Treasury holds.
    function buybackFromCampaign(address campaign, address paymentToken) external onlyFactory nonReentrant {
        if (!_trackedCampaigns.contains(campaign)) revert NotTracked();
        // Forward to the campaign's buyback path. Reverts if not in Buyback state or no refund owed.
        IGrowfiCampaignBuyback(campaign).buyback(paymentToken);
    }

    // ---------- redeem ----------

    /// @notice Burn GROW for a pro-rata basket of all treasury holdings.
    function redeem(uint256 growAmount) external nonReentrant {
        if (growAmount == 0) revert ZeroAmount();

        uint256 totalSupply_ = growToken.totalSupply();
        uint256 treasuryGrow = growToken.balanceOf(address(this));
        if (totalSupply_ <= treasuryGrow) revert NoCirculatingSupply();
        uint256 circulating = totalSupply_ - treasuryGrow;

        IERC20(address(growToken)).safeTransferFrom(msg.sender, address(this), growAmount);
        growToken.burn(growAmount);

        // Stablecoin pro-rata
        uint256 nStable = _acceptedStablecoins.length();
        for (uint256 i; i < nStable; ++i) {
            IERC20 tk = IERC20(_acceptedStablecoins.at(i));
            uint256 bal = tk.balanceOf(address(this));
            if (bal > 0) {
                uint256 out = (bal * growAmount) / circulating;
                if (out > 0) {
                    tk.safeTransfer(msg.sender, out);
                }
            }
        }

        // CampaignToken pro-rata
        uint256 nCampaigns = _trackedCampaigns.length();
        for (uint256 i; i < nCampaigns; ++i) {
            IERC20 ct = IERC20(IGrowfiCampaignView(_trackedCampaigns.at(i)).campaignToken());
            uint256 ctBal = ct.balanceOf(address(this));
            if (ctBal > 0) {
                uint256 ctOut = (ctBal * growAmount) / circulating;
                if (ctOut > 0) {
                    ct.safeTransfer(msg.sender, ctOut);
                }
            }
        }

        emit Redeemed(msg.sender, growAmount);
    }

    // ---------- rescue ----------

    // ---------- treasury-held GROW reserve release ----------

    /// @notice Send out part of the Treasury's GROW reserve. Use case: the team / DAO
    ///         reserve was minted to the Treasury at deploy via `Token.mintTreasuryGenesis`,
    ///         and is excluded from the floor's circulating divisor while it sits here.
    ///         Each release moves tokens INTO circulating (and dilutes the floor accordingly).
    /// @dev Multisig only. Reverts on zero recipient or zero amount. The Treasury's GROW
    ///      balance is not touched by `redeem` (those tokens are burned), and not rescuable
    ///      via `rescueToken` either — `releaseGrow` is the only path out.
    function releaseGrow(address to, uint256 amount) external onlyFactory {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(address(growToken)).safeTransfer(to, amount);
        emit GrowReleased(to, amount);
    }

    /// @notice Multisig recovers ERC20s mistakenly or maliciously sent to the treasury.
    /// @dev Cannot drain accepted stablecoins, GROW, or any tracked CampaignToken.
    function rescueToken(IERC20 token, address to, uint256 amount) external onlyFactory {
        address tk = address(token);
        if (_acceptedStablecoins.contains(tk)) revert CannotRescueAcceptedStablecoin();
        if (tk == address(growToken)) revert CannotRescueGrow();
        uint256 n = _trackedCampaigns.length();
        for (uint256 i; i < n; ++i) {
            if (IGrowfiCampaignView(_trackedCampaigns.at(i)).campaignToken() == tk) {
                revert CannotRescueCampaignToken();
            }
        }
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit TokenRescued(tk, to, amount);
    }
}
