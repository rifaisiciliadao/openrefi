// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGrowfiTreasury} from "./interfaces/IGrowfiTreasury.sol";

/**
 * GrowfiToken — protocol-wide utility token (GROW).
 *
 * Three things live here:
 * 1. Standard ERC20 + burnable (so anyone can burn their own GROW).
 * 2. Bonding-curve mint via `GrowfiMinter` (free emission to participants of any campaign).
 * 3. Direct primary sale: any allowlisted stablecoin → GROW at floor × (1 + markup).
 *
 * Multi-stablecoin direct sale:
 * - The buyer chooses which stablecoin to pay in (USDC, USDT, DAI, …) at call time.
 * - Treasury holds the multisig-controlled allowlist + decimal scale per token.
 * - Stablecoins are assumed 1:1 USD-pegged in v1; the multisig is responsible for monitoring
 *   de-pegs and removing problematic tokens via `Treasury.removeAcceptedStablecoin`.
 *
 * Pricing of the direct sale:
 * - Reads `treasury.intrinsicFloorPrice()` (sum of all stablecoin holdings + CampaignTokens
 *   ÷ circulating GROW). If that's 0 (deploy-time / drained), falls back to `referencePrice`,
 *   a cached value seeded at deploy and refreshed on every successful buy.
 * - `salePrice = referenceUsd × (BPS + markupBps) / BPS`.
 * - Buyer passes `maxPriceAccepted` for slippage protection.
 *
 * Trust model:
 * - `factory` admin: rotates `minter` and `treasury`, toggles sale, sets markup, seeds
 *   `referencePrice`. Driven by the factory owner (multisig) via factory forwarding.
 * - `minter` (GrowfiMinter): the only non-`buy` mint path. Holds bonding-curve + escrow logic.
 *
 * Genesis: a single `_mint` at `initialize()` time, recipient set by deploy script.
 */
