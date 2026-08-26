import { useState } from 'react';
import type { MediaCandidate } from '@/core/types';
import { sendMessage } from '@/core/messaging';
import { CandidateList } from '@/ui/components/CandidateList';
import { FormatPicker } from '@/ui/components/FormatPicker';
import { PostItems } from '@/ui/components/PostItems';
import { JobList } from '@/ui/components/JobList';
import { EngineJobList } from '@/ui/components/EngineJobList';
import { DownloadIcon, LockIcon, PanelIcon, RefreshIcon } from '@/ui/components/Icons';
import { useActiveTab, useCandidates, useEngineJobs, useJobs, useSitePermission } from '@/ui/hooks';

export default function App() {
  const tab = useActiveTab();
  const { candidates, loading, rescan } = useCandidates(tab?.id);
  const jobs = useJobs();
  const { jobs: engineJobs, status: engineStatus } = useEngineJobs();
  const permission = useSitePermission(tab?.url);
  const [selected, setSelected] = useState<MediaCandidate | null>(null);
  /** Set when a link turned out to hold several items (a carousel). */
  const [postItems, setPostItems] = useState<MediaCandidate[] | null>(null);
  const [probing, setProbing] = useState(false);
  const [probeError, setProbeError] = useState<string | null>(null);

  const usingEngine = engineStatus?.connected === true && engineJobs !== null;

  const activeJobs = jobs.filter((job) =>
    ['queued', 'resolving', 'downloading', 'muxing', 'paused'].includes(job.status),
  );

  const activeEngineJobs = (engineJobs ?? []).filter((job) =>
    ['queued', 'preparing', 'downloading', 'paused', 'verifying', 'retrying', 'waitingForSource'].includes(
      job.state,
    ),
  );

  const showingJobs = usingEngine ? activeEngineJobs.length > 0 : activeJobs.length > 0;

  /**
   * Ask the resolver to work the page out from its URL alone. This is what makes
   * players that expose nothing to the DOM — Facebook, Instagram, TikTok —
   * downloadable without a per-site adapter.
   */
  const probePage = async () => {
    if (!tab?.url) return;
    setProbing(true);
    setProbeError(null);
    try {
      const found = await sendMessage('resolve:page', { pageUrl: tab.url, title: tab.title });
      if (found.length > 1) setPostItems(found);
      else if (found[0]) setSelected(found[0]);
      else setProbeError('Nothing downloadable found on this page.');
    } catch (error) {
      setProbeError(
        error instanceof Error ? error.message : 'Nothing downloadable found on this page.',
      );
    } finally {
      setProbing(false);
    }
  };

  return (
    <div className="flex max-h-[560px] flex-col">
      <Header
        onRescan={rescan}
        onOpenPanel={() => {
          if (tab?.id !== undefined) void sendMessage('panel:open', { tabId: tab.id });
          window.close();
        }}
      />

      <main className="flex-1 overflow-y-auto px-3 pb-3">
        {postItems ? (
          <PostItems
            items={postItems}
            onBack={() => setPostItems(null)}
            onStarted={() => setPostItems(null)}
          />
        ) : selected ? (
          <FormatPicker
            candidate={selected}
            onBack={() => setSelected(null)}
            onStarted={() => setSelected(null)}
          />
        ) : (
          <div className="flex flex-col gap-4">
            <section className="flex flex-col gap-2">
              {candidates.length > 0 ? (
                <CandidateList candidates={candidates} onSelect={setSelected} />
              ) : permission.granted === false ? (
                <NeedsPermission onGrant={() => void permission.request()} />
              ) : (
                <Empty
                  loading={loading}
                  probing={probing}
                  error={probeError}
                  canProbe={Boolean(tab?.url?.startsWith('http'))}
                  onProbe={() => void probePage()}
                />
              )}
            </section>

            {showingJobs && (
              <section className="flex flex-col gap-2">
                <h2 className="px-0.5 text-[11px] font-semibold uppercase tracking-wide text-duck-muted">
                  Downloading
                </h2>
                {usingEngine ? (
                  <EngineJobList jobs={activeEngineJobs} compact />
                ) : (
                  <JobList jobs={activeJobs} compact />
                )}
              </section>
            )}
          </div>
        )}
      </main>
    </div>
  );
}

