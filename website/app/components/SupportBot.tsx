"use client";

import { useEffect, useRef, useState } from "react";
import {
  ArrowUpIcon,
  ChatCircleDotsIcon,
  WhatsappLogoIcon
} from "@phosphor-icons/react/dist/ssr";
import { isArabic, search } from "../lib/search";
import { siteConfig } from "../site-config";

type Turn = {
  from: "you" | "duck";
  text: string;
  /** Follow-up questions the answer suggests, shown as tappable chips. */
  related?: string[];
  /** True when nothing matched and the only honest next step is a person. */
  handoff?: boolean;
  /** Placeholder shown while the answer is being written. */
  pending?: boolean;
};

/** Two of each, so an Arabic speaker sees their own language offered first. */
const OPENERS = [
  "نسيت رمز الخزنة",
  "Duck مش شايف الفولدرات",
  "How do I cancel Premium?",
  "Can I keep listening with the screen off?"
];

const GREETING: Turn = {
  from: "duck",
  text: "اسألني أي حاجة عن Duck بالعربي أو بالإنجليزي. بجاوب من توثيق التطبيق نفسه، فلو مش عارف حاجة هقولك بدل ما أخمّن.\n\nAsk me anything about Duck, in Arabic or English.",
  related: OPENERS
};

export function SupportBot() {
  const [turns, setTurns] = useState<Turn[]>([GREETING]);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const endRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    // Only after a real exchange, so the page does not jump on first paint.
    if (turns.length > 1) {
      endRef.current?.scrollIntoView({ behavior: "smooth", block: "nearest" });
    }
  }, [turns]);

  async function ask(question: string) {
    const query = question.trim();
    if (!query || busy) return;

    const ar = isArabic(query);
    setBusy(true);
    setDraft("");
    setTurns((prev) => [
      ...prev,
      { from: "you", text: query },
      { from: "duck", text: ar ? "بكتب..." : "Typing...", pending: true }
    ]);

    // The suggestion chips still come from the local index. They are a menu of
    // questions the documentation definitely answers, so they should not
    // depend on a network call to appear.
    const related = search(query)
      .slice(1)
      .map((m) => (ar ? m.article.questionAr : m.article.question));

    let reply: Turn;
    try {
      const res = await fetch("/api/support", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          question: query,
          history: turns
            .filter((t) => !t.pending)
            .slice(-6)
            .map((t) => ({
              role: t.from === "you" ? "user" : "assistant",
              content: t.text
            }))
        })
      });
      const data = await res.json();
      reply = {
        from: "duck",
        text: data.answer ?? "",
        related: data.grounded ? related : undefined,
        handoff: !data.grounded
      };
    } catch {
      // Offline, or the route is down. Say so rather than showing an empty
      // bubble, and put the human route in front of them.
      reply = {
        from: "duck",
        text: ar
          ? "مش قادر أوصل للسيرفر دلوقتي. جرّب تاني أو كلّم الدعم."
          : "I could not reach the server. Try again, or message support.",
        handoff: true
      };
    }

    setTurns((prev) => [...prev.slice(0, -1), reply]);
    setBusy(false);
    inputRef.current?.focus();
  }

  return (
    <div className="bot">
      <div className="bot-head">
        <span className="bot-avatar">
          <ChatCircleDotsIcon size={17} weight="fill" />
        </span>
        <div>
          <p className="bot-name">Duck Support</p>
          <p className="bot-sub">Answers from the app documentation</p>
        </div>
      </div>

      <div className="bot-log">
        {turns.map((turn, i) => (
          <div
            key={i}
            className={`bubble bubble-${turn.from}${turn.pending ? " bubble-pending" : ""}`}
            dir={isArabic(turn.text) ? "rtl" : "ltr"}
          >
            <p className="bubble-text">{turn.text}</p>

            {turn.handoff ? (
              <a
                className="btn btn-primary btn-sm bot-handoff"
                href={siteConfig.whatsapp.href}
                target="_blank"
                rel="noopener noreferrer"
              >
                <WhatsappLogoIcon size={15} weight="fill" />
                Message support
              </a>
            ) : null}

            {turn.related?.length ? (
              <div className="bot-chips">
                {turn.related.map((q) => (
                  <button
                    key={q}
                    type="button"
                    className="chip"
                    dir={isArabic(q) ? "rtl" : "ltr"}
                    onClick={() => ask(q)}
                  >
                    {q}
                  </button>
                ))}
              </div>
            ) : null}
          </div>
        ))}
        <div ref={endRef} />
      </div>

      <form
        className="bot-form"
        onSubmit={(e) => {
          e.preventDefault();
          ask(draft);
        }}
      >
        <label className="visually-hidden" htmlFor="bot-input">
          Ask a question
        </label>
        <input
          id="bot-input"
          ref={inputRef}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          placeholder="Ask a question"
          disabled={busy}
          autoComplete="off"
        />
        <button type="submit" aria-label="Send" disabled={!draft.trim() || busy}>
          <ArrowUpIcon size={17} weight="bold" />
        </button>
      </form>
    </div>
  );
}
