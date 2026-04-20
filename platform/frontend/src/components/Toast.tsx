"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { Spinner } from "./Spinner";

export type ToastKind = "success" | "error" | "info" | "pending";

export interface Toast {
  id: string;
  kind: ToastKind;
  title: string;
  message?: string;
  action?: { label: string; href: string };
  duration?: number;
}

interface ToastContextValue {
  push: (t: Omit<Toast, "id">) => string;
  update: (id: string, patch: Partial<Omit<Toast, "id">>) => void;
  dismiss: (id: string) => void;
}

const ToastContext = createContext<ToastContextValue | null>(null);

const DEFAULT_DURATIONS: Record<ToastKind, number> = {
  pending: 0,
  success: 6_000,
  error: 8_000,
  info: 5_000,
};

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const timers = useRef(new Map<string, ReturnType<typeof setTimeout>>());

  const dismiss = useCallback((id: string) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
    const tmr = timers.current.get(id);
    if (tmr) {
      clearTimeout(tmr);
      timers.current.delete(id);
    }
  }, []);

  const scheduleAutoDismiss = useCallback(
    (id: string, duration: number) => {
      const existing = timers.current.get(id);
      if (existing) clearTimeout(existing);
      if (duration > 0) {
        const tmr = setTimeout(() => dismiss(id), duration);
        timers.current.set(id, tmr);
      } else {
        timers.current.delete(id);
      }
    },
    [dismiss],
  );

  const push = useCallback(
    (t: Omit<Toast, "id">) => {
      const id =
        typeof crypto !== "undefined" && "randomUUID" in crypto
          ? crypto.randomUUID()
          : `t_${Date.now()}_${Math.random().toString(36).slice(2)}`;
      const full: Toast = { id, ...t };
      setToasts((prev) => [...prev, full]);
      scheduleAutoDismiss(
        id,
        full.duration ?? DEFAULT_DURATIONS[full.kind],
      );
      return id;
    },
    [scheduleAutoDismiss],
  );

  const update = useCallback(
    (id: string, patch: Partial<Omit<Toast, "id">>) => {
      setToasts((prev) =>
        prev.map((t) => (t.id === id ? { ...t, ...patch } : t)),
      );
      if (patch.kind || patch.duration !== undefined) {
        const current = toasts.find((t) => t.id === id);
        const mergedKind = patch.kind ?? current?.kind ?? "info";
        const duration =
          patch.duration ?? DEFAULT_DURATIONS[mergedKind];
        scheduleAutoDismiss(id, duration);
      }
    },
    [toasts, scheduleAutoDismiss],
  );

  useEffect(() => {
    return () => {
      for (const tmr of timers.current.values()) clearTimeout(tmr);
      timers.current.clear();
    };
  }, []);

  const value = useMemo<ToastContextValue>(
    () => ({ push, update, dismiss }),
    [push, update, dismiss],
  );

  return (
    <ToastContext.Provider value={value}>
      {children}
      <ToastViewport toasts={toasts} onDismiss={dismiss} />
    </ToastContext.Provider>
  );
}

export function useToast() {
  const ctx = useContext(ToastContext);
  if (!ctx) {
    throw new Error("useToast must be used inside <ToastProvider>");
  }
  return ctx;
}

function ToastViewport({
  toasts,
  onDismiss,
}: {
  toasts: Toast[];
  onDismiss: (id: string) => void;
}) {
  return (
    <div
      aria-live="polite"
      aria-atomic="true"
      className="pointer-events-none fixed bottom-4 right-4 z-50 flex w-full max-w-sm flex-col gap-2"
    >
      {toasts.map((t) => (
        <ToastCard key={t.id} toast={t} onDismiss={onDismiss} />
      ))}
    </div>
  );
}

