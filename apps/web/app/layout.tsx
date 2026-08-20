import type { Metadata } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://xaq.sh"),
  title: "xaq — a coding agent in about 540 KiB",
  description:
    "One binary. One conversation. Four local tools. xaq connects directly to ChatGPT, Claude, and Grok subscriptions without a daemon, runtime, or proxy.",
  openGraph: {
    title: "xaq",
    description: "A coding agent in about 540 KiB.",
    url: "https://xaq.sh",
    siteName: "xaq",
  },
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body
        className={`${GeistSans.variable} ${GeistMono.variable} font-sans antialiased`}
      >
        {children}
      </body>
    </html>
  );
}
