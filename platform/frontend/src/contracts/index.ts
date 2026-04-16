import CampaignFactoryAbi from "./abis/CampaignFactory.json";
import CampaignAbi from "./abis/Campaign.json";
import CampaignTokenAbi from "./abis/CampaignToken.json";
import StakingVaultAbi from "./abis/StakingVault.json";
import YieldTokenAbi from "./abis/YieldToken.json";
import HarvestManagerAbi from "./abis/HarvestManager.json";
import type { Address } from "viem";

export const abis = {
  CampaignFactory: CampaignFactoryAbi,
  Campaign: CampaignAbi,
  CampaignToken: CampaignTokenAbi,
  StakingVault: StakingVaultAbi,
  YieldToken: YieldTokenAbi,
  HarvestManager: HarvestManagerAbi,
} as const;

export const CHAIN_ID = Number(
  process.env.NEXT_PUBLIC_CHAIN_ID || 421614,
);

export const addresses: Record<number, { factory: Address; usdc: Address }> = {
  // Arbitrum Sepolia
  421614: {
    factory:
      (process.env.NEXT_PUBLIC_FACTORY_ADDRESS as Address) ||
      "0x0000000000000000000000000000000000000000",
    usdc:
      (process.env.NEXT_PUBLIC_USDC_ADDRESS as Address) ||
      "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
  },
  // Arbitrum One
  42161: {
    factory:
      (process.env.NEXT_PUBLIC_FACTORY_ADDRESS as Address) ||
      "0x0000000000000000000000000000000000000000",
    usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
  },
};

export function getAddresses(chainId: number = CHAIN_ID) {
  return addresses[chainId] || addresses[421614];
}
