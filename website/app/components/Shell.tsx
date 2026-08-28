import Image from "next/image";
import Link from "next/link";
import { GooglePlayLogoIcon } from "@phosphor-icons/react/dist/ssr";
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

export function Nav() {
  return (
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
