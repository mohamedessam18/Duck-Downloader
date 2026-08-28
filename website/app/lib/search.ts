import { articles, type Article } from "./knowledge";

/** True when the text contains Arabic letters. */
export function isArabic(text: string): boolean {
  return /[؀-ۿ]/.test(text);
}

/**
 * Reduces a word to something two spellings of it can share.
 *
 * The English side strips a few endings. The Arabic side does something more
 * important: it removes the diacritics and the tatweel that change how a word
 * is typed without changing what it means, and normalises the alef and yaa
 * forms people use interchangeably. Someone typing "الخزنه" and someone typing
 * "الخزنة" are asking the same question, and only one of those is in the
 * knowledge base.
 */
function normalise(word: string): string {
  let w = word.toLowerCase();

  if (/[؀-ۿ]/.test(w)) {
    w = w
      .replace(/[ً-ْـ]/g, "")   // harakat and tatweel
      .replace(/[آأإٱ]/g, "ا") // alef forms
      .replace(/ى/g, "ي")            // alef maqsura to yaa
      .replace(/ة/g, "ه")            // taa marbuta to haa
      .replace(/[^؀-ۿ0-9]/g, "");
    // The definite article carries no meaning for matching.
    if (w.length > 4 && w.startsWith("ال")) w = w.slice(2);
    return w;
  }

  w = w.replace(/[^a-z0-9]/g, "");
  if (w.length > 4 && w.endsWith("ing")) return w.slice(0, -3);
  if (w.length > 4 && w.endsWith("ed")) return w.slice(0, -2);
  if (w.length > 3 && w.endsWith("s") && !w.endsWith("ss")) return w.slice(0, -1);
  return w;
}

/**
 * Words that appear in almost every question and so separate nothing.
 *
 * Both languages, because a bilingual index needs both: without the Arabic
 * half, "ازاي اعمل كذا" scores every article containing "ازاي".
 */
const STOP = new Set([
  "the", "a", "an", "is", "are", "do", "does", "did", "can", "could", "how",
  "what", "when", "where", "why", "i", "my", "me", "you", "your", "it", "to",
  "of", "in", "on", "for", "and", "or", "but", "with", "this", "that", "get",
  "have", "has", "will", "would", "should", "there", "any", "if", "not", "no",
  // Arabic, already normalised the way normalise() would leave them
  "ازاي", "ايه", "هل", "في", "من", "علي", "عن", "مع", "ده", "دي", "انا",
  "هو", "هي", "كان", "بس", "لو", "مش", "ما", "لا", "و", "يا", "عشان",
  "ليه", "امتي", "فين", "كده", "اللي", "بتاع", "بتاعت", "عايز", "عاوز",
]);

function tokenise(text: string): string[] {
  return text
    .split(/\s+/)
    .map(normalise)
    .filter((w) => w.length > 1 && !STOP.has(w));
}

export type Match = { article: Article; score: number };

/**
 * Ranks articles against a question, in either language.
 *
 * Keywords are weighted above the question text because they are the words a
 * person reaches for when they do not know the app's own vocabulary: someone
 * whose vault will not open types "locked out" or "مش بتفتح", never
 * "passcode".
 *
 * Returns nothing rather than a poor guess when the score is too low. An
 * assistant that answers everything is an assistant you cannot trust on
 * anything, and "I don't know, here is a human" is a real answer.
 */
export function search(query: string, limit = 3): Match[] {
  const terms = tokenise(query);
  if (terms.length === 0) return [];

  const scored = articles.map((article) => {
    // Both languages are indexed together, so an Arabic question can still
    // match an article whose distinguishing word is a product name in Latin
    // script, like "PiP" or "Premium".
    const questionWords = new Set([
      ...tokenise(article.question),
      ...tokenise(article.questionAr),
    ]);
    const keywordText = new Set(article.keywords.flatMap(tokenise));
    const answerWords = new Set([
      ...tokenise(article.answer),
      ...tokenise(article.answerAr),
    ]);

    let score = 0;
    for (const term of terms) {
      if (keywordText.has(term)) score += 5;
      if (questionWords.has(term)) score += 3;
      if (answerWords.has(term)) score += 1;

      if (score === 0) {
        for (const kw of keywordText) {
          if (kw.length > 3 && (kw.includes(term) || term.includes(kw))) {
            score += 2;
            break;
          }
        }
      }
    }

    return { article, score: score / Math.sqrt(terms.length) };
  });

  return scored
    .filter((m) => m.score >= 3)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);
}
