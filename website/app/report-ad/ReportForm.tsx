"use client";

import { useEffect, useMemo, useState } from "react";
import {
  CheckCircleIcon,
  WarningCircleIcon,
  XIcon
} from "@phosphor-icons/react";

/**
 * The API the app already talks to. Reports go straight there rather than
 * through this site's own server, because the browser is allowed to and a
 * proxy would be one more thing that can be down.
 */
const API = "https://api.duckdownloader.site/api/ad-report";

/**
 * Why someone is reporting. Fixed, not free text, so the same complaint
 * arriving thirty times can be counted — which is the only way a report turns
 * into an advertiser you can go and block.
 */
const REASONS = [
  { id: "sexual", label: "Sexual or adult content" },
  { id: "scam", label: "A scam, or asking for money or card details" },
  { id: "gambling", label: "Gambling or betting" },
  { id: "shocking", label: "Shocking, violent or disturbing" },
  { id: "malware", label: "Tried to install something" },
  { id: "age-inappropriate", label: "Not suitable for the app's age rating" },
  { id: "other", label: "Something else" }
] as const;

/** What the app can attach that the person could not type accurately. */
const CONTEXT_KEYS = [
  { key: "adFormat", label: "Ad type" },
  { key: "appVersion", label: "App version" },
  { key: "platform", label: "Device" },
  { key: "locale", label: "Language" },
  { key: "seenAt", label: "Seen at" }
] as const;

type Context = Partial<Record<(typeof CONTEXT_KEYS)[number]["key"], string>>;

export function ReportForm() {
  const [reason, setReason] = useState<string>("");
  const [details, setDetails] = useState("");
  const [context, setContext] = useState<Context>({});
  const [includeContext, setIncludeContext] = useState(true);
  const [state, setState] = useState<"idle" | "sending" | "sent" | "failed">(
    "idle"
  );
  const [error, setError] = useState<string | null>(null);

  // The app opens this page with the technical details in the query string.
  // Reading them here rather than asking the person to type their Android
  // version is the difference between a report you can act on and one you
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

  const hasContext = useMemo(
    () => Object.keys(context).length > 0,
    [context]
  );

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!reason || state === "sending") return;

    setState("sending");
    setError(null);
    try {
      const response = await fetch(API, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          reason,
          details: details.trim() || null,
          ...(includeContext ? context : {})
        })
      });
      if (!response.ok) {
        // 429 is the rate limiter, and telling someone "try again" when the
        // real answer is "wait a minute" sends them round the same loop.
        throw new Error(
          response.status === 429
            ? "Too many reports from this connection. Wait a minute and try again."
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
        <CheckCircleIcon size={40} weight="fill" />
        <h2>Report received</h2>
        <p>
          Thank you. Reports like this are what make it possible to find a bad
          advertiser and block them — one complaint is hard to act on, the same
          one arriving repeatedly is not.
        </p>
        <p className="report-note">
          This goes to the developer, not to Google. If an ad broke Google&apos;s
          own rules, the <strong>ⓘ</strong> mark on the ad itself reports it to
          them as well, and that is worth doing too.
        </p>
      </div>
    );
  }

  return (
    <form className="report-form" onSubmit={submit}>
      <fieldset className="report-reasons">
        <legend>What was wrong with it?</legend>
        {REASONS.map((option) => (
          <label
            key={option.id}
            className={`report-reason${reason === option.id ? " is-picked" : ""}`}
          >
            <input
              type="radio"
              name="reason"
              value={option.id}
              checked={reason === option.id}
              onChange={() => setReason(option.id)}
            />
            <span>{option.label}</span>
          </label>
        ))}
      </fieldset>

      <label className="report-field">
        <span>Anything else? <em>Optional</em></span>
        <textarea
          rows={4}
          maxLength={2000}
          value={details}
          onChange={(event) => setDetails(event.target.value)}
          placeholder="What the ad showed, what it asked for, or what it looked like."
        />
      </label>

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
            {CONTEXT_KEYS.filter(({ key }) => context[key]).map(
              ({ key, label }) => (
                <div key={key}>
                  <dt>{label}</dt>
                  <dd>{context[key]}</dd>
                </div>
              )
            )}
          </dl>
          <p className="report-privacy">
            Nothing here identifies you. No account, no device id, no location —
            just what the app is and which ad it showed.
          </p>
        </div>
      ) : null}

      {error ? (
        <p className="report-error">
          <WarningCircleIcon size={17} weight="fill" />
          {error}
        </p>
      ) : null}

      <button
        className="btn btn-primary"
        type="submit"
        disabled={!reason || state === "sending"}
      >
        {state === "sending" ? "Sending…" : "Send report"}
      </button>
      {!reason ? (
        <p className="report-hint">Pick a reason to send the report.</p>
      ) : null}
    </form>
  );
}
