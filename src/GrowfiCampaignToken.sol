// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";

/// @title GrowfiCampaignToken — "The Seat"
/// @notice Per-campaign staking token. Strictly deflationary: supply can only decrease.
/// @dev Mintable only by GrowfiCampaign contract. Burnable by GrowfiCampaign + GrowfiStakingVault.
///      Initializable so it can be deployed as an EIP-1167 clone.
contract GrowfiCampaignToken is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable, ERC20VotesUpgradeable {
    address public campaign;
    address public stakingVault;

    error OnlyCampaign();
    error OnlyCampaignOrVault();
    error StakingVaultAlreadySet();

    modifier onlyCampaign() {
        if (msg.sender != campaign) revert OnlyCampaign();
        _;
    }

    modifier onlyCampaignOrVault() {
        if (msg.sender != campaign && msg.sender != stakingVault) revert OnlyCampaignOrVault();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(string memory name_, string memory symbol_, address campaign_) external initializer {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __ERC20Votes_init();
        campaign = campaign_;
    }

    /// @notice Set the GrowfiStakingVault address. Can only be called once by the GrowfiCampaign.
    function setStakingVault(address stakingVault_) external onlyCampaign {
        if (stakingVault != address(0)) revert StakingVaultAlreadySet();
        stakingVault = stakingVault_;
    }

    /// @notice Mint new tokens. Only callable by GrowfiCampaign during initial sales.
    function mint(address to, uint256 amount) external onlyCampaign {
        _mint(to, amount);
    }

    /// @notice Burn tokens from an account. Callable by GrowfiCampaign (buyback/sellback) or GrowfiStakingVault (penalties).
    function burn(address from, uint256 amount) external onlyCampaignOrVault {
        _burn(from, amount);
    }

    // --- Overrides required by Solidity for ERC20 + ERC20Votes ---

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, value);
    }

    function nonces(address owner_) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner_);
    }
}
