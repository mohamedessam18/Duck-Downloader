import { useMemo, useState } from 'react';
import { sendMessage } from '@/core/messaging';
import type { DownloadJob } from '@/core/types';
import { JobList } from '@/ui/components/JobList';
import { EngineJobList } from '@/ui/components/EngineJobList';
import { useEngineJobs, useJobs, useSettings } from '@/ui/hooks';
import type { EngineStatus } from '@/engine/client';
import { GuardPanel } from '@/ui/components/GuardPanel';

type Tab = 'active' | 'done' | 'guard' | 'settings';

const ACTIVE_STATUSES: DownloadJob['status'][] = [
  'queued',
  'resolving',
  'downloading',
  'muxing',
  'paused',
];

const ENGINE_ACTIVE = ['queued', 'preparing', 'downloading', 'paused', 'verifying', 'retrying', 'waitingForSource'];

export default function App() {
  const jobs = useJobs();
  const { jobs: engineJobs, status: engineStatus } = useEngineJobs();
  const [tab, setTab] = useState<Tab>('active');

  // The engine is the real download manager whenever it is installed; the
  // in-browser queue is only the fallback for machines without it.
  const usingEngine = engineStatus?.connected === true && engineJobs !== null;

  const { active, done } = useMemo(
    () => ({
      active: jobs.filter((job) => ACTIVE_STATUSES.includes(job.status)),
      done: jobs.filter((job) => !ACTIVE_STATUSES.includes(job.status)),
    }),
    [jobs],
  );

  const engineActive = (engineJobs ?? []).filter((job) => ENGINE_ACTIVE.includes(job.state));
  const engineDone = (engineJobs ?? []).filter((job) => !ENGINE_ACTIVE.includes(job.state));

  return (
    <div className="flex h-screen flex-col">
      <nav className="flex gap-1 border-b border-duck-border px-3 py-2">
        <TabButton
          current={tab}
          value="active"
          onSelect={setTab}
          count={usingEngine ? engineActive.length : active.length}
        >
          Active
        </TabButton>
        <TabButton
          current={tab}
          value="done"
          onSelect={setTab}
          count={usingEngine ? engineDone.length : done.length}
        >
          History
        </TabButton>
        <TabButton current={tab} value="guard" onSelect={setTab}>
          Guard
        </TabButton>
        <TabButton current={tab} value="settings" onSelect={setTab}>
          Settings
        </TabButton>
      </nav>

      <main className="flex-1 overflow-y-auto p-3">
        {tab === 'active' && (
          <div className="flex flex-col gap-3">
            <EngineBanner status={engineStatus} />
            {usingEngine ? (
              engineActive.length > 0 ? (
                <EngineJobList jobs={engineActive} />
              ) : (
                <Empty message="No active downloads." />
              )
            ) : active.length > 0 ? (
              <JobList jobs={active} />
            ) : (
              <Empty message="No active downloads." />
            )}
          </div>
        )}
        {tab === 'done' &&
          (usingEngine ? (
            engineDone.length > 0 ? (
              <EngineJobList jobs={engineDone} />
            ) : (
              <Empty message="Nothing downloaded yet." />
            )
          ) : done.length > 0 ? (
            <JobList jobs={done} />
          ) : (
            <Empty message="Nothing downloaded yet." />
          ))}
        {tab === 'guard' && <GuardPanel />}
        {tab === 'settings' && <SettingsPanel />}
      </main>
    </div>
  );
}

function TabButton({
  current,
  value,
  onSelect,
  count,
  children,
}: {
  current: Tab;
  value: Tab;
  onSelect: (tab: Tab) => void;
  count?: number;
  children: React.ReactNode;
}) {
  const selected = current === value;
  return (
    <button
      type="button"
      onClick={() => onSelect(value)}
      className={`flex items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-[12px] font-semibold transition ${
        selected ? 'bg-duck-surface text-duck-text' : 'text-duck-muted hover:text-duck-text'
      }`}
    >
      {children}
      {count !== undefined && count > 0 && (
        <span className="rounded bg-duck-accent/15 px-1.5 text-[10px] tabular-nums text-duck-accent">
          {count}
        </span>
      )}
    </button>
  );
}

function SettingsPanel() {
  const [settings, update] = useSettings();

  return (
    <div className="flex flex-col gap-4">
      <Group title="On the page">
        <Toggle
          label="Show the download button on videos"
          checked={settings.overlayEnabled}
          onChange={(overlayEnabled) => update({ overlayEnabled })}
        />
        <Toggle
          label="One-click download (skip the quality list)"
          checked={settings.oneClickDownload}
          onChange={(oneClickDownload) => update({ oneClickDownload })}
        />
        <Select
          label="Preferred quality"
          value={String(settings.preferredHeight)}
          onChange={(value) => update({ preferredHeight: Number(value) })}
          options={[
            ['0', 'Always ask'],
            ['2160', '4K'],
            ['1440', '1440p'],
            ['1080', '1080p'],
            ['720', '720p'],
            ['480', '480p'],
          ]}
        />
      </Group>

      <YouTubeCheck />

      <Group title="Downloads">
        <Toggle
          label="Handle all browser downloads"
          checked={settings.interceptDownloads}
          onChange={(interceptDownloads) => update({ interceptDownloads })}
        />
        <p className="text-[10px] leading-relaxed text-duck-muted">
          Files you download anywhere in the browser are taken over by Duck, so they
          arrive faster and can be paused and resumed. Turned off, only media Duck
          detects goes through the engine.
        </p>
      </Group>

      <Group title="Engine">
        <Toggle
          label="Merge video and audio in the browser"
          checked={settings.localMux}
          onChange={(localMux) => update({ localMux })}
        />
        <p className="text-[10px] leading-relaxed text-duck-muted">
          High resolutions arrive as separate video and audio tracks. Merging them
          here keeps the whole download on your machine. Files over 400MB are sent
          to the server instead, because the browser cannot hold them in memory.
        </p>
        <Toggle
          label="Use the Duck server when a link cannot be resolved locally"
          checked={settings.backendFallback}
          onChange={(backendFallback) => update({ backendFallback })}
        />
        <p className="text-[10px] leading-relaxed text-duck-muted">
          With this off, Duck only downloads what it can work out inside your browser. Nothing is
          sent anywhere. With it on, the page link is sent to the Duck server for the links your
          browser cannot handle alone.
        </p>
        <Toggle
          label="YouTube support"
          checked={settings.youtubeEnabled}
          onChange={(youtubeEnabled) => update({ youtubeEnabled })}
        />
      </Group>
    </div>
  );
}

