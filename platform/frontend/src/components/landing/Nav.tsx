"use client";

import Link from "next/link";
import { useTranslations } from "next-intl";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { LanguageSwitcher } from "../LanguageSwitcher";
import { LandingLogo } from "./LandingLogo";

export function Nav() {
  const t = useTranslations("landing.nav");
  const tNav = useTranslations("nav");

  return (
    <nav className="relative z-20 w-full">
      <div className="mx-auto flex max-w-7xl items-center justify-between px-4 py-5 md:px-8 md:py-6 gap-3">
        <a
          href="#home"
          className="shrink-0 transition-transform duration-200 hover:scale-[1.02]"
        >
          <LandingLogo />
        </a>

        <div className="hidden items-center gap-8 md:flex">
          <a
            href="#campaigns"
            className="relative text-sm font-bold tracking-wide transition-colors text-[#4a4a4a] hover:text-black"
            style={{ fontFamily: "var(--font-header)" }}
          >
            {tNav("explore")}
          </a>
          <Link
            href="/create"
            className="relative text-sm font-bold tracking-wide transition-colors text-[#4a4a4a] hover:text-black"
            style={{ fontFamily: "var(--font-header)" }}
          >
            {tNav("create")}
          </Link>
          <Link
            href="/portfolio"
            className="relative text-sm font-bold tracking-wide transition-colors text-[#4a4a4a] hover:text-black"
            style={{ fontFamily: "var(--font-header)" }}
          >
            {tNav("portfolio")}
          </Link>
        </div>

        <div className="flex items-center gap-2 shrink-0">
          <LanguageSwitcher />
          <ConnectButton.Custom>
            {({ account, chain, openAccountModal, openConnectModal, mounted }) => {
              const ready = mounted;
              const connected = ready && account && chain;
              return !connected ? (
                <button
                  type="button"
                  onClick={openConnectModal}
                  className="inline-flex items-center rounded-full bg-black px-4 md:px-6 h-10 md:h-11 text-xs md:text-sm font-bold text-white shadow-[0_4px_16px_-4px_rgba(0,0,0,0.25)] transition-all duration-300 hover:scale-[1.03] hover:shadow-[0_8px_24px_-4px_rgba(0,0,0,0.4)] whitespace-nowrap"
                  style={{ fontFamily: "var(--font-header)" }}
                >
                  <span className="hidden sm:inline">{t("connectWallet")}</span>
                  <span className="sm:hidden">{t("connect")}</span>
                </button>
              ) : (
                <button
                  type="button"
                  onClick={openAccountModal}
                  className="inline-flex items-center rounded-full bg-white/85 border border-black/15 px-3 md:px-5 h-10 md:h-11 text-xs md:text-sm font-bold text-black backdrop-blur-md transition-all duration-300 hover:bg-white whitespace-nowrap"
                  style={{ fontFamily: "var(--font-header)" }}
                >
                  {account.displayName}
                </button>
              );
            }}
          </ConnectButton.Custom>
        </div>
      </div>
    </nav>
  );
}
