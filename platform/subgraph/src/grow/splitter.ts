import { Address, BigInt, Bytes } from "@graphprotocol/graph-ts";
import { Flushed as FlushedEvent } from "../../generated/GrowfiFeeSplitter/GrowfiFeeSplitter";
import { FeeFlush } from "../../generated/schema";

export function handleFlushed(event: FlushedEvent): void {
  const id = Bytes.fromHexString(event.transaction.hash.toHexString()).concat(
    Bytes.fromI32(event.logIndex.toI32())
  );
  const f = new FeeFlush(id);
  f.token = event.params.token;
  f.toTreasury = event.params.toTreasury;
  f.toOperations = event.params.toOperations;
  f.caller = event.transaction.from;
  f.timestamp = event.block.timestamp;
  f.block = event.block.number;
  f.transactionHash = event.transaction.hash;
  f.save();
}
