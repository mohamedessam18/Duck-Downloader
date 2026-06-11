import type { MetadataRoute } from "next";
import { siteConfig } from "./site-config";

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: siteConfig.name,
    short_name: siteConfig.shortName,
    description: siteConfig.description,
    start_url: "/",
    display: "standalone",
    background_color: "#020618",
    theme_color: "#ffc52f",
    icons: [
      {
        src: "/duck-idle.png",
        sizes: "512x512",
        type: "image/png"
      }
    ]
  };
}
