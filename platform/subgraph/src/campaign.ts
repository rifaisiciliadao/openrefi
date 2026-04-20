import { BigInt, Bytes, log, store } from "@graphprotocol/graph-ts";
import {
  TokensPurchased as TokensPurchasedEvent,
  AcceptedTokenAdded as AcceptedTokenAddedEvent,
  AcceptedTokenRemoved as AcceptedTokenRemovedEvent,
  CampaignStateChanged as CampaignStateChangedEvent,
  CampaignActivated as CampaignActivatedEvent,
  BuybackTriggered as BuybackTriggeredEvent,
  BuybackClaimed as BuybackClaimedEvent,
  SellBackRequested as SellBackRequestedEvent,
  SellBackFilled as SellBackFilledEvent,
  SellBackCancelled as SellBackCancelledEvent,
  CampaignPaused as CampaignPausedEvent,
  FundingDeadlineUpdated as FundingDeadlineUpdatedEvent,
  MinCapUpdated as MinCapUpdatedEvent,
  MaxCapUpdated as MaxCapUpdatedEvent,
} from "../generated/templates/Campaign/Campaign";
import {
  Campaign,
  AcceptedToken,
  Purchase,
  SellBackOrder,
  User,
  GlobalStats,
} from "../generated/schema";

const STATES = ["Funding", "Active", "Buyback", "Ended"];
const GLOBAL_ID = Bytes.fromUTF8("global");

function loadOrCreateUser(addr: Bytes, timestamp: BigInt): User {
  let user = User.load(addr);
  if (user == null) {
    user = new User(addr);
    user.purchasesCount = 0;
    user.positionsCount = 0;
    user.totalInvested = BigInt.zero();
    user.firstSeenAt = timestamp;

    // increment global user counter
    let stats = GlobalStats.load(GLOBAL_ID);
    if (stats != null) {
      stats.userCount = stats.userCount + 1;
      stats.save();
    }
  }
  return user;
}

function eventId(txHash: Bytes, logIndex: BigInt): Bytes {
  return txHash.concatI32(logIndex.toI32());
}

export function handleTokensPurchased(event: TokensPurchasedEvent): void {
  const campaignAddress = event.address;
  const campaign = Campaign.load(campaignAddress);
  if (campaign == null) return;

  // Purchase entity
  const purchase = new Purchase(eventId(event.transaction.hash, event.logIndex));
  purchase.campaign = campaignAddress;
  purchase.buyer = event.params.buyer;
  purchase.paymentToken = event.params.paymentToken;
  purchase.paymentAmount = event.params.paymentAmount;
  purchase.campaignTokensOut = event.params.campaignTokensOut;
  purchase.oraclePriceUsed = event.params.oraclePriceUsed;
  purchase.newCurrentSupply = event.params.newCurrentSupply;
  purchase.timestamp = event.block.timestamp;
  purchase.block = event.block.number;
  purchase.transactionHash = event.transaction.hash;
  purchase.save();

  // Update Campaign stats
  campaign.currentSupply = event.params.newCurrentSupply;

  // Approximate totalRaised using oraclePriceUsed (USD 18 dec) × paymentAmount / 1e18
  // (for fixed rate, oraclePriceUsed == pricePerToken so tokensOut * price = USD)
  const usdValue = event.params.campaignTokensOut
    .times(campaign.pricePerToken)
    .div(BigInt.fromI32(10).pow(18));
  campaign.totalRaised = campaign.totalRaised.plus(usdValue);
  campaign.save();

  // User
  const user = loadOrCreateUser(event.params.buyer, event.block.timestamp);
  user.purchasesCount = user.purchasesCount + 1;
  user.totalInvested = user.totalInvested.plus(usdValue);
  user.save();

  // Global
  let stats = GlobalStats.load(GLOBAL_ID);
  if (stats != null) {
    stats.totalRaised = stats.totalRaised.plus(usdValue);
    stats.save();
  }
}

export function handleAcceptedTokenAdded(event: AcceptedTokenAddedEvent): void {
  const campaignAddress = event.address;
  const id = campaignAddress.concat(event.params.tokenAddress);

  const token = new AcceptedToken(id);
  token.campaign = campaignAddress;
  token.tokenAddress = event.params.tokenAddress;
  token.symbol = event.params.symbol;
  token.pricingMode = event.params.pricingMode == 0 ? "Fixed" : "Oracle";
  token.fixedRate = event.params.fixedRate;
  token.oracleFeed = event.params.oracleFeed;
  token.active = true;
  token.addedAt = event.block.timestamp;
  token.save();
}

export function handleAcceptedTokenRemoved(
  event: AcceptedTokenRemovedEvent,
): void {
  const id = event.address.concat(event.params.tokenAddress);
  const token = AcceptedToken.load(id);
  if (token != null) {
    token.active = false;
    token.save();
  }
}

export function handleCampaignStateChanged(
  event: CampaignStateChangedEvent,
): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;
  const idx = event.params.newState;
  if (idx < STATES.length) {
    campaign.state = STATES[idx];
    campaign.save();
  }
}

export function handleCampaignActivated(event: CampaignActivatedEvent): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;
  campaign.state = "Active";
  campaign.activatedAt = event.block.timestamp;
  campaign.save();
}

export function handleBuybackTriggered(event: BuybackTriggeredEvent): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;
  campaign.state = "Buyback";
  campaign.save();
}

export function handleBuybackClaimed(event: BuybackClaimedEvent): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;
  campaign.currentSupply = campaign.currentSupply.minus(
    event.params.campaignTokensBurned,
  );
  campaign.save();
}

export function handleSellBackRequested(event: SellBackRequestedEvent): void {
  const id = event.address.concatI32(event.params.queuePosition.toI32());
  const order = new SellBackOrder(id);
  order.campaign = event.address;
  order.user = event.params.user;
  order.amount = event.params.amount;
  order.filledAmount = BigInt.zero();
  order.status = "pending";
  order.queuePosition = event.params.queuePosition;
  order.requestedAt = event.block.timestamp;
  order.save();
}

export function handleSellBackFilled(event: SellBackFilledEvent): void {
  // Seller order is the oldest pending one — we can't easily find it without
  // tracking queue position. Simplification: find latest pending for this seller.
  // For MVP, mark the user's most recent pending order as filled.
  log.info("SellBackFilled: seller={} amount={}", [
    event.params.seller.toHexString(),
    event.params.campaignTokenAmount.toString(),
  ]);
  // Full queue-position tracking requires additional indexing state — skipped for MVP.
}

export function handleSellBackCancelled(event: SellBackCancelledEvent): void {
  // Similarly, we'd need queue position tracking. Skipped for MVP.
  log.info("SellBackCancelled: user={} amount={}", [
    event.params.user.toHexString(),
    event.params.amountReturned.toString(),
  ]);
}

export function handleCampaignPaused(event: CampaignPausedEvent): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;
  campaign.paused = event.params.paused;
  campaign.save();
}

export function handleFundingDeadlineUpdated(
  event: FundingDeadlineUpdatedEvent,
): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;
  campaign.fundingDeadline = event.params.newDeadline;
  campaign.save();
}

export function handleMinCapUpdated(event: MinCapUpdatedEvent): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;
  campaign.minCap = event.params.newMinCap;
  campaign.save();
}

export function handleMaxCapUpdated(event: MaxCapUpdatedEvent): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;
  campaign.maxCap = event.params.newMaxCap;
  campaign.save();
}
