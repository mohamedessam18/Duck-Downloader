import Image from "next/image";
import { SoftwareJsonLd } from "./seo";
import { siteConfig } from "./site-config";

const features = [
  {
    title: "1-Second Extraction",
    text: "Instant URL parsing and direct stream delivery powered by a high-speed multi-platform engine.",
    icon: "play"
  },
  {
    title: "Complete Social Support",
    text: "Seamlessly save high-quality media from YouTube, Instagram, Facebook, TikTok, X (Twitter), and SoundCloud.",
    icon: "link"
  },
  {
    title: "Secure Private Vault",
    text: "Protect your personal downloads inside a passcode-secured, local-first folder with filename obfuscation.",
    icon: "shield"
  },
  {
    title: "Active Download Queue",
    text: "Queue multiple media files simultaneously with real-time progress bars, speed metrics, and status updates.",
    icon: "queue"
  }
];

const steps = [
  "Copy a public video, audio, or photo link.",
  "Tap the central Duck button to trigger 1-second extraction.",
  "Select your desired video quality (1080p, 2K, 4K) or audio format.",
  "Watch progress live and access files instantly in your local library."
];

const faqs = [
  {
    question: "How does the 1-second download work?",
    answer:
      "Duck integrates a high-speed, direct-to-device streaming client that bypasses traditional server-side scraping queues, allowing downloads to start instantly at maximum residential bandwidth."
  },
  {
    question: "Is Duck really secure and private?",
    answer:
      "Yes. Duck is designed local-first. We do not track your downloads, search history, or personal data. The optional secure vault obfuscates files and locks them behind a device-level passcode."
  },
  {
    question: "Does Duck require a paid subscription?",
    answer:
      "No. Duck is fully functional for free with basic ads. Users can optionally upgrade to Duck Pro for a completely ad-free experience, unlimited background conversions, and advanced premium features."
  },
  {
    question: "Can I download my own private social media posts?",
    answer:
      "Duck is optimized for public media. However, if a video is age-restricted or private to your account, you can use Duck's built-in secure WebView browser to log in and sync local session cookies on-device."
  }
];

