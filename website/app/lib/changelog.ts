/**
 * What changed, in the words of someone who uses the app.
 *
 * Two rules keep this page worth reading.
 *
 * One entry per release that reached people, not per commit. Someone comparing
 * this against the version on their phone needs the unit to be the version
 * number, and half the commits in any release move nothing they can see.
 *
 * And it says what happened to them, not what happened to the code. The Videos
 * tab listing music folders is the entry; the swapped MEDIA_TYPE constant
 * behind it belongs in the commit message. If a line cannot be written without
 * naming a class, it probably does not belong here at all.
 */
export type ReleaseKind = "added" | "fixed" | "improved";

export type Release = {
  version: string;
  /** Play build number, so a tester can match this to what they installed. */
  build: number;
  /** ISO date. Null while the release is built but not yet published. */
  date: string | null;
  /** One line on what this release is about, if it has a theme. */
  summary?: string;
  changes: { kind: ReleaseKind; text: string }[];
};

export const releases: Release[] = [
  {
    version: "1.2.2",
    build: 11,
    // Written, not yet on Play. The site reads this null and says an update is
    // on the way; dating it is what flips the banner to "available now".
    date: null,
    summary:
      "Instagram, Threads and YouTube Shorts download again, and your sign-ins stay on your phone.",
    changes: [
      {
        kind: "fixed",
        text: "Instagram posts kept asking you to sign in even when you already were, over and over. They now open on the first try, and a post that has been deleted says so instead of asking you to sign in again.",
      },
      {
        kind: "fixed",
        text: "A YouTube Shorts link copied or shared from YouTube never worked. The extra text YouTube adds to the end of the link was enough to break it.",
      },
      {
        kind: "fixed",
        text: "YouTube videos downloaded at the lowest quality no matter which one you picked. Choosing 1080p gave you 144p.",
      },
      {
        kind: "fixed",
        text: "Threads posts could not be downloaded at all.",
      },
      {
        kind: "fixed",
        text: "When a download failed, Duck blamed your internet connection whatever the real reason was. It now tells you what actually went wrong.",
      },
      {
        kind: "fixed",
        text: "A download that stopped receiving data sat there for fifteen minutes before giving up. It now stops waiting after a few seconds and tries another way.",
      },
      {
        kind: "fixed",
        text: "Signing in through the in-app browser and pressing back threw the sign-in away, and the button that opened it often did nothing at all.",
      },
      {
        kind: "added",
        text: "A post with photos and videos mixed together downloads each item as what it is, instead of turning everything into one kind.",
      },
      {
        kind: "added",
        text: "A Reel or a Threads video can be saved as sound or as its cover picture, not only as a video.",
      },
      {
        kind: "added",
        text: "Settings now has Linked accounts: see which sites Duck is signed in to, and sign out of one or all of them.",
      },
      {
        kind: "improved",
        text: "Your sign-ins are stored encrypted on your phone and are never kept on our server. They travel with the one download that needs them and are deleted straight after.",
      },
    ],
  },
  {
    version: "1.2.1",
    build: 10,
    date: "2026-08-31",
    summary:
      "File management works again, and the vault stops locking you out mid-video.",
    changes: [
      {
        kind: "fixed",
        text: "The Videos tab listed music folders and the Audios tab listed video folders. Each tab now shows its own media, and a folder holding both appears in both places with only the matching half inside.",
      },
      {
        kind: "fixed",
        text: "Renaming, moving and deleting files did nothing on Android 11 and later. The permission dialog never appeared, so the action failed before you could approve it.",
      },
      {
        kind: "improved",
        text: "Android now asks once for permission to edit your library instead of once per file. Later edits happen without a dialog.",
      },
      {
        kind: "fixed",
        text: "Opening a video from the vault locked the vault behind you, and going back showed an empty list. Rotating the screen was enough to trigger it.",
      },
      {
        kind: "added",
        text: "Vault file names and thumbnails are blurred until you tap the eye icon, so a glance over your shoulder shows nothing.",
      },
      {
        kind: "improved",
        text: "Leaving the vault returns you to the tab you came from, and no longer asks you to confirm.",
      },
      {
        kind: "improved",
        text: "The vault locks itself after two minutes unused, but never while something is playing.",
      },
      {
        kind: "fixed",
        text: "The download progress bar stuttered. It was saving to storage and rebuilding the whole library on every chunk that arrived.",
      },
      {
        kind: "improved",
        text: "Switching tabs and opening screens now slide in one direction instead of fading, and every screen in the app moves the same way.",
      },
      {
        kind: "fixed",
        text: "Progress read \"%20 CACHED\" instead of \"20% CACHED\", folder counts read \"1 items\", and moving a file reported \"Moved 1 file(s)\".",
      },
      {
        kind: "improved",
        text: "Settings has been rebuilt, and the privacy policy now opens the published page instead of a copy inside the app.",
      },
      {
        kind: "fixed",
        text: "Old notification channels piled up in Android's settings, six of them doing nothing. The clipboard alert was also five seconds long, three times longer than the sound for a failed download.",
      },
    ],
  },
  {
    version: "1.1.2",
    build: 8,
    date: "2026-07-19",
    summary: "The release currently on Google Play.",
    changes: [
      { kind: "added", text: "Secure Vault with AES-256 encryption and a passcode." },
      { kind: "added", text: "Background audio and picture-in-picture in the player." },
      { kind: "added", text: "Quick download overlay when you share a link to Duck." },
      { kind: "improved", text: "Faster downloads on high-resolution video." },
    ],
  },
];

/**
 * What the site should say about the newest release, if anything.
 *
 * Derived from the release list rather than a flag of its own. A separate
 * "there is an update coming" switch is one more thing to remember to turn
 * off, and the day it is forgotten the site tells everyone an update is on the
 * way months after it shipped. The changelog already records the distinction:
 * an entry with no date is written but not published.
 *
 * "Available" is deliberately temporary. A banner still shouting about a
 * release from six months ago is not news, it is decoration, so it stops
 * after {@link ANNOUNCE_DAYS}.
 */
export const ANNOUNCE_DAYS = 21;

export type UpdateBannerState =
  | { kind: "coming"; version: string }
  | { kind: "available"; version: string }
  | null;

export function updateBanner(
  today: Date = new Date(),
  list: Release[] = releases,
): UpdateBannerState {
  const latest = list[0];
  if (!latest) return null;

  if (latest.date === null) {
    return { kind: "coming", version: latest.version };
  }

  const released = new Date(`${latest.date}T00:00:00Z`);
  if (Number.isNaN(released.getTime())) return null;

  const days = (today.getTime() - released.getTime()) / 86_400_000;
  // A release dated in the future has not happened yet either.
  if (days < 0) return { kind: "coming", version: latest.version };
  if (days > ANNOUNCE_DAYS) return null;
  return { kind: "available", version: latest.version };
}
