import test from "node:test";
import assert from "node:assert/strict";

import { updateBanner, ANNOUNCE_DAYS } from "../.build-test/changelog.js";

const dated = (date) => [{ version: "1.2.2", build: 11, date, changes: [] }];
const on = (iso) => new Date(`${iso}T12:00:00Z`);

test("a release with no date is still coming", () => {
  const state = updateBanner(on("2026-09-02"), dated(null));
  assert.equal(state.kind, "coming");
  assert.equal(state.version, "1.2.2");
});

test("a release dated today is available", () => {
  const state = updateBanner(on("2026-09-02"), dated("2026-09-02"));
  assert.equal(state.kind, "available");
});

test("a release dated in the future has not happened yet", () => {
  // Writing tomorrow's date while preparing a release must not announce it.
  const state = updateBanner(on("2026-09-02"), dated("2026-09-10"));
  assert.equal(state.kind, "coming");
});

test("news stops being news", () => {
  // A banner still shouting about a months-old release is decoration, and
  // nobody remembers to take it down by hand.
  const inside = updateBanner(on("2026-09-02"), dated("2026-08-20"));
  assert.equal(inside.kind, "available");

  const outside = updateBanner(on("2026-12-01"), dated("2026-08-20"));
  assert.equal(outside, null);
});

test("the cutoff is where it says it is", () => {
  const released = new Date("2026-01-01T00:00:00Z");
  const justInside = new Date(released.getTime() + ANNOUNCE_DAYS * 86400000);
  const justOutside = new Date(released.getTime() + (ANNOUNCE_DAYS + 1) * 86400000);

  assert.equal(updateBanner(justInside, dated("2026-01-01")).kind, "available");
  assert.equal(updateBanner(justOutside, dated("2026-01-01")), null);
});

test("no releases at all is no banner, not a crash", () => {
  assert.equal(updateBanner(on("2026-09-02"), []), null);
});

test("an unreadable date is no banner, not a crash", () => {
  assert.equal(updateBanner(on("2026-09-02"), dated("not a date")), null);
});
