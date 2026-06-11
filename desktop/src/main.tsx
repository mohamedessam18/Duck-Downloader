import React, { useEffect, useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import './styles.css';

import duckAngry from './assets/duck-angry.png';
import duckError from './assets/duck-error.png';
import duckIdle from './assets/duck-idle.png';
import duckLoading from './assets/duck-loading.png';
import duckSuccess from './assets/duck-success.png';

type DownloadType = 'video' | 'audio';
type DownloadStatus =
  | 'queued'
  | 'downloading'
  | 'processing'
  | 'paused'
  | 'completed'
  | 'failed'
  | 'cancelled';

type DownloadItem = {
  id: string;
  url: string;
  title: string;
  thumbnail?: string | null;
  platform: string;
  quality?: string | null;
  type: DownloadType;
  filePath?: string | null;
  createdAt: string;
  status: DownloadStatus;
  progress: number;
  favorite: boolean;
};

type FormatInfo = {
  id: string;
  label: string;
  ext?: string | null;
  height?: number | null;
  width?: number | null;
  filesize?: number | null;
};

type MediaMetadata = {
  url: string;
  title: string;
  thumbnail?: string | null;
  duration?: string | null;
  platform: string;
  qualities: FormatInfo[];
  audio_formats: FormatInfo[];
};

type StatusUpdate = {
  progress: number;
  speed?: string | null;
  eta?: string | null;
  status: DownloadStatus | 'processing';
  fileUrl?: string | null;
  filename?: string | null;
  error?: string | null;
};

type Flow = 'idle' | 'extracting' | 'ready' | 'downloading' | 'success' | 'error';
type Tab = 'home' | 'videos' | 'audios';

const urlRegex = /^https?:\/\/[^\s/$.?#].[^\s]*$/i;

function isPublicMediaCandidate(value: string) {
  return urlRegex.test(value.trim());
}

function wsUrlFor(apiBaseUrl: string, downloadId: string) {
  const url = new URL(apiBaseUrl);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  url.pathname = `/ws/download/${downloadId}`;
  url.search = '';
  return url.toString();
}

function duckForFlow(flow: Flow) {
  if (flow === 'extracting' || flow === 'downloading') return duckLoading;
  if (flow === 'success') return duckSuccess;
  if (flow === 'error') return duckError;
  return duckIdle;
}

function App() {
  const [apiBaseUrl, setApiBaseUrl] = useState('http://localhost:8000');
  const [tab, setTab] = useState<Tab>('home');
  const [downloads, setDownloads] = useState<DownloadItem[]>([]);
  const [flow, setFlow] = useState<Flow>('idle');
  const [status, setStatus] = useState('Tap the duck');
  const [metadata, setMetadata] = useState<MediaMetadata | null>(null);
  const [selectedType, setSelectedType] = useState<DownloadType>('video');
  const [quality, setQuality] = useState('Best');
  const [busy, setBusy] = useState(false);
  const [controlPending, setControlPending] = useState<Set<string>>(new Set());
  const [activeId, setActiveId] = useState<string | null>(null);
  const [playerItem, setPlayerItem] = useState<DownloadItem | null>(null);

  useEffect(() => {
    void window.duckDesktop.getApiBaseUrl().then(setApiBaseUrl);
    void refreshDownloads();
  }, []);

  async function refreshDownloads() {
    const stored = await window.duckDesktop.getDownloads();
    setDownloads(stored);
  }

  const videos = useMemo(
    () =>
      downloads
        .filter((item) => item.type === 'video' && item.status === 'completed')
        .sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
    [downloads],
  );
  const audios = useMemo(
    () =>
      downloads
        .filter((item) => item.type === 'audio' && item.status === 'completed')
        .sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
    [downloads],
  );
  const activeDownloads = useMemo(
    () =>
      downloads
        .filter((item) =>
          ['queued', 'downloading', 'processing', 'paused'].includes(item.status),
        )
        .sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
    [downloads],
  );
  const active = activeDownloads.find((item) => item.id === activeId) || activeDownloads[0];

  useEffect(() => {
    if (activeId && !activeDownloads.some((item) => item.id === activeId)) {
      setActiveId(activeDownloads[0]?.id || null);
      if (activeDownloads.length === 0 && flow === 'downloading') {
        setFlow('idle');
        setStatus('Tap the duck');
      }
      return;
    }
    if (activeDownloads.length > 0 && (flow === 'idle' || flow === 'success')) {
      setActiveId((current) => current || activeDownloads[0].id);
      setFlow('downloading');
      setStatus('Downloading...');
    }
  }, [activeDownloads, activeId, flow]);

  async function pasteAndExtract() {
    if (busy) return;
    setBusy(true);
    setFlow('extracting');
    setStatus('Checking link...');
    setMetadata(null);

    try {
      const url = await window.duckDesktop.readClipboard();
      if (!url || !isPublicMediaCandidate(url)) {
        throw new Error('Copy a public social media link first.');
      }
      const response = await fetch(`${apiBaseUrl}/api/extract`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url }),
      });
      if (!response.ok) throw new Error(await readApiError(response));
      const data = (await response.json()) as Omit<MediaMetadata, 'url'>;
      const media = { ...data, url };
      setMetadata(media);
      setSelectedType('video');
      setQuality(firstQuality(media, 'video'));
      setFlow('ready');
      setStatus('Choose video or audio');
    } catch (error) {
      setFlow('error');
      setStatus(error instanceof Error ? error.message : 'Extraction failed.');
    } finally {
      setBusy(false);
    }
  }

  async function startDownload() {
    if (!metadata || busy) return;
    setBusy(true);
    setFlow('downloading');
    setStatus('Downloading...');
    setMetadata(null);

    try {
      const response = await fetch(`${apiBaseUrl}/api/download`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          url: metadata.url,
          type: selectedType,
          quality,
          premiumNoWatermark: false,
        }),
      });
      if (!response.ok) throw new Error(await readApiError(response));
      const { downloadId } = (await response.json()) as { downloadId: string };
      const item: DownloadItem = {
        id: downloadId,
        url: metadata.url,
        title: metadata.title,
        thumbnail: metadata.thumbnail,
        platform: metadata.platform,
        quality,
        type: selectedType,
        createdAt: new Date().toISOString(),
        status: 'queued',
        progress: 0,
        favorite: false,
      };
      await saveItem(item);
      setActiveId(downloadId);
      watchDownload(downloadId, item);
    } catch (error) {
      setFlow('error');
      setStatus(error instanceof Error ? error.message : 'Download failed.');
    } finally {
      setBusy(false);
    }
  }

  function watchDownload(downloadId: string, baseItem: DownloadItem) {
    const socket = new WebSocket(wsUrlFor(apiBaseUrl, downloadId));
    socket.onmessage = async (event) => {
      const update = JSON.parse(event.data as string) as StatusUpdate;
      const next: DownloadItem = {
        ...baseItem,
        progress: update.progress ?? baseItem.progress,
        status: update.status === 'processing' ? 'processing' : update.status,
      };
      await saveItem(next);

      if (update.status === 'completed' && update.fileUrl) {
        const filePath = await window.duckDesktop.downloadRemoteFile({
          url: update.fileUrl,
          filename:
            update.filename ||
            `${baseItem.title}.${baseItem.type === 'audio' ? 'mp3' : 'mp4'}`,
          type: baseItem.type,
        });
        await saveItem({
          ...next,
          filePath,
          progress: 100,
          status: 'completed',
        });
        setMetadata(null);
        setFlow('success');
        setStatus('Download complete');
        socket.close();
      }

      if (update.status === 'failed') {
        await saveItem({ ...next, status: 'failed' });
        setFlow('error');
        setStatus(update.error || 'Download failed.');
        socket.close();
      }

      if (update.status === 'paused' || update.status === 'cancelled') {
        if (update.status === 'cancelled') {
          await deleteItem(next);
          if (activeId === downloadId) {
            setActiveId(null);
            setFlow('idle');
            setStatus('Tap the duck');
          }
        } else {
          await saveItem({ ...next, status: update.status });
          setStatus('Download paused');
          setFlow('downloading');
        }
        socket.close();
      }
    };
    socket.onerror = () => {
      setFlow('error');
      setStatus('Connection to download server failed.');
    };
  }

  async function saveItem(item: DownloadItem) {
    await window.duckDesktop.saveDownload(item);
    await refreshDownloads();
  }

  async function deleteItem(item: DownloadItem) {
    await window.duckDesktop.deleteDownload(item.id);
    await refreshDownloads();
  }

  async function pauseDownload(item: DownloadItem) {
    await controlDownload(item, 'pause');
  }

  async function resumeDownload(item: DownloadItem) {
    const next = await controlDownload(item, 'resume');
    if (next && next.status !== 'paused') watchDownload(item.id, next);
  }

  async function cancelDownload(item: DownloadItem) {
    await controlDownload(item, 'cancel');
  }

  async function controlDownload(
    item: DownloadItem,
    action: 'pause' | 'resume' | 'cancel',
  ) {
    setControlPending((current) => new Set(current).add(item.id));
    try {
      const response = await fetch(`${apiBaseUrl}/api/download/${item.id}/${action}`, {
        method: 'POST',
      });
      if (!response.ok) {
        const message = await readApiError(response);
        setFlow('error');
        setStatus(
          response.status === 404
            ? 'Restart backend with latest build, then try again.'
            : message,
        );
        return null;
      }
      const update = (await response.json()) as StatusUpdate;
      const next: DownloadItem = {
        ...item,
        progress: update.progress ?? item.progress,
        status: update.status,
      };
      await saveItem(next);
      if (action === 'resume' && next.status !== 'paused') {
        setActiveId(item.id);
        setFlow('downloading');
        setStatus('Downloading...');
      } else if (action === 'resume') {
        setStatus('Pausing...');
      } else if (action === 'pause') {
        setStatus('Download paused');
      } else {
        await deleteItem(next);
        if (activeId === item.id) {
          setActiveId(null);
          setFlow('idle');
          setStatus('Tap the duck');
        }
      }
      return next;
    } catch {
      setFlow('error');
      setStatus('Restart backend with latest build, then try again.');
      return null;
    } finally {
      setControlPending((current) => {
        const next = new Set(current);
        next.delete(item.id);
        return next;
      });
    }
  }

  function changeType(type: DownloadType) {
    if (!metadata) return;
    setSelectedType(type);
    setQuality(firstQuality(metadata, type));
  }

  return (
    <main className="app-shell">
      {tab === 'home' && (
        <HomeView
          flow={flow}
          status={status}
          metadata={metadata}
          selectedType={selectedType}
          quality={quality}
          busy={busy}
          active={active}
          activeDownloads={activeDownloads}
          controlPending={controlPending}
          videoCount={videos.length}
          onDuckClick={pasteAndExtract}
          onTypeChange={changeType}
          onQualityChange={setQuality}
          onDownload={startDownload}
          onPause={pauseDownload}
          onResume={resumeDownload}
          onCancel={cancelDownload}
          onOpenVideos={() => setTab('videos')}
        />
      )}
      {tab === 'videos' && (
        <LibraryView
          title="VIDEOS"
          items={videos}
          empty="No downloaded videos yet."
          onBack={() => setTab('home')}
          onOpen={setPlayerItem}
          onDelete={deleteItem}
        />
      )}
      {tab === 'audios' && (
        <LibraryView
          title="AUDIOS"
          items={audios}
          empty="No downloaded audios yet."
          onBack={() => setTab('home')}
          onOpen={setPlayerItem}
          onDelete={deleteItem}
        />
      )}
      <BottomNav tab={tab} onTab={setTab} />
      {playerItem && <Player item={playerItem} onClose={() => setPlayerItem(null)} />}
    </main>
  );
}

