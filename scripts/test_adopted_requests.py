"""python3 -m unittest scripts/test_adopted_requests.py"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import adopted_requests as a


def issue(n, title, labels, closed, reason="completed", who="alice"):
    return {"number": n, "title": title, "state": "closed", "state_reason": reason, "closed_at": closed + "T00:00:00Z",
            "labels": [{"name": x} for x in labels], "user": {"login": who}}


class AdoptedTests(unittest.TestCase):
    def test_only_done_or_adopted_requests_closed_after_the_date_and_not_declined(self):
        issues = [
            issue(1, "in", ["request", "status:done"], "2026-10-03"),
            issue(2, "before", ["request", "status:done"], "2026-09-30"),
            issue(3, "same day", ["request", "status:done"], "2026-10-01"),          # the release day itself is the base
            issue(4, "declined", ["request", "status:declined"], "2026-10-03", "not_planned"),
            issue(5, "not a request", ["bug", "status:done"], "2026-10-03"),
            issue(6, "adopted", ["request", "status:adopted"], "2026-10-02"),
            {**issue(7, "pr", ["request", "status:done"], "2026-10-03"), "pull_request": {}},
        ]
        got = a.adopted(issues, "2026-10-01")
        self.assertEqual([i["number"] for i in got], [6, 1])                          # oldest first

    def test_both_languages_and_the_requester_are_named(self):
        out = a.render([issue(52, "フォルダのツリーに、最近開いたものを出す", ["request", "status:done"], "2026-10-03", who="erin")])
        self.assertIn("### 採用した要望", out)
        self.assertIn("### Requests adopted", out)
        self.assertIn("@erin", out)
        self.assertIn("#52", out)

    def test_markdown_in_a_title_cannot_make_a_link_or_a_tag(self):
        out = a.render([issue(8, "[click](http://evil.example) <img src=x> `code`", ["request", "status:done"], "2026-10-03")])
        # a character that Markdown would act on must always come with a backslash before it
        self.assertIsNone(re.search(r"(?<!\\)\[click", out))      # an unescaped "[" would start a link
        self.assertIsNone(re.search(r"(?<!\\)<img", out))         # an unescaped "<" would start a tag
        self.assertIsNone(re.search(r"(?<!\\)`code", out))
        self.assertIn("\\[click\\]", out)

    def test_nothing_adopted_says_so(self):
        self.assertIn("ありません", a.render([]))


if __name__ == "__main__":
    unittest.main()
