"use client";

import { useTranslations } from "next-intl";

/**
 * ProductiveAssetCard — surfaces the v3 producer commitments + collateral state.
 *
 * On-chain primitives (passed in from the page):
 *   - `annualHarvestUsd18`   : USD/yr commitment, 18-dec.
 *   - `firstHarvestYear`     : calendar year of harvest 1 (e.g. 2027).
 *   - `coverageHarvests`     : N pre-funded harvests via lockCollateral.
 *   - `maxCap18` × `pricePerToken18` : maximum raise (USD), used to derive
 *     payback horizon and implied yield.
 *   - `collateralLocked6` / `collateralDrawn6` : USDC reserve state (6-dec).
 *
 * Derived in UI:
 *   - maxRaiseUsd        = maxCap × price                 (full-raise potential)
 *   - impliedYieldPct    = annual / maxRaiseUsd × 100
 *   - harvestsToRepay    = ⌈maxRaiseUsd / annual⌉         (years to recover principal)
 *   - paybackEndYear     = firstHarvestYear + harvestsToRepay - 1
 *   - coverageEndYear    = firstHarvestYear + coverageHarvests - 1 (when cov > 0)
 *
 * The producer commits an ABSOLUTE annual USD return (not a %) because each
 * agricultural product has its own price/unit dynamics — derivable from raise
 * size + commitment, not the other way around.
 */
