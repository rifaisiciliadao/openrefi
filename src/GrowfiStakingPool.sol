// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGrowfiStakingPool} from "./interfaces/IGrowfiStakingPool.sol";

/**
 * GrowfiStakingPool — stake GROW, earn USDC.
 *
 * Reward distribution: rate × elapsed-time accumulator. The Treasury notifies a USDC
 * amount, which is streamed out linearly over `rewardsDuration` (default 30 days).
 * Each second a slice `rate × dt / effectiveTotalStaked` is added to the per-token tracker.
 *
 * Time-in-pool boost (continuous, capped):
 *   multiplierBps = BPS + min((now - streakStart) / RAMP_DURATION, 1.0) × BPS
 *   capped at MAX_MULTIPLIER (2.0× = 20_000 bps) at 365 days.
 *
 * Streak rules:
 * - First stake (balance == 0): streakStart = now, multiplier = 1.0×.
 * - Adding to existing stake: streak preserved.
 * - Any withdraw (partial or full): streak RESETS, multiplier back to 1.0×.
 * - Claim: streak preserved. Multiplier may bump up if a tier crossing happened.
 *
 * Multiplier application:
 * - The user's effective balance (= raw balance × multiplier) is what counts toward
 *   reward share. The accumulator's denominator is `effectiveTotalStaked`.
 * - Multiplier in storage is REFRESHED on every user action (stake / withdraw / claim).
 *   Between actions, the stored multiplier stays fixed even if the streak crosses a
 *   threshold time-wise. This keeps the math conserving without on-chain "pokes".
 * - Frontend can read `previewMultiplier(user)` to show the live ramped multiplier;
 *   the user must take any action (e.g., a `claim()`) to apply it.
 *
 * No lockup. Withdraw is always available. Multiplier loss on withdraw is the
 * implicit "cost" of exiting.
 */
