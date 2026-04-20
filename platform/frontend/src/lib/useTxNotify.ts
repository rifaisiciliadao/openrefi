"use client";

import { useCallback } from "react";
import { useToast } from "@/components/Toast";
import { txUrl } from "@/lib/explorer";

/**
 * Thin wrapper around the toast system that panels can call from their
 * imperative tx handlers. Centralises the "view on explorer" link shape
 * and the user-rejection filtering, so individual panels don't have to
 * care whether the error is a wallet rejection or a real revert.
 */
export function useTxNotify() {
  const toast = useToast();

  const success = useCallback(
    (title: string, hash?: `0x${string}`, message?: string) => {
      toast.push({
        kind: "success",
        title,
        message,
        action: hash
          ? { label: "View on BaseScan", href: txUrl(hash) }
          : undefined,
      });
    },
    [toast],
  );

  const error = useCallback(
    (title: string, err: unknown, hash?: `0x${string}`) => {
      const msg = err instanceof Error ? err.message : String(err);
      if (/user rejected|user denied|rejected by user/i.test(msg)) {
        return;
      }
      toast.push({
        kind: "error",
        title,
        message: shortenMessage(msg),
        action: hash
          ? { label: "View on BaseScan", href: txUrl(hash) }
          : undefined,
      });
    },
    [toast],
  );

  const info = useCallback(
    (title: string, message?: string) => {
      toast.push({ kind: "info", title, message });
    },
    [toast],
  );

  return { success, error, info };
}

function shortenMessage(raw: string): string {
  const firstLine = raw.split("\n")[0]?.trim() ?? raw;
  if (firstLine.length <= 180) return firstLine;
  return firstLine.slice(0, 177) + "...";
}
