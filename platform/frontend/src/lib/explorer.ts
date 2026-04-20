import { baseSepolia, base } from "wagmi/chains";

const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? baseSepolia.id);

const EXPLORERS: Record<number, string> = {
  [baseSepolia.id]: "https://sepolia.basescan.org",
  [base.id]: "https://basescan.org",
};

export function explorerBase(chainId: number = CHAIN_ID): string {
  return EXPLORERS[chainId] ?? EXPLORERS[baseSepolia.id];
}

export function txUrl(hash: string, chainId: number = CHAIN_ID): string {
  return `${explorerBase(chainId)}/tx/${hash}`;
}

export function addressUrl(address: string, chainId: number = CHAIN_ID): string {
  return `${explorerBase(chainId)}/address/${address}`;
}
