"use client";

import { useTranslations } from "next-intl";
import {
  normalizeProductSegment,
  parseProductType,
  titleizeProductSegment,
} from "./productUnit";

const LOCALIZED_ASSET_KEYS = new Set(["tree", "land", "ha", "plot", "vineyard"]);
const LOCALIZED_PRODUCT_KEYS = new Set([
  "olive",
  "olive-oil",
  "citrus",
  "grapes",
  "wine",
  "honey",
  "nuts",
  "other",
]);

export function useLocalizedProductDisplay() {
  const t = useTranslations("create.step1");

  const segmentLabel = (kind: "assets" | "products", value: string) => {
    const key = normalizeProductSegment(value);
    const known =
      kind === "assets"
        ? LOCALIZED_ASSET_KEYS.has(key)
        : LOCALIZED_PRODUCT_KEYS.has(key);

    return known ? t(`${kind}.${key}` as never) : titleizeProductSegment(value);
  };

  const assetProductLabel = (productType: string | undefined | null) => {
    const parsed = parseProductType(productType);
    const asset = parsed.assetType ? segmentLabel("assets", parsed.assetType) : "";
    const product = parsed.productType
      ? segmentLabel("products", parsed.productType)
      : "";

    return [asset, product].filter(Boolean).join(" · ");
  };

  return { assetProductLabel };
}
