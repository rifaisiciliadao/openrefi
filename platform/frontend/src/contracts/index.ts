import CampaignFactoryAbi from "./abis/CampaignFactory.json";
import CampaignAbi from "./abis/Campaign.json";
import CampaignTokenAbi from "./abis/CampaignToken.json";
import StakingVaultAbi from "./abis/StakingVault.json";
import YieldTokenAbi from "./abis/YieldToken.json";
import HarvestManagerAbi from "./abis/HarvestManager.json";
import CampaignRegistryAbi from "./abis/CampaignRegistry.json";
import ProducerRegistryAbi from "./abis/ProducerRegistry.json";
import GrowTokenAbi from "./abis/GrowToken.json";
import GrowTreasuryAbi from "./abis/GrowTreasury.json";
import GrowMinterAbi from "./abis/GrowMinter.json";
import GrowFeeSplitterAbi from "./abis/GrowFeeSplitter.json";
import GrowStakingPoolAbi from "./abis/GrowStakingPool.json";
import type { Address } from "viem";

export const abis = {
  CampaignFactory: CampaignFactoryAbi,
  Campaign: CampaignAbi,
  CampaignToken: CampaignTokenAbi,
  StakingVault: StakingVaultAbi,
  YieldToken: YieldTokenAbi,
  HarvestManager: HarvestManagerAbi,
  CampaignRegistry: CampaignRegistryAbi,
  ProducerRegistry: ProducerRegistryAbi,
  GrowToken: GrowTokenAbi,
  GrowTreasury: GrowTreasuryAbi,
  GrowMinter: GrowMinterAbi,
  GrowFeeSplitter: GrowFeeSplitterAbi,
  GrowStakingPool: GrowStakingPoolAbi,
} as const;

export const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID || 84532);

type ChainAddresses = {
  factory: Address;
  usdc: Address;
  usdt?: Address;
  dai?: Address;
  registry: Address;
  producerRegistry: Address;
  growToken?: Address;
  growTreasury?: Address;
  growMinter?: Address;
  growFeeSplitter?: Address;
  growStakingPool?: Address;
};

const ZERO: Address = "0x0000000000000000000000000000000000000000";

export const addresses: Record<number, ChainAddresses> = {
  // Local anvil — every address comes from .env.local at boot
  31337: {
    factory: (process.env.NEXT_PUBLIC_FACTORY_ADDRESS as Address) || ZERO,
    usdc: (process.env.NEXT_PUBLIC_USDC_ADDRESS as Address) || ZERO,
    usdt: process.env.NEXT_PUBLIC_USDT_ADDRESS as Address | undefined,
    dai: process.env.NEXT_PUBLIC_DAI_ADDRESS as Address | undefined,
    registry: (process.env.NEXT_PUBLIC_REGISTRY_ADDRESS as Address) || ZERO,
    producerRegistry:
      (process.env.NEXT_PUBLIC_PRODUCER_REGISTRY_ADDRESS as Address) || ZERO,
    growToken: process.env.NEXT_PUBLIC_GROW_TOKEN as Address | undefined,
    growTreasury: process.env.NEXT_PUBLIC_GROW_TREASURY as Address | undefined,
    growMinter: process.env.NEXT_PUBLIC_GROW_MINTER as Address | undefined,
    growFeeSplitter:
      process.env.NEXT_PUBLIC_GROW_FEE_SPLITTER as Address | undefined,
    growStakingPool:
      process.env.NEXT_PUBLIC_GROW_STAKING_POOL as Address | undefined,
  },
  // Base Sepolia (live testnet deployment, see CONTRACTS.md)
  84532: {
    factory:
      (process.env.NEXT_PUBLIC_FACTORY_ADDRESS as Address) ||
      "0x3fA41528a22645Bef478E9eBae83981C02e98f74",
    usdc:
      (process.env.NEXT_PUBLIC_USDC_ADDRESS as Address) ||
      "0x32C344Dc9713d904442d0E5B0d2b7994E52B0d4E",
    usdt: process.env.NEXT_PUBLIC_USDT_ADDRESS as Address | undefined,
    dai: process.env.NEXT_PUBLIC_DAI_ADDRESS as Address | undefined,
    registry:
      (process.env.NEXT_PUBLIC_REGISTRY_ADDRESS as Address) ||
      "0xb0Ba4660b2D136BF087FA9bf0aec946f0a87597e",
    producerRegistry:
      (process.env.NEXT_PUBLIC_PRODUCER_REGISTRY_ADDRESS as Address) ||
      "0x702915469f66415C70b4203b40ab9A97203D979b",
    growToken: process.env.NEXT_PUBLIC_GROW_TOKEN as Address | undefined,
    growTreasury: process.env.NEXT_PUBLIC_GROW_TREASURY as Address | undefined,
    growMinter: process.env.NEXT_PUBLIC_GROW_MINTER as Address | undefined,
    growFeeSplitter:
      process.env.NEXT_PUBLIC_GROW_FEE_SPLITTER as Address | undefined,
    growStakingPool:
      process.env.NEXT_PUBLIC_GROW_STAKING_POOL as Address | undefined,
  },
  // Base Mainnet (future)
  8453: {
    factory:
      (process.env.NEXT_PUBLIC_FACTORY_ADDRESS as Address) || ZERO,
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    registry:
      (process.env.NEXT_PUBLIC_REGISTRY_ADDRESS as Address) || ZERO,
    producerRegistry:
      (process.env.NEXT_PUBLIC_PRODUCER_REGISTRY_ADDRESS as Address) || ZERO,
  },
};

export function getAddresses(chainId: number = CHAIN_ID) {
  return addresses[chainId] || addresses[84532];
}
