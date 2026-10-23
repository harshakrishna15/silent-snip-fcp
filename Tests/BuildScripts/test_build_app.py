"""Exercise real packaging with disposable bundles and stubbed signing/process services."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile

REPO = Path(__file__).resolve().parents[2]


class AppBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="silent snip package ")
        self.root = Path(self.temporary.name)
        (self.root / "Scripts").mkdir()
        shutil.copytree(REPO / "Config", self.root / "Config")
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.helper = self.root / "build/Candidate/SilentSnipHelper.app"
        self.bundle(self.helper, "local.silentsnip.helper.candidate", "SilentSnip")
        self.extension = self.root / "build/Candidate/AudioPlugin/SilentSnipAudio.appex"
        self.bundle(self.extension, "local.silentsnip.app.audio", "SilentSnipAudio")
        self.output = self.root / "build/App/Silent Snip.app"
        self.bundle(self.output, "local.silentsnip.app", "SilentSnip")
        (self.output / "old-marker").write_text("previous app")
        self.archive = self.root / "dist/Silent Snip.zip"
        self.archive.parent.mkdir()
        self.archive.write_text("previous archive")
        script = (REPO / "Scripts/build-app.sh").read_text()
        script = script.replace("/usr/bin/pgrep", '"' + str(self.tools / "pgrep") + '"')
        (self.root / "Scripts/build-app.sh").write_text(script)
        for name, text in {
            "pgrep": '''#!/bin/bash
if [[ "$RUNNING" == host && "$1" == -x ]]; then exit 0; fi
if [[ "$RUNNING" == output && "$1" == -f ]]; then exit 0; fi
exit 1
''',
            "codesign": '''#!/bin/bash
[[ "$FAIL_SIGN" == 0 ]]
''',
            "mv": '''#!/bin/bash
if [[ "$FAIL_MOVE" == app && "$1" == */.single-app.*/Silent* ]]; then exit 1; fi
if [[ "$FAIL_MOVE" == archive && "$2" == */dist/Silent* ]]; then exit 1; fi
exec /bin/mv "$@"
''',
        }.items():
            path = self.tools / name
            path.write_text(text)
            path.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    def bundle(self, path, identity, executable):
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identity, "CFBundleExecutable": executable,
            "SilentSnipContainingApp": {"bundleIdentifier": "local.silentsnip.app", "executable": "SilentSnip", "enabled": True}}))
        binary = path / "Contents/MacOS" / executable
        binary.write_bytes(b"fixture executable")
        binary.chmod(0o755)

    def run_build(self, *args, **overrides):
        env = dict(os.environ, PATH=f"{self.tools}:/usr/bin:/bin", RUNNING="none", FAIL_SIGN="0", FAIL_MOVE="none")
        env.update(overrides)
        return subprocess.run(["/bin/bash", str(self.root / "Scripts/build-app.sh"), "--reuse-components", *args],
                              env=env, cwd="/", capture_output=True, text=True)

    def assert_previous_preserved(self):
        self.assertTrue((self.output / "old-marker").exists())
        self.assertEqual(self.archive.read_text(), "previous archive")

    def test_release_archive_contains_one_app_with_extension_and_live_share_routes(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads((self.output / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "local.silentsnip.app")
        self.assertEqual(info["CFBundleExecutable"], "SilentSnip")
        self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], ["silentsnip"])
        self.assertIn("com.apple.proapps.MediaAssetProtocol", info)
        self.assertTrue((self.output / "Contents/Resources/SilentSnip.sdef").exists())
        self.assertTrue((self.output / "Contents/PlugIns/SilentSnipAudio.appex/Contents/MacOS/SilentSnipAudio").exists())
        with zipfile.ZipFile(self.archive) as archive:
            names = [name for name in archive.namelist() if not name.startswith("__MACOSX/")]
            self.assertTrue(all(name.startswith("Silent Snip.app/") for name in names))
            self.assertFalse(any(".app/" in name[len("Silent Snip.app/"):] for name in names))
            self.assertIn("Silent Snip.app/Contents/MacOS/SilentSnip", names)
        self.assertFalse((self.output / "old-marker").exists())

    def test_stage_is_inert_and_preserves_published_app_and_archive(self):
        result = self.run_build("--stage", RUNNING="host")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_previous_preserved()
        candidate = self.root / "build/Candidate/App/Silent Snip.app"
        info = plistlib.loads((candidate / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "local.silentsnip.app")
        extension_info = plistlib.loads((candidate / "Contents/PlugIns/SilentSnipAudio.appex/Contents/Info.plist").read_bytes())
        self.assertFalse(extension_info["SilentSnipContainingApp"]["enabled"])
        for key in ("CFBundleURLTypes", "CFBundleDocumentTypes", "com.apple.proapps.MediaAssetProtocol"):
            self.assertNotIn(key, info)

    def test_running_apps_or_unknown_probe_status_prevent_replacement(self):
        for mode in ("host", "output"):
            result = self.run_build(RUNNING=mode)
            self.assertNotEqual(result.returncode, 0)
            self.assert_previous_preserved()
        (self.tools / "pgrep").write_text("#!/bin/bash\nexit 2\n")
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assert_previous_preserved()

    def test_loaded_stage_is_protected(self):
        result = self.run_build("--stage", RUNNING="output")
        self.assertNotEqual(result.returncode, 0)
        self.assert_previous_preserved()

    def test_signature_failure_preserves_published_app_and_archive(self):
        result = self.run_build(FAIL_SIGN="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_previous_preserved()

    def test_app_publication_failure_restores_previous_app(self):
        result = self.run_build(FAIL_MOVE="app")
        self.assertNotEqual(result.returncode, 0)
        self.assert_previous_preserved()

    def test_archive_publication_failure_rolls_back_app_too(self):
        result = self.run_build(FAIL_MOVE="archive")
        self.assertNotEqual(result.returncode, 0)
        self.assert_previous_preserved()

    def test_symlinked_or_unrelated_output_is_never_replaced(self):
        info = self.output / "Contents/Info.plist"
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "other.app"}))
        self.assertNotEqual(self.run_build().returncode, 0)
        self.assert_previous_preserved()
        outside = self.root / "unrelated.app"
        self.output.rename(outside)
        self.output.symlink_to(outside, target_is_directory=True)
        self.assertNotEqual(self.run_build().returncode, 0)
        self.assertTrue((outside / "old-marker").exists())

    def test_wrong_extension_identity_is_rejected_before_publication(self):
        (self.extension / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "other.extension"}))
        self.assertNotEqual(self.run_build().returncode, 0)
        self.assert_previous_preserved()


if __name__ == "__main__":
    unittest.main()
