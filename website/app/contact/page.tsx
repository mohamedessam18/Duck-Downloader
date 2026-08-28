import type { Metadata } from "next";
import Image from "next/image";
import {
  BugIcon,
  EnvelopeSimpleIcon,
  LightbulbIcon,
  ShieldWarningIcon,
  WhatsappLogoIcon
} from "@phosphor-icons/react/dist/ssr";
import { Footer, Nav, PageHead } from "../components/Shell";
import { Reveal } from "../components/Reveal";
import { siteConfig } from "../site-config";

export const metadata: Metadata = {
  title: "Contact",
  description: "Reach Duck Downloader support by WhatsApp or email.",
  alternates: { canonical: "/contact" }
};

/**
 * Every route below opens something the sender can see afterwards: a WhatsApp
 * thread, or their own sent-mail. There is no form posting into a server we
 * would then have to keep alive, and no "message sent" screen that could be
 * lying. A message you can still see is a message that did not vanish.
 */
const ROUTES = [
  {
    icon: BugIcon,
    title: "Something is broken",
    body: "Tell us what you did, what you expected, and what happened instead. Your phone model and Android version help.",
    subject: "Duck Downloader - bug report",
    prefill:
      "What I did:\n\nWhat I expected:\n\nWhat happened instead:\n\nPhone and Android version:"
  },
  {
    icon: LightbulbIcon,
    title: "An idea",
    body: "Something missing, or something that could be simpler. Short is fine.",
    subject: "Duck Downloader - idea",
    prefill: "My idea:\n\nWhy it would help:"
  },
  {
    icon: ShieldWarningIcon,
    title: "A security issue",
    body: "Report it privately and it gets looked at first. Please do not post it publicly before it is fixed.",
    subject: "Duck Downloader - security report",
    prefill: "What I found:\n\nHow to reproduce it:"
  }
];

export default function ContactPage() {
  const wa = siteConfig.whatsapp;

  return (
    <>
      <Nav />
      <main>
        <PageHead
          eyebrow="Contact"
          title="Talk to a person"
          lede="One developer reads all of this, so plain and specific beats formal every time."
        />

        <section className="wrap section-tight">
          <div className="contact-grid">
            <Reveal>
              <a
                className="contact-card contact-primary"
                href={wa.href}
                target="_blank"
                rel="noopener noreferrer"
              >
                <span className="contact-icon">
                  <WhatsappLogoIcon size={22} weight="fill" />
                </span>
                <h2 className="h3">WhatsApp</h2>
                <p className="body">
                  The fastest route. Usually answered the same day.
                </p>
                <span className="contact-value">{wa.display}</span>
              </a>
            </Reveal>
            <Reveal delay={70}>
              <a
                className="contact-card"
                href={`mailto:${siteConfig.contactEmail}`}
              >
                <span className="contact-icon">
                  <EnvelopeSimpleIcon size={22} weight="bold" />
                </span>
                <h2 className="h3">Email</h2>
                <p className="body">
                  Better for anything long, or when you need to attach a file.
                </p>
                <span className="contact-value">{siteConfig.contactEmail}</span>
              </a>
            </Reveal>
          </div>
        </section>

        <section className="wrap section">
          <div className="contact-lead">
            <Reveal>
              <h2 className="h2">Pick a starting point</h2>
              <p className="body contact-lead-body">
                Both buttons open with the questions already written, so you
                only have to answer them. Nothing is posted to a server you
                cannot see; the message stays in your own WhatsApp or sent mail.
              </p>
            </Reveal>
            <Reveal className="contact-lead-shot" delay={80}>
              <div className="clip-frame">
                <Image
                  src="/shots/crop-clipboard.jpg"
                  alt="Duck Downloader notification on a phone"
                  width={1080}
                  height={620}
                  sizes="(max-width: 900px) 92vw, 400px"
                />
              </div>
            </Reveal>
          </div>
          <div className="routes">
            {ROUTES.map((route, i) => {
              const Icon = route.icon;
              const mail = `mailto:${siteConfig.contactEmail}?subject=${encodeURIComponent(route.subject)}&body=${encodeURIComponent(route.prefill)}`;
              const chat = `${wa.href}?text=${encodeURIComponent(`${route.subject}\n\n${route.prefill}`)}`;
              return (
                <Reveal key={route.title} delay={i * 60}>
                  <div className="route">
                    <span className="cell-icon">
                      <Icon size={19} weight="bold" />
                    </span>
                    <h3 className="h3">{route.title}</h3>
                    <p className="body">{route.body}</p>
                    <div className="route-actions">
                      <a
                        className="btn btn-primary btn-sm"
                        href={chat}
                        target="_blank"
                        rel="noopener noreferrer"
                      >
                        WhatsApp
                      </a>
                      <a className="btn btn-ghost btn-sm" href={mail}>
                        Email
                      </a>
                    </div>
                  </div>
                </Reveal>
              );
            })}
          </div>
          <Reveal delay={200}>
            <p className="small routes-note">
              Both buttons open with the questions already filled in, so you only
              have to answer them.
            </p>
          </Reveal>
        </section>
      </main>
      <Footer />
    </>
  );
}