contract GrowfiToken is Initializable, ERC20Upgradeable, ERC20BurnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_MARKUP_BPS = 5_000;

    address public factory;
    address public minter;
    address public treasury;

    bool public saleActive;
    uint256 public markupBps;
    uint256 public referencePrice;

    /// @notice One-shot guard for `mintTreasuryGenesis`. Once true, no further treasury
    ///         genesis mint is possible — the team's reserve allocation is finalized.
    bool public treasuryGenesisMinted;

    error NotFactory();
    error NotMinter();
    error ZeroAddress();
    error ZeroAmount();
    error SaleNotActive();
    error NoFloorAvailable();
    error PriceExceedsMax();
    error InvalidMarkup();
    error TreasuryNotSet();
    error PaymentTokenNotAccepted();
    error TreasuryGenesisAlreadyMinted();

    event MinterUpdated(address indexed previous, address indexed current);
    event TreasuryUpdated(address indexed previous, address indexed current);
    event SaleActiveSet(bool active);
    event MarkupSet(uint256 markupBps);
    event ReferencePriceSet(uint256 oldPrice, uint256 newPrice);
    event GenesisMinted(address indexed recipient, uint256 amount);
    event TreasuryGenesisMinted(address indexed treasury, uint256 amount);
    event DirectBuy(
        address indexed buyer,
        address indexed paymentToken,
        uint256 paymentAmount,
        uint256 growOut,
        uint256 effectivePrice
    );
    /// @notice Emitted after every direct buy with the outcome of the auto-allocation hook.
    /// @dev `success=false` means the Treasury didn't spread the freshly received USDC into
    ///      tracked campaigns — usually because automation is off, no campaigns are tracked
    ///      and Active, or per-campaign share rounded to zero. The buy itself succeeded.
    event AutoAllocAttempted(address indexed paymentToken, uint256 amount, bool success);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address factory_,
        address genesisRecipient,
        uint256 genesisAmount,
        uint256 initialMarkupBps,
        uint256 initialReferencePrice
    ) external initializer {
        if (factory_ == address(0)) revert ZeroAddress();
        if (initialMarkupBps > MAX_MARKUP_BPS) revert InvalidMarkup();

        __ERC20_init(name_, symbol_);
        __ERC20Burnable_init();

        factory = factory_;
        markupBps = initialMarkupBps;
        referencePrice = initialReferencePrice;
        saleActive = true;

        if (genesisAmount > 0) {
            if (genesisRecipient == address(0)) revert ZeroAddress();
            _mint(genesisRecipient, genesisAmount);
            emit GenesisMinted(genesisRecipient, genesisAmount);
        }
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    // ---------- factory admin ----------

    function setMinter(address newMinter) external onlyFactory {
        if (newMinter == address(0)) revert ZeroAddress();
        emit MinterUpdated(minter, newMinter);
        minter = newMinter;
    }

    function setTreasury(address newTreasury) external onlyFactory {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setSaleActive(bool active) external onlyFactory {
        saleActive = active;
        emit SaleActiveSet(active);
    }

    function setMarkup(uint256 newMarkupBps) external onlyFactory {
        if (newMarkupBps > MAX_MARKUP_BPS) revert InvalidMarkup();
        markupBps = newMarkupBps;
        emit MarkupSet(newMarkupBps);
    }

    function setReferencePrice(uint256 newPrice) external onlyFactory {
        emit ReferencePriceSet(referencePrice, newPrice);
        referencePrice = newPrice;
    }

    /// @notice One-shot mint of a "team / DAO reserve" allocation directly into the Treasury.
    /// @dev    The Treasury holds these tokens in `growToken.balanceOf(address(treasury))`,
    ///         which the floor calculation EXCLUDES from `circulating`. So this mint does NOT
    ///         dilute the floor: the supply stays out of the divisor until the multisig releases
    ///         it via `Treasury.releaseGrow`. Designed to replace the legacy 1M-to-deployer
    ///         genesis with a transparent, on-chain-locked reserve.
    function mintTreasuryGenesis(uint256 amount) external onlyFactory {
        if (treasuryGenesisMinted) revert TreasuryGenesisAlreadyMinted();
        if (treasury == address(0)) revert TreasuryNotSet();
        if (amount == 0) revert ZeroAmount();
        treasuryGenesisMinted = true;
        _mint(treasury, amount);
        emit TreasuryGenesisMinted(treasury, amount);
    }

    // ---------- minter (bonding curve emission) ----------

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    // ---------- primary sale ----------

    /// @notice The reference price (USD-18-dec per GROW) used as base for sales.
    /// Floor if available, else cached fallback.
    function effectiveReferencePrice() public view returns (uint256) {
        if (treasury != address(0)) {
            uint256 floor = IGrowfiTreasury(treasury).intrinsicFloorPrice();
            if (floor > 0) return floor;
        }
        return referencePrice;
    }

    /// @notice The sale price (USD-18-dec per GROW) at which `buy` executes right now.
    /// @dev Reverts if no reference is available.
    function currentSalePrice() external view returns (uint256) {
        uint256 refPrice = effectiveReferencePrice();
        if (refPrice == 0) revert NoFloorAvailable();
        return (refPrice * (BPS + markupBps)) / BPS;
    }

    /// @notice Direct purchase of GROW with any allowlisted stablecoin. USDC / USDT / DAI / etc.
    /// @param paymentToken      The stablecoin used to pay. Must be on Treasury allowlist.
    /// @param paymentAmount     Raw amount (in payment token's native decimals) the buyer pays.
    /// @param maxPriceAccepted  Slippage cap: revert if effective price exceeds this value.
    /// @return growOut          GROW raw amount (18-dec) minted to the buyer.
    function buy(address paymentToken, uint256 paymentAmount, uint256 maxPriceAccepted)
        external
        nonReentrant
        returns (uint256 growOut)
    {
        if (!saleActive) revert SaleNotActive();
        if (treasury == address(0)) revert TreasuryNotSet();
        if (paymentAmount == 0) revert ZeroAmount();

        IGrowfiTreasury t = IGrowfiTreasury(treasury);
        if (!t.isAcceptedStablecoin(paymentToken)) revert PaymentTokenNotAccepted();
        uint256 scale = t.stablecoinScale(paymentToken);

        // Live USD price of the payment stablecoin (1e18 = $1). Reverts on stale/depeg/borked
        // feeds — the buyer is not allowed to mint GROW with a "fake $1" stablecoin.
        uint256 priceUsd18 = t.getStablecoinPriceUsd18(paymentToken);

        uint256 floor = t.intrinsicFloorPrice();
        uint256 refPrice = floor > 0 ? floor : referencePrice;
        if (refPrice == 0) revert NoFloorAvailable();

        uint256 effectivePrice = (refPrice * (BPS + markupBps)) / BPS;
        if (effectivePrice > maxPriceAccepted) revert PriceExceedsMax();

        // paymentUsd18 = paymentAmount × scale × priceUsd18 / 1e18
        // growOut (18-dec) = paymentUsd18 × 1e18 / effectivePrice
        //                 = paymentAmount × scale × priceUsd18 / effectivePrice
        growOut = (paymentAmount * scale * priceUsd18) / effectivePrice;

        IERC20(paymentToken).safeTransferFrom(msg.sender, treasury, paymentAmount);
        _mint(msg.sender, growOut);

        // Cache the floor we used so the fallback path stays fresh.
        if (floor > 0) {
            referencePrice = floor;
        }

        emit DirectBuy(msg.sender, paymentToken, paymentAmount, growOut, effectivePrice);

        // Auto-allocate the freshly received USDC across all tracked Active campaigns.
        // Only fires when `Treasury.automationEnabled == true` (multisig switch). Wrapped
        // in try/catch so failures (automation off, no Active tracked campaigns, dust split,
        // a single rogue campaign reverting) leave the direct buy itself successful — the
        // funds stay in the Treasury and the multisig can call `allocateAcrossTracked`
        // manually later.
        try IGrowfiTreasury(treasury).allocateAcrossTracked(paymentToken, paymentAmount) {
            emit AutoAllocAttempted(paymentToken, paymentAmount, true);
        } catch {
            emit AutoAllocAttempted(paymentToken, paymentAmount, false);
        }
    }
}
