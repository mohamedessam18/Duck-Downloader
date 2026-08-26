import { siteConfig } from "./site-config";

/**
 * Structured data for the app listing.
 *
 * This existed before but was never rendered, so none of it ever reached a
 * crawler. It also described a Windows build that does not exist and carried a
 * hardcoded version number nothing kept in step. Both are gone: the shape now
 * follows the same `play` flag the rest of the page reads, so the availability
 * Google is told matches the button a visitor sees.
 */
export function SoftwareJsonLd() {
  const payload = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: siteConfig.name,
    applicationCategory: "MultimediaApplication",
    operatingSystem: "Android",
    description: siteConfig.description,
    url: siteConfig.url,
    offers: {
      "@type": "Offer",
      availability: siteConfig.play.live
        ? "https://schema.org/InStock"
        : "https://schema.org/PreOrder",
      price: "0",
      priceCurrency: "USD"
    }
  };

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(payload) }}
    />
  );
}
