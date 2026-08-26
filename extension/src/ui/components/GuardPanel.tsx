import { useEffect, useState } from 'react';
import type { GuardStatus } from '@/core/guard-types';
import { sendMessage } from '@/core/messaging';
import { LockIcon } from './Icons';

/**
 * The Guard section.
 *
 * Two things this UI is careful about:
 *  - It never pretends to be more than it is. The limits notice is permanent,
 *    not a dismissible tip, because someone relying on this deserves to know
 *    where the wall actually ends.
 *  - Turning protection *up* is one click. Turning it *down* always costs the
 *    PIN, and switching Guard off costs the PIN plus the wait.
 */
export function GuardPanel() {
  const [status, setStatus] = useState<GuardStatus | null>(null);

  const refresh = () => void sendMessage('guard:status', {}).then(setStatus);

  useEffect(() => {
    refresh();
    const timer = setInterval(refresh, 1000);
    return () => clearInterval(timer);
  }, []);

  if (!status) return <p className="text-[12px] text-duck-muted">Loading…</p>;

  return (
    <div className="flex flex-col gap-4">
      <header className="flex items-start gap-2.5">
        <span
          className={`mt-0.5 flex size-8 flex-none items-center justify-center rounded-lg ${
            status.enabled ? 'bg-duck-accent text-black' : 'bg-duck-surface text-duck-muted'
          }`}
        >
          <LockIcon className="size-4" />
        </span>
        <div>
          <h2 className="text-[13px] font-bold">Content Guard</h2>
          <p className="text-[11px] leading-relaxed text-duck-muted">
            {status.enabled
              ? 'Adult sites are blocked in this browser.'
              : 'Block adult sites, and make it hard to undo.'}
          </p>
        </div>
      </header>

      {status.enabled ? (
        <ActiveGuard status={status} onChange={refresh} />
      ) : (
        <SetupGuard configured={status.configured} onChange={refresh} />
      )}

      <Limits />
    </div>
  );
}

function SetupGuard({ configured, onChange }: { configured: boolean; onChange: () => void }) {
  const [pin, setPin] = useState('');
  const [confirmPin, setConfirmPin] = useState('');
  const [hours, setHours] = useState(24);
  const [message, setMessage] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    if (pin.length < 4) return setError('Use at least 4 digits.');
    if (pin !== confirmPin) return setError('The two PINs do not match.');

    setBusy(true);
    setError(null);
    try {
      await sendMessage('guard:enable', {
        pin,
        cooldownHours: hours,
        blockMessage: message || undefined,
      });
      setPin('');
      setConfirmPin('');
      onChange();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not turn Guard on.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex flex-col gap-2.5">
      {configured && (
        <p className="rounded-lg border border-duck-border bg-duck-surface p-2 text-[11px] text-duck-muted">
          Guard is off. Turning it back on sets a new PIN.
        </p>
      )}

      <Field label="PIN">
        <input
          type="password"
          inputMode="numeric"
          value={pin}
          onChange={(event) => setPin(event.target.value.replace(/\D/g, ''))}
          placeholder="At least 4 digits"
          className={inputClass}
        />
      </Field>

      <Field label="Confirm PIN">
        <input
          type="password"
          inputMode="numeric"
          value={confirmPin}
          onChange={(event) => setConfirmPin(event.target.value.replace(/\D/g, ''))}
          className={inputClass}
        />
      </Field>

      <Field label="Wait before Guard can be turned off">
        <select
          value={hours}
          onChange={(event) => setHours(Number(event.target.value))}
          className={inputClass}
        >
          <option value={1}>1 hour</option>
          <option value={12}>12 hours</option>
          <option value={24}>24 hours</option>
          <option value={72}>3 days</option>
          <option value={168}>7 days</option>
        </select>
      </Field>

      <Field label="Message on the block page">
        <input
          value={message}
          onChange={(event) => setMessage(event.target.value)}
          placeholder="Write something for yourself"
          className={inputClass}
        />
      </Field>

      <p className="text-[10px] leading-relaxed text-duck-muted">
        The wait is the part that works. A PIN you know is no obstacle to you — a
        day between wanting this off and it being off, is.
      </p>

      {error && <p className="text-[11px] text-duck-danger">{error}</p>}

      <button
        type="button"
        onClick={() => void submit()}
        disabled={busy}
        className="rounded-xl bg-duck-accent px-4 py-2.5 text-[13px] font-bold text-black transition hover:brightness-105 disabled:opacity-60"
      >
        {busy ? 'Turning on…' : 'Turn Content Guard on'}
      </button>
    </div>
  );
}

