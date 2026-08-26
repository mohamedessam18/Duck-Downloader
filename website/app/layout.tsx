import type { Metadata, Viewport } from "next";
import { GeistSans } from "geist/font/sans";
import "./styles.css";
import { siteConfig } from "./site-config";

export const metadata: Metadata = {
  metadataBase: new URL(siteConfig.url),
  title: {
    default: `${siteConfig.name} - ${siteConfig.tagline}`,
    template: `%s - ${siteConfig.name}`
  },
  description: siteConfig.description,
  applicationName: siteConfig.name,
  keywords: [
    "Duck Downloader",
    "social media downloader",
    "video downloader",
    "private vault",
    "Android downloader"
  ],
  openGraph: {
    title: `${siteConfig.name} - ${siteConfig.tagline}`,
    description: siteConfig.description,
    url: siteConfig.url,
    siteName: siteConfig.name,
    images: [
      { url: "/duck-logo.png", width: 1200, height: 630, alt: "Duck Downloader" }
    ],
    locale: "en_US",
    type: "website"
  },
  twitter: {
    card: "summary_large_image",
    title: `${siteConfig.name} - ${siteConfig.tagline}`,
    description: siteConfig.description,
    images: ["/duck-logo.png"]
  },
  icons: { icon: "/duck-idle.png", apple: "/duck-idle.png" }
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  // Matches --bg so the status bar does not band against the page on mobile.
  themeColor: "#08090B"
};

export default function RootLayout({
  children
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={GeistSans.className}>
      <body>{children}</body>
    </html>
  );
}
