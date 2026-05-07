// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * IGrowfiMinter — hook surface called by GrowfiCampaign during its lifecycle.
 *
 * The minter sits between Campaign actions and the GROW token: it gates emissions,
 * applies the bonding curve, holds pre-softcap escrow, and voids escrow on buyback.
 *
 * Design notes:
 * - All hooks are gated to the calling Campaign address (the minter checks the
 *   caller against its internal registry of known campaigns).
 * - Hooks are best-effort fail-open: if the minter rejects or reverts, Campaign
 *   should NOT brick the user's buy. We use a low-level call wrapper at the call site.
 * - `recordBuy` reports the just-minted CampaignToken amount, plus the supply BEFORE
 *   this buy (so the minter can walk the bonding curve tiers without re-reading
 *   chain state).
 */
interface IGrowfiMinter {
    /**
     * Called from GrowfiCampaign.buy() right after the new tokens have been minted
     * and `currentSupply` has been incremented but BEFORE `_activate()` may run.
     *
     * @param buyer        Recipient of the CampaignToken (and of any GROW that mints to wallet).
     * @param supplyBefore Campaign currentSupply BEFORE this buy.
     * @param supplyAfter  Campaign currentSupply AFTER this buy.
     */
    function recordBuy(address buyer, uint256 supplyBefore, uint256 supplyAfter) external;

    /**
     * Called from GrowfiCampaign._activate() the moment the campaign transitions
     * Funding → Active. Unlocks pre-softcap escrow for claim by holders.
     */
    function onSoftCapReached() external;

    /**
     * Called from GrowfiCampaign.triggerBuyback() the moment the campaign
     * transitions Funding → Buyback (failed: deadline passed, softcap not reached).
     * Voids all pre-softcap escrow for that campaign.
     */
    function onBuyback() external;
}
