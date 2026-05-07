"use client";

import { useReadContracts } from "wagmi";
import { formatUnits, type Address } from "viem";
import { useTranslations } from "next-intl";
import { abis, getAddresses } from "@/contracts";
import { DirectBuyGrowPanel } from "@/components/DirectBuyGrowPanel";
import { EscrowClaimPanel } from "@/components/EscrowClaimPanel";
import { GrowStakingPanel } from "@/components/GrowStakingPanel";
import { Flywheel } from "@/components/grow/Flywheel";

const treasuryAbi = abis.GrowTreasury as never;
const tokenAbi = abis.GrowToken as never;

export default function GrowDashboard() {
  const t = useTranslations("grow");
  const a = getAddresses();
  const enabled = Boolean(a.growToken && a.growTreasury);

  const { data: reads } = useReadContracts({
    query: { enabled, refetchInterval: 15_000 },
    contracts: [
      {
        abi: treasuryAbi,
        address: a.growTreasury as Address,
        functionName: "intrinsicFloorPrice",
      },
      {
        abi: tokenAbi,
        address: a.growToken as Address,
        functionName: "totalSupply",
      },
      {
        abi: tokenAbi,
        address: a.growToken as Address,
        functionName: "balanceOf",
        args: [a.growTreasury as Address],
      },
    ],
  });

  const floor = (reads?.[0]?.result as bigint | undefined) ?? 0n;
  const totalSupply = (reads?.[1]?.result as bigint | undefined) ?? 0n;
  const treasuryGrow = (reads?.[2]?.result as bigint | undefined) ?? 0n;
  const circulating = totalSupply > treasuryGrow ? totalSupply - treasuryGrow : 0n;

  return (
    <div className="mx-auto max-w-6xl px-4 pb-20 pt-28 md:px-8">
      <header className="mb-8">
        <h1 className="text-3xl font-bold tracking-tight text-zinc-900 md:text-4xl">
          {t("title")}
        </h1>
        <p className="mt-2 max-w-2xl text-sm text-zinc-600 md:text-base">
          {t("subtitle")}
        </p>
      </header>

      {/* Stats strip — Floor / Circulating, plus Treasury holds when > 0.
          Sale price lives inside the Buy GROW panel since it's a function of
          the markup. Treasury holds is hidden when zero (would always be zero
          in v1 outside of buybacks; surfacing a permanent "0" is just noise). */}
      <section
        className={`mb-10 grid grid-cols-1 gap-4 ${
          treasuryGrow > 0n ? "md:grid-cols-3" : "md:grid-cols-2"
        }`}
      >
        <Stat
          label={t("floorPrice")}
          value={
            floor === 0n
              ? "—"
              : `$${Number(formatUnits(floor, 18)).toFixed(4)}`
          }
          hint={t("floorHint")}
        />
        <Stat
          label={t("circulating")}
          value={Number(formatUnits(circulating, 18)).toFixed(0)}
          hint={t("circulatingHint", {
            total: Number(formatUnits(totalSupply, 18)).toFixed(0),
          })}
        />
        {treasuryGrow > 0n && (
          <Stat
            label={t("treasuryHolds")}
            value={Number(formatUnits(treasuryGrow, 18)).toFixed(0)}
            hint={t("treasuryHoldsHint")}
          />
        )}
      </section>

      <section className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <DirectBuyGrowPanel />
        <GrowStakingPanel />
        <div className="lg:col-span-2">
          <EscrowClaimPanel />
        </div>
      </section>

      <Flywheel />
    </div>
  );
}

function Stat({
  label,
  value,
  hint,
}: {
  label: string;
  value: string;
  hint?: string;
}) {
  return (
    <div className="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
      <div className="text-xs uppercase tracking-wide text-zinc-500">{label}</div>
      <div className="mt-1 font-mono text-2xl text-zinc-900">{value}</div>
      {hint && <div className="mt-1 text-[11px] text-zinc-500">{hint}</div>}
    </div>
  );
}