contract GrowfiStakingPool is Initializable, ReentrancyGuard, IGrowfiStakingPool {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_MULTIPLIER = 20_000; // 2.0× cap
    uint256 public constant RAMP_DURATION = 365 days;

    address public factory;
    IERC20 public growToken;
    IERC20 public usdc;
    address public treasury;

    /// @notice Raw GROW staked (sum across all users).
    uint256 public totalStaked;
    /// @notice Sum of (raw balance × multiplier) across all stakers — denominator for reward distribution.
    uint256 public effectiveTotalStaked;

    /// @notice Accumulator: cumulative USDC-raw × 1e18 / effective-GROW-raw.
    uint256 public rewardPerTokenStored;
    /// @notice Reward emission rate (USDC-raw per second) during the active period.
    uint256 public rewardRate;
    /// @notice Last time the accumulator was bumped.
    uint256 public lastUpdateTime;
    /// @notice Timestamp at which the current emission period ends.
    uint256 public periodFinish;
    /// @notice Length of each distribution period; default 30 days. Multisig settable when no period is active.
    uint256 public rewardsDuration;

    /// @notice USDC accumulated by `notifyReward` while the pool was empty. Flushed at first stake.
    uint256 public pendingForFirstStaker;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public effectiveBalanceOf;
    /// @notice Timestamp at which the user's current streak started. 0 = no active stake.
    mapping(address => uint256) public streakStartAt;
    /// @notice Last-snapshotted multiplier in BPS for this user. Refreshed on every user action.
    mapping(address => uint256) public multiplierBps;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    error NotFactory();
    error NotTreasury();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error PeriodActive();

    event TreasuryUpdated(address indexed previous, address indexed current);
    event RewardsDurationUpdated(uint256 previous, uint256 current);
    event Staked(address indexed user, uint256 amount, uint256 newBalance);
    event Withdrawn(address indexed user, uint256 amount, uint256 newBalance);
    event Claimed(address indexed user, uint256 reward);
    event RewardNotified(uint256 amount, uint256 rewardRate, uint256 periodFinish);
    event PendingFlushedToFirstStaker(uint256 amount);
    event MultiplierUpdated(address indexed user, uint256 previousBps, uint256 currentBps, uint256 streakStart);
    event StreakReset(address indexed user, uint256 newStreakStart);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address factory_, address growToken_, address usdc_, address treasury_)
        external
        initializer
    {
        if (factory_ == address(0) || growToken_ == address(0) || usdc_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        factory = factory_;
        growToken = IERC20(growToken_);
        usdc = IERC20(usdc_);
        treasury = treasury_;
        rewardsDuration = 30 days;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    // ---------- factory admin ----------

    function setTreasury(address newTreasury) external onlyFactory {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Update the distribution duration. Only allowed when no period is active to keep
    ///         math sane (changing duration mid-period would re-base the rewardRate ambiguously).
    function setRewardsDuration(uint256 newDuration) external onlyFactory {
        if (block.timestamp < periodFinish) revert PeriodActive();
        if (newDuration == 0) revert ZeroAmount();
        emit RewardsDurationUpdated(rewardsDuration, newDuration);
        rewardsDuration = newDuration;
    }

    // ---------- multiplier math ----------

    /// @notice Continuous ramp 1.0× → 2.0× linearly over 365 days, then capped at 2.0×.
    function _computeMultiplier(uint256 streakStart) internal view returns (uint256) {
        if (streakStart == 0) return BPS; // sentinel — user has no active stake
        uint256 elapsed = block.timestamp - streakStart;
        if (elapsed >= RAMP_DURATION) return MAX_MULTIPLIER;
        // multiplier = BPS + (elapsed / RAMP_DURATION) × BPS
        return BPS + (elapsed * BPS) / RAMP_DURATION;
    }

    /// @notice Frontend helper: shows what the multiplier WOULD be if refreshed now.
    function previewMultiplier(address user) external view returns (uint256) {
        if (balanceOf[user] == 0) return 0;
        return _computeMultiplier(streakStartAt[user]);
    }

    // ---------- accumulator math ----------

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (effectiveTotalStaked == 0) return rewardPerTokenStored;
        uint256 timeSlice = lastTimeRewardApplicable() - lastUpdateTime;
        return rewardPerTokenStored + (timeSlice * rewardRate * 1e18) / effectiveTotalStaked;
    }

    /// @notice Pending USDC reward for `user` based on their snapshotted effective balance.
    /// @dev Uses the multiplier currently stored on-chain. To get the value AFTER a tier
    ///      cross has been refreshed, the user must call `stake`/`withdraw`/`claim`.
    function earned(address user) public view returns (uint256) {
        return rewards[user]
            + (effectiveBalanceOf[user] * (rewardPerToken() - userRewardPerTokenPaid[user])) / 1e18;
    }

    function _updateAccumulator() internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
    }

    /// @dev Settle the user's pending rewards using their CURRENT effective balance, then
    ///      refresh the multiplier to reflect the current streak. Future accumulation uses
    ///      the new effective balance.
    function _settleAndRefresh(address user) internal {
        // Step 1: settle pending using OLD effective balance
        rewards[user] = earned(user);
        userRewardPerTokenPaid[user] = rewardPerTokenStored;

        // Step 2: recompute multiplier from streak (only if user has an active stake)
        if (balanceOf[user] > 0 && streakStartAt[user] != 0) {
            uint256 oldBps = multiplierBps[user];
            uint256 newBps = _computeMultiplier(streakStartAt[user]);
            if (newBps != oldBps) {
                uint256 oldEff = effectiveBalanceOf[user];
                uint256 newEff = (balanceOf[user] * newBps) / BPS;
                effectiveBalanceOf[user] = newEff;
                effectiveTotalStaked = effectiveTotalStaked - oldEff + newEff;
                multiplierBps[user] = newBps;
                emit MultiplierUpdated(user, oldBps, newBps, streakStartAt[user]);
            }
        }
    }

    // ---------- stake / withdraw / claim ----------

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _updateAccumulator();
        _settleAndRefresh(msg.sender);

        bool wasFreshUser = balanceOf[msg.sender] == 0;
        bool poolWasEmpty = effectiveTotalStaked == 0;

        if (wasFreshUser) {
            // Fresh stake — start the streak now, multiplier 1.0×.
            streakStartAt[msg.sender] = block.timestamp;
            multiplierBps[msg.sender] = BPS;
            emit StreakReset(msg.sender, block.timestamp);
        }

        balanceOf[msg.sender] += amount;
        totalStaked += amount;

        uint256 oldEff = effectiveBalanceOf[msg.sender];
        uint256 newEff = (balanceOf[msg.sender] * multiplierBps[msg.sender]) / BPS;
        effectiveBalanceOf[msg.sender] = newEff;
        effectiveTotalStaked = effectiveTotalStaked - oldEff + newEff;

        growToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount, balanceOf[msg.sender]);

        // Pool was empty; if there's a pending reward bucket from a prior notify, kick off a fresh
        // distribution period so the first staker actually earns it.
        if (poolWasEmpty && pendingForFirstStaker > 0) {
            uint256 pending = pendingForFirstStaker;
            pendingForFirstStaker = 0;
            _startPeriod(pending);
            emit PendingFlushedToFirstStaker(pending);
        }
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();

        _updateAccumulator();
        _settleAndRefresh(msg.sender);

        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;

        // Withdraw always RESETS the streak — exiting (even partial) costs the multiplier.
        if (balanceOf[msg.sender] > 0) {
            streakStartAt[msg.sender] = block.timestamp;
            multiplierBps[msg.sender] = BPS;
            emit StreakReset(msg.sender, block.timestamp);
        } else {
            streakStartAt[msg.sender] = 0;
            multiplierBps[msg.sender] = 0;
        }

        uint256 oldEff = effectiveBalanceOf[msg.sender];
        uint256 newEff = balanceOf[msg.sender] > 0 ? balanceOf[msg.sender] : 0; // 1.0× × balance OR 0
        effectiveBalanceOf[msg.sender] = newEff;
        effectiveTotalStaked = effectiveTotalStaked - oldEff + newEff;

        growToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, balanceOf[msg.sender]);
    }

    function claim() external nonReentrant returns (uint256 reward) {
        _updateAccumulator();
        _settleAndRefresh(msg.sender);

        reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            usdc.safeTransfer(msg.sender, reward);
            emit Claimed(msg.sender, reward);
        }
    }

    function exit() external nonReentrant {
        _updateAccumulator();
        _settleAndRefresh(msg.sender);

        uint256 bal = balanceOf[msg.sender];
        if (bal > 0) {
            uint256 oldEff = effectiveBalanceOf[msg.sender];
            balanceOf[msg.sender] = 0;
            totalStaked -= bal;
            effectiveBalanceOf[msg.sender] = 0;
            effectiveTotalStaked -= oldEff;
            streakStartAt[msg.sender] = 0;
            multiplierBps[msg.sender] = 0;
            growToken.safeTransfer(msg.sender, bal);
            emit Withdrawn(msg.sender, bal, 0);
        }

        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            usdc.safeTransfer(msg.sender, reward);
            emit Claimed(msg.sender, reward);
        }
    }

    // ---------- reward notification ----------

    /// @notice Treasury pushes USDC into the pool and notifies. The amount is distributed
    ///         linearly over `rewardsDuration`. If a period is already active, the
    ///         remaining + new amount are recalibrated over a fresh `rewardsDuration`.
    function notifyReward(uint256 amount) external onlyTreasury {
        if (amount == 0) return;

        _updateAccumulator();

        if (effectiveTotalStaked == 0) {
            // No stakers — accumulate to pending; first staker triggers a fresh period.
            pendingForFirstStaker += amount;
            return;
        }

        _startPeriod(amount);
    }

    function _startPeriod(uint256 amount) internal {
        uint256 leftover = 0;
        if (block.timestamp < periodFinish) {
            leftover = (periodFinish - block.timestamp) * rewardRate;
        }
        rewardRate = (amount + leftover) / rewardsDuration;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardNotified(amount, rewardRate, periodFinish);
    }
}
