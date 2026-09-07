import type { Metadata } from "next";
import { GeistMono } from "geist/font/mono";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://xaq.sh"),
  title: "xaq | A coding agent in a single native binary",
  description:
    "One binary. One conversation. Four local tools. xaq connects directly to ChatGPT, Claude, and Grok subscriptions without a daemon, runtime, or proxy.",
  openGraph: {
    title: "xaq",
    description: "A coding agent in a single native binary.",
    url: "https://xaq.sh",
    siteName: "xaq",
  },
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className={`${GeistMono.variable} font-mono antialiased`}>
        {children}
      </body>
    </html>
  );
}
