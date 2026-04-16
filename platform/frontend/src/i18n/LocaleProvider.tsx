"use client";

import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";
import { NextIntlClientProvider } from "next-intl";
import en from "@/messages/en.json";
import it from "@/messages/it.json";
import es from "@/messages/es.json";
import fr from "@/messages/fr.json";

export type Locale = "en" | "it" | "es" | "fr";

export const LOCALES: Locale[] = ["en", "it", "es", "fr"];
export const DEFAULT_LOCALE: Locale = "en";

export const LOCALE_META: Record<
  Locale,
  { name: string; flag: string; native: string }
> = {
  en: { name: "English", flag: "🇬🇧", native: "English" },
  it: { name: "Italian", flag: "🇮🇹", native: "Italiano" },
  es: { name: "Spanish", flag: "🇪🇸", native: "Español" },
  fr: { name: "French", flag: "🇫🇷", native: "Français" },
};

const MESSAGES: Record<Locale, Record<string, unknown>> = { en, it, es, fr };

const STORAGE_KEY = "growfi:locale";

interface LocaleContextValue {
  locale: Locale;
  setLocale: (locale: Locale) => void;
}

const LocaleContext = createContext<LocaleContextValue | null>(null);

export function useLocale() {
  const ctx = useContext(LocaleContext);
  if (!ctx) throw new Error("useLocale must be used within LocaleProvider");
  return ctx;
}

function detectBrowserLocale(): Locale {
  if (typeof navigator === "undefined") return DEFAULT_LOCALE;
  const lang = navigator.language.toLowerCase().split("-")[0];
  return (LOCALES as string[]).includes(lang) ? (lang as Locale) : DEFAULT_LOCALE;
}

export function LocaleProvider({ children }: { children: React.ReactNode }) {
  const [locale, setLocaleState] = useState<Locale>(DEFAULT_LOCALE);
  const [hydrated, setHydrated] = useState(false);

  useEffect(() => {
    const stored =
      typeof window !== "undefined" ? localStorage.getItem(STORAGE_KEY) : null;
    if (stored && (LOCALES as string[]).includes(stored)) {
      setLocaleState(stored as Locale);
    } else {
      setLocaleState(detectBrowserLocale());
    }
    setHydrated(true);
  }, []);

  const setLocale = (next: Locale) => {
    setLocaleState(next);
    if (typeof window !== "undefined") {
      localStorage.setItem(STORAGE_KEY, next);
    }
  };

  const messages = useMemo(() => MESSAGES[locale], [locale]);

  const value = useMemo(() => ({ locale, setLocale }), [locale]);

  // Render with the current locale. Before hydration we use the default
  // to avoid SSR/CSR mismatch; useEffect above will swap to the real one.
  return (
    <LocaleContext.Provider value={value}>
      <NextIntlClientProvider
        locale={locale}
        messages={messages}
        now={new Date()}
        timeZone="Europe/Rome"
      >
        {hydrated ? children : <div suppressHydrationWarning>{children}</div>}
      </NextIntlClientProvider>
    </LocaleContext.Provider>
  );
}
