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
      <div className="flex justify-between items-center px-4 md:px-8 h-16 max-w-7xl mx-auto w-full gap-2 md:gap-6">
        <Link href="/" className="flex items-center gap-1 shrink-0 min-w-0">
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
          <Link
            href="/portfolio"
            className="text-sm font-medium tracking-wide text-on-surface-variant hover:text-on-surface transition-colors"
          >
            {t("portfolio")}
          </Link>
        </div>

        <div className="flex items-center gap-2 shrink-0">
          <LanguageSwitcher />
          <ConnectButton.Custom>
            {({
              account,
              chain,
              openAccountModal,
              openChainModal,
              openConnectModal,
              mounted,
            }) => {
              const ready = mounted;
              const connected = ready && account && chain;
              const pillBase =
                "h-10 px-3 md:px-4 rounded-full text-xs md:text-sm font-semibold bg-white border border-outline-variant/30 text-on-surface hover:bg-surface-container-low transition-colors flex items-center gap-2 whitespace-nowrap";

              return (
                <div className="flex items-center gap-2" aria-hidden={!ready}>
                  {!connected ? (
                    <button
                      onClick={openConnectModal}
                      type="button"
                      className={pillBase}
                    >
                      <span className="hidden sm:inline">{t("connectWallet")}</span>
                      <span className="sm:hidden">{t("connect")}</span>
                    </button>
                  ) : chain.unsupported ? (
                    <button
                      onClick={openChainModal}
                      type="button"
                      className="h-10 px-3 md:px-4 rounded-full text-xs md:text-sm font-semibold bg-error text-on-error flex items-center gap-2 whitespace-nowrap"
                    >
                      Wrong network
                    </button>
                  ) : (
                    <>
                      <Link
                        href={`/producer/${account.address}`}
                        className={pillBase}
                        title={t("profile")}
                      >
                        <svg
                          width="16"
                          height="16"
                          viewBox="0 0 24 24"
                          fill="currentColor"
                        >
                          <path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z" />
                        </svg>
                        <span className="hidden md:inline">{t("profile")}</span>
                      </Link>
                      <button
                        onClick={openAccountModal}
                        type="button"
                        className={pillBase}
                      >
                        {account.displayName}
                      </button>
                    </>
                  )}
                </div>
              );
            }}
          </ConnectButton.Custom>
        </div>
      </div>
    </nav>
  );
}
