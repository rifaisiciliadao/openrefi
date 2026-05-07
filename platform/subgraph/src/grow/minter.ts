import { Address, BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  CampaignRegistered as CampaignRegisteredEvent,
  GrowEscrowed as GrowEscrowedEvent,
  GrowMinted as GrowMintedEvent,
  SoftCapReached as SoftCapReachedEvent,
  CampaignBuyback as CampaignBuybackEvent,
  EscrowClaimed as EscrowClaimedEvent,
  BondingCurveUpdated as BondingCurveUpdatedEvent,
  ExcludedFromMintUpdated as ExcludedFromMintUpdatedEvent,
} from "../../generated/GrowfiMinter/GrowfiMinter";
import {
  CampaignGrowState,
  GrowEscrow,
  GrowEscrowClaim,
  BondingCurveSnapshot,
  GrowHolder,
  Campaign,
} from "../../generated/schema";

const ZERO = BigInt.zero();

function loadCampaignGrowState(campaign: Address, ts: BigInt): CampaignGrowState {
  const id = Bytes.fromHexString(campaign.toHexString()) as Bytes;
  let s = CampaignGrowState.load(id);
  if (s == null) {
    s = new CampaignGrowState(id);
    s.campaign = id; // FK — Campaign entity must exist (created by factory handler)
    s.status = "Pending";
    s.cumBuyVolumeUsd = ZERO;
    s.totalEscrowed = ZERO;
    s.totalMinted = ZERO;
    s.registeredAt = ts;
  }
  return s as CampaignGrowState;
}

function escrowId(campaign: Address, user: Address): Bytes {
  return Bytes.fromHexString(campaign.toHexString()).concat(
    Bytes.fromHexString(user.toHexString().slice(2))
  );
}

function loadOrCreateEscrow(campaign: Address, user: Address, ts: BigInt): GrowEscrow {
  const id = escrowId(campaign, user);
  let e = GrowEscrow.load(id);
  if (e == null) {
    e = new GrowEscrow(id);
    e.campaign = Bytes.fromHexString(campaign.toHexString()) as Bytes;
    e.user = Bytes.fromHexString(user.toHexString()) as Bytes;
    e.amount = ZERO;
    e.status = "Pending";
  }
  e.lastUpdatedAt = ts;
  return e as GrowEscrow;
}

function loadOrCreateHolder(addr: Address, ts: BigInt): GrowHolder {
  const id = Bytes.fromHexString(addr.toHexString()) as Bytes;
  let h = GrowHolder.load(id);
  if (h == null) {
    h = new GrowHolder(id);
    h.balance = ZERO;
    h.totalEarnedFromBuys = ZERO;
    h.totalEarnedFromEscrowClaims = ZERO;
    h.totalEarnedFromCampaignBuys = ZERO;
    h.totalRedeemed = ZERO;
    h.firstSeenAt = ts;
  }
  h.lastActivityAt = ts;
  return h as GrowHolder;
}

export function handleCampaignRegistered(event: CampaignRegisteredEvent): void {
  const s = loadCampaignGrowState(event.params.campaign, event.block.timestamp);
  s.save();
}

export function handleGrowEscrowed(event: GrowEscrowedEvent): void {
  const s = loadCampaignGrowState(event.params.campaign, event.block.timestamp);
  s.totalEscrowed = s.totalEscrowed.plus(event.params.amount);
  s.save();

  const e = loadOrCreateEscrow(event.params.campaign, event.params.buyer, event.block.timestamp);
  e.amount = e.amount.plus(event.params.amount);
  e.status = "Pending";
  e.save();

  const h = loadOrCreateHolder(event.params.buyer, event.block.timestamp);
  h.save();
}

export function handleGrowMinted(event: GrowMintedEvent): void {
  const s = loadCampaignGrowState(event.params.campaign, event.block.timestamp);
  s.totalMinted = s.totalMinted.plus(event.params.amount);
  s.save();

  const h = loadOrCreateHolder(event.params.buyer, event.block.timestamp);
  h.totalEarnedFromCampaignBuys = h.totalEarnedFromCampaignBuys.plus(event.params.amount);
  h.save();
}

export function handleSoftCapReached(event: SoftCapReachedEvent): void {
  const s = loadCampaignGrowState(event.params.campaign, event.block.timestamp);
  s.status = "Active";
  s.activatedAt = event.block.timestamp;
  s.save();

  // Mark all pending escrows for this campaign as claimable. This is a bulk update;
  // AssemblyScript subgraphs don't support batch updates over @derivedFrom relations
  // efficiently, so we leave individual escrows as "Pending" until claim time. The
  // CampaignGrowState.status field tells consumers whether claim is possible.
}

export function handleCampaignBuyback(event: CampaignBuybackEvent): void {
  const s = loadCampaignGrowState(event.params.campaign, event.block.timestamp);
  s.status = "Failed";
  s.failedAt = event.block.timestamp;
  s.save();
}

export function handleEscrowClaimed(event: EscrowClaimedEvent): void {
  const id = Bytes.fromHexString(event.transaction.hash.toHexString()).concat(
    Bytes.fromI32(event.logIndex.toI32())
  );
  const c = new GrowEscrowClaim(id);
  c.campaign = event.params.campaign;
  c.amount = event.params.amount;
  c.timestamp = event.block.timestamp;
  c.block = event.block.number;
  c.transactionHash = event.transaction.hash;

  const holder = loadOrCreateHolder(event.params.user, event.block.timestamp);
  holder.totalEarnedFromEscrowClaims = holder.totalEarnedFromEscrowClaims.plus(event.params.amount);
  holder.save();
  c.claimer = holder.id;
  c.save();

  const e = loadOrCreateEscrow(event.params.campaign, event.params.user, event.block.timestamp);
  e.amount = ZERO;
  e.status = "Claimed";
  e.save();
}

export function handleBondingCurveUpdated(event: BondingCurveUpdatedEvent): void {
  const id = Bytes.fromHexString(event.transaction.hash.toHexString()).concat(
    Bytes.fromI32(event.logIndex.toI32())
  );
  const snap = new BondingCurveSnapshot(id);
  snap.tier1RateBps = event.params.tier1RateBps;
  snap.tier2RateBps = event.params.tier2RateBps;
  snap.tier3RateBps = event.params.tier3RateBps;
  snap.tier2to3ThresholdBps = event.params.thresholdBps;
  snap.setAt = event.block.timestamp;
  snap.save();
}

export function handleExcludedFromMintUpdated(event: ExcludedFromMintUpdatedEvent): void {
  // No dedicated entity for exclusions; could add if needed.
}
