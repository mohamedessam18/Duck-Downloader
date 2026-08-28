import type { Metadata } from "next";
import Image from "next/image";
import {
  ClipboardTextIcon,
  FoldersIcon,
  LockKeyIcon,
  PictureInPictureIcon,
  ScissorsIcon,
  SpeakerHighIcon,
  WifiSlashIcon
} from "@phosphor-icons/react/dist/ssr";
import { Footer, Nav, PageHead, PlayButton } from "../components/Shell";
import { Reveal } from "../components/Reveal";

export const metadata: Metadata = {
  title: "Features",
  description:
    "Downloading, a private encrypted vault, a full player, and file management for everything already on your phone.",
  alternates: { canonical: "/features" }
};

/**
 * Four sections, four different layout families.
 *
 * The version this replaces alternated image-left and image-right four times,
 * which is the zigzag every templated site uses and reads as one section
 * repeated. Each block below is composed differently: an overlap, a full-bleed
 * band, a wide strip, an asymmetric grid. The content decided which, not a
 * desire for variety on its own.
 */
export default function FeaturesPage() {
  return (
    <>
      <Nav />
      <main>
        <PageHead
          eyebrow="Features"
          title="What it actually does"
          lede="Four things, each shown on the screen where it happens."
        />

        {/* 1. Overlap: the phone breaks out of the copy block */}
        <section className="section feat-overlap">
          <div className="wrap">
            <div className="overlap-grid">
              <Reveal className="overlap-copy">
                <span className="rule-n">01</span>
                <h2 className="h2">It notices before you ask</h2>
                <p className="body">
                  Copy a link anywhere on your phone and Duck offers to save it.
                  No pasting, no opening the app first, no hunting for a
                  download button that moved.
                </p>
                <ul className="points">
                  <li>
                    <ClipboardTextIcon size={17} weight="bold" />
                    <span>Watches the clipboard, only for links it handles</span>
                  </li>
                  <li>
                    <WifiSlashIcon size={17} weight="bold" />
                    <span>Saved files play with no connection and no server</span>
                  </li>
                </ul>
              </Reveal>
              <Reveal className="overlap-media" delay={90}>
                <div className="clip-frame">
                  <Image
                    src="/shots/crop-clipboard.jpg"
                    alt="A notification offering to download a link that was just copied"
                    width={1080}
                    height={620}
                    sizes="(max-width: 900px) 92vw, 520px"
                  />
                </div>
              </Reveal>
            </div>
          </div>
        </section>

        {/* 2. Full-bleed band: the vault gets its own ground */}
        <section className="section band" id="vault">
          <div className="wrap band-grid">
            <Reveal className="band-shots">
              <div className="clip-frame band-a">
                <Image
                  src="/shots/crop-vault-pin.jpg"
                  alt="The vault asking for a six-digit passcode"
                  width={1080}
                  height={900}
                  sizes="(max-width: 900px) 60vw, 300px"
                />
              </div>
              <div className="clip-frame band-b">
                <Image
                  src="/shots/crop-vault-blur.jpg"
                  alt="Vault files with their names and thumbnails blurred"
                  width={1080}
                  height={760}
                  sizes="(max-width: 900px) 60vw, 300px"
                />
              </div>
            </Reveal>
            <Reveal className="band-copy" delay={80}>
              <span className="rule-n">02</span>
              <h2 className="h2">A vault that stays shut</h2>
              <p className="body">
                Files moved into the vault are encrypted on your device with
                AES-256, behind a six-digit passcode or your fingerprint. Names
                and thumbnails stay blurred until you ask for them.
              </p>
              <p className="body">
                The key never leaves the phone. A lost passcode means the files
                stay locked, including to us.
              </p>
              <ul className="points">
                <li>
                  <LockKeyIcon size={17} weight="bold" />
                  <span>The key is derived on the device, never uploaded</span>
                </li>
                <li>
                  <FoldersIcon size={17} weight="bold" />
                  <span>Vault files never appear in the folder browser</span>
                </li>
              </ul>
            </Reveal>
          </div>
        </section>

        {/* 3. Wide strip: the player is landscape, so the section is too */}
        <section className="section">
          <div className="wrap">
            <Reveal>
              <div className="strip-head">
                <span className="rule-n">03</span>
                <h2 className="h2">A player worth staying in</h2>
              </div>
            </Reveal>
            <Reveal delay={70}>
              <div className="wide-frame strip-frame">
                <Image
                  src="/shots/crop-player.jpg"
                  alt="The player controls: trim, GIF, picture-in-picture, lock and speed"
                  width={2400}
                  height={620}
                  sizes="(max-width: 1100px) 94vw, 1060px"
                />
              </div>
            </Reveal>
            <div className="strip-points">
              {[
                { icon: SpeakerHighIcon, t: "Background audio", d: "Leave the app or lock the screen. Nothing to switch on." },
                { icon: PictureInPictureIcon, t: "Picture-in-picture", d: "A floating window that stays on top of other apps." },
                { icon: ScissorsIcon, t: "Trim and convert", d: "Cut a clip, pull the audio, make a GIF, change speed." }
              ].map((p, i) => {
                const Icon = p.icon;
                return (
                  <Reveal key={p.t} delay={120 + i * 60}>
                    <div className="strip-point">
                      <Icon size={19} weight="bold" />
                      <h3 className="h3">{p.t}</h3>
                      <p className="body">{p.d}</p>
                    </div>
                  </Reveal>
                );
              })}
            </div>
          </div>
        </section>

        {/* 4. Asymmetric grid: two screenshots at different weights */}
        <section className="section band">
          <div className="wrap">
            <Reveal>
              <div className="strip-head">
                <span className="rule-n">04</span>
                <h2 className="h2">Every folder on the phone</h2>
              </div>
            </Reveal>
            <Reveal delay={60}>
              <p className="body mosaic-lede">
                Not only what Duck downloaded. Browse, rename, move and delete
                anything in your media library. Android asks for permission
                once, for the whole library, instead of once per file.
              </p>
            </Reveal>
            <div className="mosaic">
              <Reveal className="mosaic-big" delay={100}>
                <div className="clip-frame">
                  <Image
                    src="/shots/crop-folders.jpg"
                    alt="The folder browser listing video folders on the device"
                    width={1080}
                    height={880}
                    sizes="(max-width: 900px) 92vw, 640px"
                  />
                </div>
              </Reveal>
              <Reveal className="mosaic-small" delay={150}>
                <div className="clip-frame">
                  <Image
                    src="/shots/crop-library.jpg"
                    alt="The video library listing saved downloads"
                    width={1080}
                    height={980}
                    sizes="(max-width: 900px) 92vw, 380px"
                  />
                </div>
              </Reveal>
            </div>
          </div>
        </section>

        <section className="section">
          <div className="wrap showcase">
            <Reveal>
              <h2 className="h2">Keep what you save</h2>
            </Reveal>
            <Reveal delay={70}>
              <PlayButton />
            </Reveal>
          </div>
        </section>
      </main>
      <Footer />
    </>
  );
}
