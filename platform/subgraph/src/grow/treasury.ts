import { Address, BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  StablecoinAccepted as StablecoinAcceptedEvent,
  StablecoinRevoked as StablecoinRevokedEvent,
  CampaignTracked as CampaignTrackedEvent,
  CampaignUntracked as CampaignUntrackedEvent,
  Allocated as AllocatedEvent,
  Redeemed as RedeemedEvent,
  TokenRescued as TokenRescuedEvent,
} from "../../generated/GrowfiTreasury/GrowfiTreasury";
import {
  GrowfiTreasuryState,
  StablecoinAcceptance,
  TreasuryAllocation,
  TreasuryRedemption,
  TreasuryRescue,
  GrowHolder,
} from "../../generated/schema";

const ZERO = BigInt.zero();

function loadOrCreateState(addr: Address): GrowfiTreasuryState {
  const id = Bytes.fromHexString(addr.toHexString()) as Bytes;
  let s = GrowfiTreasuryState.load(id);
  if (s == null) {
    s = new GrowfiTreasuryState(id);
    s.acceptedStablecoinsCount = ZERO;
    s.trackedCampaignsCount = ZERO;
    s.totalAllocations = ZERO;
    s.totalRedemptions = ZERO;
    s.intrinsicFloorPrice = ZERO;
  }
  return s as GrowfiTreasuryState;
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

export function handleStablecoinAccepted(event: StablecoinAcceptedEvent): void {
  const id = Bytes.fromHexString(event.params.token.toHexString()) as Bytes;
  let acc = StablecoinAcceptance.load(id);
  if (acc == null) {
    acc = new StablecoinAcceptance(id);
  }
  acc.active = true;
  acc.scale = event.params.scale;
  acc.priceFeed = event.params.priceFeed;
  acc.heartbeat = event.params.heartbeat;
  acc.minPriceBps = event.params.minPriceBps;
  acc.maxPriceBps = event.params.maxPriceBps;
  acc.acceptedAt = event.block.timestamp;
  acc.revokedAt = null;
  acc.save();

  const s = loadOrCreateState(event.address);
  s.acceptedStablecoinsCount = s.acceptedStablecoinsCount.plus(BigInt.fromI32(1));
  s.save();
}

export function handleStablecoinRevoked(event: StablecoinRevokedEvent): void {
  const id = Bytes.fromHexString(event.params.token.toHexString()) as Bytes;
  const acc = StablecoinAcceptance.load(id);
  if (acc != null) {
    acc.active = false;
    acc.revokedAt = event.block.timestamp;
    acc.save();
  }

  const s = loadOrCreateState(event.address);
  if (s.acceptedStablecoinsCount.gt(ZERO)) {
    s.acceptedStablecoinsCount = s.acceptedStablecoinsCount.minus(BigInt.fromI32(1));
  }
  s.save();
}

export function handleCampaignTracked(event: CampaignTrackedEvent): void {
  const s = loadOrCreateState(event.address);
  s.trackedCampaignsCount = s.trackedCampaignsCount.plus(BigInt.fromI32(1));
  s.save();
}

export function handleCampaignUntracked(event: CampaignUntrackedEvent): void {
  const s = loadOrCreateState(event.address);
  if (s.trackedCampaignsCount.gt(ZERO)) {
    s.trackedCampaignsCount = s.trackedCampaignsCount.minus(BigInt.fromI32(1));
  }
  s.save();
}

export function handleAllocated(event: AllocatedEvent): void {
  const id = Bytes.fromHexString(event.transaction.hash.toHexString()).concat(
    Bytes.fromI32(event.logIndex.toI32())
  );
  const a = new TreasuryAllocation(id);
  a.campaign = event.params.campaign;
  a.paymentToken = event.params.paymentToken;
  a.amount = event.params.amount;
  a.campaignTokensReceived = event.params.campaignTokensReceived;
  a.timestamp = event.block.timestamp;
  a.block = event.block.number;
  a.transactionHash = event.transaction.hash;
  a.save();

  const s = loadOrCreateState(event.address);
  s.totalAllocations = s.totalAllocations.plus(BigInt.fromI32(1));
  s.save();
}

export function handleRedeemed(event: RedeemedEvent): void {
  const id = Bytes.fromHexString(event.transaction.hash.toHexString()).concat(
    Bytes.fromI32(event.logIndex.toI32())
  );
  const r = new TreasuryRedemption(id);
  const holder = loadOrCreateHolder(event.params.redeemer, event.block.timestamp);
  holder.save();
  r.redeemer = holder.id;
  r.growBurned = event.params.growBurned;
  r.timestamp = event.block.timestamp;
  r.block = event.block.number;
  r.transactionHash = event.transaction.hash;
  r.save();

  const s = loadOrCreateState(event.address);
  s.totalRedemptions = s.totalRedemptions.plus(BigInt.fromI32(1));
  s.save();
}

export function handleTokenRescued(event: TokenRescuedEvent): void {
  const id = Bytes.fromHexString(event.transaction.hash.toHexString()).concat(
    Bytes.fromI32(event.logIndex.toI32())
  );
  const r = new TreasuryRescue(id);
  r.token = event.params.token;
  r.recipient = event.params.to;
  r.amount = event.params.amount;
  r.timestamp = event.block.timestamp;
  r.save();
}
