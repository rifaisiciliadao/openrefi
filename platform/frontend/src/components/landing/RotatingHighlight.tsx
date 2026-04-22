"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";

const FADE_MS = 380;
const INTERVAL_MS = 2800;

export function RotatingHighlight({ count }: { count: number }) {
  const t = useTranslations("landing.hero");
  const [index, setIndex] = useState(0);
  const [visible, setVisible] = useState(true);

  useEffect(() => {
    if (count <= 1) return;
    const prefersReduced =
      typeof window !== "undefined" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (prefersReduced) return;

    const id = window.setInterval(() => {
      setVisible(false);
      window.setTimeout(() => {
        setIndex((i) => (i + 1) % count);
        setVisible(true);
      }, FADE_MS);
    }, INTERVAL_MS);
    return () => window.clearInterval(id);
  }, [count]);

  return (
    <span
      style={{
        fontFamily: "var(--font-accent)",
        fontWeight: 800,
        letterSpacing: "-0.01em",
        color: "#000000",
        display: "inline-block",
        transition: `opacity ${FADE_MS}ms ease`,
        opacity: visible ? 1 : 0,
      }}
    >
      {t(`examples.${index}`)}
    </span>
  );
}
