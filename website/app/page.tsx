import Image from "next/image";
import Link from "next/link";
import {
  ClipboardTextIcon,
  DownloadSimpleIcon,
  FoldersIcon,
  GooglePlayLogoIcon,
  LockKeyIcon,
  PlayCircleIcon,
  PlusIcon,
  SlidersHorizontalIcon,
  WhatsappLogoIcon,
  WifiSlashIcon
} from "@phosphor-icons/react/dist/ssr";
import { Reveal } from "./components/Reveal";
import { SoftwareJsonLd } from "./seo";
import { siteConfig } from "./site-config";

/**
 * Screenshots are the real app, captured over adb on a real device.
 *
 * The page this replaced built its hero "preview" out of styled divs: a fake
 * clipboard toast, a fake progress row, a fake download list. That is a
 * promise the product has to keep, made by markup that cannot keep it. These
 * are the screens themselves, so what the page shows and what the app does
 * cannot drift apart.
 */
const shot = (name: string) => `/shots/${name}.jpg`;

const faqs = [
  {
    q: "Which links does it handle?",
    a: "Public posts on the major social platforms. Private accounts, paid or DRM-protected content, and anything behind a login are out of scope by design."
  },
  {
    q: "Do my files or links leave the device?",
    a: "No. Downloads are written straight to your storage, and the vault is encrypted on the device itself. Nothing about what you save reaches a server."
  },
  {
    q: "What happens if I forget the vault passcode?",
    a: "The files stay encrypted and cannot be recovered. That is what makes the vault a vault: the key exists only on your device, and only you have it."
  },
  {
    q: "Is there a free version?",
    a: `Yes. ${siteConfig.name} is free with ads. Premium removes them and adds faster processing.`
  },
  {
    q: "Can I use it offline?",
    a: "Everything you have already saved plays offline. Fetching a new link needs a connection."
  }
];

