/**
 * Adult-content gate.
 *
 * The keyword list is the one the Flutter app already ships
 * (`_isAdultUrl` in lib/state/downloads_controller.dart) so the two clients
 * block the same set — a link refused on the phone should not sail through in
 * the browser.
 *
 * This is a hostname check only. It runs before anything else: on a blocked
 * host the content script does not inject, the sniffer ignores the tab, and the
 * resolver refuses the URL. That is deliberately cruder than the app's
 * per-post checks (Reddit `over_18`, X `possibly_sensitive`), which need API
 * calls the extension has no reason to make on every page load.
 */

const KEYWORDS = [
  'porn', 'xxx', 'sex', 'nude', 'adult', 'camgirl', 'livecam', 'hentai',
  'xvideo', 'pornhub', 'xnxx', 'xhamster', 'redtube', 'youporn', 'chaturbate',
  'rule34', 'onlyfans', 'stripchat', 'bongacams', 'camsoda', 'adultfriendfinder',
  'cam4', 'imlive', 'livejasmin', 'doujin', 'nhentai', 'gelbooru', 'danbooru',
  'e621', 'sankakucomplex', 'yande.re', 'e-hentai', 'luscious', 'spankbang',
  'eporner', 'hqporn', 'motherless', 'heavyr', 'tube8', 'pornai', 'aiporn',
  'nudify', 'undressai', 'pornpen', 'soulgen', 'candyai', 'dreamgf', 'nsfwai',
  'spicychat', 'janitorai',
];

/**
 * Hosts that contain a blocked keyword as an ordinary substring of an innocent
 * name. Without these, "sex" alone takes out Essex, Sussex and Middlesex, and
 * "adult" takes out adulteducation-style domains.
 */
const ALLOWED = [
  'essex', 'sussex', 'middlesex', 'wessex', 'unisex', 'sexton', 'sexagesimal',
  'adulteducation', 'adulting', 'nudelta',
];

export function isBlockedHost(hostname: string): boolean {
  const host = hostname.toLowerCase();
  let stripped = host;
  for (const allowed of ALLOWED) stripped = stripped.split(allowed).join('');
  return KEYWORDS.some((keyword) => stripped.includes(keyword));
}

export function isBlockedUrl(url: string): boolean {
  try {
    return isBlockedHost(new URL(url).hostname);
  } catch {
    return false;
  }
}