function HomeView(props: {
  flow: Flow;
  status: string;
  metadata: MediaMetadata | null;
  selectedType: DownloadType;
  quality: string;
  busy: boolean;
  active?: DownloadItem;
  activeDownloads: DownloadItem[];
  controlPending: Set<string>;
  videoCount: number;
  onDuckClick(): void;
  onTypeChange(type: DownloadType): void;
  onQualityChange(value: string): void;
  onDownload(): void;
  onPause(item: DownloadItem): void;
  onResume(item: DownloadItem): void;
  onCancel(item: DownloadItem): void;
  onOpenVideos(): void;
}) {
  const progress = props.active?.progress || 0;
  const showQueue = props.activeDownloads.length > 1 && !props.metadata;
  const formats =
    props.selectedType === 'video'
      ? props.metadata?.qualities || []
      : props.metadata?.audio_formats || [];

  return (
    <section className={showQueue ? 'home home-queue' : 'home'}>
      <header className="brand">
        <h1>Duck</h1>
        <p>DOWNLOADER</p>
      </header>
      <div className="hint">
        <span>🔗</span>
        <p>Copy a link from any social media and tap the duck to download!</p>
      </div>
      <button className="duck-button" onClick={props.onDuckClick} aria-label="Tap duck">
        <span className="duck-ring" />
        <img
          className={`duck duck-${props.flow}`}
          src={duckForFlow(props.flow)}
          alt="Duck mascot"
        />
      </button>
      <StatusBar flow={props.flow} status={props.status} progress={progress} />
      {props.metadata ? (
        <section className="options-card">
          <div className="media-head">
            {props.metadata.thumbnail ? (
              <img src={props.metadata.thumbnail} alt="" />
            ) : (
              <div className="thumb-fallback">▶</div>
            )}
            <div>
              <strong>{props.metadata.title}</strong>
              <span>{props.metadata.platform}</span>
            </div>
          </div>
          <div className="option-row">
            <button
              className={props.selectedType === 'video' ? 'chip active' : 'chip'}
              onClick={() => props.onTypeChange('video')}
            >
              ▶ Video
            </button>
            <button
              className={props.selectedType === 'audio' ? 'chip active' : 'chip'}
              onClick={() => props.onTypeChange('audio')}
            >
              ♪ Audio
            </button>
            <select
              value={props.quality}
              onChange={(event) => props.onQualityChange(event.target.value)}
            >
              {qualityLabels(formats).map((label) => (
                <option key={label} value={label}>
                  {label}
                </option>
              ))}
            </select>
          </div>
          <button className="download-button" disabled={props.busy} onClick={props.onDownload}>
            {props.busy ? 'Please wait...' : 'Download'}
          </button>
        </section>
      ) : showQueue ? (
        <DownloadQueueCard
          items={props.activeDownloads}
          pendingIds={props.controlPending}
          onPause={props.onPause}
          onResume={props.onResume}
          onCancel={props.onCancel}
        />
      ) : (
        <button className="library-card" onClick={props.onOpenVideos}>
          <span className="folder-icon">▶</span>
          <span>
            <strong>VIDEOS</strong>
            <small>
              {props.videoCount
                ? `${props.videoCount} downloaded video${props.videoCount === 1 ? '' : 's'}`
                : 'View all downloaded videos'}
            </small>
          </span>
          <b>›</b>
        </button>
      )}
    </section>
  );
}

