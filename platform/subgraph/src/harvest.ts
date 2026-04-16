import { BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  HarvestReported as HarvestReportedEvent,
  ProductRedeemed as ProductRedeemedEvent,
  USDCRedeemed as USDCRedeemedEvent,
  USDCDeposited as USDCDepositedEvent,
  USDCClaimed as USDCClaimedEvent,
  ProtocolFeeCollected as ProtocolFeeCollectedEvent,
} from "../generated/templates/HarvestManager/HarvestManager";
import { Season, Claim, Campaign, ContractIndex } from "../generated/schema";

function campaignFromManager(managerAddr: Bytes): Campaign | null {
  const idx = ContractIndex.load(managerAddr);
  if (idx == null) return null;
  return Campaign.load(idx.campaign);
}

function seasonEntityId(campaignId: Bytes, sid: BigInt): Bytes {
  return campaignId.concatI32(sid.toI32());
}

function claimId(campaignId: Bytes, seasonId: BigInt, user: Bytes): Bytes {
  return campaignId.concatI32(seasonId.toI32()).concat(user);
}

export function handleHarvestReported(event: HarvestReportedEvent): void {
  const campaign = campaignFromManager(event.address);
  if (campaign == null) return;

  const id = seasonEntityId(campaign.id, event.params.seasonId);
  let season = Season.load(id);
  if (season == null) {
    season = new Season(id);
    season.campaign = campaign.id;
    season.seasonId = event.params.seasonId;
    season.startTime = event.block.timestamp;
    season.active = false;
    season.usdcDeposited = BigInt.zero();
    season.usdcOwed = BigInt.zero();
  }

  season.totalHarvestValueUSD = event.params.totalHarvestValueUSD;
  season.protocolFee = event.params.protocolFee;
  season.holderPool = event.params.holderPool;
  season.totalProductUnits = event.params.totalProductUnits;
  season.merkleRoot = event.params.merkleRoot;
  season.claimStart = event.params.claimStart;
  season.claimEnd = event.params.claimEnd;
  season.usdcDeadline = event.params.usdcDeadline;
  season.reported = true;
  season.reportedAt = event.block.timestamp;
  season.save();
}

export function handleProductRedeemed(event: ProductRedeemedEvent): void {
  const campaign = campaignFromManager(event.address);
  if (campaign == null) return;

  const id = claimId(campaign.id, event.params.seasonId, event.params.user);
  const seasonKey = seasonEntityId(campaign.id, event.params.seasonId);

  let claim = Claim.load(id);
  if (claim == null) {
    claim = new Claim(id);
    claim.season = seasonKey;
    claim.campaign = campaign.id;
    claim.user = event.params.user;
    claim.usdcAmount = BigInt.zero();
    claim.usdcClaimed = BigInt.zero();
  }
  claim.redemptionType = "product";
  claim.yieldBurned = event.params.yieldBurned;
  claim.productAmount = event.params.productAmount;
  claim.fulfilled = true;
  claim.claimedAt = event.block.timestamp;
  claim.save();
}

export function handleUSDCRedeemed(event: USDCRedeemedEvent): void {
  const campaign = campaignFromManager(event.address);
  if (campaign == null) return;

  const id = claimId(campaign.id, event.params.seasonId, event.params.user);
  const seasonKey = seasonEntityId(campaign.id, event.params.seasonId);

  let claim = Claim.load(id);
  if (claim == null) {
    claim = new Claim(id);
    claim.season = seasonKey;
    claim.campaign = campaign.id;
    claim.user = event.params.user;
    claim.productAmount = BigInt.zero();
    claim.usdcClaimed = BigInt.zero();
    claim.fulfilled = false;
  }
  claim.redemptionType = "usdc";
  claim.yieldBurned = event.params.yieldBurned;
  claim.usdcAmount = event.params.usdcAmount;
  claim.claimedAt = event.block.timestamp;
  claim.save();

  const season = Season.load(seasonKey);
  if (season != null) {
    season.usdcOwed = season.usdcOwed.plus(event.params.usdcAmount);
    season.save();
  }
}

export function handleUSDCDeposited(event: USDCDepositedEvent): void {
  const campaign = campaignFromManager(event.address);
  if (campaign == null) return;

  const season = Season.load(
    seasonEntityId(campaign.id, event.params.seasonId),
  );
  if (season != null) {
    season.usdcDeposited = event.params.totalDeposited;
    season.save();
  }
}

export function handleUSDCClaimed(event: USDCClaimedEvent): void {
  const campaign = campaignFromManager(event.address);
  if (campaign == null) return;

  const id = claimId(campaign.id, event.params.seasonId, event.params.user);
  const claim = Claim.load(id);
  if (claim != null) {
    claim.usdcClaimed = claim.usdcClaimed.plus(event.params.amount);
    claim.save();
  }
}

export function handleProtocolFeeCollected(
  event: ProtocolFeeCollectedEvent,
): void {
  // Snapshot only; no entity mutation for MVP.
}
