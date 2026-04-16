"use client";

import Link from "next/link";
import { useTranslations } from "next-intl";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { Logo } from "./Logo";
import { LanguageSwitcher } from "./LanguageSwitcher";

export function Header() {
  const t = useTranslations("nav");

  return (
    <nav className="fixed top-0 w-full z-50 bg-white/70 backdrop-blur-xl border-b border-outline-variant/15">
      <div className="flex justify-between items-center px-8 h-16 max-w-7xl mx-auto w-full gap-6">
        <Link href="/" className="flex items-center gap-1 shrink-0">
          <Logo />
        </Link>

        <div className="hidden md:flex gap-8 items-center">
          <Link
            href="/"
            className="text-sm font-medium tracking-wide text-on-surface-variant hover:text-on-surface transition-colors"
          >
            {t("explore")}
          </Link>
          <Link
            href="/create"
            className="text-sm font-medium tracking-wide text-on-surface-variant hover:text-on-surface transition-colors"
          >
            {t("create")}
          </Link>
        </div>

        <div className="flex items-center gap-2">
          <LanguageSwitcher />
          <ConnectButton
            label={t("connectWallet")}
            accountStatus="address"
            showBalance={false}
          />
        </div>
      </div>
    </nav>
  );
}
