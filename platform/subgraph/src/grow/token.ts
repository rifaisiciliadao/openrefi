import { Address, BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  Transfer as TransferEvent,
  DirectBuy as DirectBuyEvent,
  GenesisMinted as GenesisMintedEvent,
  SaleActiveSet as SaleActiveSetEvent,
  MarkupSet as MarkupSetEvent,
  ReferencePriceSet as ReferencePriceSetEvent,
  MinterUpdated as MinterUpdatedEvent,
  TreasuryUpdated as TreasuryUpdatedEvent,
  GrowfiToken as GrowfiTokenContract,
} from "../../generated/GrowfiToken/GrowfiToken";
import { GrowToken, GrowHolder, GrowDirectBuy } from "../../generated/schema";

const ZERO = BigInt.zero();

function loadOrCreateGrowToken(addr: Address): GrowToken {
  const id = Bytes.fromHexString(addr.toHexString()) as Bytes;
  let t = GrowToken.load(id);
  if (t == null) {
    t = new GrowToken(id);
    t.totalSupply = ZERO;
    t.treasuryHolds = ZERO;
    t.circulatingSupply = ZERO;
    t.saleActive = true;
    t.markupBps = ZERO;
    t.referencePrice = ZERO;
    t.effectiveFloorPrice = ZERO;
    t.totalDirectBuys = ZERO;
    t.totalDirectBuyVolumeUsd = ZERO;
  }
  return t as GrowToken;
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

export function handleGrowTransfer(event: TransferEvent): void {
  const tokenState = loadOrCreateGrowToken(event.address);

  // Mint: from = address(0). Burn: to = address(0). Otherwise: transfer.
  const ZERO_ADDR = Address.zero();
  const fromIsZero = event.params.from.equals(ZERO_ADDR);
  const toIsZero = event.params.to.equals(ZERO_ADDR);

  if (fromIsZero) {
    tokenState.totalSupply = tokenState.totalSupply.plus(event.params.value);
  } else {
    const fromHolder = loadOrCreateHolder(event.params.from, event.block.timestamp);
    fromHolder.balance = fromHolder.balance.minus(event.params.value);
    if (toIsZero) {
      fromHolder.totalRedeemed = fromHolder.totalRedeemed.plus(event.params.value);
    }
    fromHolder.save();
  }

  if (toIsZero) {
    tokenState.totalSupply = tokenState.totalSupply.minus(event.params.value);
  } else {
    const toHolder = loadOrCreateHolder(event.params.to, event.block.timestamp);
    toHolder.balance = toHolder.balance.plus(event.params.value);
    toHolder.save();
  }

  // Recompute circulating using on-chain treasury reference if available.
  const tokenContract = GrowfiTokenContract.bind(event.address);
  const treasuryRef = tokenContract.try_treasury();
  if (!treasuryRef.reverted && !treasuryRef.value.equals(ZERO_ADDR)) {
    const balCall = tokenContract.try_balanceOf(treasuryRef.value);
    if (!balCall.reverted) {
      tokenState.treasuryHolds = balCall.value;
    }
  }
  tokenState.circulatingSupply =
    tokenState.totalSupply.gt(tokenState.treasuryHolds)
      ? tokenState.totalSupply.minus(tokenState.treasuryHolds)
      : ZERO;

  tokenState.save();
}

export function handleDirectBuy(event: DirectBuyEvent): void {
  const id = Bytes.fromHexString(event.transaction.hash.toHexString()).concat(
    Bytes.fromI32(event.logIndex.toI32())
  );
  const buy = new GrowDirectBuy(id);
  buy.buyer = Bytes.fromHexString(event.params.buyer.toHexString()) as Bytes;
  buy.paymentToken = event.params.paymentToken;
  buy.paymentAmount = event.params.paymentAmount;
  buy.growOut = event.params.growOut;
  buy.effectivePrice = event.params.effectivePrice;
  buy.timestamp = event.block.timestamp;
  buy.block = event.block.number;
  buy.transactionHash = event.transaction.hash;
  buy.save();

  const buyer = loadOrCreateHolder(event.params.buyer, event.block.timestamp);
  buyer.totalEarnedFromBuys = buyer.totalEarnedFromBuys.plus(event.params.growOut);
  buyer.save();

  const tokenState = loadOrCreateGrowToken(event.address);
  tokenState.totalDirectBuys = tokenState.totalDirectBuys.plus(BigInt.fromI32(1));
  // Note: paymentAmount is in payment-token native decimals; not normalized to USD-18 here.
  tokenState.totalDirectBuyVolumeUsd = tokenState.totalDirectBuyVolumeUsd.plus(event.params.paymentAmount);
  tokenState.effectiveFloorPrice = event.params.effectivePrice;
  tokenState.save();
}

export function handleGenesisMinted(event: GenesisMintedEvent): void {
  // The Transfer handler will already mint the supply; this handler just stamps the holder.
  const h = loadOrCreateHolder(event.params.recipient, event.block.timestamp);
  h.save();
}

export function handleSaleActiveSet(event: SaleActiveSetEvent): void {
  const t = loadOrCreateGrowToken(event.address);
  t.saleActive = event.params.active;
  t.save();
}

export function handleMarkupSet(event: MarkupSetEvent): void {
  const t = loadOrCreateGrowToken(event.address);
  t.markupBps = event.params.markupBps;
  t.save();
}

export function handleReferencePriceSet(event: ReferencePriceSetEvent): void {
  const t = loadOrCreateGrowToken(event.address);
  t.referencePrice = event.params.newPrice;
  t.save();
}

export function handleMinterUpdated(event: MinterUpdatedEvent): void {
  // Record-only; no entity field tracks the minter directly. Could add if needed.
}

export function handleTokenTreasuryUpdated(event: TreasuryUpdatedEvent): void {
  // Recompute treasuryHolds on the next Transfer. Nothing to do here directly.
}
