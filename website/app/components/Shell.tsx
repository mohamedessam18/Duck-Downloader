import Image from "next/image";
import Link from "next/link";
import { ArrowRightIcon, GooglePlayLogoIcon } from "@phosphor-icons/react/dist/ssr";
import { updateBanner } from "../lib/changelog";
import { siteConfig } from "../site-config";

/**
 * One nav and one footer for every page.
 *
 * The site was a single page until now, so both lived inline in it. Copying
 * them into five more pages is how a nav ends up with a different set of links
 * depending on where you are standing.
 */
const LINKS = [
  { href: "/features", label: "Features" },
  { href: "/support", label: "Support" },
  { href: "/changelog", label: "Updates" },
  { href: "/contact", label: "Contact" }
];

export function PlayButton({ small = false }: { small?: boolean }) {
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

/**
 * A strip above the nav for the newest release, and nothing else.
 *
 * Two states, both read from the changelog: a release that is written but not
 * yet dated is on the way, and a freshly dated one is out. It disappears on
 * its own once the news stops being news, so nobody has to remember to remove
 * it.
 */
export function UpdateBanner() {
  const state = updateBanner();
  if (!state) return null;

  const coming = state.kind === "coming";
  const { live, url } = siteConfig.play;

  const label = coming
    ? `Update is coming — v${state.version}`
    : `Update is available now — v${state.version}`;

  const body = (
    <>
      <span className={`update-dot${coming ? " is-coming" : ""}`} aria-hidden="true" />
      <span className="update-text">{label}</span>
      <span className="update-go">
        {coming ? "See what's in it" : "Get it on Google Play"}
        <ArrowRightIcon size={14} weight="bold" />
      </span>
    </>
  );

  // While it is still coming there is nothing to install, so the link goes to
  // the changelog. Sending someone to the store for a build that is not there
  // is worse than saying nothing.
  if (coming || !live || !url) {
    return (
      <Link className="update-banner" href="/changelog">
        {body}
      </Link>
    );
  }
  return (
    <a className="update-banner" href={url}>
      {body}
    </a>
  );
}

export function Nav() {
  return (
    <>
      <UpdateBanner />
      <header className="nav">
        <div className="nav-inner">
          <Link className="brand" href="/">
            <Image src="/duck-idle.png" alt="" width={26} height={26} priority />
            <span>{siteConfig.name}</span>
          </Link>
          <nav className="nav-links" aria-label="Primary">
            {LINKS.map((link) => (
              <Link key={link.href} className="nav-link" href={link.href}>
                {link.label}
              </Link>
            ))}
          </nav>
          <PlayButton small />
        </div>
      </header>
    </>
  );
}

export function Footer() {
  return (
    <footer className="footer">
      <div className="wrap footer-inner">
        <Link className="brand" href="/">
          <Image src="/duck-idle.png" alt="" width={22} height={22} />
          <span>{siteConfig.name}</span>
        </Link>
        <div className="footer-links">
          {LINKS.map((link) => (
            <Link key={link.href} href={link.href}>
              {link.label}
            </Link>
          ))}
          <Link href="/privacy">Privacy</Link>
        </div>
      </div>
    </footer>
  );
}

/** Page heading used by every inner page, so they open the same way. */
export function PageHead({
  eyebrow,
  title,
  lede
}: {
  eyebrow?: string;
  title: string;
  lede?: string;
}) {
  return (
    <header className="page-head">
      <div className="wrap">
        {eyebrow ? <p className="eyebrow">{eyebrow}</p> : null}
        <h1 className="h2">{title}</h1>
        {lede ? <p className="lede page-lede">{lede}</p> : null}
      </div>
    </header>
  );
}