function ToastCard({
  toast,
  onDismiss,
}: {
  toast: Toast;
  onDismiss: (id: string) => void;
}) {
  const palette = KIND_STYLE[toast.kind];
  return (
    <div
      role="status"
      className={`pointer-events-auto flex items-start gap-3 rounded-lg border px-4 py-3 shadow-lg backdrop-blur transition-all ${palette.wrapper}`}
    >
      <div className={`mt-0.5 shrink-0 ${palette.icon}`}>
        {toast.kind === "pending" ? <Spinner size={18} /> : <KindIcon kind={toast.kind} />}
      </div>
      <div className="min-w-0 flex-1">
        <div className={`text-sm font-semibold ${palette.title}`}>
          {toast.title}
        </div>
        {toast.message ? (
          <div className={`mt-0.5 text-xs leading-relaxed ${palette.message}`}>
            {toast.message}
          </div>
        ) : null}
        {toast.action ? (
          <a
            href={toast.action.href}
            target="_blank"
            rel="noopener noreferrer"
            className={`mt-1 inline-block text-xs font-medium underline ${palette.action}`}
          >
            {toast.action.label} ↗
          </a>
        ) : null}
      </div>
      <button
        type="button"
        onClick={() => onDismiss(toast.id)}
        className={`shrink-0 rounded text-xs ${palette.close}`}
        aria-label="Dismiss"
      >
        ✕
      </button>
    </div>
  );
}

function KindIcon({ kind }: { kind: Exclude<ToastKind, "pending"> }) {
  if (kind === "success") {
    return (
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" aria-hidden="true">
        <path
          d="M4 10.5l4 4 8-9"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    );
  }
  if (kind === "error") {
    return (
      <svg width="18" height="18" viewBox="0 0 20 20" fill="none" aria-hidden="true">
        <path
          d="M10 6v4m0 3.5h.01M10 2a8 8 0 100 16 8 8 0 000-16z"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    );
  }
  return (
    <svg width="18" height="18" viewBox="0 0 20 20" fill="none" aria-hidden="true">
      <path
        d="M10 14V9.5M10 6.5h.01M10 2a8 8 0 100 16 8 8 0 000-16z"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

const KIND_STYLE: Record<
  ToastKind,
  {
    wrapper: string;
    icon: string;
    title: string;
    message: string;
    action: string;
    close: string;
  }
> = {
  success: {
    wrapper: "border-emerald-200 bg-emerald-50/95 dark:border-emerald-900/60 dark:bg-emerald-950/80",
    icon: "text-emerald-600 dark:text-emerald-300",
    title: "text-emerald-900 dark:text-emerald-100",
    message: "text-emerald-800/80 dark:text-emerald-200/80",
    action: "text-emerald-700 dark:text-emerald-200",
    close: "text-emerald-700/60 hover:text-emerald-900 dark:text-emerald-200/60 dark:hover:text-emerald-100",
  },
  error: {
    wrapper: "border-rose-200 bg-rose-50/95 dark:border-rose-900/60 dark:bg-rose-950/80",
    icon: "text-rose-600 dark:text-rose-300",
    title: "text-rose-900 dark:text-rose-100",
    message: "text-rose-800/80 dark:text-rose-200/80",
    action: "text-rose-700 dark:text-rose-200",
    close: "text-rose-700/60 hover:text-rose-900 dark:text-rose-200/60 dark:hover:text-rose-100",
  },
  info: {
    wrapper: "border-slate-200 bg-white/95 dark:border-slate-800 dark:bg-slate-900/80",
    icon: "text-slate-600 dark:text-slate-300",
    title: "text-slate-900 dark:text-slate-100",
    message: "text-slate-700 dark:text-slate-300",
    action: "text-emerald-700 dark:text-emerald-300",
    close: "text-slate-500 hover:text-slate-900 dark:text-slate-400 dark:hover:text-slate-100",
  },
  pending: {
    wrapper: "border-sky-200 bg-sky-50/95 dark:border-sky-900/60 dark:bg-sky-950/80",
    icon: "text-sky-600 dark:text-sky-300",
    title: "text-sky-900 dark:text-sky-100",
    message: "text-sky-800/80 dark:text-sky-200/80",
    action: "text-sky-700 dark:text-sky-200",
    close: "text-sky-700/60 hover:text-sky-900 dark:text-sky-200/60 dark:hover:text-sky-100",
  },
};