function DownloadQueueCard(props: {
  items: DownloadItem[];
  pendingIds: Set<string>;
  onPause(item: DownloadItem): void;
  onResume(item: DownloadItem): void;
  onCancel(item: DownloadItem): void;
}) {
  return (
    <section className="queue-card">
      <header>
        <strong>Download Queue</strong>
        <span>{props.items.length}</span>
      </header>
      <div className="queue-list">
        {props.items.slice(0, 4).map((item) => (
          <article className={props.pendingIds.has(item.id) ? 'queue-row pending' : 'queue-row'} key={item.id}>
            {item.thumbnail ? (
              <img src={item.thumbnail} alt="" />
            ) : (
              <span>{item.type === 'audio' ? '♪' : '▶'}</span>
            )}
            <div>
              <p>{item.title}</p>
              <div className="mini-progress">
                <i style={{ width: `${Math.max(0, Math.min(100, item.progress))}%` }} />
              </div>
            </div>
            <small>{item.progress}%</small>
            <em>{item.type}</em>
            <button
              className="queue-action"
              disabled={props.pendingIds.has(item.id)}
              onClick={() =>
                item.status === 'paused' ? props.onResume(item) : props.onPause(item)
              }
              aria-label={item.status === 'paused' ? 'Resume download' : 'Pause download'}
            >
              {props.pendingIds.has(item.id) ? '…' : item.status === 'paused' ? '▶' : 'Ⅱ'}
            </button>
            <button
              className="queue-action danger"
              disabled={props.pendingIds.has(item.id)}
              onClick={() => props.onCancel(item)}
              aria-label="Cancel download"
            >
              ×
            </button>
          </article>
        ))}
      </div>
    </section>
  );
}

