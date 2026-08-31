export const siteConfig = {
  name: "Duck Downloader",
  shortName: "Duck",
  tagline: "Copy a link. Keep the file.",
  description:
    "Duck Downloader saves video, photos and audio from public social links straight to your phone. Files stay on your device, and the private vault is encrypted with a passcode only you know.",
  url: "https://duckdownloader.site",

  // Live since 31 August 2026.
  //
  // The hero CTA, the platform card and the footer all read this one object,
  // so the site cannot end up claiming "available" in one place and "coming
  // soon" in another the way it used to.
  //
  // The `?pli=1` the Play Console hands you is a UI hint for a signed-in
  // browser and means nothing to anyone arriving from here — left off so the
  // link that gets shared is the short, canonical one.
  play: {
    live: true,
    url: "https://play.google.com/store/apps/details?id=com.duck.downloader" as string | null,
    label: "Get it on Google Play"
  },

  contactEmail: "mohvmedesam@gmail.com",

  // Shown in the footer and on the privacy page. Both surfaces read from here
  // rather than hardcoding their own copy: the address on the policy page is
  // the one Google Play checks, and the two drifting apart is the kind of
  // mismatch that gets a listing flagged.
  //
  // The number is for WhatsApp support, so it is never rendered as a `tel:`
  // link. wa.me wants the number without the leading + or any spaces, which is
  // why the display string and the link string are kept apart here.
  whatsapp: {
    display: "+20 121 303 7089",
    href: "https://wa.me/201213037089"
  }
} as const;
