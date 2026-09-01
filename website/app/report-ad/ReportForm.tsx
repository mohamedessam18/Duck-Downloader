"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import {
  CheckCircleIcon,
  CoinsIcon,
  DownloadSimpleIcon,
  EyeSlashIcon,
  ImageSquareIcon,
  QuestionIcon,
  ShieldWarningIcon,
  SmileyXEyesIcon,
  WarningCircleIcon,
  XIcon
} from "@phosphor-icons/react";

const API = "https://api.duckdownloader.site/api/ad-report";

/** Matches MAX_SCREENSHOT_BYTES on the server, so the refusal happens here. */
const MAX_BYTES = 5 * 1024 * 1024;

/**
 * Why someone is reporting. A fixed list, not free text, because the whole
 * value of these reports is being countable: one complaint is hard to act on,
 * the same reason arriving thirty times names an advertiser to block.
 */
const REASONS = [
  { id: "sexual", label: "Sexual or adult content", Icon: EyeSlashIcon },
  { id: "scam", label: "A scam, or after money or card details", Icon: CoinsIcon },
  { id: "gambling", label: "Gambling or betting", Icon: CoinsIcon },
  { id: "shocking", label: "Shocking or disturbing", Icon: SmileyXEyesIcon },
  { id: "malware", label: "Tried to install something", Icon: DownloadSimpleIcon },
  { id: "age-inappropriate", label: "Wrong for this app's age rating", Icon: ShieldWarningIcon },
  { id: "other", label: "Something else", Icon: QuestionIcon }
] as const;

const CONTEXT_KEYS = [
  { key: "adFormat", label: "Ad type" },
  { key: "appVersion", label: "App version" },
  { key: "platform", label: "Device" },
  { key: "locale", label: "Language" },
  { key: "seenAt", label: "Seen at" }
] as const;

type Context = Partial<Record<(typeof CONTEXT_KEYS)[number]["key"], string>>;

function readableSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function ReportForm() {
  const [reason, setReason] = useState("");
  const [details, setDetails] = useState("");
  const [context, setContext] = useState<Context>({});
  const [includeContext, setIncludeContext] = useState(true);
  const [shot, setShot] = useState<File | null>(null);
  const [shotUrl, setShotUrl] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);
  const [state, setState] = useState<"idle" | "sending" | "sent" | "failed">("idle");
  const [error, setError] = useState<string | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  // The app opens this page with the technical details in the query string.
  // Reading them here rather than asking someone to type their Android version
  // is the difference between a report that can be acted on and one that
  // cannot.
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const found: Context = {};
    for (const { key } of CONTEXT_KEYS) {
      const value = params.get(key);
      if (value) found[key] = value.slice(0, 200);
    }
    setContext(found);
  }, []);

  // Object URLs are held by the browser until they are revoked; without this
  // every re-picked screenshot leaks one for the life of the page.
  useEffect(() => {
    if (!shot) {
      setShotUrl(null);
      return;
    }
    const url = URL.createObjectURL(shot);
    setShotUrl(url);
    return () => URL.revokeObjectURL(url);
  }, [shot]);

  const hasContext = useMemo(() => Object.keys(context).length > 0, [context]);

  function accept(file: File | undefined) {
    if (!file) return;
    if (!file.type.startsWith("image/")) {
      setError("That is not an image. A screenshot from your phone works.");
      return;
    }
    if (file.size > MAX_BYTES) {
      setError(`That image is ${readableSize(file.size)}. The limit is 5 MB.`);
      return;
    }
    setError(null);
    setShot(file);
  }

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!reason || state === "sending") return;

    setState("sending");
    setError(null);
    try {
      const body = new FormData();
      body.append("reason", reason);
      if (details.trim()) body.append("details", details.trim());
      if (includeContext) {
        for (const [key, value] of Object.entries(context)) {
          if (value) body.append(key, value);
        }
      }
      if (shot) body.append("screenshot", shot);

      const response = await fetch(API, { method: "POST", body });
      if (!response.ok) {
        throw new Error(
          response.status === 429
            ? "Too many reports from this connection. Wait a minute and try again."
            : response.status === 413
              ? "That image was rejected as too large."
              : "The server did not accept the report."
        );
      }
      setState("sent");
    } catch (caught) {
      setState("failed");
      setError(
        caught instanceof Error && caught.message
          ? caught.message
          : "Could not reach the server. Check your connection and try again."
      );
    }
  }

  if (state === "sent") {
    return (
      <div className="report-done">
        <CheckCircleIcon size={44} weight="fill" />
        <h2>Report received</h2>
        <p>
          Thank you. One complaint is hard to act on; the same one arriving
          repeatedly names an advertiser, and that one can be blocked.
        </p>
        <p className="report-note">
          This came to the developer, not to Google. If the ad broke
          Google&apos;s own rules, the <strong>ⓘ</strong> mark on the ad
          reports it to them as well — a separate channel, and worth using too.
        </p>
      </div>
    );
  }

  return (
    <form className="report-form" onSubmit={submit}>
      <fieldset className="report-reasons">
        <legend>
          <span className="report-step-label">
            <i>1</i> What was wrong with it?
          </span>
        </legend>
        <div className="report-grid">
          {REASONS.map(({ id, label, Icon }) => (
            <label key={id} className="report-card">
              <input
                type="radio"
                name="reason"
                value={id}
                checked={reason === id}
                onChange={() => setReason(id)}
              />
              <Icon size={20} weight="duotone" />
              <span>{label}</span>
            </label>
          ))}
        </div>
      </fieldset>

      <div className="report-field">
        <label className="report-step-label" htmlFor="report-details">
          <i>2</i> Anything else? <em>optional</em>
        </label>
        <textarea
          id="report-details"
          maxLength={2000}
          value={details}
          onChange={(event) => setDetails(event.target.value)}
          placeholder="What it showed, what it asked for, or where it tried to send you."
        />
      </div>

      <div>
        <span className="report-step-label">
          <i>3</i> A screenshot <em>optional</em>
        </span>

        {shot && shotUrl ? (
          <div className="report-preview">
            <img src={shotUrl} alt="" />
            <div className="meta">
              <div className="name">{shot.name}</div>
              <div className="size">{readableSize(shot.size)}</div>
            </div>
            <button
              type="button"
              className="report-strip"
              onClick={() => {
                setShot(null);
                if (fileInput.current) fileInput.current.value = "";
              }}
            >
              <XIcon size={13} weight="bold" />
              Remove
            </button>
          </div>
        ) : (
          <label
            className={`report-drop${dragging ? " is-over" : ""}`}
            onDragOver={(event) => {
              event.preventDefault();
              setDragging(true);
            }}
            onDragLeave={() => setDragging(false)}
            onDrop={(event) => {
              event.preventDefault();
              setDragging(false);
              accept(event.dataTransfer.files?.[0]);
            }}
          >
            <input
              ref={fileInput}
              type="file"
              accept="image/*"
              onChange={(event) => accept(event.target.files?.[0])}
            />
            <ImageSquareIcon size={26} weight="duotone" />
            <strong>Add a screenshot of the ad</strong>
            <small>PNG, JPG or WebP — up to 5 MB</small>
          </label>
        )}

        <p className="report-warn">
          <ShieldWarningIcon size={16} weight="fill" />
          <span>
            The image is sent exactly as it is. If your screenshot caught
            anything of yours — your files, a message, a name — crop it down to
            the ad first.
          </span>
        </p>
      </div>

      {hasContext ? (
        <div className="report-context">
          <div className="report-context-head">
            <span>Sent with your report</span>
            <button
              type="button"
              className="report-strip"
              onClick={() => setIncludeContext((on) => !on)}
            >
              {includeContext ? <XIcon size={13} weight="bold" /> : null}
              {includeContext ? "Don't send this" : "Include this"}
            </button>
          </div>
          <dl className={includeContext ? "" : "is-off"}>
            {CONTEXT_KEYS.filter(({ key }) => context[key]).map(({ key, label }) => (
              <div key={key}>
                <dt>{label}</dt>
                <dd>{context[key]}</dd>
              </div>
            ))}
          </dl>
          <p className="report-privacy">
            Nothing here identifies you. No account, no device id, no location —
            only what the app is and which ad it showed.
          </p>
        </div>
      ) : null}

      {error ? (
        <p className="report-error">
          <WarningCircleIcon size={17} weight="fill" />
          {error}
        </p>
      ) : null}

      <button className="btn btn-primary" type="submit" disabled={!reason || state === "sending"}>
        {state === "sending" ? "Sending…" : "Send report"}
      </button>
      {!reason ? <p className="report-hint">Pick a reason to send the report.</p> : null}
    </form>
  );
}
