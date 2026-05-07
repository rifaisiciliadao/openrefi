"use client";

import { useMemo, useState } from "react";
import { useAccount, useReadContracts, useWriteContract } from "wagmi";
import { formatUnits, type Address } from "viem";
import Link from "next/link";
import { useTranslations } from "next-intl";
import { abis, getAddresses } from "@/contracts";
import { useSubgraphCampaigns } from "@/lib/subgraph";
import { Spinner } from "./Spinner";
import { useTxNotify } from "@/lib/useTxNotify";
import { waitForTx } from "@/lib/waitForTx";

const minterAbi = abis.GrowMinter as never;

type EscrowRow = {
  campaign: Address;
  campaignName: string;
  campaignState: "Funding" | "Active" | "Buyback" | "Ended";
  escrow: bigint;
  /** Minter status: 1 = Pending, 2 = Active (claimable), 3 = Failed (voided). */
  minterStatus: number;
};

/**
 * Lists the connected wallet's GROW escrow per tracked campaign.
 *
 * Three states surfaced per row:
 *   • Pending  — campaign hasn't reached soft cap yet. Waiting.
 *   • Active   — campaign reached soft cap. "Claim" button lights up.
 *   • Failed   — campaign expired below soft cap; escrow voided permanently.
 *
 * NOTE: This iterates over every campaign from the subgraph and reads
 * `Minter.getEscrow(campaign, user)`. Once the subgraph indexes the
 * `GrowEscrowed` event we can replace this with a direct user→escrow query
 * (faster, no per-campaign multicall).
 */
export function EscrowClaimPanel() {
  const t = useTranslations("grow.escrow");
  const { address: account, isConnected } = useAccount();
  const a = getAddresses();
  const notify = useTxNotify();
  const { writeContractAsync } = useWriteContract();
  const { data: campaigns } = useSubgraphCampaigns();

  const [claiming, setClaiming] = useState<Address | null>(null);

  const minterAddr = a.growMinter;
  const candidates = useMemo(
    () => (campaigns ?? []).map((c) => c.id as Address),
    [campaigns],
  );

  // Batch: for each campaign, read getEscrow(c, user) + campaignStates(c).status
  const { data: reads, refetch } = useReadContracts({
    query: {
      enabled: Boolean(minterAddr && account && candidates.length > 0),
      refetchInterval: 15_000,
    },
    contracts: candidates.flatMap((c) => [
      {
        abi: minterAbi,
        address: minterAddr as Address,
        functionName: "getEscrow",
        args: [c, account ?? "0x0"],
      },
      {
        abi: minterAbi,
        address: minterAddr as Address,
        functionName: "campaignStates",
        args: [c],
      },
    ]),
  });

  const rows: EscrowRow[] = useMemo(() => {
    if (!campaigns || !reads) return [];
    const out: EscrowRow[] = [];
    for (let i = 0; i < candidates.length; i++) {
      const escrow = reads[i * 2]?.result as bigint | undefined;
      if (!escrow || escrow === 0n) continue;
      const stateTuple = reads[i * 2 + 1]?.result as
        | [number, bigint, bigint, bigint]
        | undefined;
      const minterStatus = stateTuple?.[0] ?? 0;
      const camp = campaigns[i];
      out.push({
        campaign: candidates[i],
        campaignName: camp?.metadataURI ? "(see metadata)" : "Campaign",
        campaignState: (camp?.state as EscrowRow["campaignState"]) ?? "Funding",
        escrow,
        minterStatus,
      });
    }
    return out;
  }, [campaigns, reads, candidates]);

  async function handleClaim(campaign: Address) {
    if (!account || !minterAddr) return;
    try {
      setClaiming(campaign);
      const hash = await writeContractAsync({
        abi: minterAbi,
        address: minterAddr as Address,
        functionName: "claimEscrow",
        args: [campaign],
      });
      await waitForTx(hash);
      notify.success("GROW escrow claimed", hash);
      refetch();
    } catch (err) {
      const message =
        (err as Error).message?.split("\n")[0] ?? "Transaction failed";
      if (!/user (rejected|denied)/i.test(message)) {
        notify.error("Claim failed", message);
      }
    } finally {
      setClaiming(null);
    }
  }

  if (!minterAddr) {
    return (
      <div className="rounded-lg border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">
        {t("notDeployed")}
      </div>
    );
  }

  return (
    <div className="rounded-xl border border-zinc-200 bg-white p-6 shadow-sm">
      <h2 className="mb-1 text-xl font-semibold text-zinc-900">{t("title")}</h2>
      <p className="mb-4 text-sm text-zinc-500">{t("blurb")}</p>

      {!isConnected ? (
        <div className="rounded-lg border border-zinc-200 bg-zinc-50 p-4 text-sm text-zinc-600">
          {t("connectPrompt")}
        </div>
      ) : rows.length === 0 ? (
        <div className="rounded-lg border border-zinc-200 bg-zinc-50 p-4 text-sm text-zinc-600">
          {t("empty")}
        </div>
      ) : (
        <ul className="divide-y divide-zinc-200">
          {rows.map((row) => {
            const isClaimable = row.minterStatus === 2;
            const isFailed = row.minterStatus === 3;
            return (
              <li key={row.campaign} className="flex items-center gap-3 py-3">
                <div className="min-w-0 flex-1">
                  <Link
                    href={`/campaign/${row.campaign}`}
                    className="block truncate text-sm font-medium text-zinc-900 hover:text-emerald-700"
                  >
                    {row.campaign.slice(0, 6)}…{row.campaign.slice(-4)}
                  </Link>
                  <div className="text-xs text-zinc-500">
                    {t("campaign")}:{" "}
                    <span className="font-medium">{row.campaignState}</span>
                    {" · "}
                    {isClaimable
                      ? t("readyToClaim")
                      : isFailed
                        ? t("voided")
                        : t("pendingSoftcap")}
                  </div>
                </div>
                <div className="text-right">
                  <div className="font-mono text-sm text-zinc-900">
                    {Number(formatUnits(row.escrow, 18)).toFixed(4)}
                  </div>
                  <div className="text-[10px] uppercase tracking-wide text-zinc-500">
                    $GROW
                  </div>
                </div>
                <button
                  type="button"
                  onClick={() => handleClaim(row.campaign)}
                  disabled={!isClaimable || claiming !== null}
                  className="flex w-24 items-center justify-center gap-1 rounded-lg bg-emerald-600 px-3 py-2 text-xs font-semibold text-white transition hover:bg-emerald-700 disabled:cursor-not-allowed disabled:bg-zinc-300"
                >
                  {claiming === row.campaign ? (
                    <Spinner />
                  ) : isFailed ? (
                    t("voidedShort")
                  ) : isClaimable ? (
                    t("claim")
                  ) : (
                    t("pending")
                  )}
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
