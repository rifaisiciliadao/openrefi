"use client";

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
  firstHarvestYear,
  coverageHarvests,
  maxCap18,
  pricePerToken18,
  collateralLocked6,
  collateralDrawn6,
}: {
  annualHarvestUsd18: bigint;
  firstHarvestYear: bigint;
  coverageHarvests: bigint;
  maxCap18: bigint;
  pricePerToken18: bigint;
  collateralLocked6: bigint;
  collateralDrawn6: bigint;
}) {
  const annual = Number(annualHarvestUsd18) / 1e18;
  const firstYear = Number(firstHarvestYear);
  const coverage = Number(coverageHarvests);
  const maxRaise =
    (Number(maxCap18) / 1e18) * (Number(pricePerToken18) / 1e18);

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

  return (
    <div className="bg-surface-container-lowest rounded-2xl p-6 border border-outline-variant/15 space-y-5">
      <h3 className="text-sm font-semibold text-on-surface">
        Producer commitment
      </h3>

      <div className="grid grid-cols-2 gap-3">
        <Tile label="Annual harvest" value={annual > 0 ? `${fmt$(annual)}/yr` : "—"} />
        <Tile label="Implied yield" value={impliedYieldPct > 0 ? `${impliedYieldPct.toFixed(impliedYieldPct < 1 ? 2 : 1)}%/yr` : "—"} />
        <Tile
          label="First harvest"
          value={firstYear > 0 ? String(firstYear) : "—"}
        />
        <Tile
          label="Payback"
          value={
            harvestsToRepay !== null && paybackEnd !== null
              ? `${harvestsToRepay} yrs (→ ${paybackEnd})`
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

        <div className="h-2 rounded-full bg-surface-container-high overflow-hidden flex">
          <div
            className="bg-primary"
            style={{ width: `${guaranteeRatio * 100}%` }}
          />
        </div>
        <p className="text-[11px] text-on-surface-variant">
          {coverage > 0 && coverageEnd !== null ? (
            <>
              Producer pre-funded harvests <b>{firstYear}–{coverageEnd}</b> with
              USDC collateral.{" "}
              {tail !== null && tail > 0 && paybackEnd !== null && (
                <>
                  Tail of <b>{tail}</b>{" "}
                  {tail === 1 ? "year" : "years"} ({coverageEnd + 1}–{paybackEnd}) carries
                  normal delivery risk.
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