/**
 * Answers one question: can this browser resolve YouTube on its own?
 *
 * The answer depends entirely on the signed-in session making the request, so
 * it cannot be determined anywhere but here. It decides whether YouTube
 * downloads can stay local or must go through the server.
 */
function YouTubeCheck() {
  const [result, setResult] = useState<
    { status: string; reason?: string; playable: number; total: number } | null | 'none'
  >(null);
  const [busy, setBusy] = useState(false);

  const run = async () => {
    setBusy(true);
    try {
      const found = await sendMessage('diagnose:youtube', {});
      setResult(found ?? 'none');
    } catch {
      setResult('none');
    } finally {
      setBusy(false);
    }
  };

  const ok = result !== null && result !== 'none' && result.status === 'OK' && result.playable > 0;

  return (
    <Group title="YouTube">
      <button
        type="button"
        onClick={() => void run()}
        disabled={busy}
        className="rounded-xl bg-duck-surface px-3 py-2.5 text-[12px] font-semibold transition hover:bg-duck-surface-hover disabled:opacity-60"
      >
        {busy ? 'Asking YouTube…' : 'Check if YouTube works without the server'}
      </button>

      {result === 'none' && (
        <p className="text-[11px] text-duck-muted">
          Open a YouTube video in a tab first, then run this again.
        </p>
      )}

      {result !== null && result !== 'none' && (
        <div
          className={`rounded-xl border p-2.5 text-[11px] leading-relaxed ${
            ok
              ? 'border-emerald-500/30 bg-emerald-500/10 text-emerald-400'
              : 'border-amber-500/30 bg-amber-500/10 text-amber-400'
          }`}
        >
          <p className="font-semibold">
            {ok
              ? `Works locally — ${result.playable} formats available`
              : `YouTube answered ${result.status}`}
          </p>
          <p className="mt-1 opacity-90">
            {ok
              ? 'Duck can download YouTube on this machine without sending anything to a server.'
              : 'YouTube will not hand this browser the formats directly, so these downloads go through the Duck server.'}
          </p>
          {result.reason && <p className="mt-1 opacity-70">{result.reason}</p>}
        </div>
      )}
    </Group>
  );
}

function Group({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="flex flex-col gap-2.5">
      <h2 className="text-[11px] font-semibold uppercase tracking-wide text-duck-muted">{title}</h2>
      {children}
    </section>
  );
}

function Toggle({
  label,
  checked,
  onChange,
}: {
  label: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <label className="flex cursor-pointer items-center gap-2.5 rounded-xl border border-duck-border bg-duck-surface p-2.5">
      <input
        type="checkbox"
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
        className="size-4 flex-none accent-duck-accent"
      />
      <span className="text-[12px] leading-snug">{label}</span>
    </label>
  );
}

function Select({
  label,
  value,
  onChange,
  options,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  options: Array<[string, string]>;
}) {
  return (
    <label className="flex items-center gap-2.5 rounded-xl border border-duck-border bg-duck-surface p-2.5">
      <span className="flex-1 text-[12px]">{label}</span>
      <select
        value={value}
        onChange={(event) => onChange(event.target.value)}
        className="rounded-lg border border-duck-border bg-duck-bg px-2 py-1 text-[12px] text-duck-text"
      >
        {options.map(([optionValue, optionLabel]) => (
          <option key={optionValue} value={optionValue}>
            {optionLabel}
          </option>
        ))}
      </select>
    </label>
  );
}

/**
 * States what is actually handling downloads.
 *
 * Worth saying plainly: with the engine, downloads survive the browser closing
 * and resume across restarts. Without it they do not, and the user should know
 * which one they have rather than discovering it when a transfer disappears.
 */
function EngineBanner({ status }: { status: EngineStatus | null }) {
  if (!status) return null;

  if (status.connected) {
    return (
      <p className="rounded-lg border border-emerald-500/25 bg-emerald-500/10 px-2.5 py-2 text-[10px] leading-relaxed text-emerald-400">
        Duck Engine {status.engineVersion} is running. Downloads continue even if you close the
        browser.
      </p>
    );
  }

  return (
    <p className="rounded-lg border border-duck-border bg-duck-surface px-2.5 py-2 text-[10px] leading-relaxed text-duck-muted">
      {status.reason} Downloads run inside the browser for now, so closing it stops them.
    </p>
  );
}

function Empty({ message }: { message: string }) {
  return (
    <div className="rounded-xl border border-dashed border-duck-border px-4 py-10 text-center text-[12px] text-duck-muted">
      {message}
    </div>
  );
}
