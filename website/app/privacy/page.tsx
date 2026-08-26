import type { Metadata } from "next";
import Image from "next/image";
import Link from "next/link";
import { siteConfig } from "../site-config";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description: `How ${siteConfig.name} handles your data: everything stays on your device.`,
  alternates: {
    canonical: "/privacy"
  }
};

/// Google Play requires a publicly reachable privacy policy URL for the store
/// listing, and it must stay reachable for as long as the app is published —
/// so this lives in the site rather than only as a dialog inside the app.
const LAST_UPDATED = "July 19, 2026";

const sections = [
  {
    heading: "1. Information We Collect",
    body: [
      "We do not collect any personal data directly from our users. All downloads and files are stored locally on your device or in your secure local vault.",
      "However, the App uses third-party services that may collect information used to identify you:"
    ],
    list: [
      {
        term: "Google Play Services",
        detail: "Used to run the application on Android devices."
      },
      {
        term: "Google AdMob",
        detail:
          "Used to serve advertisements in the free version of the App. AdMob may collect device identifiers, IP addresses, and ad-related data to show relevant ads."
      },
      {
        term: "Firebase Crashlytics and Analytics",
        detail:
          "Used to diagnose crashes and measure stability. Reports contain no file names, links or vault contents, and you can switch this off at any time under Settings → Send Diagnostics."
      }
    ]
  },
  {
    heading: "2. App Access and Permissions",
    body: [
      "The App requests access to your device storage in order to download, browse and manage media files. This permission is used solely for functionality and no media files are uploaded to our servers."
    ]
  },
  {
    heading: "3. Security",
    body: [
      "The App provides a secure private vault to store your downloaded media. Files in the vault are encrypted on your device with AES-256, unlocked only by your PIN or biometrics, and are never accessible to third parties or sent to any server."
    ]
  },
  {
    heading: "4. Children's Privacy",
    body: [
      "Our App is not intended for children under the age of 13. We do not knowingly collect personal information from children under 13."
    ]
  },
  {
    heading: "5. Changes to This Privacy Policy",
    body: [
      "We may update our Privacy Policy from time to time. You are advised to review this page periodically for any changes."
    ]
  }
];

export default function PrivacyPolicyPage() {
  return (
    <>
      <header className="legal-header">
        <div className="wrap">
        <Link className="brand" href="/">
          <Image src="/duck-idle.png" alt="" width={38} height={38} />
          <span>{siteConfig.name}</span>
        </Link>
      </div>
      </header>

      <main className="legal">
        <p className="eyebrow">Legal</p>
        <h1 className="h2">Privacy Policy</h1>
        <p className="legal-meta">Last updated: {LAST_UPDATED}</p>

        <p className="legal-lede">
          {siteConfig.name} (&quot;we&quot;, &quot;our&quot;, or &quot;us&quot;) is committed to
          protecting your privacy. This Privacy Policy explains how we collect, use, and share
          information when you use our mobile application, {siteConfig.name} (the &quot;App&quot;).
        </p>

        {sections.map((section) => (
          <section key={section.heading}>
            <h2>{section.heading}</h2>
            {section.body.map((paragraph) => (
              <p key={paragraph}>{paragraph}</p>
            ))}
            {section.list ? (
              <ul>
                {section.list.map((entry) => (
                  <li key={entry.term}>
                    <strong>{entry.term}:</strong> {entry.detail}
                  </li>
                ))}
              </ul>
            ) : null}
          </section>
        ))}

        <section>
          <h2>6. Contact Us</h2>
          <p>
            If you have any questions or suggestions about our Privacy Policy, do not hesitate to
            contact us at <a href={`mailto:${siteConfig.contactEmail}`}>{siteConfig.contactEmail}</a>.
          </p>
        </section>

        <Link className="btn btn-ghost legal-back" href="/">
          Back to home
        </Link>
      </main>
    </>
  );
}