function ActiveGuard({ status, onChange }: { status: GuardStatus; onChange: () => void }) {
  const [pin, setPin] = useState('');
  const [domain, setDomain] = useState('');
  const [error, setError] = useState<string | null>(null);

  const act = async (run: () => Promise<unknown>) => {
    setError(null);
    try {
      await run();
      setPin('');
      onChange();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'That did not work.');
    }
  };

  const remaining = status.msUntilUnlock ?? 0;
  const ready = status.pendingUnlock && remaining <= 0;

  return (
    <div className="flex flex-col gap-3">
      <Toggle
        label="Force SafeSearch on search engines"
        checked={status.safeSearch}
        onChange={(safeSearch) =>
          void act(() =>
            sendMessage('guard:update', { patch: { safeSearch }, pin: safeSearch ? undefined : pin }),
          )
        }
      />
      <Toggle
        label="Hide sensitive posts in X, Reddit and Instagram"
        checked={status.feedFilter}
        onChange={(feedFilter) =>
          void act(() =>
            sendMessage('guard:update', { patch: { feedFilter }, pin: feedFilter ? undefined : pin }),
          )
        }
      />

      <div className="flex flex-col gap-1.5">
        <p className="text-[11px] font-semibold uppercase tracking-wide text-duck-muted">
          Also block these sites
        </p>
        <div className="flex gap-1.5">
          <input
            value={domain}
            onChange={(event) => setDomain(event.target.value)}
            placeholder="example.com"
            className={`${inputClass} flex-1`}
          />
          <button
            type="button"
            onClick={() =>
              void act(async () => {
                const clean = domain.trim().replace(/^https?:\/\//, '').replace(/\/.*$/, '');
                if (!clean) return;
                await sendMessage('guard:update', {
                  patch: { customDomains: [...status.customDomains, clean] },
                });
                setDomain('');
              })
            }
            className="rounded-lg bg-duck-surface px-3 text-[12px] font-semibold transition hover:bg-duck-surface-hover"
          >
            Add
          </button>
        </div>
        {status.customDomains.length > 0 && (
          <ul className="flex flex-wrap gap-1">
            {status.customDomains.map((entry) => (
              <li
                key={entry}
                className="rounded-md bg-duck-surface px-2 py-1 text-[11px] text-duck-muted"
              >
                {entry}
              </li>
            ))}
          </ul>
        )}
        <p className="text-[10px] text-duck-muted">
          Removing one needs the PIN, so add carefully.
        </p>
      </div>

      <div className="rounded-xl border border-duck-border bg-duck-surface p-3">
        {status.pendingUnlock ? (
          <div className="flex flex-col gap-2">
            <p className="text-[11px] text-duck-muted">
              {ready ? 'The waiting period is over.' : 'Guard turns off in'}
            </p>
            {!ready && (
              <p className="font-mono text-[20px] font-bold tabular-nums text-duck-accent">
                {formatRemaining(remaining)}
              </p>
            )}
            <div className="flex gap-1.5">
              <button
                type="button"
                onClick={() => void act(() => sendMessage('guard:cancelUnlock', {}))}
                className="flex-1 rounded-lg bg-duck-accent px-3 py-2 text-[12px] font-bold text-black"
              >
                Keep Guard on
              </button>
              {ready && (
                <button
                  type="button"
                  onClick={() => void act(() => sendMessage('guard:completeUnlock', {}))}
                  className="rounded-lg px-3 py-2 text-[12px] font-semibold text-duck-muted transition hover:text-duck-danger"
                >
                  Turn off
                </button>
              )}
            </div>
          </div>
        ) : (
          <div className="flex flex-col gap-2">
            <input
              type="password"
              inputMode="numeric"
              value={pin}
              onChange={(event) => setPin(event.target.value.replace(/\D/g, ''))}
              placeholder="PIN"
              className={inputClass}
            />
            <button
              type="button"
              onClick={() => void act(() => sendMessage('guard:requestUnlock', { pin }))}
              disabled={pin.length === 0}
              className="rounded-lg px-3 py-2 text-[12px] font-semibold text-duck-muted transition hover:text-duck-text disabled:opacity-40"
            >
              Start the {status.cooldownHours}-hour wait to turn Guard off
            </button>
          </div>
        )}
      </div>

      {error && <p className="text-[11px] text-duck-danger">{error}</p>}
    </div>
  );
}

/**
 * Deliberately not dismissible. Someone leaning on this needs to know exactly
 * where it stops, and the honest answer is "at the browser's own settings page".
 */
function Limits() {
  return (
    <div className="rounded-xl border border-duck-border bg-duck-surface p-3">
      <p className="text-[11px] font-semibold">What this cannot do</p>
      <ul className="mt-1.5 flex list-disc flex-col gap-1 pl-4 text-[10px] leading-relaxed text-duck-muted">
        <li>Any extension can be removed from the browser's extensions page.</li>
        <li>It does not cover other browsers, other profiles, or other devices.</li>
        <li>
          To close those gaps: set DNS to Cloudflare <strong>1.1.1.3</strong> and install the
          policy described in POLICY.md, which makes this extension unremovable.
        </li>
      </ul>
    </div>
  );
}

const inputClass =
  'rounded-lg border border-duck-border bg-duck-bg px-3 py-2 text-[12px] text-duck-text outline-none focus:border-duck-accent';

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="flex flex-col gap-1">
      <span className="text-[11px] text-duck-muted">{label}</span>
      {children}
    </label>
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

function formatRemaining(ms: number): string {
  const hours = Math.floor(ms / 3_600_000);
  const minutes = Math.floor((ms % 3_600_000) / 60_000);
  const seconds = Math.floor((ms % 60_000) / 1000);
  const pad = (value: number) => String(value).padStart(2, '0');
  return `${pad(hours)}:${pad(minutes)}:${pad(seconds)}`;
}
