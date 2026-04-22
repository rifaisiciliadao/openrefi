import type { Metadata } from "next";
import {
  Inter,
  Be_Vietnam_Pro,
  Crimson_Text,
  Plus_Jakarta_Sans,
} from "next/font/google";
import { Providers } from "./providers";
import { ConditionalChrome } from "@/components/ConditionalChrome";
import "./globals.css";

const inter = Inter({
  subsets: ["latin"],
  variable: "--font-inter",
});

const beVietnamPro = Be_Vietnam_Pro({
  subsets: ["latin"],
  weight: ["700"],
  variable: "--font-be-vietnam-pro",
  display: "swap",
});

const plusJakarta = Plus_Jakarta_Sans({
  subsets: ["latin"],
  weight: ["700", "800"],
  variable: "--font-jakarta",
  display: "swap",
});

const crimsonText = Crimson_Text({
  subsets: ["latin"],
  weight: ["400"],
  style: ["normal", "italic"],
  variable: "--font-crimson-text",
  display: "swap",
});

export const metadata: Metadata = {
  title: "GrowFi — Regenerative Finance for a Living Planet",
  description:
    "Fund real Sicilian olive harvests onchain. $1,000 returns 5 liters of cold-pressed EVO at harvest — or your USDC back, guaranteed by smart contract escrow.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="it"
      className={`${inter.variable} ${beVietnamPro.variable} ${plusJakarta.variable} ${crimsonText.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col font-sans bg-surface text-on-surface">
        <Providers>
          <ConditionalChrome>{children}</ConditionalChrome>
        </Providers>
      </body>
    </html>
  );
}
