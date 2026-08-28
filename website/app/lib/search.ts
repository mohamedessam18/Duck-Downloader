import { articles, type Article } from "./knowledge";

/** A stemmer would be overkill; these are the endings that actually collide. */
function normalise(word: string): string {
  const w = word.toLowerCase().replace(/[^a-z0-9]/g, "");
  if (w.length > 4 && w.endsWith("ing")) return w.slice(0, -3);
  if (w.length > 4 && w.endsWith("ed")) return w.slice(0, -2);
  if (w.length > 3 && w.endsWith("s") && !w.endsWith("ss")) return w.slice(0, -1);
  return w;
}

/**
 * Words that appear in almost every question and so separate nothing.
 *
 * Without this, "how do I cancel" scores every article that contains "how",
 * and the ranking is decided by noise rather than by the one word that carried
 * the question.
 */
const STOP = new Set([
  "the", "a", "an", "is", "are", "do", "does", "did", "can", "could", "how",
  "what", "when", "where", "why", "i", "my", "me", "you", "your", "it", "to",
  "of", "in", "on", "for", "and", "or", "but", "with", "this", "that", "get",
  "have", "has", "will", "would", "should", "there", "any", "if", "not", "no",
]);

function tokenise(text: string): string[] {
  return text
    .split(/\s+/)
    .map(normalise)
    .filter((w) => w.length > 1 && !STOP.has(w));
}

export type Match = { article: Article; score: number };

/**
 * Ranks articles against a question.
 *
 * Keywords are weighted above the question text because they are the words a
 * person reaches for when they do not know the app's own vocabulary: someone
 * whose vault will not open types "locked out", never "passcode".
 *
 * Returns nothing rather than a poor guess when the score is too low. An
 * assistant that answers everything is an assistant you cannot trust on
 * anything, and "I don't know, here is a human" is a real answer.
 */
export function search(query: string, limit = 3): Match[] {
  const terms = tokenise(query);
  if (terms.length === 0) return [];

  const scored = articles.map((article) => {
    const questionWords = new Set(tokenise(article.question));
    const keywordText = new Set(article.keywords.flatMap(tokenise));
    const answerWords = new Set(tokenise(article.answer));

    let score = 0;
    for (const term of terms) {
      if (keywordText.has(term)) score += 5;
      if (questionWords.has(term)) score += 3;
      if (answerWords.has(term)) score += 1;

      // A term the user typed that only appears inside a longer keyword still
      // counts: "uninstalling" should reach the "uninstall" article.
      if (score === 0) {
        for (const kw of keywordText) {
          if (kw.length > 3 && (kw.includes(term) || term.includes(kw))) {
            score += 2;
            break;
          }
        }
      }
    }

    // Divided by term count so a long rambling question cannot out-score a
    // short precise one purely by having more words to match.
    return { article, score: score / Math.sqrt(terms.length) };
  });

  return scored
    .filter((m) => m.score >= 3)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);
}
