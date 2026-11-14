import base64
import os
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from xml.etree import ElementTree as ET

sys.path.insert(0, os.path.dirname(__file__))
import make_appcast as m  # noqa: E402


def b64(n: int) -> str:
    """n バイトの署名（base64）。本物の ed25519 署名は 64 バイト = 88 文字。"""
    return base64.b64encode(bytes(range(256))[:n] if n <= 256 else b"x" * n).decode()


SIG = b64(64)


def item(version: str):
    return m.build_item(version=version, url=m.release_url(version, f"MrEditor-{version}.dmg"),
                        length=1234, signature=SIG, notes="line <1>\n& line 2",
                        pub_date=datetime(2026, 11, 14, tzinfo=timezone.utc))


def write(path: str, text: str, mode: str = "w") -> None:
    with open(path, mode, **({} if "b" in mode else {"encoding": "utf-8"})) as f:
        f.write(text)


def run(appcast: str, dmg: str, notes: str, sig: str, version: str = "1.29.0") -> int:
    return m.main(["--appcast", appcast, "--version", version, "--dmg", dmg,
                   "--signature", sig, "--notes", notes])


class AppcastTests(unittest.TestCase):
    def test_item_has_what_sparkle_needs(self):
        i = item("1.29.0")
        self.assertEqual(i.findtext(m.q("version")), "1.29.0")
        self.assertEqual(i.findtext(m.q("minimumSystemVersion")), "13.0")
        enc = i.find("enclosure")
        self.assertEqual(enc.get("url"),
                         "https://github.com/MR-TABATA/MrEditor/releases/download/v1.29.0/MrEditor-1.29.0.dmg")
        self.assertEqual(enc.get("length"), "1234")
        self.assertEqual(enc.get(m.q("edSignature")), SIG)

    def test_notes_are_escaped_so_they_cannot_inject_markup(self):
        d = item("1.29.0").findtext("description")
        self.assertIn("&lt;1&gt;", d)
        self.assertIn("&amp; line 2", d)
        self.assertNotIn("<1>", d)

    def test_newest_first_and_same_version_replaces(self):
        tree = m.empty_channel()
        m.add_item(tree, item("1.28.0"))
        m.add_item(tree, item("1.29.0"))
        m.add_item(tree, item("1.29.0"))   # やり直し
        versions = [i.findtext(m.q("version")) for i in tree.getroot().iter("item")]
        self.assertEqual(versions, ["1.29.0", "1.28.0"])


class SignatureTests(unittest.TestCase):
    """署名は base64 で 64 バイト（88 文字）。境界の前後を確かめる。"""

    def test_exactly_64_bytes_is_valid(self):
        self.assertTrue(m.valid_signature(b64(64)))
        self.assertEqual(len(b64(64)), 88)

    def test_63_and_65_bytes_are_rejected(self):
        self.assertFalse(m.valid_signature(b64(63)))
        self.assertFalse(m.valid_signature(b64(65)))

    def test_not_base64_is_rejected(self):
        self.assertFalse(m.valid_signature("short"))
        self.assertFalse(m.valid_signature("!" * 88))
        self.assertFalse(m.valid_signature(""))


class FileTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.d = self._tmp.name
        self.dmg = os.path.join(self.d, "MrEditor-1.29.0.dmg")
        self.notes = os.path.join(self.d, "notes.md")
        self.appcast = os.path.join(self.d, "sub", "appcast.xml")
        write(self.dmg, "x" * 4096)
        write(self.notes, "## 1.29.0\n日本語のノート")

    def tearDown(self):
        self._tmp.cleanup()

    def test_roundtrip_through_a_file(self):
        self.assertEqual(run(self.appcast, self.dmg, self.notes, SIG), 0)
        self.assertEqual(m.versions_in(self.appcast), ["1.29.0"])
        enc = ET.parse(self.appcast).getroot().find("channel/item/enclosure")
        self.assertEqual(enc.get("length"), "4096")

    def test_whitespace_around_the_signature_is_stripped(self):
        self.assertEqual(run(self.appcast, self.dmg, self.notes, f"  {SIG}\n"), 0)
        enc = ET.parse(self.appcast).getroot().find("channel/item/enclosure")
        self.assertEqual(enc.get(m.q("edSignature")), SIG)

    def test_refuses_a_bad_signature_and_a_missing_dmg_without_creating_the_file(self):
        self.assertEqual(run(self.appcast, self.dmg, self.notes, b64(63)), 1)
        self.assertEqual(run(self.appcast, self.dmg + "x", self.notes, SIG), 1)
        self.assertEqual(run(self.appcast, self.dmg, self.notes + "x", SIG), 1)
        self.assertFalse(os.path.exists(self.appcast))

    def test_a_broken_existing_appcast_is_left_untouched_and_fails(self):
        os.makedirs(os.path.dirname(self.appcast))
        write(self.appcast, "<rss><channel><item>")          # 壊れた XML
        before = open(self.appcast, encoding="utf-8").read()
        self.assertEqual(run(self.appcast, self.dmg, self.notes, SIG), 1)
        self.assertEqual(open(self.appcast, encoding="utf-8").read(), before, "既存のファイルを壊さない")

    def test_an_appcast_without_a_channel_fails_and_is_left_untouched(self):
        os.makedirs(os.path.dirname(self.appcast))
        write(self.appcast, '<?xml version="1.0"?><rss version="2.0"></rss>')
        before = open(self.appcast, encoding="utf-8").read()
        self.assertEqual(run(self.appcast, self.dmg, self.notes, SIG), 1)
        self.assertEqual(open(self.appcast, encoding="utf-8").read(), before)

    def test_no_temp_file_is_left_behind(self):
        self.assertEqual(run(self.appcast, self.dmg, self.notes, SIG), 0)
        self.assertEqual(os.listdir(os.path.dirname(self.appcast)), ["appcast.xml"])


if __name__ == "__main__":
    unittest.main()
