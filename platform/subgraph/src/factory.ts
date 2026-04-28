import { BigInt, Bytes, log } from "@graphprotocol/graph-ts";
import {
  CampaignCreated as CampaignCreatedEvent,
  ProtocolFeeRecipientUpdated as ProtocolFeeRecipientUpdatedEvent,
} from "../generated/CampaignFactory/CampaignFactory";
import {
  Campaign as CampaignTemplate,
  StakingVault as StakingVaultTemplate,
  HarvestManager as HarvestManagerTemplate,
} from "../generated/templates";
import { Campaign, GlobalStats, ContractIndex } from "../generated/schema";

const GLOBAL_ID = Bytes.fromUTF8("global");

function loadOrCreateGlobalStats(): GlobalStats {
  let stats = GlobalStats.load(GLOBAL_ID);
  if (stats == null) {
    stats = new GlobalStats(GLOBAL_ID);
    stats.campaignCount = 0;
    stats.userCount = 0;
    stats.totalRaised = BigInt.zero();
    stats.totalStakers = 0;
  }
  return stats;
}

export function handleCampaignCreated(event: CampaignCreatedEvent): void {
  const campaignAddress = event.params.campaign;

  const campaign = new Campaign(campaignAddress);
  campaign.producer = event.params.producer;
  campaign.campaignToken = event.params.campaignToken;
  campaign.yieldToken = event.params.yieldToken;
  campaign.stakingVault = event.params.stakingVault;
  campaign.harvestManager = event.params.harvestManager;
  campaign.pricePerToken = event.params.pricePerToken;
  campaign.minCap = event.params.minCap;
  campaign.maxCap = event.params.maxCap;
  campaign.fundingDeadline = event.params.fundingDeadline;
  campaign.seasonDuration = event.params.seasonDuration;
  campaign.minProductClaim = event.params.minProductClaim;
  campaign.expectedYearlyReturnBps = event.params.expectedYearlyReturnBps;
  campaign.expectedFirstYearHarvest = event.params.expectedFirstYearHarvest;
  campaign.coverageHarvests = event.params.coverageHarvests;
  campaign.collateralLocked = BigInt.zero();
  campaign.collateralDrawn = BigInt.zero();
  campaign.currentSupply = BigInt.zero();
  campaign.totalStaked = BigInt.zero();
  campaign.totalRaised = BigInt.zero();
  campaign.currentYieldRate = BigInt.fromI32(5).times(
    BigInt.fromI32(10).pow(18),
  ); // 5x
  campaign.currentSeasonId = BigInt.zero();
  campaign.state = "Funding";
  campaign.paused = false;
  campaign.createdAt = event.params.createdAt;
  campaign.createdAtBlock = event.block.number;
  campaign.metadataVersion = BigInt.zero();
  campaign.save();

  // Register reverse lookup indices for the template handlers
  const vaultIdx = new ContractIndex(event.params.stakingVault);
  vaultIdx.campaign = campaignAddress;
  vaultIdx.kind = "vault";
  vaultIdx.save();

  const harvestIdx = new ContractIndex(event.params.harvestManager);
  harvestIdx.campaign = campaignAddress;
  harvestIdx.kind = "harvest";
  harvestIdx.save();

  // Spawn dynamic templates for this campaign
  CampaignTemplate.create(campaignAddress);
  StakingVaultTemplate.create(event.params.stakingVault);
  HarvestManagerTemplate.create(event.params.harvestManager);

  // Update global stats
  const stats = loadOrCreateGlobalStats();
  stats.campaignCount = stats.campaignCount + 1;
  stats.save();

  log.info("Campaign created: {}", [campaignAddress.toHexString()]);
}

export function handleProtocolFeeRecipientUpdated(
  event: ProtocolFeeRecipientUpdatedEvent,
): void {
  // Recorded as global event; no entity change required
  log.info("Protocol fee recipient updated from {} to {}", [
    event.params.oldRecipient.toHexString(),
    event.params.newRecipient.toHexString(),
  ]);
}
