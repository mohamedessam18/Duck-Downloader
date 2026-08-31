import type { Metadata } from "next";
import { MegaphoneSimpleIcon } from "@phosphor-icons/react/dist/ssr";
import { Footer, Nav, PageHead } from "../components/Shell";
import { Reveal } from "../components/Reveal";
import { ReportForm } from "./ReportForm";

export const metadata: Metadata = {
  title: "Report an ad",
  description:
    "Tell us about an ad in Duck Downloader that was offensive, a scam, or not suitable.",
  alternates: { canonical: "/report-ad" }
};

/**
 * Ads pay for the free tier, and that is a deal with the person using the app:
 * they see ads, and in return the ads stay within what the app claims to be.
 * When one is a scam or is adult content in an app rated for everyone, that
 * deal is broken and the only person who can find out is the person it
 * happened to.
 *
 * This page does not route to Google. AdMob has its own reporting on the ad
 * itself, and that is said plainly below rather than left for someone to
 * discover after waiting for a reply that was never coming.
 */
export default function ReportAdPage() {
  return (
    <>
      <Nav />
      <main className="page">
        <PageHead
          eyebrow="Ads"
          title="Report an ad"
          lede="Ads keep Duck free, and they are supposed to stay within what this app is. If one did not, tell us which and it can be blocked."
        />

        <Reveal>
          <section className="panel report-panel">
            <ReportForm />
          </section>
        </Reveal>

        <Reveal>
          <section className="panel report-explain">
            <h2>
              <MegaphoneSimpleIcon size={19} weight="fill" />
              What happens to this
            </h2>
            <ol>
              <li>
                <strong>It comes to the developer, not to Google.</strong> Google
                is not told about this report and will not act on it.
              </li>
              <li>
                <strong>Reports are counted by reason.</strong> One is hard to
                act on. The same one arriving repeatedly points at a specific
                advertiser.
              </li>
              <li>
                <strong>That advertiser gets blocked.</strong> Ad networks let a
                developer block advertisers and whole categories, and a report
                is what makes it obvious which.
              </li>
            </ol>
            <p className="report-note">
              If an ad broke Google&apos;s own rules, the <strong>ⓘ</strong> mark
              on the ad reports it to Google directly. That is a different
              channel and it is worth using as well as this one.
            </p>
          </section>
        </Reveal>
      </main>
      <Footer />
    </>
  );
}
