import Image from "next/image";
import Link from "next/link";
import {
  ArrowRightIcon,
  ChatCircleDotsIcon,
  SparkleIcon,
  SquaresFourIcon
} from "@phosphor-icons/react/dist/ssr";
import { Footer, Nav, PlayButton } from "./components/Shell";
import { Reveal } from "./components/Reveal";
import { SoftwareJsonLd } from "./seo";
import { releases } from "./lib/changelog";
import { siteConfig } from "./site-config";

/**
 * One screen, then three doors.
 *
 * This page used to be the whole site: a bento of features, the vault, the
 * player, a FAQ, all stacked. Once those got pages of their own it was saying
 * everything twice, and a landing page that repeats the site is a landing page
 * nobody scrolls. Its job now is to make the product legible in one screen and
 * then get out of the way.
 */
const DOORS = [
  {
    href: "/features",
    icon: SquaresFourIcon,
    title: "What it does",
    body: "Downloading, the vault, the player, and every folder on your phone."
  },
  {
    href: "/support",
    icon: ChatCircleDotsIcon,
    title: "Get help",
    body: "An assistant that answers from the app's documentation, or a person."
  },
  {
    href: "/changelog",
    icon: SparkleIcon,
    title: "What's new",
    body: "Every release, and what changed for the people using it."
  }
];

export default function HomePage() {
  // The newest entry, so the door to the changelog carries real news.
  const latest = releases[0];

  return (
    <>
      <SoftwareJsonLd />
      <Nav />

      <main>
        <section className="hero hero-tall">
          <div className="hero-bg" aria-hidden />
          <div className="wrap hero-grid">
            <div className="hero-copy">
              <h1 className="display">
                Copy a link.
                <br />
                Keep the file.
              </h1>
              <p className="lede">
                Duck saves video, photos and audio from public social links to
                your phone. Files stay on your device.
              </p>
              <div className="hero-actions">
                <PlayButton />
                <Link className="btn btn-ghost" href="/features">
                  See what it does
                </Link>
              </div>
            </div>

            <div className="hero-device">
              <div className="phone">
                <div className="phone-glow" aria-hidden />
                <Image
                  src="/shots/hero-home.jpg"
                  alt="Duck Downloader home screen after a completed download"
                  width={1080}
                  height={2400}
                  priority
                  sizes="(max-width: 900px) 78vw, 300px"
                />
              </div>
            </div>
          </div>
        </section>

        <section className="doors-section">
          <div className="wrap">
            <div className="doors">
              {DOORS.map((door, i) => {
                const Icon = door.icon;
                return (
                  <Reveal key={door.href} delay={i * 70}>
                    <Link className="door" href={door.href}>
                      <span className="door-icon">
                        <Icon size={20} weight="bold" />
                      </span>
                      <h2 className="h3">{door.title}</h2>
                      <p className="body">{door.body}</p>
                      {door.href === "/changelog" ? (
                        <span className="door-note">
                          Latest: v{latest.version}
                        </span>
                      ) : null}
                      <span className="door-go">
                        <ArrowRightIcon size={16} weight="bold" />
                      </span>
                    </Link>
                  </Reveal>
                );
              })}
            </div>
          </div>
        </section>
      </main>

      <Footer />
    </>
  );
}
