export const siteConfig = {
  name: "Duck Downloader",
  shortName: "Duck",
  version: "0.1.0",
  tagline: "Copy. Detect. Download.",
  description:
    "Duck Downloader is a simple downloader for public social media links, available for Android and Windows.",
  url: "https://duckdownloader.app",
  ctaState: "comingSoon",
  futureDownloads: {
    androidApkUrl: null,
    windowsInstallerUrl: null
  },
  platforms: [
    {
      name: "Android",
      status: "Available",
      detail: "Mobile app for copying public links and saving media locally.",
      actionLabel: "Coming soon"
    },
    {
      name: "Windows",
      status: "Available",
      detail: "Desktop app with clipboard reading, queue progress, and local library.",
      actionLabel: "Coming soon"
    }
  ]
} as const;