export default function HomePage() {
  const play = siteConfig.play;

  return (
    <>
      <SoftwareJsonLd />
      <header className="nav">
        <div className="nav-inner">
          <Link className="brand" href="/">
            <Image src="/duck-idle.png" alt="" width={26} height={26} priority />
            <span>{siteConfig.name}</span>
          </Link>
          <nav className="nav-links" aria-label="Primary">
            <a className="nav-link" href="#features">Features</a>
            <a className="nav-link" href="#vault">Vault</a>
            <a className="nav-link" href="#how">How it works</a>
            <a className="nav-link" href="#faq">FAQ</a>
          </nav>
          <PlayButton small />
        </div>
      </header>

      <main>
        {/* 1. Hero - asymmetric split */}
        <section className="hero">
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
                <a className="btn btn-ghost" href="#features">See what it does</a>
              </div>
            </div>
            <div className="hero-device">
              <div className="phone">
                <div className="phone-glow" aria-hidden />
                <Image
                  src={shot("hero-home")}
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

        {/* 2. Clipboard - split */}
        <section className="section">
          <div className="wrap split">
            <div className="split-copy">
              <Reveal>
                <h2 className="h2">It notices before you ask</h2>
              </Reveal>
              <Reveal delay={70}>
                <p className="body">
                  Copy a link anywhere on your phone and Duck offers to save it.
                  No pasting, no switching apps first, no hunting for a download
                  button that moved.
                </p>
              </Reveal>
              <Reveal delay={120}>
                <p className="small">
                  Detection can be switched off in Settings at any time.
                </p>
              </Reveal>
            </div>
            <Reveal className="split-media">
              <div className="phone">
                <Image
                  src={shot("clipboard")}
                  alt="A notification offering to download a link that was just copied"
                  width={1080}
                  height={2400}
                  sizes="(max-width: 860px) 74vw, 280px"
                />
              </div>
            </Reveal>
          </div>
        </section>

        {/* 3. Features - bento, five cells for five features */}
        <section className="section" id="features">
          <div className="wrap">
            <Reveal>
              <p className="eyebrow">What it does</p>
              <h2 className="h2" style={{ marginBottom: "44px" }}>
                A library, not a downloads folder
              </h2>
            </Reveal>

            <div className="bento">
              <Reveal className="cell cell-lg cell-media">
                <div className="cell-icon"><DownloadSimpleIcon size={20} weight="bold" /></div>
                <h3 className="h3">Watch it arrive</h3>
                <p className="body">
                  Real progress, from the first byte to the finished file, with
                  the duck doing the waiting for you.
                </p>
                <div className="cell-shot cell-shot-tall">
                  <Image
                    src={shot("crop-progress")}
                    alt="A download in progress, 80 percent cached"
                    width={1080}
                    height={820}
                    sizes="(max-width: 900px) 90vw, 620px"
                  />
                </div>
              </Reveal>

              <Reveal className="cell cell-sm" delay={60}>
                <div className="cell-icon"><WifiSlashIcon size={20} weight="bold" /></div>
                <h3 className="h3">Yours offline</h3>
                <p className="body">
                  Saved files play with no connection, and no server between you
                  and them.
                </p>
              </Reveal>

              <Reveal className="cell cell-sm" delay={90}>
                <div className="cell-icon"><SlidersHorizontalIcon size={20} weight="bold" /></div>
                <h3 className="h3">Trim and convert</h3>
                <p className="body">
                  Cut a clip, pull the audio out, make a GIF, shrink a file that
                  is too big to send.
                </p>
              </Reveal>

              <Reveal className="cell cell-md cell-media" delay={120}>
                <div className="cell-icon"><FoldersIcon size={20} weight="bold" /></div>
                <h3 className="h3">Every folder on the phone</h3>
                <p className="body">
                  Browse, rename and move what is already on your device, not
                  only what Duck downloaded.
                </p>
                <div className="cell-shot cell-shot-tall">
                  <Image
                    src={shot("crop-folders")}
                    alt="The folder browser listing video folders on the device"
                    width={1080}
                    height={880}
                    sizes="(max-width: 900px) 90vw, 460px"
                  />
                </div>
              </Reveal>

              <Reveal className="cell cell-md cell-media" delay={150}>
                <div className="cell-icon"><PlayCircleIcon size={20} weight="bold" /></div>
                <h3 className="h3">Sorted as it lands</h3>
                <p className="body">
                  Video, photos and audio each get their own shelf, with
                  favourites and playlists on top.
                </p>
                <div className="cell-shot cell-shot-tall">
                  <Image
                    src={shot("crop-library")}
                    alt="The video library listing several saved downloads"
                    width={1080}
                    height={980}
                    sizes="(max-width: 900px) 90vw, 460px"
                  />
                </div>
              </Reveal>
            </div>
          </div>
        </section>

        {/* 4. Vault - split, flipped */}
        <section className="section split-flip" id="vault">
          <div className="wrap split split-flip">
            <div className="split-copy">
              <Reveal>
                <h2 className="h2">A vault that stays shut</h2>
              </Reveal>
              <Reveal delay={70}>
                <p className="body">
                  Move anything into the vault and it is encrypted on your
                  device with AES-256, behind a six-digit passcode or your
                  fingerprint. Names and thumbnails stay blurred until you ask
                  for them, so a glance over your shoulder shows nothing.
                </p>
              </Reveal>
              <Reveal delay={120}>
                <p className="small">
                  The key never leaves the phone. Lose the passcode and the
                  files stay locked, including to us.
                </p>
              </Reveal>
            </div>
            <Reveal className="split-media" delay={60}>
              <div className="phone">
                <div className="phone-glow" aria-hidden />
                <Image
                  src={shot("vault-blurred")}
                  alt="The vault listing files with their names and thumbnails blurred"
                  width={1080}
                  height={2400}
                  sizes="(max-width: 860px) 74vw, 280px"
                />
              </div>
            </Reveal>
          </div>
        </section>

        {/* 5. Player - full-width showcase */}
        <section className="section">
          <div className="wrap showcase">
            <Reveal>
              <h2 className="h2">A player worth staying in</h2>
            </Reveal>
            <Reveal delay={70}>
              <p className="lede">
                Gestures for seek and volume, picture-in-picture, background
                audio that survives a locked screen, and trimming without
                leaving the video.
              </p>
            </Reveal>
            <Reveal className="showcase-frame" delay={120}>
              <div className="wide-frame">
                <Image
                  src={shot("player")}
                  alt="The video player in landscape with trim, GIF, picture-in-picture and speed controls"
                  width={2400}
                  height={1080}
                  sizes="(max-width: 1000px) 92vw, 940px"
                />
              </div>
            </Reveal>
          </div>
        </section>

        {/* 6. How it works - hairline steps */}
        <section className="section" id="how">
          <div className="wrap">
            <Reveal>
              <h2 className="h2" style={{ marginBottom: "40px" }}>
                Three taps, start to finish
              </h2>
            </Reveal>
            <div className="steps">
              {[
                {
                  n: "Copy",
                  t: "Grab the link",
                  d: "Share or copy a post from any app on your phone."
                },
                {
                  n: "Confirm",
                  t: "Pick the quality",
                  d: "Duck reads the link and offers what is available."
                },
                {
                  n: "Keep",
                  t: "It is yours",
                  d: "The file lands in your library, and in your gallery if you want it there."
                }
              ].map((step, i) => (
                <Reveal className="step" key={step.n} delay={i * 70}>
                  <span className="step-n">{step.n}</span>
                  <h3 className="h3">{step.t}</h3>
                  <p className="body">{step.d}</p>
                </Reveal>
              ))}
            </div>
          </div>
        </section>

        {/* 7. FAQ - accordion */}
        <section className="section" id="faq">
          <div className="wrap">
            <Reveal>
              <p className="eyebrow">Before you ask</p>
              <h2 className="h2" style={{ marginBottom: "40px" }}>
                Questions worth answering
              </h2>
            </Reveal>
            <div className="faq">
              {faqs.map((item, i) => (
                <Reveal key={item.q} delay={i * 40}>
                  <details>
                    <summary>
                      {item.q}
                      <PlusIcon className="faq-mark" size={18} weight="bold" />
                    </summary>
                    <p className="body faq-answer">{item.a}</p>
                  </details>
                </Reveal>
              ))}
            </div>
          </div>
        </section>

        {/* 8. Closing CTA */}
        <section className="section">
          <div className="wrap showcase">
            <Reveal>
              <h2 className="h2">Keep what you save</h2>
            </Reveal>
            <Reveal delay={70}>
              <PlayButton />
            </Reveal>
          </div>
        </section>
      </main>

      <footer className="footer">
        <div className="wrap footer-inner">
          <Link className="brand" href="/">
            <Image src="/duck-idle.png" alt="" width={22} height={22} />
            <span>{siteConfig.name}</span>
          </Link>
          <div className="footer-links">
            <Link href="/privacy">Privacy</Link>
            <a href={`mailto:${siteConfig.contactEmail}`}>{siteConfig.contactEmail}</a>
            <a
              href={siteConfig.whatsapp.href}
              target="_blank"
              rel="noopener noreferrer"
            >
              <WhatsappLogoIcon size={16} weight="fill" aria-hidden />
              WhatsApp support
            </a>
          </div>
        </div>
      </footer>
    </>
  );
}

/**
 * The only call to action on the page.
 *
 * One intent, one label, everywhere it appears. The page it replaced had
 * "Get App" in the nav, "Download APK" in the hero and "Windows Installer"
 * beside it, which asked the reader to work out that two of them were the same
 * request. It also promised a platform whose installer did not exist yet, next
 * to a card claiming that platform was "Available".
 */
function PlayButton({ small = false }: { small?: boolean }) {
  const { live, url, label } = siteConfig.play;
  const className = `btn btn-primary${small ? " btn-sm" : ""}`;

  if (live && url) {
    return (
      <a className={className} href={url}>
        <GooglePlayLogoIcon size={small ? 17 : 19} weight="fill" />
        {label}
      </a>
    );
  }

  return (
    <span className={className} aria-disabled="true">
      <GooglePlayLogoIcon size={small ? 17 : 19} weight="fill" />
      {small ? "Coming soon" : "Coming to Google Play"}
    </span>
  );
}