function Icon({ name, className }: { name: "android" | "windows" | "link" | "shield" | "queue" | "play" | "arrow"; className?: string }) {
  const common = {
    width: 22,
    height: 22,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 2,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    className: className,
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

  if (name === "arrow") {
    return (
      <svg {...common} strokeWidth={2.5}>
        <path d="M5 12h14" />
        <path d="m12 5 7 7-7 7" />
      </svg>
    );
  }

  return (
    <svg {...common}>
      <path d="m8 5 11 7-11 7V5Z" />
    </svg>
  );
}

function AppPreview() {
  return (
    <div className="app-window-wrapper">
      <div className="glow-effect" />
      <div className="app-window" aria-label="Duck Downloader app preview">
        <div className="window-bar">
          <div className="window-dots" aria-hidden="true">
            <span />
            <span />
            <span />
          </div>
          <span>Duck Downloader - Mobile Preview</span>
        </div>
        <div className="window-body">
          <div className="preview-logo">
            <Image src="/duck-idle.png" alt="Duck Downloader logo" width={48} height={48} priority />
            <span className="logo-text">Duck Downloader</span>
          </div>

          <div className="hint-pill">
            <Icon name="link" className="pulse-icon" />
            <span>Link detected from clipboard! Tap the duck to save.</span>
          </div>

          <div className="duck-stage">
            <div className="stage-glow" />
            <Image src="/duck-loading.png" alt="Duck loading state" width={170} height={170} className="floating-duck" />
            <div className="stage-ring" aria-hidden="true" />
          </div>

          <div className="progress-preview">
            <strong className="glitch-text">Downloading...</strong>
            <div className="progress-track">
              <span className="progress-bar-fill" />
            </div>
            <div className="progress-meta">
              <small>74% - High-speed Stream</small>
              <small className="speed-badge">12.4 MB/s</small>
            </div>
          </div>

          <div className="queue-preview">
            <div className="queue-head">
              <strong>Active Downloads</strong>
              <span className="count-badge">2</span>
            </div>
            {[
              ["Video (1080p)", "Instagram Reel - Tech Setup", "92%"],
              ["Audio (MP3)", "SoundCloud Track - Chill Mix", "40%"]
            ].map(([type, title, progress]) => (
              <div className="queue-row" key={title}>
                <div className="thumb">
                  <Icon name="play" />
                </div>
                <div className="queue-meta-text">
                  <span className="row-title">{title}</span>
                  <div className="mini-track">
                    <i className="mini-fill" style={{ width: progress }} />
                  </div>
                </div>
                <b className="row-percentage">{progress}</b>
                <em className="row-type">{type}</em>
              </div>
            ))}
          </div>

          <nav className="preview-tabs" aria-label="Preview app tabs">
            <span className="tab-item active">HOME</span>
            <span className="tab-item">VIDEOS</span>
            <span className="tab-item">AUDIOS</span>
          </nav>
        </div>
      </div>
    </div>
  );
}

export default function Home() {
  return (
    <>
      <SoftwareJsonLd />
      <header className="site-header">
        <a className="brand-logo" href="#top" aria-label="Duck Downloader home">
          <Image src="/duck-idle.png" alt="" width={36} height={36} className="header-duck" />
          <span>Duck Downloader</span>
        </a>
        <nav className="header-nav" aria-label="Primary navigation">
          <a href="#features" className="nav-link">Features</a>
          <a href="#workflow" className="nav-link">Workflow</a>
          <a href="#platforms" className="nav-link">Platforms</a>
          <a href="#faq" className="nav-link">FAQ</a>
        </nav>
        <a className="header-cta" href="#platforms">
          <span>Get App</span>
          <Icon name="arrow" className="cta-arrow" />
        </a>
      </header>

      <main id="top">
        <section className="hero-section">
          <div className="hero-grid">
            <div className="hero-content">
              <div className="badge-new">Version {siteConfig.version} Now Available</div>
              <h1 className="hero-title">
                Save Media <br />
                <span className="text-gradient">In Under A Second</span>
              </h1>
              <p className="hero-description">
                A calm, ultra-fast download manager for public social links. Just copy a link, tap the duck, and store high-quality video or audio directly on your device.
              </p>
              <div className="hero-cta-group">
                <a href="#platforms" className="btn btn-primary">
                  <Icon name="android" />
                  <span>Download APK</span>
                </a>
                <a href="#platforms" className="btn btn-secondary">
                  <Icon name="windows" />
                  <span>Windows Installer</span>
                </a>
              </div>
              <div className="hero-features-preview">
                <span className="feature-pill">
                  <Icon name="shield" /> Safe & Local-first
                </span>
                <span className="feature-pill">
                  <Icon name="queue" /> Multi-item Queue
                </span>
                <span className="feature-pill">
                  <Icon name="play" /> High-quality Muxing
                </span>
              </div>
            </div>
            <div className="hero-preview-container">
              <AppPreview />
            </div>
          </div>
        </section>

        <section className="section-container" id="features">
          <div className="section-header text-center">
            <span className="pre-title">Core Capability</span>
            <h2 className="section-title">Built For Speed, Privacy & Simplicity</h2>
            <p className="section-subtitle">
              We stripped away all unnecessary forms, complicated settings, and bloated dependencies to give you the cleanest possible download experience.
            </p>
          </div>
          <div className="features-grid-container">
            {features.map((feature) => (
              <div className="feature-card-wrapper" key={feature.title}>
                <div className="feature-card-glow" />
                <article className="feature-card-body">
                  <div className="feature-card-icon">
                    <Icon name={feature.icon as any} />
                  </div>
                  <h3 className="feature-card-title">{feature.title}</h3>
                  <p className="feature-card-text">{feature.text}</p>
                </article>
              </div>
            ))}
          </div>
        </section>

        <section className="section-container workflow-section" id="workflow">
          <div className="workflow-grid">
            <div className="workflow-info">
              <span className="pre-title">How it works</span>
              <h2 className="section-title">From clipboard to storage in 4 simple steps.</h2>
              <p className="section-subtitle">
                The interface is built dynamically around the central Duck action. Paste links instantly and choose your qualities in a clean, overlay card.
              </p>
            </div>
            <div className="workflow-steps-list">
              <ol className="styled-steps-ol">
                {steps.map((step, index) => (
                  <li className="step-item" key={step}>
                    <div className="step-number">{String(index + 1).padStart(2, "0")}</div>
                    <div className="step-content-body">
                      <p className="step-text">{step}</p>
                    </div>
                  </li>
                ))}
              </ol>
            </div>
          </div>
        </section>

        <section className="section-container" id="platforms">
          <div className="section-header text-center">
            <span className="pre-title">Available Platforms</span>
            <h2 className="section-title">Get Duck For Your Device</h2>
            <p className="section-subtitle">
              Enjoy lightning-fast downloading and offline local organization across mobile and desktop interfaces.
            </p>
          </div>
          <div className="platforms-grid-container">
            {siteConfig.platforms.map((platform) => (
              <article className="platform-card-wrapper" key={platform.name}>
                <div className="platform-card-header">
                  <div className="platform-icon-container">
                    <Icon name={platform.name === "Android" ? "android" : "windows"} />
                  </div>
                  <div>
                    <h3 className="platform-card-title">{platform.name}</h3>
                    <span className="platform-status-badge">{platform.status}</span>
                  </div>
                </div>
                <p className="platform-card-desc">{platform.detail}</p>
                {platform.name === "Android" ? (
                  <a href="/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk" download className="platform-download-btn">
                    Download APK (Recommended)
                  </a>
                ) : (
                  <button type="button" aria-disabled="true" className="platform-download-btn disabled">
                    {platform.actionLabel}
                  </button>
                )}
              </article>
            ))}
          </div>
        </section>

        <section className="section-container safety-section" id="safety">
          <div className="safety-grid">
            <div className="safety-info">
              <span className="pre-title">Security Standards</span>
              <h2 className="section-title">Strictly Designed For Personal Use</h2>
            </div>
            <div className="safety-details-list">
              <div className="safety-detail-item">
                <strong>Public Links Only</strong>
                <p>Duck does not support private profiles, DRM-locked content, or paid/protected websites.</p>
              </div>
              <div className="safety-detail-item">
                <strong>No Tracking / No Logs</strong>
                <p>We do not store your download logs, search keywords, or cached files. Everything stays on-device.</p>
              </div>
              <div className="safety-detail-item">
                <strong>Encrypted Vault Obfuscation</strong>
                <p>Private vault files are renamed, hidden in a secure subfolder, and locked local-only behind a passcode.</p>
              </div>
            </div>
          </div>
        </section>

        <section className="section-container faq-section" id="faq">
          <div className="faq-grid">
            <div className="faq-info">
              <span className="pre-title">Got Questions?</span>
              <h2 className="section-title">Frequently Asked Questions</h2>
            </div>
            <div className="faq-accordion-list">
              {faqs.map((faq) => (
                <details className="faq-details" key={faq.question}>
                  <summary className="faq-summary">
                    <span>{faq.question}</span>
                    <span className="summary-arrow">+</span>
                  </summary>
                  <div className="faq-content">
                    <p>{faq.answer}</p>
                  </div>
                </details>
              ))}
            </div>
          </div>
        </section>
      </main>

      <footer className="site-footer">
        <div className="footer-top">
          <a className="footer-brand" href="#top">
            <Image src="/duck-idle.png" alt="" width={38} height={38} />
            <span>{siteConfig.name}</span>
          </a>
          <p className="footer-tagline">{siteConfig.tagline}</p>
        </div>
        <div className="footer-bottom">
          <small className="copyright">© 2026 Duck Downloader. All rights reserved. Created for personal, public link organization only.</small>
          <div className="footer-links">
            <a href="/privacy-policy.html" className="footer-link">Privacy Policy</a>
          </div>
        </div>
      </footer>
    </>
  );
}
