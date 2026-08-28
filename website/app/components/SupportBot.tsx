"use client";

import { useEffect, useRef, useState } from "react";
import {
  ArrowUpIcon,
  ChatCircleDotsIcon,
  WhatsappLogoIcon
} from "@phosphor-icons/react/dist/ssr";
import { search } from "../lib/search";
import { siteConfig } from "../site-config";

type Turn = {
  from: "you" | "duck";
  text: string;
  /** Follow-up questions the answer suggests, shown as tappable chips. */
  related?: string[];
  /** True when nothing matched and the only honest next step is a person. */
  handoff?: boolean;
};

const OPENERS = [
  "How do I download a video?",
  "I forgot my vault passcode",
  "How do I cancel Premium?",
  "Duck cannot see my folders"
];

const GREETING: Turn = {
  from: "duck",
  text: "Ask me anything about Duck. I answer from the app's own documentation, so if I do not know something I will say so rather than guess.",
  related: OPENERS
};

export function SupportBot() {
  const [turns, setTurns] = useState<Turn[]>([GREETING]);
  const [draft, setDraft] = useState("");
  const endRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    // Only after a real exchange, so the page does not jump on first paint.
    if (turns.length > 1) {
      endRef.current?.scrollIntoView({ behavior: "smooth", block: "nearest" });
    }
  }, [turns]);

  function ask(question: string) {
    const query = question.trim();
    if (!query) return;

    const matches = search(query);
    const reply: Turn = matches.length
      ? {
          from: "duck",
          text: matches[0].article.answer,
          related: matches.slice(1).map((m) => m.article.question)
        }
      : {
          from: "duck",
          // Saying nothing useful is a real answer. Inventing one is not.
          text: "I could not find that in the documentation. A person can help you faster than I can guess.",
          handoff: true
        };

    setTurns((prev) => [...prev, { from: "you", text: query }, reply]);
    setDraft("");
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
          <div key={i} className={`bubble bubble-${turn.from}`}>
            <p>{turn.text}</p>

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
          autoComplete="off"
        />
        <button type="submit" aria-label="Send" disabled={!draft.trim()}>
          <ArrowUpIcon size={17} weight="bold" />
        </button>
      </form>
    </div>
  );
}
