"use client";

import { useReadContract, useReadContracts } from "wagmi";
import type { Address } from "viem";
import { abis, getAddresses } from "./index";

const factoryAbi = abis.CampaignFactory as never;
const campaignAbi = abis.Campaign as never;
const stakingAbi = abis.StakingVault as never;

/**
 * Returns array of all deployed campaign addresses
 */
export function useCampaignsList() {
  const { factory } = getAddresses();

  return useReadContract({
    address: factory,
    abi: factoryAbi,
    functionName: "getCampaigns",
    query: {
      enabled:
        factory !== "0x0000000000000000000000000000000000000000",
    },
  }) as { data: Address[] | undefined; isLoading: boolean; error: Error | null };
}

export interface CampaignSummary {
  address: Address;
  producer: Address;
  pricePerToken: bigint;
  minCap: bigint;
  maxCap: bigint;
  currentSupply: bigint;
  fundingDeadline: bigint;
  state: number;
}

/**
 * Reads full state of a single Campaign contract.
 */
export function useCampaignData(address: Address | undefined) {
  return useReadContracts({
    contracts: address
      ? [
          { address, abi: campaignAbi, functionName: "producer" },
          { address, abi: campaignAbi, functionName: "pricePerToken" },
          { address, abi: campaignAbi, functionName: "minCap" },
          { address, abi: campaignAbi, functionName: "maxCap" },
          { address, abi: campaignAbi, functionName: "currentSupply" },
          { address, abi: campaignAbi, functionName: "fundingDeadline" },
          { address, abi: campaignAbi, functionName: "state" },
          { address, abi: campaignAbi, functionName: "campaignToken" },
          { address, abi: campaignAbi, functionName: "stakingVault" },
          { address, abi: campaignAbi, functionName: "harvestManager" },
        ]
      : [],
    query: { enabled: !!address },
  });
}

/**
 * Reads yield rate + totalStaked from StakingVault.
 */
export function useStakingData(vaultAddress: Address | undefined) {
  return useReadContracts({
    contracts: vaultAddress
      ? [
          { address: vaultAddress, abi: stakingAbi, functionName: "totalStaked" },
          { address: vaultAddress, abi: stakingAbi, functionName: "currentYieldRate" },
          { address: vaultAddress, abi: stakingAbi, functionName: "currentSeasonId" },
        ]
      : [],
    query: { enabled: !!vaultAddress },
  });
}

export const CampaignStates = ["Funding", "Active", "Buyback", "Ended"] as const;
