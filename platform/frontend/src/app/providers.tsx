"use client";

import { getDefaultConfig, RainbowKitProvider } from "@rainbow-me/rainbowkit";
import { WagmiProvider } from "wagmi";
import { base, baseSepolia, foundry } from "wagmi/chains";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fallback, http } from "viem";
import "@rainbow-me/rainbowkit/styles.css";
import { LocaleProvider } from "@/i18n/LocaleProvider";
import { ToastProvider } from "@/components/Toast";
import { InviteGateProvider } from "@/lib/inviteGate";

// Base Sepolia: the default `https://sepolia.base.org` RPC frequently returns
// "block not found" mid-call, which makes viem's simulateContract pre-check
// fail (seen on `activateCampaign`, `buy`, etc.). Fallback across a few
// independent public endpoints so one flaky RPC doesn't brick user tx flow.
// Each transport auto-retries 3x with 500ms backoff; `fallback` then rotates
// to the next if all retries still fail.
const baseSepoliaTransport = fallback(
  [
    http("https://sepolia.base.org", { retryCount: 3, retryDelay: 500, timeout: 10_000 }),
    http("https://base-sepolia-rpc.publicnode.com", { retryCount: 3, retryDelay: 500, timeout: 10_000 }),
    http("https://base-sepolia.blockpi.network/v1/rpc/public", { retryCount: 3, retryDelay: 500, timeout: 10_000 }),
  ],
  { rank: false, retryCount: 1 },
);

const baseTransport = fallback(
  [
    http("https://mainnet.base.org", { retryCount: 3, retryDelay: 500, timeout: 10_000 }),
    http("https://base-rpc.publicnode.com", { retryCount: 3, retryDelay: 500, timeout: 10_000 }),
  ],
  { rank: false, retryCount: 1 },
);

// Local anvil (chainId 31337) — only enabled when NEXT_PUBLIC_CHAIN_ID points at it.
// Keeps prod bundles lean; dev builds against 8545 just work.
const anvilTransport = http("http://127.0.0.1:8545", {
  retryCount: 1,
  retryDelay: 200,
  timeout: 5_000,
});

const isLocal = process.env.NEXT_PUBLIC_CHAIN_ID === "31337";

export const config = getDefaultConfig({
  appName: "GrowFi",
  projectId: process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID!,
  chains: isLocal ? [foundry, baseSepolia, base] : [baseSepolia, base],
  transports: {
    [baseSepolia.id]: baseSepoliaTransport,
    [base.id]: baseTransport,
    [foundry.id]: anvilTransport,
  },
  ssr: true,
});

const queryClient = new QueryClient();

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <LocaleProvider>
      <WagmiProvider config={config}>
        <QueryClientProvider client={queryClient}>
          <RainbowKitProvider>
            <ToastProvider>
              <InviteGateProvider>{children}</InviteGateProvider>
            </ToastProvider>
          </RainbowKitProvider>
        </QueryClientProvider>
      </WagmiProvider>
    </LocaleProvider>
  );
}
