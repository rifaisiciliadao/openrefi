import { BigInt, Bytes, log, store } from "@graphprotocol/graph-ts";
import {
  TokensPurchased as TokensPurchasedEvent,
  FundingFeeCollected as FundingFeeCollectedEvent,
  AcceptedTokenAdded as AcceptedTokenAddedEvent,
  AcceptedTokenRemoved as AcceptedTokenRemovedEvent,
  CampaignStateChanged as CampaignStateChangedEvent,
  CampaignActivated as CampaignActivatedEvent,
  BuybackTriggered as BuybackTriggeredEvent,
  BuybackClaimed as BuybackClaimedEvent,
  SellBackRequested as SellBackRequestedEvent,
  SellBackFilled as SellBackFilledEvent,
  SellBackCancelled as SellBackCancelledEvent,
  PausedSet as PausedSetEvent,
  FundingDeadlineUpdated as FundingDeadlineUpdatedEvent,
  MinCapUpdated as MinCapUpdatedEvent,
  MaxCapUpdated as MaxCapUpdatedEvent,
  CollateralLocked as CollateralLockedEvent,
  CollateralShortfallSettled as CollateralShortfallSettledEvent,
  ModuleAttached as ModuleAttachedEvent,
  ModuleDetached as ModuleDetachedEvent,
  ModuleEnabledSet as ModuleEnabledSetEvent,
  RepaymentInitialized as RepaymentInitializedEvent,
  RepaymentPoolFunded as RepaymentPoolFundedEvent,
  RepaymentPoolCredited as RepaymentPoolCreditedEvent,
  RepaymentPoolWithdrawn as RepaymentPoolWithdrawnEvent,
  RepaymentBonusSet as RepaymentBonusSetEvent,
  Repaid as RepaidEvent,
  EcommerceInitialized as EcommerceInitializedEvent,
  EcommerceCatalogURISet as EcommerceCatalogURISetEvent,
  EcommerceProtocolFeeSet as EcommerceProtocolFeeSetEvent,
  EcommerceRepaymentAllocationSet as EcommerceRepaymentAllocationSetEvent,
  EcommerceSkuSet as EcommerceSkuSetEvent,
  EcommerceSkuActiveSet as EcommerceSkuActiveSetEvent,
  EcommerceOrderPlaced as EcommerceOrderPlacedEvent,
} from "../generated/templates/Campaign/Campaign";
import {
  Campaign,
  AcceptedToken,
  Purchase,
  FundingFeeByTx,
  SellBackOrder,
  User,
  GlobalStats,
  Protocol,
  Module,
  RepaymentPool,
  Repayment,
  EcommerceStore,
  EcommerceSku,
  EcommerceOrder,
} from "../generated/schema";

const PROTOCOL_ID = Bytes.fromUTF8("protocol");
const REPAYMENT_PROTOCOL_FEE_BPS = BigInt.fromI32(200);
const BPS_DENOMINATOR = BigInt.fromI32(10000);

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

function moduleId(campaign: Bytes, moduleType: Bytes): Bytes {
  return campaign.concat(moduleType);
}

function skuEntityId(campaign: Bytes, skuId: Bytes): Bytes {
  return campaign.concat(skuId);
}

function loadOrCreateRepaymentPool(
  campaignAddress: Bytes,
  timestamp: BigInt,
): RepaymentPool {
  let pool = RepaymentPool.load(campaignAddress);
  if (pool == null) {
    pool = new RepaymentPool(campaignAddress);
    pool.campaign = campaignAddress;
    pool.initialized = false;
    pool.bonusPerCt = BigInt.zero();
    pool.poolBalance = BigInt.zero();
    pool.totalFunded = BigInt.zero();
    pool.totalCredited = BigInt.zero();
    pool.totalWithdrawn = BigInt.zero();
    pool.totalRedeemed = BigInt.zero();
    pool.totalProtocolFees = BigInt.zero();
    pool.redeemCount = 0;
    pool.lastUpdatedAt = timestamp;
  }
  return pool;
}

