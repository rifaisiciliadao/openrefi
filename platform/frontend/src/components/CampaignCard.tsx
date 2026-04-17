"use client";

import Link from "next/link";
import { useTranslations } from "next-intl";
import { useCampaignMetadata } from "@/lib/metadata";

export type CampaignState = "funding" | "active" | "ended";

export interface CampaignCardProps {
  address: string;
  /** Fallback name if metadata isn't available (e.g. truncated address). */
  name: string;
  producer: string;
  location: string;
  /** Fallback image if metadata isn't available. */
  image: string;
  state: CampaignState;
  progress: number;
  yieldRate: number;
  deadline?: string;
  stakers?: number;
  /** Optional on-chain pointer to off-chain JSON (set via CampaignRegistry). */
  metadataURI?: string | null;
  metadataVersion?: string | number | null;
}

const stateConfig: Record<
  CampaignState,
  { bg: string; text: string; progressColor: string; yieldColor: string }
> = {
  funding: {
    bg: "bg-primary-fixed",
    text: "text-on-primary-fixed-variant",
    progressColor: "bg-primary",
    yieldColor: "text-primary",
  },
  active: {
    bg: "bg-secondary-container",
    text: "text-white",
    progressColor: "bg-secondary",
    yieldColor: "text-secondary",
  },
  ended: {
    bg: "bg-surface-variant",
    text: "text-on-surface-variant",
    progressColor: "bg-outline",
    yieldColor: "text-on-surface-variant",
  },
};

export function CampaignCard({
  address,
  name,
  image,
  state,
  progress,
  yieldRate,
  deadline,
  stakers,
  metadataURI,
  metadataVersion,
}: CampaignCardProps) {
  const t = useTranslations("home");
  const cfg = stateConfig[state];
  const isEnded = state === "ended";

  const { data: metadata } = useCampaignMetadata(metadataURI, metadataVersion);

  const resolvedName = metadata?.name || name;
  const resolvedImage = metadata?.image || image;
  const resolvedLocation = metadata?.location;

  return (
    <Link href={`/campaign/${address}`} className="block group">
      <div className="bg-surface-container-lowest rounded-2xl overflow-hidden border border-outline-variant/15 hover:-translate-y-1 transition-transform duration-300">
        <div className="h-48 bg-surface-container-low relative overflow-hidden">
          {isEnded && (
            <div className="absolute inset-0 bg-surface-variant/40 z-10 mix-blend-multiply" />
          )}
          <img
            src={resolvedImage}
            alt={resolvedName}
            className={`w-full h-full object-cover group-hover:scale-105 transition-transform duration-500 ${isEnded ? "grayscale" : ""}`}
          />
          <div
            className={`absolute top-4 left-4 ${cfg.bg} ${cfg.text} px-3 py-1 rounded-full text-xs font-semibold tracking-wide uppercase shadow-sm backdrop-blur-md ${isEnded ? "z-20" : ""}`}
          >
            {t(`state.${state}`)}
          </div>
        </div>

        <div className="p-6">
          <h3 className="font-semibold text-on-surface mb-1">{resolvedName}</h3>
          {resolvedLocation && (
            <p className="text-xs text-on-surface-variant mb-4">
              {resolvedLocation}
            </p>
          )}
          {!resolvedLocation && <div className="mb-4" />}

          <div className="space-y-4">
            <div>
              <div className="flex justify-between text-xs font-semibold tracking-wide text-on-surface-variant mb-2">
                <span>{t("card.progress")}</span>
                <span>{progress}%</span>
              </div>
              <div className="h-1 bg-surface-container-high rounded-full overflow-hidden">
                <div
                  className={`h-full ${cfg.progressColor} rounded-full transition-all duration-700`}
                  style={{ width: `${progress}%` }}
                />
              </div>
            </div>

            <div className="flex justify-between items-center pt-4 border-t border-outline-variant/15">
              <span className="text-xs font-semibold tracking-wide uppercase text-on-surface-variant">
                {isEnded ? t("card.status") : t("card.expectedYield")}
              </span>
              <span className={`font-bold ${cfg.yieldColor}`}>
                {isEnded ? t("card.completed") : `${yieldRate}x`}
              </span>
            </div>

            {!isEnded && (
              <div className="text-xs text-on-surface-variant">
                {state === "funding" &&
                  deadline &&
                  t("card.deadline", { days: deadline })}
                {state === "active" &&
                  stakers &&
                  t("card.season", { count: stakers })}
              </div>
            )}
          </div>
        </div>
      </div>
    </Link>
  );
}