function StatusBar(props: { flow: Flow; status: string; progress: number }) {
  const active = props.flow === 'downloading' || props.flow === 'extracting';
  const value = props.flow === 'success' ? 100 : active ? props.progress : 0;
  return (
    <div className={`status status-${props.flow}`}>
      <p>{props.status}</p>
      <div className="progress-track">
        <span
          className={props.flow === 'extracting' ? 'indeterminate' : ''}
          style={{ width: `${Math.max(0, Math.min(100, value))}%` }}
        />
      </div>
      {props.flow === 'downloading' && <small>{props.progress}%</small>}
    </div>
  );
}

function LibraryView(props: {
  title: string;
  items: DownloadItem[];
  empty: string;
  onBack(): void;
  onOpen(item: DownloadItem): void;
  onDelete(item: DownloadItem): void;
}) {
  return (
    <section className="library">
      <header>
        <button className="back-button" onClick={props.onBack}>
          ↩
        </button>
        <h2>{props.title}</h2>
      </header>
      {props.items.length === 0 ? (
        <p className="empty">{props.empty}</p>
      ) : (
        <div className="download-list">
          {props.items.map((item) => (
            <article className="download-row" key={item.id}>
              <button className="row-main" onClick={() => props.onOpen(item)}>
                {item.thumbnail ? <img src={item.thumbnail} alt="" /> : <span>▶</span>}
                <span>
                  <strong>{displayName(item)}</strong>
                  <small>{item.quality || (item.type === 'audio' ? 'Saved audio' : 'Saved video')}</small>
                </span>
              </button>
              <div className="row-actions">
                {item.filePath && (
                  <button onClick={() => window.duckDesktop.revealFile(item.filePath!)}>
                    ⊞
                  </button>
                )}
                <button onClick={() => props.onDelete(item)}>×</button>
              </div>
            </article>
          ))}
        </div>
      )}
    </section>
  );
}