function loadOrCreateEcommerceStore(
  campaignAddress: Bytes,
  timestamp: BigInt,
): EcommerceStore {
  let storeEntity = EcommerceStore.load(campaignAddress);
  if (storeEntity == null) {
    storeEntity = new EcommerceStore(campaignAddress);
    storeEntity.campaign = campaignAddress;
    storeEntity.initialized = false;
    storeEntity.protocolFeeBps = 0;
    storeEntity.repaymentAllocationBps = 0;
    storeEntity.grossSales = BigInt.zero();
    storeEntity.protocolFees = BigInt.zero();
    storeEntity.repaymentAllocated = BigInt.zero();
    storeEntity.orderCount = 0;
    storeEntity.lastUpdatedAt = timestamp;
  }
  return storeEntity;
}

export function handleTokensPurchased(event: TokensPurchasedEvent): void {
  const campaignAddress = event.address;
  const campaign = Campaign.load(campaignAddress);
  if (campaign == null) return;

  // Purchase entity. `fundingFee` comes from the sibling `FundingFeeCollected`
  // event emitted earlier in the same tx (v2 Campaign only). Pre-v2 purchases
  // never emit that event, so the lookup returns null and we store 0 —
  // historically accurate.
  const feeEntity = FundingFeeByTx.load(event.transaction.hash);
  const fundingFee = feeEntity != null ? feeEntity.fee : BigInt.zero();

  const purchase = new Purchase(eventId(event.transaction.hash, event.logIndex));
  purchase.campaign = campaignAddress;
  purchase.buyer = event.params.buyer;
  purchase.paymentToken = event.params.paymentToken;
  purchase.paymentAmount = event.params.paymentAmount;
  purchase.fundingFee = fundingFee;
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

  // Attribution: when the GROW Treasury is the buyer, the funding came from
  // protocol auto-allocation rather than a direct backer. Track separately so
  // the UI can render a two-segment funding bar.
  const protocol = Protocol.load(PROTOCOL_ID);
  if (protocol !== null) {
    const treasury = protocol.growTreasury;
    if (treasury !== null && event.params.buyer.equals(treasury)) {
      campaign.treasuryRaised = campaign.treasuryRaised.plus(usdValue);
      campaign.treasuryTokensOut = campaign.treasuryTokensOut.plus(
        event.params.campaignTokensOut,
      );
    }
  }
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

export function handleFundingFeeCollected(event: FundingFeeCollectedEvent): void {
  // Writes the per-tx aux entity used by handleTokensPurchased to join the
  // fee amount onto the Purchase. FundingFeeCollected fires BEFORE
  // TokensPurchased in the same `buy()` tx, so the lookup is always populated
  // for v2 buys.
  const fee = new FundingFeeByTx(event.transaction.hash);
  fee.paymentToken = event.params.paymentToken;
  fee.fee = event.params.fee;
  fee.save();
}

export function handleCollateralLocked(event: CollateralLockedEvent): void {
  const c = Campaign.load(event.address);
  if (c == null) return;
  c.collateralLocked = event.params.newCollateralLocked;
  c.save();
}

export function handleCollateralShortfallSettled(
  event: CollateralShortfallSettledEvent,
): void {
  const c = Campaign.load(event.address);
  if (c == null) return;
  c.collateralDrawn = event.params.newCollateralDrawn;
  c.save();
}

export function handleAcceptedTokenAdded(event: AcceptedTokenAddedEvent): void {
  const campaignAddress = event.address;
  const id = campaignAddress.concat(event.params.token);

  const token = new AcceptedToken(id);
  token.campaign = campaignAddress;
  token.tokenAddress = event.params.token;
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
  const id = event.address.concat(event.params.token);
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

export function handlePausedSet(event: PausedSetEvent): void {
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

export function handleModuleAttached(event: ModuleAttachedEvent): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;

  const id = moduleId(event.address, event.params.moduleType);
  let module = Module.load(id);
  if (module == null) {
    module = new Module(id);
    module.campaign = event.address;
    module.moduleType = event.params.moduleType;
    module.attachedAt = event.block.timestamp;
    module.attachedAtTx = event.transaction.hash;
  }
  module.kind = event.params.kind;
  module.impl = event.params.impl;
  module.metadataURI = event.params.metadataURI;
  module.enabled = true;
  module.detachedAt = null;
  module.detachedAtTx = null;
  module.save();
}

export function handleModuleDetached(event: ModuleDetachedEvent): void {
  const id = moduleId(event.address, event.params.moduleType);
  const module = Module.load(id);
  if (module == null) return;
  module.impl = event.params.previousImpl;
  module.enabled = false;
  module.detachedAt = event.block.timestamp;
  module.detachedAtTx = event.transaction.hash;
  module.save();
}

export function handleModuleEnabledSet(event: ModuleEnabledSetEvent): void {
  const id = moduleId(event.address, event.params.moduleType);
  const module = Module.load(id);
  if (module == null) return;
  module.enabled = event.params.enabled;
  module.save();
}

export function handleRepaymentInitialized(
  event: RepaymentInitializedEvent,
): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;

  const pool = loadOrCreateRepaymentPool(event.address, event.block.timestamp);
  pool.initialized = true;
  pool.bonusPerCt = event.params.initialBonusPerCt;
  pool.initializedAt = event.block.timestamp;
  pool.lastUpdatedAt = event.block.timestamp;
  pool.save();
}

export function handleRepaymentPoolFunded(
  event: RepaymentPoolFundedEvent,
): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;

  const pool = loadOrCreateRepaymentPool(event.address, event.block.timestamp);
  pool.poolBalance = event.params.newPoolBalance;
  pool.totalFunded = pool.totalFunded.plus(event.params.amount);
  pool.lastUpdatedAt = event.block.timestamp;
  pool.save();
}

