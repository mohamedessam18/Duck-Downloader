import type { Metadata } from "next";
import Image from "next/image";
import { LifebuoyIcon, WhatsappLogoIcon } from "@phosphor-icons/react/dist/ssr";
import { Footer, Nav, PageHead } from "../components/Shell";
import { Reveal } from "../components/Reveal";
import { SupportBot } from "../components/SupportBot";
import { articles } from "../lib/knowledge";
import { siteConfig } from "../site-config";

export const metadata: Metadata = {
  title: "Support",
  description:
    "Answers about downloads, the vault, Premium and file management, plus a way to reach a person.",
  alternates: { canonical: "/support" }
};

const TOPICS = [
  { id: "downloads", label: "Downloading" },
  { id: "vault", label: "The vault" },
  { id: "playback", label: "Playing media" },
  { id: "files", label: "Your files" },
  { id: "premium", label: "Premium" },
  { id: "general", label: "General" }
] as const;

export default function SupportPage() {
  return (
    <>
      <Nav />
      <main>
        <PageHead
          eyebrow="Support"
          title="Ask, or read"
          lede="The assistant answers from the same documentation below. It has no invented answers to give, so when it does not know, it says so."
        />

        <section className="wrap section-tight">
          <div className="support-top">
            <Reveal>
              <SupportBot />
            </Reveal>
            <Reveal className="support-aside" delay={90}>
              <p className="aside-label">Most asked</p>
              <div className="aside-card">
                <div className="clip-frame">
                  <Image
                    src="/shots/crop-vault-pin.jpg"
                    alt="The vault asking for a six-digit passcode"
                    width={1080}
                    height={900}
                    sizes="(max-width: 1000px) 92vw, 320px"
                  />
                </div>
                <h3 className="h3">Forgot the vault passcode</h3>
                <p className="body">
                  There is no reset. The key is derived on your device, so no
                  server holds a copy and nobody can open it for you.
                </p>
              </div>
              <div className="aside-card">
                <div className="clip-frame">
                  <Image
                    src="/shots/crop-settings.jpg"
                    alt="The Settings screen showing the Downloads section"
                    width={1080}
                    height={900}
                    sizes="(max-width: 1000px) 92vw, 320px"
                  />
                </div>
                <h3 className="h3">Turning things off</h3>
                <p className="body">
                  Link detection, auto-save and crash reports each have a switch
                  in Settings.
                </p>
              </div>
            </Reveal>
          </div>
        </section>

        <section className="wrap section">
          <Reveal>
            <h2 className="h3 kb-title">Everything it knows</h2>
          </Reveal>
          {TOPICS.map((topic, t) => {
            const entries = articles.filter((a) => a.topic === topic.id);
            if (entries.length === 0) return null;
            return (
              <Reveal key={topic.id} delay={t * 40}>
                <div className="kb-group">
                  <h3 className="kb-heading">{topic.label}</h3>
                  <div className="faq">
                    {entries.map((entry) => (
                      <details key={entry.id}>
                        <summary>{entry.question}</summary>
                        <p className="body faq-answer">{entry.answer}</p>
                      </details>
                    ))}
                  </div>
                </div>
              </Reveal>
            );
          })}
        </section>

        <section className="wrap section-tight">
          <Reveal>
            <div className="callout">
              <span className="callout-icon">
                <LifebuoyIcon size={20} weight="bold" />
              </span>
              <div>
                <h2 className="h3">Still stuck?</h2>
                <p className="body">
                  Message support directly. Include what you were doing and what
                  happened instead, and it gets sorted faster.
                </p>
              </div>
              <a
                className="btn btn-primary"
                href={siteConfig.whatsapp.href}
                target="_blank"
                rel="noopener noreferrer"
              >
                <WhatsappLogoIcon size={17} weight="fill" />
                WhatsApp
              </a>
            </div>
          </Reveal>
        </section>
      </main>
      <Footer />
    </>
  );
}
