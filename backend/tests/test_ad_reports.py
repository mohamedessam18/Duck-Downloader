"""What gets stored when a user reports an ad, and what does not.

This endpoint accepts writes from anyone with the app, so the interesting
questions are about what it refuses: oversized text, junk reasons, control
characters, and — most of all — anything that could identify the person who
complained.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.ad_reports import (  # noqa: E402
    MAX_DETAILS,
    MAX_FIELD,
    REASONS,
    append,
    build_record,
    normalise_reason,
    summarise,
)


class TestReason:
    @pytest.mark.parametrize("reason", REASONS)
    def test_known_reasons_survive(self, reason):
        assert normalise_reason(reason) == reason

    @pytest.mark.parametrize(
        "value", ["SCAM", "  gambling  ", "Sexual"]
    )
    def test_case_and_padding_do_not_make_a_new_reason(self, value):
        assert normalise_reason(value) in REASONS

    @pytest.mark.parametrize("value", [None, "", "whatever", "'; DROP TABLE"])
    def test_anything_unknown_becomes_other(self, value):
        # Stored as a free string, these could never be counted — and counting
        # is the entire reason this exists.
        assert normalise_reason(value) == "other"


class TestRecord:
    def test_nothing_identifying_is_stored(self):
        record = build_record(
            reason="scam",
            details="it asked for my card",
            ad_format="interstitial",
            app_version="1.2.1",
            platform="Android 13",
            locale="ar",
            seen_at="2026-08-31T12:00:00Z",
        )
        # A report that can be traced back to a person is a liability, and none
        # of it would help decide whether to block an advertiser.
        forbidden = {"ip", "device_id", "user", "email", "account", "advertising_id"}
        assert forbidden.isdisjoint(record.keys())

    def test_long_text_is_cut_rather_than_refused(self):
        record = build_record(
            reason="other",
            details="x" * 50_000,
            ad_format="y" * 500,
            app_version=None,
            platform=None,
            locale=None,
            seen_at=None,
        )
        # Refusing would lose a real complaint; storing it whole would let the
        # endpoint be used as free storage.
        assert len(record["details"]) == MAX_DETAILS
        assert len(record["ad_format"]) <= MAX_FIELD

    def test_control_characters_are_stripped(self):
        record = build_record(
            reason="scam",
            details="line\x00one\x1bhere",
            ad_format=None,
            app_version=None,
            platform=None,
            locale=None,
            seen_at=None,
        )
        assert "\x00" not in record["details"]
        assert "\x1b" not in record["details"]

    def test_a_report_with_no_context_is_still_a_report(self):
        # The page lets the user remove the technical details. Refusing the
        # report then would punish them for using a control we gave them.
        record = build_record(
            reason="sexual",
            details=None,
            ad_format=None,
            app_version=None,
            platform=None,
            locale=None,
            seen_at=None,
        )
        assert record["reason"] == "sexual"
        assert record["id"]

    def test_every_report_gets_its_own_id_and_a_timestamp(self):
        made = [
            build_record(
                reason="scam", details=None, ad_format=None, app_version=None,
                platform=None, locale=None, seen_at=None,
            )
            for _ in range(50)
        ]
        assert len({r["id"] for r in made}) == 50
        assert all(r["received_at"] for r in made)


class TestStorage:
    def test_reports_append_and_read_back(self, tmp_path):
        for reason in ["scam", "scam", "sexual"]:
            append(
                build_record(
                    reason=reason, details="d", ad_format=None, app_version=None,
                    platform=None, locale=None, seen_at=None,
                ),
                tmp_path,
            )

        summary = summarise(tmp_path)
        assert summary["total"] == 3
        # The counts are the point: one complaint is noise, the same one
        # thirty times is an advertiser to block.
        assert summary["by_reason"]["scam"] == 2
        assert summary["by_reason"]["sexual"] == 1

    def test_the_newest_report_is_first(self, tmp_path):
        for i in range(3):
            append(
                build_record(
                    reason="other", details=f"report {i}", ad_format=None,
                    app_version=None, platform=None, locale=None, seen_at=None,
                ),
                tmp_path,
            )
        assert summarise(tmp_path)["recent"][0]["details"] == "report 2"

    def test_one_corrupt_line_does_not_hide_the_rest(self, tmp_path):
        path = tmp_path / "ad-reports.jsonl"
        path.write_text(
            json.dumps({"id": "a", "reason": "scam"}) + "\n"
            + "{ this is not json\n"
            + json.dumps({"id": "b", "reason": "sexual"}) + "\n",
            encoding="utf-8",
        )
        # An append-only log that stops being readable at the first bad byte
        # would lose every report written after it.
        summary = summarise(tmp_path)
        assert summary["total"] == 2

    def test_no_file_yet_is_not_an_error(self, tmp_path):
        assert summarise(tmp_path) == {"total": 0, "by_reason": {}, "recent": []}

    def test_concurrent_writes_do_not_interleave(self, tmp_path):
        import threading

        def write(n):
            append(
                build_record(
                    reason="scam", details="x" * 500, ad_format=None,
                    app_version=None, platform=None, locale=None, seen_at=None,
                ),
                tmp_path,
            )

        threads = [threading.Thread(target=write, args=(i,)) for i in range(40)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # A torn line in an append-only log is permanent.
        lines = (tmp_path / "ad-reports.jsonl").read_text(encoding="utf-8").splitlines()
        assert len(lines) == 40
        for line in lines:
            json.loads(line)
