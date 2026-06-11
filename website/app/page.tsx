import Image from "next/image";
import { SoftwareJsonLd } from "./seo";
import { siteConfig } from "./site-config";

const features = [
  {
    title: "One tap flow",
    text: "Copy a public link, tap the duck, choose video or audio, then watch real progress."
  },
  {
    title: "Download queue",
    text: "Multiple downloads can keep moving together with per-item status and progress."
  },
  {
    title: "Local library",
    text: "Downloaded videos and audios are organized locally with thumbnails and file actions."
  },
  {
    title: "Backend engine",
    text: "Duck uses a FastAPI service with yt-dlp and FFmpeg for public supported sources."
  }
];

const steps = [
  "Copy a public social media link.",
  "Tap the duck to detect and extract options.",
  "Pick video or audio quality.",
  "Download locally and manage it from your library."
];

const faqs = [
  {
    question: "Is Duck available now?",
    answer:
      "Android and Windows are the first supported platforms. Public download links are marked Coming soon until the release files are published."
  },
  {
    question: "Does Duck download private or protected media?",
    answer:
      "No. Duck is designed for public links only and does not bypass DRM, logins, or protected content."
  },
  {
    question: "Does the site include real installer links?",
    answer:
      "Not yet. The buttons intentionally show Coming soon so there are no broken or fake downloads."
  },
  {
    question: "Where do downloads go in the app?",
    answer:
      "The apps save real files locally and keep metadata such as title, thumbnail, quality, and status in local storage."
  }
];

function Icon({ name }: { name: "android" | "windows" | "link" | "shield" | "queue" | "play" }) {
  const common = {
    width: 22,
    height: 22,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 2,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    "aria-hidden": true
  };

  if (name === "android") {
    return (
      <svg {...common}>
        <path d="M7 8h10v9a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2V8Z" />
        <path d="m8 4 2 3" />
        <path d="m16 4-2 3" />
        <path d="M9 12h.01" />
        <path d="M15 12h.01" />
        <path d="M5 10v5" />
        <path d="M19 10v5" />
      </svg>
    );
  }

  if (name === "windows") {
    return (
      <svg {...common}>
        <path d="M4 5.5 11 4v7H4V5.5Z" />
        <path d="M13 3.6 20 2v9h-7V3.6Z" />
        <path d="M4 13h7v7l-7-1.5V13Z" />
        <path d="M13 13h7v9l-7-1.6V13Z" />
      </svg>
    );
  }

  if (name === "link") {
    return (
      <svg {...common}>
        <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" />
        <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" />
      </svg>
    );
  }

  if (name === "shield") {
    return (
      <svg {...common}>
        <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10Z" />
        <path d="m9 12 2 2 4-4" />
      </svg>
    );
  }

  if (name === "queue") {
    return (
      <svg {...common}>
        <path d="M4 7h16" />
        <path d="M4 12h12" />
        <path d="M4 17h8" />
      </svg>
    );
  }

  return (
    <svg {...common}>
      <path d="m8 5 11 7-11 7V5Z" />
    </svg>
  );
}

function ComingSoonButton({ label }: { label: string }) {
  return (
    <button className="button button-muted" type="button" aria-disabled="true">
      <span>{label}</span>
      <strong>Coming soon</strong>
    </button>
  );
}

function AppPreview() {
  return (
    <div className="app-window" aria-label="Duck Downloader app preview">
      <div className="window-bar">
        <div className="window-dots" aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
        <span>Duck Downloader</span>
      </div>
      <div className="window-body">
        <div className="preview-logo">
          <Image src="/duck-logo.png" alt="Duck Downloader logo" width={190} height={86} priority />
        </div>

        <div className="hint-pill">
          <Icon name="link" />
          <span>Copy a link from any social media and tap the duck to download.</span>
        </div>

        <div className="duck-stage">
          <Image src="/duck-loading.png" alt="Duck loading state" width={188} height={188} />
          <div className="stage-ring" aria-hidden="true" />
        </div>

        <div className="progress-preview">
          <strong>Downloading...</strong>
          <div className="progress-track">
            <span />
          </div>
          <small>42% - live queue progress</small>
        </div>

        <div className="queue-preview">
          <div className="queue-head">
            <strong>Download Queue</strong>
            <span>3</span>
          </div>
          {[
            ["Video", "Public video link", "83%"],
            ["Audio", "Audio extraction", "40%"],
            ["Video", "New clipboard link", "0%"]
          ].map(([type, title, progress]) => (
            <div className="queue-row" key={title}>
              <div className="thumb">
                <Icon name="play" />
              </div>
              <div className="queue-meta">
                <span>{title}</span>
                <div className="mini-track">
                  <i style={{ width: progress }} />
                </div>
              </div>
              <b>{progress}</b>
              <em>{type}</em>
            </div>
          ))}
        </div>

        <nav className="preview-tabs" aria-label="Preview app tabs">
          <span className="active">HOME</span>
          <span>VIDEOS</span>
          <span>AUDIOS</span>
        </nav>
      </div>
    </div>
  );
}