export function handleRepaymentPoolCredited(
  event: RepaymentPoolCreditedEvent,
): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;

  const pool = loadOrCreateRepaymentPool(event.address, event.block.timestamp);
  pool.poolBalance = event.params.newPoolBalance;
  pool.totalCredited = pool.totalCredited.plus(event.params.amount);
  pool.lastUpdatedAt = event.block.timestamp;
  pool.save();
}

export function handleRepaymentPoolWithdrawn(
  event: RepaymentPoolWithdrawnEvent,
): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;

  const pool = loadOrCreateRepaymentPool(event.address, event.block.timestamp);
  pool.poolBalance = event.params.newPoolBalance;
  pool.totalWithdrawn = pool.totalWithdrawn.plus(event.params.amount);
  pool.lastUpdatedAt = event.block.timestamp;
  pool.save();
}

export function handleRepaymentBonusSet(event: RepaymentBonusSetEvent): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;

  const pool = loadOrCreateRepaymentPool(event.address, event.block.timestamp);
  pool.bonusPerCt = event.params.newBonusPerCt;
  pool.lastUpdatedAt = event.block.timestamp;
  pool.save();
}

export function handleRepaid(event: RepaidEvent): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;

  const grossPaid = event.params.principalPaid.plus(event.params.bonusPaid);
  const protocolFee = grossPaid
    .times(REPAYMENT_PROTOCOL_FEE_BPS)
    .div(BPS_DENOMINATOR);
  const netPaid = grossPaid.minus(protocolFee);

  const repayment = new Repayment(eventId(event.transaction.hash, event.logIndex));
  repayment.campaign = event.address;
  repayment.holder = event.params.holder;
  repayment.campaignTokensBurned = event.params.campaignTokensBurned;
  repayment.principalPaid = event.params.principalPaid;
  repayment.bonusPaid = event.params.bonusPaid;
  repayment.protocolFee = protocolFee;
  repayment.totalPaid = grossPaid;
  repayment.netPaid = netPaid;
  repayment.newPoolBalance = event.params.newPoolBalance;
  repayment.timestamp = event.block.timestamp;
  repayment.block = event.block.number;
  repayment.transactionHash = event.transaction.hash;
  repayment.save();

  const pool = loadOrCreateRepaymentPool(event.address, event.block.timestamp);
  pool.poolBalance = event.params.newPoolBalance;
  pool.totalRedeemed = pool.totalRedeemed.plus(netPaid);
  pool.totalProtocolFees = pool.totalProtocolFees.plus(protocolFee);
  pool.redeemCount = pool.redeemCount + 1;
  pool.lastUpdatedAt = event.block.timestamp;
  pool.save();

  campaign.currentSupply = campaign.currentSupply.minus(
    event.params.campaignTokensBurned,
  );
  campaign.save();
}

export function handleEcommerceInitialized(
  event: EcommerceInitializedEvent,
): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;

  const storeEntity = loadOrCreateEcommerceStore(
    event.address,
    event.block.timestamp,
  );
  storeEntity.initialized = true;
  storeEntity.protocolFeeBps = event.params.protocolFeeBps;
  storeEntity.repaymentAllocationBps = event.params.repaymentAllocationBps;
  storeEntity.catalogURI = event.params.catalogURI;
  storeEntity.initializedAt = event.block.timestamp;
  storeEntity.lastUpdatedAt = event.block.timestamp;
  storeEntity.save();
}

