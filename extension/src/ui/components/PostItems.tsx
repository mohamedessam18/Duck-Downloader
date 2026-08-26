import { useState } from 'react';
import type { MediaCandidate } from '@/core/types';
import { sendMessage } from '@/core/messaging';
import { formatBytes } from '../format';
import { BackIcon, DownloadIcon, MusicIcon, VideoIcon } from './Icons';

interface Props {
  items: MediaCandidate[];
  onBack: () => void;
  onStarted: () => void;
}

/**
 * A post that holds more than one piece of media.
 *
 * Instagram carousels are the reason this exists: a post can be images, videos,
 * or both mixed together, and each slide has to be downloadable on its own with
 * the right extension. Items arrive already typed by the backend, so a hybrid
 * post renders as a hybrid grid rather than being flattened into one kind.
 */
export function PostItems({ items, onBack, onStarted }: Props) {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const start = async (item: MediaCandidate) => {
    const format = item.formats[0];
    if (!format) return;
    setBusy(item.id);
    setError(null);
    try {
      await sendMessage('download:start', { candidate: item, format });
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not start the download.');
    } finally {
      setBusy(null);
    }
  };

  const startAll = async () => {
    setBusy('all');
    setError(null);
    try {
      // Sequential rather than parallel: the download manager polls every job,
      // and firing a 20-slide carousel at once buries the network and the UI.
      for (const item of items) {
        const format = item.formats[0];
        if (format) await sendMessage('download:start', { candidate: item, format });
      }
      onStarted();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not start the downloads.');
    } finally {
      setBusy(null);
    }
  };

  const videos = items.filter((item) => item.formats[0]?.kind === 'video').length;
  const images = items.length - videos;

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={onBack}
          className="rounded-lg p-1.5 text-duck-muted transition hover:bg-duck-surface hover:text-duck-text"
          aria-label="Back"
        >
          <BackIcon />
        </button>
        <div className="min-w-0 flex-1">
          <p className="truncate text-[13px] font-semibold">{items.length} items in this post</p>
          <p className="text-[11px] text-duck-muted">
            {[videos && `${videos} video${videos > 1 ? 's' : ''}`, images && `${images} image${images > 1 ? 's' : ''}`]
              .filter(Boolean)
              .join(' · ')}
          </p>
        </div>
      </div>

      {error && (
        <p className="rounded-lg border border-duck-danger/40 bg-duck-danger/10 p-2 text-[11px] text-duck-danger">
          {error}
        </p>
      )}

      <button
        type="button"
        onClick={() => void startAll()}
        disabled={busy !== null}
        className="flex items-center justify-center gap-2 rounded-xl bg-duck-accent px-3 py-2.5 text-[13px] font-bold text-black transition hover:brightness-105 disabled:opacity-60"
      >
        <DownloadIcon className="size-4" />
        {busy === 'all' ? 'Starting…' : `Download all ${items.length}`}
      </button>

      <ul className="grid grid-cols-3 gap-1.5">
        {items.map((item, index) => (
          <li key={item.id}>
            <ItemTile
              item={item}
              index={index}
              busy={busy === item.id}
              disabled={busy !== null}
              onStart={() => void start(item)}
            />
          </li>
        ))}
      </ul>
    </div>
  );
}

function ItemTile({
  item,
  index,
  busy,
  disabled,
  onStart,
}: {
  item: MediaCandidate;
  index: number;
  busy: boolean;
  disabled: boolean;
  onStart: () => void;
}) {
  const format = item.formats[0];
  const isVideo = format?.kind === 'video';

  return (
    <button
      type="button"
      onClick={onStart}
      disabled={disabled}
      title={`${isVideo ? 'Video' : 'Image'} ${index + 1} · ${format?.ext.toUpperCase() ?? ''}`}
      className="group relative aspect-square w-full overflow-hidden rounded-lg border border-duck-border bg-duck-surface transition hover:border-duck-accent disabled:opacity-60"
    >
      {item.thumbnail ? (
        <img src={item.thumbnail} alt="" className="size-full object-cover" />
      ) : (
        <span className="flex size-full items-center justify-center text-duck-muted">
          {isVideo ? <VideoIcon className="size-5" /> : <MusicIcon className="size-5" />}
        </span>
      )}

      <span className="absolute left-1 top-1 rounded bg-black/70 px-1 py-0.5 text-[9px] font-bold text-white">
        {isVideo ? 'VIDEO' : 'IMG'}
      </span>

      {format?.filesize ? (
        <span className="absolute bottom-1 left-1 rounded bg-black/70 px-1 py-0.5 text-[9px] text-white">
          {formatBytes(format.filesize)}
        </span>
      ) : null}

      <span className="absolute inset-0 flex items-center justify-center bg-black/55 opacity-0 transition group-hover:opacity-100">
        <DownloadIcon className={busy ? 'size-5 animate-pulse text-white' : 'size-5 text-white'} />
      </span>
    </button>
  );
}
