"""リリースまわりのシェルスクリプトの試験。

- sparkle_sign.sh: 署名を取り出せなければ、非 0 で終わる（release.sh は、これが失敗したら公開しない）。
- make_app.sh: 配布版の Info.plist に、Sparkle のキーが入る。鍵が無い・壊れていれば、止まる。
  （make_app.sh は、ビルド済みの実行ファイルを包むだけ。無ければ、この試験は飛ばす）
"""
import os
import plistlib
import stat
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")
SPARKLE_FW = os.path.join(ROOT, ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/"
                          "macos-arm64_x86_64/Sparkle.framework")
GOOD_KEY = "ICZR3j24mtpMvlV8PimreSWd3/pGe5oPf5i0yAP4k9U="   # 32 バイトの公開鍵（形式の試験用）


def sh(args, env=None):
    full = dict(os.environ)
    full.update(env or {})
    return subprocess.run(["sh", *args], capture_output=True, text=True, env=full, cwd=ROOT)


def fake_command(directory: str, name: str, stdout: str, code: int = 0) -> str:
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"#!/bin/sh\nprintf '%s' '{stdout}'\nexit {code}\n")
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    return path


class SparkleSignTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.d = self._tmp.name
        self.dmg = os.path.join(self.d, "a.dmg")
        with open(self.dmg, "wb") as f:
            f.write(b"x")

    def tearDown(self):
        self._tmp.cleanup()

    def sign(self, stdout: str, code: int = 0):
        cmd = fake_command(self.d, "sign_update", stdout, code)
        return sh([os.path.join(SCRIPTS, "sparkle_sign.sh"), self.dmg], {"SIGN_UPDATE": cmd})

    def test_prints_the_signature_from_sign_updates_output(self):
        r = self.sign('sparkle:edSignature="SIGVALUE==" length="1"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "SIGVALUE==")

    def test_fails_when_the_output_has_no_signature(self):
        r = self.sign("something unexpected")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "", "署名が無ければ、何も出さない（空の署名を使わせない）")

    def test_fails_when_sign_update_itself_fails(self):
        r = self.sign('sparkle:edSignature="X" length="1"', code=3)
        self.assertNotEqual(r.returncode, 0)

    def test_fails_when_sign_update_or_the_dmg_is_missing(self):
        r = sh([os.path.join(SCRIPTS, "sparkle_sign.sh"), self.dmg], {"SIGN_UPDATE": "/nonexistent/sign_update"})
        self.assertNotEqual(r.returncode, 0)
        cmd = fake_command(self.d, "sign_update", 'sparkle:edSignature="X" length="1"')
        r = sh([os.path.join(SCRIPTS, "sparkle_sign.sh"), self.dmg + "x"], {"SIGN_UPDATE": cmd})
        self.assertNotEqual(r.returncode, 0)


@unittest.skipUnless(os.path.isdir(SPARKLE_FW) and os.path.exists(os.path.join(ROOT, ".build/debug/MrEditor")),
                     "ビルド済みの実行ファイルと Sparkle が要る（swift build のあと）")
class MakeAppPlistTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.out = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def make(self, **env):
        base = {"OUTDIR": self.out}
        base.update(env)
        return sh([os.path.join(SCRIPTS, "make_app.sh"), "debug"], base)

    def plist(self) -> dict:
        with open(os.path.join(self.out, "MrEditor.app/Contents/Info.plist"), "rb") as f:
            return plistlib.load(f)

    def test_release_bundle_declares_the_sparkle_keys(self):
        r = self.make()                       # 既定は、配布版のバンドル ID
        self.assertEqual(r.returncode, 0, r.stderr)
        p = self.plist()
        self.assertEqual(p["SUFeedURL"], "https://mrktools.app/downloads/mreditor/appcast.xml")
        self.assertEqual(p["SUPublicEDKey"], GOOD_KEY)
        self.assertEqual(p["SUScheduledCheckInterval"], 86400)

    def test_dev_bundle_declares_no_feed_so_it_never_updates(self):
        r = self.make(BUNDLE_ID="com.aaedit.MrEditorDev", APP_NAME="MrEditor")
        self.assertEqual(r.returncode, 0, r.stderr)
        p = self.plist()
        self.assertNotIn("SUFeedURL", p)
        self.assertNotIn("SUPublicEDKey", p)

    def test_a_feed_without_a_key_stops_the_build(self):
        r = self.make(SU_PUBLIC_ED_KEY="")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("公開鍵", r.stderr)

    def test_a_key_of_the_wrong_shape_stops_the_build(self):
        r = self.make(SU_PUBLIC_ED_KEY="not-a-key")
        self.assertNotEqual(r.returncode, 0)

    def test_an_overriding_key_reaches_the_plist_and_markup_is_escaped(self):
        r = self.make(UPDATE_FEED="https://example.com/a.xml?x=1&y=2")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.plist()["SUFeedURL"], "https://example.com/a.xml?x=1&y=2")


if __name__ == "__main__":
    unittest.main()
