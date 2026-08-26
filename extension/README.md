# Duck Downloader — Browser Extension

Chrome MV3 extension built with [WXT](https://wxt.dev) + React + TypeScript + Tailwind v4.
Shares the Duck backend (`api.duckdownloader.site`) with the Flutter app.

## Run it

```bash
npm install
npm run sync:ffmpeg  # if your npm blocks install scripts, run this once
npm run dev          # loads a dev browser with HMR
npm run build        # production bundle -> .output/chrome-mv3
npm run zip          # store-ready zip
npm run compile      # type-check only
```

To load a production build by hand: `chrome://extensions` → Developer mode →
*Load unpacked* → pick `.output/chrome-mv3`.

`sync:ffmpeg` copies the ffmpeg.wasm core out of node_modules into
`src/public/ffmpeg`. It runs automatically as part of `build` and `postinstall`,
but npm configurations that block install scripts will skip the latter.

Node 20+ required (built and tested on 24).

## How it works

```
content script  ──detect──▶  background worker  ──resolve──▶  download engine
  page adapters              candidate store            chrome.downloads
  shadow-DOM overlay         network sniffer            Duck backend
```

### Detection — three sources, merged by id

The content script runs on **every site**. A download button on any page that
plays media is the product, so `<all_urls>` is what it honestly takes.

| Source | Where | Catches |
| --- | --- | --- |
| Page adapters | content script | YouTube, X/Twitter, Instagram, and a generic reader for everywhere else |
| Network sniffer | background, `webRequest` | anything the page fetches — `.m3u8`, `.mpd`, progressive `.mp4` |
| Backend extract | on demand | whatever yt-dlp can see |

The generic adapter deliberately anchors on media it **cannot** resolve. Most
modern players feed video through MSE, leaving a `blob:` URL that is meaningless
outside the page — skipping those is why the button never appeared on Facebook,
Instagram or TikTok at all. Identity instead comes from the post's permalink,
found by walking up from the player looking for a known URL shape
(`/videos/<id>`, `/reel/<id>`, `/p/<id>`, `/status/<id>`…). Matching on paths
rather than class names is deliberate: those routes last years, the markup
around them is rebuilt constantly.

### Adult content

Blocked by hostname before anything else runs — the content script does not
inject, the sniffer ignores the tab, and the resolver refuses the URL. The
keyword list is copied from the Flutter app's `_isAdultUrl`, so both clients
refuse the same set.

A small allow-list keeps the substring match from taking out innocent hosts:
without it `sex` blocks Essex, Sussex and Middlesex.

Adapters supply *identity and metadata* only. Resolving playable URLs happens
elsewhere, so an adapter never has to fight the page's CSP.

Candidates live in `chrome.storage.session`, not a module-level `Map` — the MV3
worker is torn down after ~30s idle and would otherwise forget everything the
user found while reading the page.

### Resolution — local first, server last

1. **In-page.** The worker asks a content script on the site to make the call, so
   it goes out same-origin with the user's own session.
2. **In-worker.** Same resolver, anonymous. Free to attempt.
3. **Backend.** `POST /api/extract`, then `POST /api/download`. Costs a server
   round trip and sends the page link to us.

### Downloading — three engines

- **direct** — hand the URL to `chrome.downloads`. The browser owns the transfer:
  survives worker teardown, uses no extension memory, resumes on its own.
- **muxed** — fetch both tracks and merge them with ffmpeg.wasm in an offscreen
  document. This is where high-resolution video lands, and it keeps the whole
  job on the user's machine.
- **backend** — the API downloads and merges server-side; the finished file is
  then pulled with `chrome.downloads` like any other. The fallback for whatever
  the first two cannot do.

Progress is reconciled by a 1s poll rather than `downloads.onChanged`, which does
not reliably report byte counts. `reconcile()` re-syncs on every worker startup,
so a download that finished while the worker was dead does not sit at 40% forever.

## State of YouTube support

Probed against live YouTube while building this:

| InnerTube client | Result |
| --- | --- |
| `IOS`, `ANDROID` | HTTP 400 `Precondition check failed` without the app's User-Agent — and `User-Agent` is a forbidden header for `fetch`, so an extension cannot send it |
| `TVHTML5_SIMPLY_EMBEDDED_PLAYER`, `WEB_EMBEDDED_PLAYER` | `ERROR` |
| `MWEB` | `UNPLAYABLE` |
| **`ANDROID_VR`** | **`OK`, every format uncipher-ed, up to 2160p, no User-Agent needed** |

So `ANDROID_VR` is the only local path, and it is the only one attempted.

Anonymously it returns `LOGIN_REQUIRED` for most videos (1 of 5 test videos
resolved). That is exactly why resolution is issued from the content script with
`credentials: 'include'` — with a signed-in session it is a different request.
Expect a meaningful share of YouTube downloads to still land on the backend.

`settings.youtubeEnabled` gates the feature end to end: the adapter, the
resolver, and the UI. Turning it off, or deleting `src/detect/adapters/youtube.ts`
and `src/resolve/youtube.ts`, removes it with nothing left behind in the
manifest.

**This matters commercially.** Chrome Web Store's Developer Program Policies
prohibit extensions that download YouTube content. Shipping it is a decision that
was made deliberately, not an oversight — the flag exists so a clean build is
five minutes of work if review goes badly.

### Posts with more than one item

An Instagram link is not one file. It can be a single image, a reel, a carousel
of images, a carousel of videos, or a mix of both — and every item has to be
downloadable on its own, with its own correct extension.

Scraping that from the DOM is a losing game: a carousel only keeps neighbouring
slides mounted, images carry `srcset` at several resolutions, and videos are MSE.
So the Instagram adapter does exactly one job — work out the post's canonical
shortcode URL — and `/api/playlist/extract` enumerates the rest, returning each
item already typed by `isVideo`. A hybrid post therefore stays hybrid instead of
being flattened into one kind.

- **Overlay button** on such a post downloads *everything* in it.
- **Popup** shows the items as a grid: download one, or download all.

## Permissions

`<all_urls>`, because the button has to be able to appear anywhere. The cost is
an install prompt reading "read and change all your data on all websites", and a
harder look from reviewers. What makes it defensible is that the content script
only ever looks for media elements, and adult hosts are refused before injection.

`optional_host_permissions` stays for Firefox, where the same grant is requested
at runtime instead of at install.

Declared permissions are only those actually called. `scripting` gets added when
on-demand injection lands, not before.

### Merging locally

YouTube serves its high resolutions as separate video and audio tracks. The
`muxed` engine fetches both and remuxes them with `-c copy` — no re-encoding, so
no quality loss and it finishes in seconds.

It runs in an **offscreen document**, the only place in MV3 that can. The service
worker dies after ~30s idle and has no DOM for the worker ffmpeg spawns; a
content script would hit the page's CSP and lose everything on navigation.

Three constraints shaped this, all of them non-obvious:

1. **`classWorkerURL` is mandatory.** By default `@ffmpeg/ffmpeg` spawns its
   worker from a `blob:` URL, which the extension CSP rejects. Pointing it at a
   bundled `worker.js` is what makes it MV3-legal.
2. **`'wasm-unsafe-eval'` must be in the page CSP**, or
   `WebAssembly.instantiate` is blocked outright.
3. **The core ships in the bundle** (`scripts/sync-ffmpeg.mjs` copies it out of
   node_modules at build time). MV3 forbids remote code, so a CDN core is not an
   option. It costs 32MB of install size — the single largest thing in the
   package.

Video and audio are paired **within the same container family** — WebM/VP9 with
Opus, MP4/AVC-AV1 with AAC. Verified against live YouTube: it offers both audio
families for every video, so pairing always finds a match. Mixing them would
force Opus into MP4 or AVC into WebM, which `-c copy` either refuses or produces
files some players will not open. When both families offer the same resolution,
MP4 wins on compatibility.

Peak memory is roughly twice the total input, so inputs over **400MB** go to the
backend instead of being attempted and failing slowly. Any other merge failure
falls through to the backend too, rather than surfacing an error the user cannot
act on.

## Content Guard

Blocking that the user deliberately makes hard to undo. Lives behind the
**Guard** tab in the side panel.

The design assumption: the person who turns this on and the person who later
wants it off are the same person in two different moods. So the lock is not
about secrecy — it is about **time**. A PIN alone is defeated by remembering the
PIN. A mandatory wait defeats the impulse that wanted it gone.

- **Turning protection up** — one click.
- **Turning any of it down** — needs the PIN.
- **Turning Guard off** — needs the PIN *and* the wait (1 hour to 7 days), during
  which everything stays blocked. Cancelling is one click, all the way through.

### How the blocking works

`declarativeNetRequest`, so a blocked page is stopped in the network stack and
never reaches the renderer. A content script could only hide a page that had
already loaded — and been fetched.

`scripts/sync-blocklist.mjs` builds the ruleset from two public hosts lists —
about 950,000 domains after collapsing subdomains into the parents that already
cover them.

Chrome guarantees 30,000 enabled static rules, so only a fraction fits. **Which**
fraction is the interesting part: sorting alphabetically, the obvious approach,
spends the whole budget on domains starting with "a". Instead, domains both
sources agree on come first, then shorter ones, which correlate strongly with
sites that get real traffic. Fifteen regex rules on hostname keywords catch newly
registered hosts that announce themselves in their own name.

Also enforced, all optional:
- **SafeSearch** on Google, Bing, DuckDuckGo and YouTube. This matters more than
  blocking sites — a filtered results page never offers the link, so there is
  nothing to resist.
- **Sensitive posts removed** from X, Reddit and Instagram feeds, using each
  platform's own flag. Removed from the document, not blurred: a blur leaves the
  image loaded and one CSS edit away.
- **The user's own blocklist**, for anything else.

The PIN is PBKDF2 at 250k iterations. A four-digit PIN has ten thousand
possibilities and a plain hash of all of them is computed in an instant.

### Where it stops

Stated permanently in the UI, not as a dismissible tip, because someone leaning
on this deserves to know where the wall ends: **any extension can be removed from
the browser's extensions page**, and someone comfortable in devtools can clear
the stored state, which resets the PIN and the pending wait.

Nothing an extension can do prevents either. `POLICY.md` covers what actually
does — Cloudflare `1.1.1.3` for DNS, a locked DoH setting so browsers cannot
bypass it, and a force-install policy that makes the extension unremovable. That
last one needs a stable extension ID, which means a store listing; a
`--load-extension` build gets a new ID whenever it moves.

## Not built yet

- **HLS / DASH muxing.** Manifest parsing is not implemented, so those still
  route to the backend.
- **Editing tools** — trim, convert, compress. `/api/trim` already exists, and
  ffmpeg.wasm is now loaded and available for the local versions.
- **Instagram / TikTok / Facebook / Reddit adapters.** They work through the
  network sniffer plus backend fallback today; dedicated adapters would give
  better titles and one-click behaviour.
- **Web subscription** — Stripe or ExtensionPay, separate from the mobile IAP.
- **Firefox / Edge builds.** `npm run build:firefox` already produces one; it has
  not been tested.

## Layout

```
src/
  core/        types, typed messaging, settings, candidate store
  detect/      page adapters + network sniffer
  resolve/     InnerTube resolver, backend client, orchestrator
  download/    job store, engines, offscreen control
  ui/          shadow-DOM overlay, React components, hooks
  entrypoints/ background, content, popup, sidepanel, offscreen
  public/      icons, _locales, ffmpeg core (generated)
```