export function handleEcommerceCatalogURISet(
  event: EcommerceCatalogURISetEvent,
): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;

  const storeEntity = loadOrCreateEcommerceStore(
    event.address,
    event.block.timestamp,
  );
  storeEntity.catalogURI = event.params.newCatalogURI;
  storeEntity.lastUpdatedAt = event.block.timestamp;
  storeEntity.save();
}

export function handleEcommerceProtocolFeeSet(
  event: EcommerceProtocolFeeSetEvent,
): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;

  const storeEntity = loadOrCreateEcommerceStore(
    event.address,
    event.block.timestamp,
  );
  storeEntity.protocolFeeBps = event.params.newFeeBps;
  storeEntity.lastUpdatedAt = event.block.timestamp;
  storeEntity.save();
}

export function handleEcommerceRepaymentAllocationSet(
  event: EcommerceRepaymentAllocationSetEvent,
): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;

  const storeEntity = loadOrCreateEcommerceStore(
    event.address,
    event.block.timestamp,
  );
  storeEntity.repaymentAllocationBps = event.params.newBps;
  storeEntity.lastUpdatedAt = event.block.timestamp;
  storeEntity.save();
}

export function handleEcommerceSkuSet(event: EcommerceSkuSetEvent): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;

  const id = skuEntityId(event.address, event.params.skuId);
  let sku = EcommerceSku.load(id);
  if (sku == null) {
    sku = new EcommerceSku(id);
    sku.campaign = event.address;
    sku.skuId = event.params.skuId;
    sku.sold = BigInt.zero();
  }
  sku.priceUsdc = event.params.priceUsdc;
  sku.inventory = event.params.inventory;
  sku.active = event.params.active;
  sku.updatedAt = event.block.timestamp;
  sku.save();
}

export function handleEcommerceSkuActiveSet(
  event: EcommerceSkuActiveSetEvent,
): void {
  const id = skuEntityId(event.address, event.params.skuId);
  const sku = EcommerceSku.load(id);
  if (sku == null) return;
  sku.active = event.params.active;
  sku.updatedAt = event.block.timestamp;
  sku.save();
}

export function handleEcommerceOrderPlaced(
  event: EcommerceOrderPlacedEvent,
): void {
  const campaign = Campaign.load(event.address);
  if (campaign == null) return;

  const order = new EcommerceOrder(eventId(event.transaction.hash, event.logIndex));
  order.campaign = event.address;
  order.orderId = event.params.orderId;
  order.buyer = event.params.buyer;
  order.skuId = event.params.skuId;
  order.quantity = event.params.quantity;
  order.grossPaid = event.params.grossPaid;
  order.protocolFee = event.params.protocolFee;
  order.repaymentAllocated = event.params.repaymentAllocated;
  order.producerNet = event.params.producerNet;
  order.orderHash = event.params.orderHash;
  order.timestamp = event.block.timestamp;
  order.block = event.block.number;
  order.transactionHash = event.transaction.hash;
  order.save();

  const storeEntity = loadOrCreateEcommerceStore(
    event.address,
    event.block.timestamp,
  );
  storeEntity.grossSales = storeEntity.grossSales.plus(event.params.grossPaid);
  storeEntity.protocolFees = storeEntity.protocolFees.plus(
    event.params.protocolFee,
  );
  storeEntity.repaymentAllocated = storeEntity.repaymentAllocated.plus(
    event.params.repaymentAllocated,
  );
  storeEntity.orderCount = storeEntity.orderCount + 1;
  storeEntity.lastUpdatedAt = event.block.timestamp;
  storeEntity.save();

  const sku = EcommerceSku.load(skuEntityId(event.address, event.params.skuId));
  if (sku != null) {
    if (sku.inventory.ge(event.params.quantity)) {
      sku.inventory = sku.inventory.minus(event.params.quantity);
    } else {
      sku.inventory = BigInt.zero();
    }
    sku.sold = sku.sold.plus(event.params.quantity);
    sku.updatedAt = event.block.timestamp;
    sku.save();
  }
}
