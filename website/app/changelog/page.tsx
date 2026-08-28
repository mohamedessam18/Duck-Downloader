import type { Metadata } from "next";
import Image from "next/image";
import { Footer, Nav, PageHead } from "../components/Shell";
import { Reveal } from "../components/Reveal";
import { releases, type ReleaseKind } from "../lib/changelog";

export const metadata: Metadata = {
  title: "What's new",
  description: "Every Duck Downloader release and what changed in it.",
  alternates: { canonical: "/changelog" }
};

const KIND_LABEL: Record<ReleaseKind, string> = {
  added: "New",
  fixed: "Fixed",
  improved: "Better"
};

function formatDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric"
  });
}

export default function ChangelogPage() {
  return (
    <>
      <Nav />
      <main>
        <PageHead
          title="What's new"
          lede="Every release, and what it changed for the people using it."
        />

        <section className="wrap section-tight">
          <Reveal>
            <div className="now-card">
              <div className="now-copy">
                <p className="aside-label">In the next release</p>
                <h2 className="h3">{releases[0].summary}</h2>
                <p className="small">
                  v{releases[0].version}, build {releases[0].build}, with{" "}
                  {releases[0].changes.length} changes below.
                </p>
              </div>
              <div className="clip-frame now-shot">
                <Image
                  src="/shots/crop-folders.jpg"
                  alt="The folder browser, rebuilt in this release"
                  width={1080}
                  height={880}
                  sizes="(max-width: 900px) 92vw, 420px"
                />
              </div>
            </div>
          </Reveal>
        </section>

        <section className="wrap section">
          <ol className="timeline">
            {releases.map((release, i) => (
              // The newest release is what someone came for; older ones are
              // reference. Same component, different weight.
              <Reveal key={release.version} delay={i * 60}>
                <li className={`release${i === 0 ? " release-lead" : ""}`}>
                  <div className="release-head">
                    <h2 className="h3 release-version">v{release.version}</h2>
                    <span className="release-build">build {release.build}</span>
                    <span className="release-date">
                      {release.date ? (
                        formatDate(release.date)
                      ) : (
                        <span className="pill-soon">Not released yet</span>
                      )}
                    </span>
                  </div>

                  {release.summary ? (
                    <p className="body release-summary">{release.summary}</p>
                  ) : null}

                  <ul className="release-changes">
                    {release.changes.map((change) => (
                      <li key={change.text}>
                        <span className={`tag tag-${change.kind}`}>
                          {KIND_LABEL[change.kind]}
                        </span>
                        <span className="body">{change.text}</span>
                      </li>
                    ))}
                  </ul>
                </li>
              </Reveal>
            ))}
          </ol>
        </section>
      </main>
      <Footer />
    </>
  );
}
