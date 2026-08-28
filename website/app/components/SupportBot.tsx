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

    // Answer in whichever language the question arrived in. The index holds
    // both, so an Arabic question can still match on a Latin-script product
    // name and come back in Arabic.
    const ar = isArabic(query);
    const matches = search(query);
    const reply: Turn = matches.length
      ? {
          from: "duck",
          text: ar ? matches[0].article.answerAr : matches[0].article.answer,
          related: matches
            .slice(1)
            .map((m) => (ar ? m.article.questionAr : m.article.question))
        }
      : {
          from: "duck",
          // Saying nothing useful is a real answer. Inventing one is not.
          text: ar
            ? "ملقيتش دي في التوثيق. حد من الدعم هيساعدك أسرع من إني أخمّن."
            : "I could not find that in the documentation. A person can help you faster than I can guess.",
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
          <div
            key={i}
            className={`bubble bubble-${turn.from}`}
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
          autoComplete="off"
        />
        <button type="submit" aria-label="Send" disabled={!draft.trim()}>
          <ArrowUpIcon size={17} weight="bold" />
        </button>
      </form>
    </div>
  );
}