function Player(props: { item: DownloadItem; onClose(): void }) {
  const isVideo = props.item.type === 'video';
  const [source, setSource] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setSource(null);
    setError(null);
    if (!props.item.filePath) return;
    void window.duckDesktop
      .getMediaSource(props.item.filePath)
      .then(setSource)
      .catch(() => setError('Could not prepare this file for playback.'));
  }, [props.item.filePath]);

  return (
    <div className="player-overlay">
      <section className="player">
        <button className="back-button" onClick={props.onClose}>
          ↩
        </button>
        <h3>{props.item.title}</h3>
        {error ? (
          <PlayerError item={props.item} message={error} />
        ) : props.item.filePath && source ? (
          isVideo ? (
            <video
              src={source}
              controls
              autoPlay
              onError={() =>
                setError(
                  'This file codec is not supported by the built-in player. Open it externally or download it again with the latest backend.',
                )
              }
            />
          ) : (
            <audio
              src={source}
              controls
              autoPlay
              onError={() => setError('This audio file could not be played.')}
            />
          )
        ) : props.item.filePath ? (
          <p>Loading file...</p>
        ) : (
          <p>File is not available locally.</p>
        )}
      </section>
    </div>
  );
}

function PlayerError(props: { item: DownloadItem; message: string }) {
  return (
    <div className="player-error">
      <p>{props.message}</p>
      <div>
        {props.item.filePath && (
          <>
            <button onClick={() => window.duckDesktop.openFile(props.item.filePath!)}>
              Open externally
            </button>
            <button onClick={() => window.duckDesktop.revealFile(props.item.filePath!)}>
              Show file
            </button>
          </>
        )}
      </div>
    </div>
  );
}

function BottomNav(props: { tab: Tab; onTab(tab: Tab): void }) {
  return (
    <nav className="bottom-nav">
      <button className={props.tab === 'home' ? 'active' : ''} onClick={() => props.onTab('home')}>
        <span>⌂</span> HOME
      </button>
      <button className={props.tab === 'videos' ? 'active' : ''} onClick={() => props.onTab('videos')}>
        <span>▶</span> VIDEOS
      </button>
      <button className={props.tab === 'audios' ? 'active' : ''} onClick={() => props.onTab('audios')}>
        <span>♪</span> AUDIOS
      </button>
    </nav>
  );
}

async function readApiError(response: Response) {
  try {
    const body = (await response.json()) as { detail?: string };
    return body.detail || `Request failed with status ${response.status}.`;
  } catch {
    return `Request failed with status ${response.status}.`;
  }
}

function firstQuality(metadata: MediaMetadata, type: DownloadType) {
  const labels = qualityLabels(type === 'video' ? metadata.qualities : metadata.audio_formats);
  return labels[0] || 'Best';
}

function qualityLabels(formats: FormatInfo[]) {
  const labels = formats.map((format) => format.label).filter(Boolean);
  return labels.length ? [...new Set(labels)] : ['Best'];
}

function displayName(item: DownloadItem) {
  const ext = item.type === 'audio' ? 'mp3' : 'mp4';
  return item.title.toLowerCase().endsWith(`.${ext}`) ? item.title : `${item.title}.${ext}`;
}

createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
