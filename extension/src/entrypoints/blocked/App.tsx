import { useEffect, useState } from 'react';
import { sendMessage } from '@/core/messaging';
import type { GuardStatus } from '@/core/guard-types';
import { LockIcon } from '@/ui/components/Icons';

/**
 * The page a blocked navigation lands on.
 *
 * It shows the user's own message, because a sentence someone wrote for
 * themselves in a clear moment does more than a generic "access denied". The
 * unlock path is present but deliberately unhurried — entering the PIN starts a
 * wait rather than opening the door.
 */
export default function App() {
  const [status, setStatus] = useState<GuardStatus | null>(null);
  const [pin, setPin] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [showPin, setShowPin] = useState(false);
  const [busy, setBusy] = useState(false);

  const refresh = () => void sendMessage('guard:status', {}).then(setStatus);

  useEffect(() => {
    refresh();
    const timer = setInterval(refresh, 1000);
    return () => clearInterval(timer);
  }, []);

  const requestUnlock = async () => {
    setBusy(true);
    setError(null);
    try {
      await sendMessage('guard:requestUnlock', { pin });
      setPin('');
      setShowPin(false);
      refresh();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not unlock.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <main className="mx-auto flex min-h-screen max-w-lg flex-col items-center justify-center gap-6 px-6 text-center">
      <span className="flex size-14 items-center justify-center rounded-2xl bg-duck-surface text-duck-accent">
        <LockIcon className="size-6" />
      </span>

      <div>
        <h1 className="text-[22px] font-bold tracking-tight">
          {status?.blockMessage || 'You asked to be stopped here.'}
        </h1>
        <p className="mt-2 text-[13px] leading-relaxed text-duck-muted">
          Duck Content Guard blocked this page. You turned this on yourself.
        </p>
      </div>

      {status?.pendingUnlock ? (
        <PendingUnlock status={status} onCancel={() => void sendMessage('guard:cancelUnlock', {}).then(refresh)} />
      ) : showPin ? (
        <div className="flex w-full max-w-xs flex-col gap-2">
          <input
            type="password"
            inputMode="numeric"
            autoFocus
            value={pin}
            onChange={(event) => setPin(event.target.value)}
            onKeyDown={(event) => event.key === 'Enter' && void requestUnlock()}
            placeholder="PIN"
            className="rounded-xl border border-duck-border bg-duck-surface px-4 py-3 text-center text-[16px] tracking-[0.4em] text-duck-text outline-none focus:border-duck-accent"
          />
          {error && <p className="text-[12px] text-duck-danger">{error}</p>}
          <p className="text-[11px] leading-relaxed text-duck-muted">
            The PIN does not unblock anything now. It starts a{' '}
            {status?.cooldownHours ?? 24}-hour wait, and Guard stays on the whole time.
          </p>
          <button
            type="button"
            onClick={() => void requestUnlock()}
            disabled={busy || pin.length === 0}
            className="rounded-xl bg-duck-surface px-4 py-2.5 text-[13px] font-semibold text-duck-text transition hover:bg-duck-surface-hover disabled:opacity-50"
          >
            {busy ? 'Checking…' : 'Start the waiting period'}
          </button>
        </div>
      ) : (
        <button
          type="button"
          onClick={() => setShowPin(true)}
          className="text-[12px] text-duck-muted underline underline-offset-4 transition hover:text-duck-text"
        >
          I want to turn Guard off
        </button>
      )}
    </main>
  );
}

function PendingUnlock({ status, onCancel }: { status: GuardStatus; onCancel: () => void }) {
  const remaining = status.msUntilUnlock ?? 0;
  const hours = Math.floor(remaining / 3_600_000);
  const minutes = Math.floor((remaining % 3_600_000) / 60_000);
  const seconds = Math.floor((remaining % 60_000) / 1000);

  return (
    <div className="flex w-full max-w-xs flex-col gap-3 rounded-2xl border border-duck-border bg-duck-surface p-4">
      <p className="text-[12px] text-duck-muted">Guard turns off in</p>
      <p className="font-mono text-[28px] font-bold tabular-nums text-duck-accent">
        {String(hours).padStart(2, '0')}:{String(minutes).padStart(2, '0')}:
        {String(seconds).padStart(2, '0')}
      </p>
      <p className="text-[11px] leading-relaxed text-duck-muted">
        Everything stays blocked until then. If this was an impulse, it has probably passed by now.
      </p>
      <button
        type="button"
        onClick={onCancel}
        className="rounded-xl bg-duck-accent px-4 py-2 text-[13px] font-bold text-black transition hover:brightness-105"
      >
        Cancel — keep Guard on
      </button>
    </div>
  );
}