export default function Home() {
  return (
    <>
      <SoftwareJsonLd />
      <header className="site-header">
        <a className="brand" href="#top" aria-label="Duck Downloader home">
          <Image src="/duck-idle.png" alt="" width={38} height={38} />
          <span>Duck Downloader</span>
        </a>
        <nav className="header-nav" aria-label="Primary navigation">
          <a href="#features">Features</a>
          <a href="#workflow">Workflow</a>
          <a href="#platforms">Platforms</a>
          <a href="#faq">FAQ</a>
        </nav>
        <a className="header-cta" href="#platforms">
          Get notified
        </a>
      </header>

      <main id="top">
        <section className="hero">
          <div className="hero-inner">
            <div className="availability">Android and Windows available</div>
            <h1>{siteConfig.name}</h1>
            <p className="tagline">{siteConfig.tagline}</p>
            <p className="hero-copy">
              A calm, simple downloader for public social media links. Copy a link, tap Duck, choose
              video or audio, and keep the file locally.
            </p>
            <div className="hero-actions" aria-label="Download status">
              <ComingSoonButton label="Android" />
              <ComingSoonButton label="Windows" />
            </div>
            <div className="trust-grid">
              <span>
                <Icon name="shield" /> Public links only
              </span>
              <span>
                <Icon name="queue" /> Real download queue
              </span>
              <span>
                <Icon name="play" /> Video and audio
              </span>
            </div>
            <AppPreview />
          </div>
        </section>

        <section className="section" id="features">
          <div className="section-head">
            <span className="eyebrow">Built for quick saves</span>
            <h2>Everything stays simple, visible, and local.</h2>
            <p>
              Duck keeps the product focused: one main action, clear options, real progress, and a
              local library for completed media.
            </p>
          </div>
          <div className="feature-grid">
            {features.map((feature) => (
              <article className="feature-card" key={feature.title}>
                <div className="card-icon">
                  <Icon name="queue" />
                </div>
                <h3>{feature.title}</h3>
                <p>{feature.text}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="section split" id="workflow">
          <div>
            <span className="eyebrow">How it works</span>
            <h2>From clipboard to saved file in one clean flow.</h2>
            <p>
              The interface is built around the duck button, so the user never has to hunt through
              forms or hidden pages before starting a download.
            </p>
          </div>
          <ol className="steps">
            {steps.map((step, index) => (
              <li key={step}>
                <span>{String(index + 1).padStart(2, "0")}</span>
                <p>{step}</p>
              </li>
            ))}
          </ol>
        </section>

        <section className="section" id="platforms">
          <div className="section-head">
            <span className="eyebrow">Platforms</span>
            <h2>Starting with Android and Windows.</h2>
            <p>
              The first public release targets mobile and desktop users. Download buttons are parked
              in Coming soon state until release files are ready.
            </p>
          </div>
          <div className="platform-grid">
            {siteConfig.platforms.map((platform) => (
              <article className="platform-card" key={platform.name}>
                <div className="platform-title">
                  <span>
                    <Icon name={platform.name === "Android" ? "android" : "windows"} />
                  </span>
                  <div>
                    <h3>{platform.name}</h3>
                    <p>{platform.status}</p>
                  </div>
                </div>
                <p>{platform.detail}</p>
                <button type="button" aria-disabled="true">
                  {platform.actionLabel}
                </button>
              </article>
            ))}
          </div>
        </section>

        <section className="section safety" id="safety">
          <div>
            <span className="eyebrow">Privacy and safety</span>
            <h2>Designed for public content, not protected content.</h2>
          </div>
          <div className="safety-list">
            <p>Duck does not bypass DRM, private accounts, login walls, or protected content.</p>
            <p>Audio is never auto-saved to gallery; video auto-save remains a user choice.</p>
            <p>The app stores downloads locally with user-controlled delete and share actions.</p>
          </div>
        </section>

        <section className="section faq" id="faq">
          <div>
            <span className="eyebrow">FAQ</span>
            <h2>Clear answers before release.</h2>
          </div>
          <div className="faq-list">
            {faqs.map((faq) => (
              <details key={faq.question}>
                <summary>{faq.question}</summary>
                <p>{faq.answer}</p>
              </details>
            ))}
          </div>
        </section>
      </main>

      <footer className="footer">
        <div>
          <Image src="/duck-idle.png" alt="" width={42} height={42} />
          <span>{siteConfig.name}</span>
        </div>
        <p>{siteConfig.tagline}</p>
        <small>© 2026 Duck Downloader. Built for public links only.</small>
      </footer>
    </>
  );
}
