"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { requestInvestorDemo } from "@/lib/api";

type FormState = "idle" | "submitting" | "ok" | "error";

const HERO_IMAGE = "/investors-olive-hero.jpg";
const DECK_HREF = "/growfi-seed-deck.pdf";

export default function InvestorsPage() {
  const t = useTranslations("investors");
  const [form, setForm] = useState({
    name: "",
    email: "",
    company: "",
    role: "",
    message: "",
    website: "",
  });
  const [state, setState] = useState<FormState>("idle");
  const [error, setError] = useState("");

  const stats = [
    {
      label: t("stats.protocol.label"),
      value: t("stats.protocol.value"),
      hint: t("stats.protocol.hint"),
    },
    {
      label: t("stats.campaigns.label"),
      value: t("stats.campaigns.value"),
      hint: t("stats.campaigns.hint"),
    },
    {
      label: t("stats.treasury.label"),
      value: t("stats.treasury.value"),
      hint: t("stats.treasury.hint"),
    },
  ];

  const thesis = [
    t("thesis.items.market"),
    t("thesis.items.protocol"),
    t("thesis.items.distribution"),
  ];

  const milestones = [
    {
      phase: t("milestones.product.phase"),
      title: t("milestones.product.title"),
      body: t("milestones.product.body"),
    },
    {
      phase: t("milestones.supply.phase"),
      title: t("milestones.supply.title"),
      body: t("milestones.supply.body"),
    },
    {
      phase: t("milestones.seed.phase"),
      title: t("milestones.seed.title"),
      body: t("milestones.seed.body"),
    },
  ];

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setState("submitting");
    setError("");
    try {
      await requestInvestorDemo(form);
      setState("ok");
      setForm({
        name: "",
        email: "",
        company: "",
        role: "",
        message: "",
        website: "",
      });
    } catch (err) {
      setState("error");
      setError(err instanceof Error ? err.message : t("form.error"));
    }
  }

  return (
    <div className="bg-[#f6f8f2] text-[#061b31]">
      <section className="relative isolate min-h-[72vh] overflow-hidden bg-[#06140f]">
        <img
          src={HERO_IMAGE}
          alt=""
          className="absolute inset-0 h-full w-full object-cover"
        />
        <div className="absolute inset-0 bg-[linear-gradient(90deg,rgba(6,20,15,0.94)_0%,rgba(6,20,15,0.78)_42%,rgba(6,20,15,0.16)_76%,rgba(6,20,15,0.02)_100%)]" />
        <div className="relative mx-auto flex min-h-[72vh] max-w-7xl flex-col justify-end px-4 pb-10 pt-20 md:px-8 md:pb-14">
          <div className="max-w-3xl">
            <p className="inline-flex rounded-[4px] border border-white/20 bg-white/12 px-3 py-1 text-xs font-semibold uppercase text-emerald-100 backdrop-blur-md">
              {t("hero.kicker")}
            </p>
            <h1 className="mt-5 text-5xl font-semibold leading-[1.02] text-white md:text-7xl">
              {t("hero.title")}
            </h1>
            <p className="mt-6 max-w-2xl text-base leading-7 text-emerald-50/85 md:text-lg">
              {t("hero.body")}
            </p>
            <div className="mt-8 flex flex-col gap-3 sm:flex-row">
              <a
                href="#investor-request"
                className="inline-flex min-h-[46px] items-center justify-center rounded-[6px] bg-white px-5 text-sm font-semibold text-[#06140f] transition-colors hover:bg-emerald-50"
              >
                {t("hero.requestCta")}
              </a>
              <a
                href={DECK_HREF}
                download
                className="inline-flex min-h-[46px] items-center justify-center rounded-[6px] border border-white/25 bg-white/10 px-5 text-sm font-semibold text-white backdrop-blur-md transition-colors hover:bg-white/16"
              >
                {t("hero.deckCta")}
              </a>
            </div>
          </div>
        </div>
      </section>

      <section className="border-b border-emerald-950/10 bg-white">
        <div className="mx-auto grid max-w-7xl grid-cols-1 gap-px bg-emerald-950/10 px-4 md:grid-cols-3 md:px-8">
          {stats.map((stat) => (
            <div key={stat.label} className="bg-white px-5 py-6 md:px-6">
              <div className="text-xs font-semibold uppercase text-[#64748d]">
                {stat.label}
              </div>
              <div className="mt-2 text-3xl font-semibold text-[#061b31]">
                {stat.value}
              </div>
              <p className="mt-2 text-sm leading-6 text-[#64748d]">{stat.hint}</p>
            </div>
          ))}
        </div>
      </section>

      <section className="mx-auto grid max-w-7xl gap-10 px-4 py-16 md:grid-cols-[0.9fr_1.1fr] md:px-8 md:py-20">
        <div>
          <p className="text-xs font-semibold uppercase text-emerald-700">
            {t("thesis.kicker")}
          </p>
          <h2 className="mt-3 text-3xl font-semibold leading-tight text-[#061b31] md:text-5xl">
            {t("thesis.title")}
          </h2>
        </div>
        <div className="grid gap-4">
          {thesis.map((item, index) => (
            <div
              key={item}
              className="grid grid-cols-[44px_1fr] gap-4 border-t border-emerald-950/10 pt-5"
            >
              <div className="flex h-9 w-9 items-center justify-center rounded-[6px] bg-emerald-950 text-sm font-semibold text-white">
                {index + 1}
              </div>
              <p className="text-base leading-7 text-[#273951]">{item}</p>
            </div>
          ))}
        </div>
      </section>

      <section className="bg-[#061b31] text-white">
        <div className="mx-auto grid max-w-7xl gap-8 px-4 py-16 md:grid-cols-3 md:px-8 md:py-20">
          {milestones.map((item) => (
            <article
              key={item.phase}
              className="rounded-[8px] border border-white/12 bg-white/[0.04] p-6 shadow-[0_20px_50px_-30px_rgba(0,0,0,0.55)]"
            >
              <p className="text-xs font-semibold uppercase text-emerald-200">
                {item.phase}
              </p>
              <h3 className="mt-4 text-2xl font-semibold leading-tight">
                {item.title}
              </h3>
              <p className="mt-3 text-sm leading-6 text-slate-300">{item.body}</p>
            </article>
          ))}
        </div>
      </section>

      <section
        id="investor-request"
        className="mx-auto grid max-w-7xl gap-10 px-4 py-16 md:grid-cols-[0.82fr_1fr] md:px-8 md:py-20"
      >
        <div>
          <p className="text-xs font-semibold uppercase text-emerald-700">
            {t("form.kicker")}
          </p>
          <h2 className="mt-3 text-3xl font-semibold leading-tight text-[#061b31] md:text-5xl">
            {t("form.title")}
          </h2>
          <p className="mt-5 max-w-xl text-base leading-7 text-[#64748d]">
            {t("form.body")}
          </p>
          <a
            href={DECK_HREF}
            download
            className="mt-8 inline-flex min-h-[44px] items-center justify-center rounded-[6px] border border-emerald-900/20 bg-white px-5 text-sm font-semibold text-[#061b31] shadow-[0_16px_36px_-28px_rgba(50,50,93,0.45)] transition-colors hover:bg-emerald-50"
          >
            {t("form.deck")}
          </a>
        </div>

        <form
          onSubmit={onSubmit}
          className="rounded-[8px] border border-[#e5edf5] bg-white p-5 shadow-[0_30px_45px_-34px_rgba(50,50,93,0.35),0_18px_36px_-30px_rgba(0,0,0,0.16)] md:p-7"
        >
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label={t("form.name")}>
              <input
                required
                value={form.name}
                onChange={(e) => setForm((v) => ({ ...v, name: e.target.value }))}
                className="h-11 w-full rounded-[6px] border border-[#dbe5ee] px-3 text-sm text-[#061b31] outline-none transition-colors focus:border-emerald-700"
              />
            </Field>
            <Field label={t("form.email")}>
              <input
                required
                type="email"
                autoComplete="email"
                value={form.email}
                onChange={(e) => setForm((v) => ({ ...v, email: e.target.value }))}
                className="h-11 w-full rounded-[6px] border border-[#dbe5ee] px-3 text-sm text-[#061b31] outline-none transition-colors focus:border-emerald-700"
              />
            </Field>
            <Field label={t("form.company")}>
              <input
                value={form.company}
                onChange={(e) =>
                  setForm((v) => ({ ...v, company: e.target.value }))
                }
                className="h-11 w-full rounded-[6px] border border-[#dbe5ee] px-3 text-sm text-[#061b31] outline-none transition-colors focus:border-emerald-700"
              />
            </Field>
            <Field label={t("form.role")}>
              <input
                value={form.role}
                onChange={(e) => setForm((v) => ({ ...v, role: e.target.value }))}
                className="h-11 w-full rounded-[6px] border border-[#dbe5ee] px-3 text-sm text-[#061b31] outline-none transition-colors focus:border-emerald-700"
              />
            </Field>
          </div>

          <label className="sr-only" htmlFor="website">
            Website
          </label>
          <input
            id="website"
            tabIndex={-1}
            autoComplete="off"
            value={form.website}
            onChange={(e) => setForm((v) => ({ ...v, website: e.target.value }))}
            className="hidden"
          />

          <Field label={t("form.message")} className="mt-4">
            <textarea
              required
              value={form.message}
              onChange={(e) =>
                setForm((v) => ({ ...v, message: e.target.value }))
              }
              className="min-h-[150px] w-full resize-y rounded-[6px] border border-[#dbe5ee] px-3 py-3 text-sm leading-6 text-[#061b31] outline-none transition-colors focus:border-emerald-700"
            />
          </Field>

          <button
            type="submit"
            disabled={state === "submitting"}
            className="mt-5 inline-flex min-h-[46px] w-full items-center justify-center rounded-[6px] bg-[#061b31] px-5 text-sm font-semibold text-white transition-colors hover:bg-[#0d253d] disabled:cursor-not-allowed disabled:opacity-60"
          >
            {state === "submitting" ? t("form.submitting") : t("form.submit")}
          </button>

          <div aria-live="polite" className="min-h-8">
            {state === "ok" && (
              <p className="mt-4 rounded-[6px] border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">
                {t("form.success")}
              </p>
            )}
            {state === "error" && (
              <p className="mt-4 rounded-[6px] border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-900">
                {error || t("form.error")}
              </p>
            )}
          </div>
        </form>
      </section>
    </div>
  );
}

function Field({
  label,
  children,
  className = "",
}: {
  label: string;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <label className={`block ${className}`}>
      <span className="mb-1.5 block text-xs font-semibold uppercase text-[#273951]">
        {label}
      </span>
      {children}
    </label>
  );
}