export function ProductiveAssetCard({
  annualHarvestUsd18,
  annualHarvest18,
  productUnit,
  firstHarvestYear,
  coverageHarvests,
  maxCap18,
  pricePerToken18,
  collateralLocked6,
  collateralDrawn6,
}: {
  annualHarvestUsd18: bigint;
  annualHarvest18: bigint;
  productUnit: string;
  firstHarvestYear: bigint;
  coverageHarvests: bigint;
  maxCap18: bigint;
  pricePerToken18: bigint;
  collateralLocked6: bigint;
  collateralDrawn6: bigint;
}) {
  const t = useTranslations("detail.productiveAsset");
  const annual = Number(annualHarvestUsd18) / 1e18;
  const annualQty = Number(annualHarvest18) / 1e18;
  const firstYear = Number(firstHarvestYear);
  const coverage = Number(coverageHarvests);
  const maxRaise =
    (Number(maxCap18) / 1e18) * (Number(pricePerToken18) / 1e18);
  const pricePerUnit = annualQty > 0 ? annual / annualQty : null;

  const lockedNum = Number(collateralLocked6) / 1e6;
  const drawnNum = Number(collateralDrawn6) / 1e6;
  const freeNum = Math.max(0, lockedNum - drawnNum);

  if (annualHarvestUsd18 === 0n && firstHarvestYear === 0n && coverageHarvests === 0n) {
    return null; // pre-v3 campaign — no commitments published
  }

  const impliedYieldPct = maxRaise > 0 && annual > 0 ? (annual / maxRaise) * 100 : 0;
  const harvestsToRepay = annual > 0 && maxRaise > 0 ? Math.ceil(maxRaise / annual) : null;
  const paybackEnd = harvestsToRepay !== null && firstYear > 0 ? firstYear + harvestsToRepay - 1 : null;
  const coverageEnd = coverage > 0 && firstYear > 0 ? firstYear + coverage - 1 : null;
  const guaranteeRatio =
    harvestsToRepay !== null && harvestsToRepay > 0
      ? Math.min(1, coverage / harvestsToRepay)
      : 0;
  const tail = harvestsToRepay !== null ? Math.max(0, harvestsToRepay - coverage) : null;

  const fmt$ = (n: number) =>
    `$${n.toLocaleString(undefined, { maximumFractionDigits: 0 })}`;
  const unitLabel = localizeProductUnit(productUnit, t);
  const perYear = t("perYearShort");

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-6 border border-outline-variant/15 space-y-5">
      <h3 className="text-sm font-semibold text-on-surface">
        {t("title")}
      </h3>

      <div className="grid grid-cols-2 gap-3">
        <Tile
          label={t("annualHarvest")}
          value={
            annual > 0
              ? annualQty > 0
                ? `${fmt$(annual)}/${perYear} · ${annualQty.toLocaleString(undefined, { maximumFractionDigits: 0 })} ${unitLabel}/${perYear}`
                : `${fmt$(annual)}/${perYear}`
              : "—"
          }
        />
        <Tile
          label={t("impliedYield")}
          value={
            impliedYieldPct > 0
              ? `${impliedYieldPct.toFixed(impliedYieldPct < 1 ? 2 : 1)}%/${perYear}`
              : "—"
          }
        />
        <Tile
          label={t("firstHarvest")}
          value={firstYear > 0 ? String(firstYear) : "—"}
        />
        <Tile
          label={
            pricePerUnit !== null
              ? t("pricePerUnit", { unit: unitLabel })
              : t("payback")
          }
          value={
            pricePerUnit !== null
              ? `$${pricePerUnit.toLocaleString(undefined, { maximumFractionDigits: pricePerUnit < 10 ? 2 : 0 })}`
              : harvestsToRepay !== null && paybackEnd !== null
                ? t("paybackValue", {
                    count: harvestsToRepay,
                    year: paybackEnd,
                  })
                : "—"
          }
        />
      </div>

      {/* Collateral + risk band */}
      <div className="rounded-xl border border-outline-variant/15 p-4 space-y-3">
        <div className="flex items-baseline justify-between">
          <span className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            {t("coverage")}
          </span>
          <span className="text-sm font-bold text-on-surface">
            {t("coverageValue", {
              covered: coverage,
              total: harvestsToRepay ?? "—",
            })}
          </span>
        </div>

        <div className="h-2 rounded-full bg-surface-container-high overflow-hidden flex">
          <div
            className="bg-primary"
            style={{ width: `${guaranteeRatio * 100}%` }}
          />
        </div>
        <p className="text-[11px] text-on-surface-variant">
          {coverage > 0 && coverageEnd !== null ? (
            <>
              {t("prefunded", { start: firstYear, end: coverageEnd })}{" "}
              {tail !== null && tail > 0 && paybackEnd !== null && (
                <>
                  {t("tailRisk", {
                    count: tail,
                    start: coverageEnd + 1,
                    end: paybackEnd,
                  })}
                </>
              )}
            </>
          ) : (
            <>
              {t("noPrefund")}
            </>
          )}
        </p>

        {lockedNum > 0 && (
          <div className="grid grid-cols-3 gap-3 pt-3 border-t border-outline-variant/10">
            <Tile
              label={t("locked")}
              value={`$${lockedNum.toLocaleString(undefined, { maximumFractionDigits: 2 })}`}
              compact
            />
            <Tile
              label={t("drawn")}
              value={`$${drawnNum.toLocaleString(undefined, { maximumFractionDigits: 2 })}`}
              compact
            />
            <Tile
              label={t("free")}
              value={`$${freeNum.toLocaleString(undefined, { maximumFractionDigits: 2 })}`}
              compact
            />
          </div>
        )}
      </div>
    </div>
  );
}

function localizeProductUnit(
  unit: string,
  t: (key: "units.bottles" | "units.jars" | "units.units") => string,
) {
  if (unit === "bottles") return t("units.bottles");
  if (unit === "jars") return t("units.jars");
  if (unit === "units") return t("units.units");
  return unit;
}

function Tile({
  label,
  value,
  compact = false,
}: {
  label: string;
  value: string;
  compact?: boolean;
}) {
  return (
    <div>
      <div
        className={`text-[10px] font-semibold uppercase tracking-wider text-on-surface-variant ${
          compact ? "" : "mb-1"
        }`}
      >
        {label}
      </div>
      <div className={compact ? "text-sm font-bold text-on-surface" : "text-base font-bold text-on-surface"}>
        {value}
      </div>
    </div>
  );
}
