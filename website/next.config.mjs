/** @type {import('next').NextConfig} */
const nextConfig = {
  poweredByHeader: false,
  reactStrictMode: true,
  async redirects() {
    return [
      {
        // The footer and older builds of the app pointed at the raw HTML file.
        // A published app cannot be edited after the fact, so the old path has
        // to keep resolving rather than 404 for anyone still on that version.
        source: "/privacy-policy.html",
        destination: "/privacy",
        permanent: true
      }
    ];
  }
};

export default nextConfig;
