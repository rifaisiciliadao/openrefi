import { BigInt } from "@graphprotocol/graph-ts";
import {
  ProfileUpdated as ProfileUpdatedEvent,
  KycSet as KycSetEvent,
} from "../generated/ProducerRegistry/ProducerRegistry";
import { Producer } from "../generated/schema";

export function handleProfileUpdated(event: ProfileUpdatedEvent): void {
  let producer = Producer.load(event.params.producer);
  if (producer == null) {
    producer = new Producer(event.params.producer);
    producer.version = BigInt.zero();
    producer.kyced = false;
  }
  producer.profileURI = event.params.uri;
  producer.version = event.params.version;
  producer.updatedAt = event.block.timestamp;
  producer.save();
}

export function handleKycSet(event: KycSetEvent): void {
  let producer = Producer.load(event.params.producer);
  if (producer == null) {
    producer = new Producer(event.params.producer);
    producer.version = BigInt.zero();
  }
  producer.kyced = event.params.kyced;
  producer.kycSetAt = event.block.timestamp;
  producer.save();
}
