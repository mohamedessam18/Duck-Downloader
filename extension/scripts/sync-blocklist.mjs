import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Builds the bundled adult-domain ruleset for declarativeNetRequest.
 *
 * Why bundled rather than fetched at runtime: the blocklist is the one part of
 * Duck that must keep working with no network and must never tell a server what
 * the user is browsing. Static rules are also enforced by the browser itself, so
 * a blocked page never reaches the renderer — a content script could only hide
 * it after the fact.
 *
 * Run with `npm run sync:blocklist`. The output is committed so builds are
 * reproducible and a reviewer can read exactly what ships.
 */

const SOURCES = [
  'https://raw.githubusercontent.com/blocklistproject/Lists/master/porn.txt',
  'https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn-only/hosts',
];

/**
 * Chrome guarantees 30,000 enabled static rules per extension. Staying well
 * under it leaves room for the SafeSearch and custom-list rules that share the
 * budget.
 */
const MAX_RULES = 24_000;

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');

/** host -> how many source lists it appeared in. */
const hosts = new Map();

for (const source of SOURCES) {
  const response = await fetch(source);
  if (!response.ok) throw new Error(`${source} -> HTTP ${response.status}`);
  const text = await response.text();

  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;

    // Both sources are hosts files: "0.0.0.0 example.com" or bare domains.
    const host = (line.split(/\s+/)[1] ?? line.split(/\s+/)[0] ?? '')
      .toLowerCase()
      .replace(/^www\./, '');

    if (!host || host === 'localhost' || host.startsWith('0.0.0.0')) continue;
    if (!/^[a-z0-9.-]+\.[a-z]{2,}$/.test(host)) continue;
    hosts.set(host, (hosts.get(host) ?? 0) + 1);
  }
}

/**
 * Collapses subdomains into the domain that already covers them: `||foo.com^`
 * matches `a.foo.com` too, so keeping both wastes rules from a hard budget.
 */
function collapse(all) {
  const sorted = [...all].sort((a, b) => a.split('.').length - b.split('.').length);
  const kept = new Set();
  for (const host of sorted) {
    const parts = host.split('.');
    let covered = false;
    for (let i = 1; i < parts.length - 1; i++) {
      if (kept.has(parts.slice(i).join('.'))) {
        covered = true;
        break;
      }
    }
    if (!covered) kept.add(host);
  }
  return [...kept];
}

const collapsed = collapse(hosts.keys());

/**
 * The budget covers a fraction of the list, so which fraction matters. Sorting
 * alphabetically — the obvious thing — spends the entire budget on domains
 * starting with "a".
 *
 * Instead: domains both sources agree on come first, then shorter domains,
 * which correlate strongly with the sites that actually get traffic. The long
 * tail of obscure hosts is covered by the keyword rules below and, for anyone
 * who sets it up, by DNS.
 */
const selected = collapsed
  .sort((a, b) => {
    const confidence = (hosts.get(b) ?? 0) - (hosts.get(a) ?? 0);
    if (confidence !== 0) return confidence;
    if (a.length !== b.length) return a.length - b.length;
    return a < b ? -1 : 1;
  })
  .slice(0, MAX_RULES);

const rules = selected.map((host, index) => ({
  id: index + 1,
  priority: 1,
  action: {
    type: 'redirect',
    // A redirect rather than a plain block: the user gets Duck's own page
    // explaining what happened, not an opaque browser error.
    redirect: { extensionPath: '/blocked.html' },
  },
  condition: {
    urlFilter: `||${host}^`,
    resourceTypes: ['main_frame'],
  },
}));

/**
 * Catches the long tail no fixed list can keep up with: newly registered hosts
 * that say what they are in their own name. Regex rules are capped at 1,000 by
 * Chrome, so this stays to a short, high-signal set.
 */
const KEYWORDS = [
  'porn', 'xxx', 'hentai', 'camgirl', 'livecam', 'nudes', 'sexcam', 'xvideos',
  'xhamster', 'onlyfans', 'rule34', 'nsfw', 'escort', 'stripchat', 'chaturbate',
];

rules.push(
  ...KEYWORDS.map((keyword, index) => ({
    id: MAX_RULES + index + 1,
    priority: 1,
    action: {
      type: 'redirect',
      redirect: { extensionPath: '/blocked.html' },
    },
    condition: {
      // Host component only, so a news article whose *path* mentions the word
      // is not caught.
      regexFilter: `^https?://([a-z0-9-]+\\.)*[a-z0-9-]*${keyword}[a-z0-9-]*\\.`,
      resourceTypes: ['main_frame'],
    },
  })),
);

const target = join(root, 'src/public/rules');
await mkdir(target, { recursive: true });
await writeFile(join(target, 'adult.json'), JSON.stringify(rules), 'utf8');

console.log(
  `blocklist: ${hosts.size} hosts -> ${collapsed.length} collapsed -> ` +
    `${selected.length} domain rules + ${KEYWORDS.length} keyword rules` +
    (collapsed.length > MAX_RULES ? ` (domain list capped at ${MAX_RULES})` : ''),
);
