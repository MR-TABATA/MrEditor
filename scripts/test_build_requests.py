"""python3 -m unittest scripts/test_build_requests.py"""
import datetime as dt
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_requests as b

NOW = dt.datetime(2026, 10, 5, tzinfo=dt.timezone.utc)


def issue(n, title, labels, state="open", reason=None, created="2026-10-03T00:00:00Z", comments=None, who="alice"):
    return {"number": n, "title": title, "state": state, "state_reason": reason, "created_at": created, "closed_at": None if state == "open" else "2026-10-04T00:00:00Z",
            "labels": [{"name": x} for x in labels], "user": {"login": who}, "_comments": comments or []}


OWNER_REASON = {"user": {"type": "User"}, "author_association": "OWNER", "body": "読み取り専用の設計と両立しないため、見送ります。"}


class RenderTests(unittest.TestCase):
    def test_status_comes_from_the_label_then_from_how_it_was_closed(self):
        self.assertEqual(b.status_of(issue(1, "x", ["request", "status:adopted"])), "adopted")
        self.assertEqual(b.status_of(issue(2, "x", ["request"], "closed", "not_planned")), "declined")
        self.assertEqual(b.status_of(issue(3, "x", ["request"], "closed", "completed")), "done")
        self.assertEqual(b.status_of(issue(4, "x", ["request"])), "received")

    def test_a_declined_request_shows_the_owners_reason_and_nobody_elses(self):
        stranger = {"user": {"type": "User"}, "author_association": "NONE", "body": "これは持ち主ではない人の長いコメントです。"}
        i = issue(5, "編集を足して", ["request", "status:declined"], "closed", "not_planned", comments=[OWNER_REASON, stranger])
        self.assertIn("両立しない", b.reason_of(i))
        self.assertIsNone(b.reason_of(issue(6, "x", ["request"], comments=[{"user": {"type": "User"}, "author_association": "OWNER", "body": "やらない"}])))

    def test_what_people_type_is_escaped(self):
        evil = issue(7, '<script>alert(1)</script> & "q"', ["request"], who='<img src=x onerror=1>')
        out = b.render([evil], "ja", NOW)
        self.assertNotIn("<script>alert", out)
        self.assertNotIn("<img src=x", out)
        self.assertIn("&lt;script&gt;", out)
        # the link is built from the number, whatever the title says
        self.assertIn('href="https://github.com/MR-TABATA/MrEditor/issues/7"', out)

    def test_the_reason_is_escaped_too(self):
        i = issue(8, "x", ["request", "status:declined"], "closed", "not_planned",
                  comments=[{"user": {"type": "User"}, "author_association": "OWNER", "body": "<b onmouseover=1>理由はこれです、長めに書きます</b>"}])
        out = b.render([i], "en", NOW)
        self.assertNotIn("<b onmouseover", out)

    def test_sections_follow_status_and_empty_ones_are_left_out(self):
        out = b.render([issue(1, "A", ["request"]), issue(2, "B", ["request", "status:considering"])], "ja", NOW)
        self.assertIn("受付（7日以内に返事します）", out)
        self.assertIn("検討中", out)
        self.assertNotIn("やらない（理由つき）", out)

    def test_overdue_is_flagged_only_when_still_received_and_past_seven_days(self):
        late = issue(1, "late", ["request", "status:received"], created="2026-09-25T00:00:00Z")
        fresh = issue(2, "fresh", ["request", "status:received"], created="2026-10-04T00:00:00Z")
        answered = issue(3, "answered", ["request", "status:considering"], created="2026-09-01T00:00:00Z")
        self.assertTrue(b.is_overdue(late, NOW))
        self.assertFalse(b.is_overdue(fresh, NOW))
        self.assertFalse(b.is_overdue(answered, NOW))

    def test_no_requests_says_so_in_each_language(self):
        self.assertIn("まだ要望はありません", b.render([], "ja", NOW))
        self.assertIn("No requests yet", b.render([], "en", NOW))

    def test_both_languages_link_to_each_other(self):
        self.assertIn('href="requests.ja.html"', b.render([], "en", NOW))
        self.assertIn('href="requests.html"', b.render([], "ja", NOW))


if __name__ == "__main__":
    unittest.main()
