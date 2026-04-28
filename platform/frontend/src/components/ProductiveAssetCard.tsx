"use client";

import { useState, useMemo } from "react";

/**
 * ProductiveAssetCard — surfaces the v3 commitments + a small ROI calculator.
 *
 * The numbers come from the on-chain immutable fields the producer set at
 * `createCampaign`:
 *   - `expectedYearlyReturnBps` (e.g. 1000 = 10%/year)
 *   - `expectedFirstYearHarvest` (product units)
 *   - `coverageHarvests` (number of pre-funded harvests)
 *   - plus mutable `collateralLocked` / `collateralDrawn` (USDC, 6-dec)
 *
 * Derived figures:
 *   - harvestsToRepay = ceil(10_000 / yearlyBps)
 *   - tail            = max(0, harvestsToRepay - coverage)
 *   - guaranteeRatio  = coverage / harvestsToRepay     (0..1)
 *   - collateralFree  = collateralLocked - collateralDrawn
 *
 * The ROI input is a plain client-side projection: invested * yearlyBps/10000
 * per year, scaled by the user-entered USDC amount.
 */
export function ProductiveAssetCard({
  yearlyReturnBps,
  firstYearHarvest18,
  coverageHarvests,
  collateralLocked6,
  collateralDrawn6,
  productSymbol,
}: {
  yearlyReturnBps: bigint;
  firstYearHarvest18: bigint;
  coverageHarvests: bigint;
  collateralLocked6: bigint;
  collateralDrawn6: bigint;
  productSymbol: string;
}) {
  const yearlyPct = Number(yearlyReturnBps) / 100;
  const harvestsToRepay = yearlyReturnBps > 0n
    ? Math.ceil(10_000 / Number(yearlyReturnBps))
    : null;
  const coverage = Number(coverageHarvests);
  const tail = harvestsToRepay !== null ? Math.max(0, harvestsToRepay - coverage) : null;
  const guaranteeRatio =
    harvestsToRepay !== null && harvestsToRepay > 0
      ? Math.min(1, coverage / harvestsToRepay)
      : 0;

  const lockedNum = Number(collateralLocked6) / 1e6;
  const drawnNum = Number(collateralDrawn6) / 1e6;
  const freeNum = Math.max(0, lockedNum - drawnNum);
  const firstYearHarvestNum = Number(firstYearHarvest18) / 1e18;

  const [investUsd, setInvestUsd] = useState("1000");
  const projection = useMemo(() => {
    const principal = Number(investUsd);
    if (!Number.isFinite(principal) || principal <= 0 || yearlyReturnBps === 0n)
      return null;
    const yearly = (principal * Number(yearlyReturnBps)) / 10_000;
    const horizon = harvestsToRepay ?? 1;
    const total = yearly * horizon;
    return { yearly, horizon, total };
  }, [investUsd, yearlyReturnBps, harvestsToRepay]);

  if (yearlyReturnBps === 0n && firstYearHarvest18 === 0n && coverageHarvests === 0n) {
    return null; // pre-v3 campaign — no commitments published
  }

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-6 border border-outline-variant/15 space-y-5">
      <h3 className="text-sm font-semibold text-on-surface">
        Producer commitment
      </h3>

      <div className="grid grid-cols-3 gap-3">
        <Tile
          label="Yearly return"
          value={yearlyPct > 0 ? `${yearlyPct.toFixed(yearlyPct % 1 === 0 ? 0 : 1)}%` : "—"}
        />
        <Tile
          label="Payback"
          value={harvestsToRepay !== null ? `${harvestsToRepay} harvests` : "—"}
        />
        <Tile
          label="Year-1 harvest"
          value={
            firstYearHarvestNum > 0
              ? `${firstYearHarvestNum.toLocaleString(undefined, {
                  maximumFractionDigits: 0,
                })} ${productSymbol}`
              : "—"
          }
        />
      </div>

      {/* Collateral + risk band */}
      <div className="rounded-xl border border-outline-variant/15 p-4 space-y-3">
        <div className="flex items-baseline justify-between">
          <span className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
            Coverage
          </span>
          <span className="text-sm font-bold text-on-surface">
            {coverage} / {harvestsToRepay ?? "—"} harvests
          </span>
        </div>

        {/* Bar: green = covered, neutral = uncovered tail */}
        <div className="h-2 rounded-full bg-surface-container-high overflow-hidden flex">
          <div
            className="bg-primary"
            style={{ width: `${guaranteeRatio * 100}%` }}
          />
        </div>
        <p className="text-[11px] text-on-surface-variant">
          {coverage > 0 ? (
            <>
              Producer pre-funded the first <b>{coverage}</b> harvests with
              USDC collateral. {tail !== null && tail > 0 && (
                <>
                  Remaining tail of <b>{tail}</b>{" "}
                  {tail === 1 ? "harvest" : "harvests"} carries normal delivery
                  risk.
                </>
              )}
            </>
          ) : (
            <>
              Producer published targets but did not pre-fund any harvest.
              Holders carry the full delivery risk.
            </>
          )}
        </p>

        {lockedNum > 0 && (
          <div className="grid grid-cols-3 gap-3 pt-3 border-t border-outline-variant/10">
            <Tile
              label="Locked"
              value={`$${lockedNum.toLocaleString(undefined, { maximumFractionDigits: 2 })}`}
              compact
            />
            <Tile
              label="Drawn"
              value={`$${drawnNum.toLocaleString(undefined, { maximumFractionDigits: 2 })}`}
              compact
            />
            <Tile
              label="Free"
              value={`$${freeNum.toLocaleString(undefined, { maximumFractionDigits: 2 })}`}
              compact
            />
          </div>
        )}
      </div>

      {/* ROI calculator */}
      {yearlyReturnBps > 0n && (
        <div className="rounded-xl border border-outline-variant/15 p-4 space-y-3">
          <span className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant block">
            ROI calculator
          </span>
          <label className="block">
            <span className="text-[11px] text-on-surface-variant">If you invest…</span>
            <div className="relative mt-1">
              <span className="absolute left-3 top-1/2 -translate-y-1/2 text-sm text-on-surface-variant">
                $
              </span>
              <input
                type="number"
                min="0"
                step="100"
                value={investUsd}
                onChange={(e) => setInvestUsd(e.target.value)}
                className="input pl-7"
              />
            </div>
          </label>
          {projection !== null && (
            <div className="grid grid-cols-2 gap-3">
              <Tile
                label="Per-harvest yield"
                value={`$${projection.yearly.toLocaleString(undefined, { maximumFractionDigits: 2 })}`}
              />
              <Tile
                label={`After ${projection.horizon} harvests`}
                value={`$${projection.total.toLocaleString(undefined, { maximumFractionDigits: 0 })}`}
              />
            </div>
          )}
          <p className="text-[10px] text-on-surface-variant">
            Projection uses the producer's stated yearly return as the baseline.
            Actual yield depends on each season's reported harvest value.
          </p>
        </div>
      )}
    </div>
  );
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
