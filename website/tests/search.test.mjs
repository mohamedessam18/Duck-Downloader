/**
 * The assistant is only as good as this ranking, and the failure that matters
 * is not "wrong answer" but "confident wrong answer". These cases are phrased
 * the way a stuck person actually types: not the app's vocabulary, and rarely
 * a full sentence.
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { search } from '../.build-test/search.js';

const top = (q) => search(q)[0]?.article.id;

test('finds the vault recovery answer from panic wording', () => {
  assert.equal(top('i forgot my pin'), 'vault-forgot');
  assert.equal(top('locked out of my vault'), 'vault-forgot');
  assert.equal(top('lost passcode'), 'vault-forgot');
});

test('separates cancelling from restoring', () => {
  assert.equal(top('how do i cancel my subscription'), 'premium-cancel');
  assert.equal(top('i paid but premium is missing'), 'premium-restore');
});

test('reaches the permission answer without the word permission', () => {
  assert.equal(top('folders are empty'), 'permission-denied');
  assert.equal(top('duck cannot see my videos'), 'permission-denied');
});

test('matches background playback from everyday phrasing', () => {
  assert.equal(top('listen with screen off'), 'background-audio');
  assert.equal(top('keep playing when i minimize'), 'background-audio');
});

test('handles a plural the user typed and the article did not', () => {
  assert.equal(top('what platforms are supported'), 'supported-links');
});

test('returns nothing rather than guessing', () => {
  // Nothing in the knowledge base is about either of these.
  assert.equal(search('what is the weather today').length, 0);
  assert.equal(search('recipe for koshary').length, 0);
});

test('an empty or noise query returns nothing', () => {
  assert.equal(search('').length, 0);
  assert.equal(search('   ').length, 0);
  // All stop words: nothing distinguishing was actually asked.
  assert.equal(search('how do i').length, 0);
});

test('ranks at most three and orders by score', () => {
  const hits = search('vault');
  assert.ok(hits.length <= 3);
  for (let i = 1; i < hits.length; i++) {
    assert.ok(hits[i - 1].score >= hits[i].score);
  }
});

/**
 * Arabic. The tokeniser used to strip every non-Latin character, so an Arabic
 * question arrived at the ranker as an empty string and matched nothing. These
 * are phrased the way the app's actual users type: Egyptian, unpunctuated, and
 * rarely spelled the way the knowledge base spells it.
 */
test('finds the vault answer in Arabic', () => {
  assert.equal(top('نسيت رمز الخزنة'), 'vault-forgot');
  assert.equal(top('الخزنه مش بتفتح'), 'vault-forgot');
});

test('tolerates alef and taa-marbuta spelling', () => {
  // "الخزنه" and "الخزنة" are the same word typed two ways.
  assert.equal(top('ازاي افتح الخزنه'), top('ازاي افتح الخزنة'));
});

test('reaches the permission answer in Arabic', () => {
  assert.equal(top('الفولدرات فاضية'), 'permission-denied');
});

test('separates cancelling from restoring in Arabic', () => {
  assert.equal(top('عايز الغي الاشتراك'), 'premium-cancel');
  assert.equal(top('دفعت والبريميوم مش ظاهر'), 'premium-restore');
});

test('finds background playback in Arabic', () => {
  assert.equal(top('اسمع والشاشة مقفولة'), 'background-audio');
});

test('still returns nothing for an Arabic question it has no answer to', () => {
  assert.equal(search('عايز اطبخ كشري').length, 0);
});

test('all-stopword Arabic returns nothing', () => {
  assert.equal(search('ازاي انا ده').length, 0);
});