function Header({ onRescan, onOpenPanel }: { onRescan: () => void; onOpenPanel: () => void }) {
  return (
    <header className="flex items-center gap-2 px-3 py-2.5">
      <span className="flex size-7 items-center justify-center rounded-lg bg-duck-accent text-black">
        <DownloadIcon className="size-4" />
      </span>
      <h1 className="flex-1 text-[13px] font-bold tracking-tight">Duck Downloader</h1>
      <IconButton label="Rescan page" onClick={onRescan}>
        <RefreshIcon />
      </IconButton>
      <IconButton label="Open downloads panel" onClick={onOpenPanel}>
        <PanelIcon />
      </IconButton>
    </header>
  );
}

function IconButton({
  label,
  onClick,
  children,
}: {
  label: string;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={label}
      title={label}
      className="rounded-lg p-1.5 text-duck-muted transition hover:bg-duck-surface hover:text-duck-text focus:outline-none focus-visible:ring-2 focus-visible:ring-duck-accent"
    >
      {children}
    </button>
  );
}

function Empty({
  loading,
  probing,
  error,
  canProbe,
  onProbe,
}: {
  loading: boolean;
  probing: boolean;
  error: string | null;
  canProbe: boolean;
  onProbe: () => void;
}) {
  return (
    <div className="flex flex-col items-center gap-3 rounded-xl border border-dashed border-duck-border px-4 py-7 text-center">
      <div>
        <p className="text-[13px] font-semibold">
          {loading ? 'Looking for media…' : 'Nothing detected on the page'}
        </p>
        <p className="mt-1 text-[11px] leading-relaxed text-duck-muted">
          {loading
            ? 'Scanning.'
            : 'Some players hide their video from the page. Duck can still work it out from the link.'}
        </p>
      </div>

      {error && (
        <p className="w-full rounded-lg border border-duck-danger/40 bg-duck-danger/10 p-2 text-[11px] text-duck-danger">
          {error}
        </p>
      )}

      {!loading && canProbe && (
        <button
          type="button"
          onClick={onProbe}
          disabled={probing}
          className="flex items-center gap-2 rounded-xl bg-duck-accent px-4 py-2 text-[12px] font-bold text-black transition hover:brightness-105 disabled:opacity-60"
        >
          <DownloadIcon className="size-4" />
          {probing ? 'Checking the link…' : 'Try this page'}
        </button>
      )}
    </div>
  );
}

/**
 * Sites outside the shipped host list are opt-in. Explaining that here — rather
 * than asking for `<all_urls>` at install time — is what keeps the install
 * prompt to something a user can actually agree to.
 */
function NeedsPermission({ onGrant }: { onGrant: () => void }) {
  return (
    <div className="flex flex-col items-center gap-3 rounded-xl border border-dashed border-duck-border px-4 py-7 text-center">
      <span className="flex size-9 items-center justify-center rounded-full bg-duck-surface text-duck-muted">
        <LockIcon className="size-4" />
      </span>
      <div>
        <p className="text-[13px] font-semibold">Duck has no access to this site</p>
        <p className="mt-1 text-[11px] leading-relaxed text-duck-muted">
          Grant access to this one site and Duck will detect media on it. Nothing changes for any
          other site.
        </p>
      </div>
      <button
        type="button"
        onClick={onGrant}
        className="rounded-xl bg-duck-accent px-4 py-2 text-[12px] font-bold text-black transition hover:brightness-105"
      >
        Enable on this site
      </button>
    </div>
  );
}
