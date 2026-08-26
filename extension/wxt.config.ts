import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { defineConfig } from 'wxt';
import tailwindcss from '@tailwindcss/vite';

/**
 * Pins the extension id.
 *
 * Chrome derives the id from this public key, so a build loaded unpacked gets
 * the same id as the published one. Two things depend on that being stable:
 * native messaging, whose host manifest names the id in `allowed_origins`, and
 * the enterprise policy that force-installs the extension. Without a pinned
 * key, both break every time the folder moves.
 *
 * The matching private key is not in the repository — see keys/README.md.
 */
const MANIFEST_KEY = readFileSync(
  resolve(import.meta.dirname, 'keys/key.txt'),
  'utf8',
).trim();

/**
 * Duck is expected to put a download button on any site that plays media, so
 * the content script has to run everywhere and `<all_urls>` is the honest way
 * to ask for it.
 *
 * The cost is real and worth stating plainly: the install prompt reads "read
 * and change all your data on all websites", and reviewers look harder at
 * extensions that ask for it. What keeps it defensible is that the content
 * script does nothing but look for media elements, and adult hosts are refused
 * before it ever injects — see src/core/nsfw.ts.
 *
 * `optional_host_permissions` stays for Firefox, where the equivalent grant is
 * requested at runtime rather than at install time.
 */

export default defineConfig({
  // Everything lives under src/, which is what makes WXT's built-in `@` alias
  // resolve to shared code without a custom resolver.
  srcDir: 'src',
  // Not WXT's default `.output`: a leading dot makes the folder hidden in
  // Finder, and Chrome's "Load unpacked" picker will not show it.
  outDir: 'dist',
  // Icons and _locales are copied verbatim into the bundle root.
  publicDir: 'src/public',
  modules: ['@wxt-dev/module-react'],
  vite: () => ({
    plugins: [tailwindcss()],
  }),
  manifest: {
    key: MANIFEST_KEY,
    // Resolved from _locales at load time, so the store listing and the
    // browser UI follow the user's language rather than being pinned to English.
    name: '__MSG_extName__',
    short_name: '__MSG_extShortName__',
    description: '__MSG_extDescription__',
    version: '1.0.0',
    default_locale: 'en',
    // Only what the code actually calls. Every extra entry widens the install
    // prompt and invites a reviewer to ask what it is for.
    permissions: [
      'storage',
      'downloads',
      'offscreen',
      'sidePanel',
      'tabs',
      'webRequest',
      'webNavigation',
      // Content Guard. Blocking in the network stack means a blocked page never
      // reaches the renderer — a content script could only hide it afterwards.
      'declarativeNetRequest',
      // Talks to the local Duck Engine. Downloads must outlive the browser, so
      // the transfer itself never happens in here.
      'nativeMessaging',
      // Re-injects the content script after an update. Without it, every tab
      // that was already open keeps running the replaced version until the user
      // refreshes it by hand.
      'scripting',
    ],
    host_permissions: ['<all_urls>'],
    optional_host_permissions: ['*://*/*'],
    icons: {
      16: 'icon/16.png',
      32: 'icon/32.png',
      48: 'icon/48.png',
      96: 'icon/96.png',
      128: 'icon/128.png',
    },
    action: {
      default_title: '__MSG_extName__',
    },
    side_panel: {
      default_path: 'sidepanel.html',
    },
    declarative_net_request: {
      rule_resources: [
        {
          id: 'adult',
          // Off until the user turns Guard on; toggled from src/core/guard.ts.
          enabled: false,
          path: 'rules/adult.json',
        },
      ],
    },
    // The blocked page is a redirect target, so the browser must be allowed to
    // navigate to it from any origin.
    web_accessible_resources: [
      {
        resources: ['blocked.html'],
        matches: ['<all_urls>'],
      },
    ],
    // Required for ffmpeg.wasm: MV3's default page CSP has no wasm-eval, and
    // WebAssembly.instantiate is blocked without this. It is an allowed value.
    //
    // No cross-origin isolation headers here on purpose. They would unlock
    // multi-threaded ffmpeg.wasm via SharedArrayBuffer, but they apply to every
    // extension page, and under COEP: require-corp the popup's thumbnails (from
    // i.ytimg.com, pbs.twimg.com, ...) get blocked because those CDNs send no
    // CORP header. The muxing engine therefore uses the single-threaded core,
    // which needs neither.
    content_security_policy: {
      extension_pages: "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'",
    },
    minimum_chrome_version: '116',
  },
});
