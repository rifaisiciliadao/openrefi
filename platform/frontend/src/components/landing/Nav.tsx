"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { LanguageSwitcher } from "../LanguageSwitcher";
import { LandingLogo } from "./LandingLogo";
import { useInviteGate } from "@/lib/inviteGate";
import { useInviteModal } from "@/lib/inviteModal";

export function Nav() {
  const t = useTranslations("landing.nav");
  const tNav = useTranslations("nav");
  const tInvite = useTranslations("landing.invite");
  const { state } = useInviteGate();
  const { openModal } = useInviteModal();
  const approved = state === "approved";
  const [mobileOpen, setMobileOpen] = useState(false);
  const [desktopOpen, setDesktopOpen] = useState(false);
  const desktopMenuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (typeof window === "undefined") return;
    const mql = window.matchMedia("(min-width: 768px)");
    const onChange = () => {
      if (mql.matches) {
        setMobileOpen(false);
      } else {
        setDesktopOpen(false);
      }
    };
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, []);

  useEffect(() => {
    if (!desktopOpen) return;

    const onPointerDown = (event: PointerEvent) => {
      if (
        desktopMenuRef.current &&
        !desktopMenuRef.current.contains(event.target as Node)
      ) {
        setDesktopOpen(false);
      }
    };

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setDesktopOpen(false);
      }
    };

    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [desktopOpen]);

  const desktopLinkClass =
    "relative text-sm font-bold tracking-wide transition-colors text-[#4a4a4a] hover:text-black";
  const menuLinkClass =
    "flex w-full items-center rounded-md px-3 py-2.5 text-left text-sm font-bold tracking-wide text-[#4a4a4a] hover:bg-black/5 hover:text-black transition-colors";

  return (
    <nav className="relative z-20 w-full">
      <div className="mx-auto flex max-w-7xl items-center justify-between px-4 py-5 md:px-8 md:py-6 gap-3">
        <a
          href="#home"
          className="shrink-0 transition-transform duration-200 hover:scale-[1.02]"
        >
          <LandingLogo />
        </a>

        <div className="hidden items-center gap-5 md:flex">
          <a
            href="#campaigns"
            className={desktopLinkClass}
            style={{ fontFamily: "var(--font-header)" }}
          >
            {tNav("explore")}
          </a>
          <Link
            href="/investors"
            className={desktopLinkClass}
            style={{ fontFamily: "var(--font-header)" }}
          >
            {tNav("investors")}
          </Link>
          <Link
            href="/grow"
            className={desktopLinkClass}
            style={{ fontFamily: "var(--font-header)" }}
          >
            $GROW
          </Link>
        </div>

        <div className="flex items-center gap-2 shrink-0">
          <div className="hidden md:block">
            <LanguageSwitcher />
          </div>
          <div ref={desktopMenuRef} className="relative hidden md:block">
            <button
              type="button"
              onClick={() => setDesktopOpen((v) => !v)}
              aria-label={desktopOpen ? "Close navigation menu" : "Open navigation menu"}
              aria-expanded={desktopOpen}
              aria-haspopup="menu"
              title="Menu"
              className="flex h-10 w-10 items-center justify-center rounded-full bg-white/85 border border-black/15 backdrop-blur-md text-black hover:bg-white transition-colors"
            >
              {desktopOpen ? (
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <line x1="18" y1="6" x2="6" y2="18" />
                  <line x1="6" y1="6" x2="18" y2="18" />
                </svg>
              ) : (
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <line x1="3" y1="6" x2="21" y2="6" />
                  <line x1="3" y1="12" x2="21" y2="12" />
                  <line x1="3" y1="18" x2="21" y2="18" />
                </svg>
              )}
            </button>
            {desktopOpen && (
              <div
                role="menu"
                className="absolute right-0 top-full mt-2 w-60 rounded-lg border border-black/10 bg-white/95 p-1.5 shadow-[0_18px_48px_-28px_rgba(0,0,0,0.45)] backdrop-blur-xl"
              >
                <Link
                  href="/feed"
                  role="menuitem"
                  onClick={() => setDesktopOpen(false)}
                  className={menuLinkClass}
                  style={{ fontFamily: "var(--font-header)" }}
                >
                  {tNav("feed")}
                </Link>
                <Link
                  href="/portfolio"
                  role="menuitem"
                  onClick={() => setDesktopOpen(false)}
                  className={menuLinkClass}
                  style={{ fontFamily: "var(--font-header)" }}
                >
                  {tNav("portfolio")}
                </Link>
                {approved ? (
                  <Link
                    href="/create"
                    role="menuitem"
                    onClick={() => setDesktopOpen(false)}
                    className={menuLinkClass}
                    style={{ fontFamily: "var(--font-header)" }}
                  >
                    {tNav("create")}
                  </Link>
                ) : (
                  <button
                    type="button"
                    role="menuitem"
                    onClick={() => {
                      setDesktopOpen(false);
                      openModal();
                    }}
                    className={menuLinkClass}
                    style={{ fontFamily: "var(--font-header)" }}
                  >
                    {tInvite("requestSubmit")}
                  </button>
                )}
              </div>
            )}
          </div>
          <button
            type="button"
            onClick={() => setMobileOpen((v) => !v)}
            aria-label={mobileOpen ? "Close mobile menu" : "Open mobile menu"}
            aria-expanded={mobileOpen}
            className="md:hidden flex h-10 w-10 items-center justify-center rounded-full bg-white/85 border border-black/15 backdrop-blur-md text-black hover:bg-white transition-colors"
          >
            {mobileOpen ? (
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <line x1="18" y1="6" x2="6" y2="18" />
                <line x1="6" y1="6" x2="18" y2="18" />
              </svg>
            ) : (
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <line x1="3" y1="6" x2="21" y2="6" />
                <line x1="3" y1="12" x2="21" y2="12" />
                <line x1="3" y1="18" x2="21" y2="18" />
              </svg>
            )}
          </button>
          <ConnectButton.Custom>
            {({ account, chain, openConnectModal, mounted }) => {
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
                <Link
                  href={`/grower/${account.address}`}
                  className="inline-flex items-center gap-2 rounded-full bg-white/85 border border-black/15 px-3 md:px-4 h-10 md:h-11 text-xs md:text-sm font-bold text-black backdrop-blur-md transition-all duration-300 hover:bg-white whitespace-nowrap"
                  style={{ fontFamily: "var(--font-header)" }}
                >
                  <span className="w-6 h-6 rounded-full bg-primary-fixed text-on-primary-fixed-variant flex items-center justify-center text-[10px] font-bold shrink-0">
                    {account.address.slice(2, 4).toUpperCase()}
                  </span>
                  <span className="font-mono text-xs">
                    {account.address.slice(0, 6)}…{account.address.slice(-4)}
                  </span>
                </Link>
              );
            }}
          </ConnectButton.Custom>
        </div>
      </div>

      {mobileOpen && (
        <div className="md:hidden border-t border-black/10 bg-white/90 backdrop-blur-xl">
          <div className="mx-auto flex max-w-7xl flex-col gap-1 px-4 py-3">
            <a
              href="#campaigns"
              onClick={() => setMobileOpen(false)}
              className="rounded-lg px-3 py-3 text-base font-bold tracking-wide text-[#4a4a4a] hover:bg-black/5 hover:text-black transition-colors"
              style={{ fontFamily: "var(--font-header)" }}
            >
              {tNav("explore")}
            </a>
            <Link
              href="/feed"
              onClick={() => setMobileOpen(false)}
              className="rounded-lg px-3 py-3 text-base font-bold tracking-wide text-[#4a4a4a] hover:bg-black/5 hover:text-black transition-colors"
              style={{ fontFamily: "var(--font-header)" }}
            >
              {tNav("feed")}
            </Link>
            <Link
              href="/portfolio"
              onClick={() => setMobileOpen(false)}
              className="rounded-lg px-3 py-3 text-base font-bold tracking-wide text-[#4a4a4a] hover:bg-black/5 hover:text-black transition-colors"
              style={{ fontFamily: "var(--font-header)" }}
            >
              {tNav("portfolio")}
            </Link>
            <Link
              href="/investors"
              onClick={() => setMobileOpen(false)}
              className="rounded-lg px-3 py-3 text-base font-bold tracking-wide text-[#4a4a4a] hover:bg-black/5 hover:text-black transition-colors"
              style={{ fontFamily: "var(--font-header)" }}
            >
              {tNav("investors")}
            </Link>
            <Link
              href="/grow"
              onClick={() => setMobileOpen(false)}
              className="rounded-lg px-3 py-3 text-base font-bold tracking-wide text-emerald-700 hover:bg-emerald-50 transition-colors"
              style={{ fontFamily: "var(--font-header)" }}
            >
              $GROW
            </Link>
            {approved ? (
              <Link
                href="/create"
                onClick={() => setMobileOpen(false)}
                className="rounded-lg px-3 py-3 text-base font-bold tracking-wide text-[#4a4a4a] hover:bg-black/5 hover:text-black transition-colors"
                style={{ fontFamily: "var(--font-header)" }}
              >
                {tNav("create")}
              </Link>
            ) : (
              <a
                href="#invite"
                onClick={(event) => {
                  event.preventDefault();
                  setMobileOpen(false);
                  openModal();
                }}
                className="rounded-lg px-3 py-3 text-base font-bold tracking-wide text-[#4a4a4a] hover:bg-black/5 hover:text-black transition-colors"
                style={{ fontFamily: "var(--font-header)" }}
              >
                {tInvite("requestSubmit")}
              </a>
            )}
            <div className="mt-2 border-t border-black/10 pt-3">
              <LanguageSwitcher />
            </div>
          </div>
        </div>
      )}
    </nav>
  );
}
