"use client";

import Link from "next/link";
import { useTranslations } from "next-intl";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { Logo } from "./Logo";
import { LanguageSwitcher } from "./LanguageSwitcher";
import { useInviteGate } from "@/lib/inviteGate";

export function Header() {
  const t = useTranslations("nav");
  const tInvite = useTranslations("landing.invite");
  const { state } = useInviteGate();
  const approved = state === "approved";

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
            href="/portfolio"
            className="text-sm font-medium tracking-wide text-on-surface-variant hover:text-on-surface transition-colors"
          >
            {t("portfolio")}
          </Link>
          <Link
            href="/grow"
            className="text-sm font-medium tracking-wide text-on-surface-variant hover:text-on-surface transition-colors"
          >
            $GROW
          </Link>
          {approved ? (
            <Link
              href="/create"
              className="text-sm font-medium tracking-wide text-on-surface-variant hover:text-on-surface transition-colors"
            >
              {t("create")}
            </Link>
          ) : (
            <Link
              href="/#invite"
              className="text-sm font-medium tracking-wide text-on-surface-variant hover:text-on-surface transition-colors"
            >
              {tInvite("requestSubmit")}
            </Link>
          )}
        </div>

        <div className="flex items-center gap-2 shrink-0">
          <LanguageSwitcher />
          <ConnectButton.Custom>
            {({
              account,
              chain,
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
                    <Link
                      href={`/grower/${account.address}`}
                      className={pillBase}
                      title={t("profile")}
                    >
                      <span className="w-6 h-6 rounded-full bg-primary-fixed text-on-primary-fixed-variant flex items-center justify-center text-[10px] font-bold shrink-0">
                        {account.address.slice(2, 4).toUpperCase()}
                      </span>
                      <span className="hidden sm:inline font-mono text-xs">
                        {account.address.slice(0, 6)}…{account.address.slice(-4)}
                      </span>
                    </Link>
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
