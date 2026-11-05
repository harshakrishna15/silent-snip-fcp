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
        self.frontend = self.root / "build/WorkflowPrototype/Products/Silent Snip Workflow Prototype.app"
        self.bundle(self.frontend, "local.silentsnip.workflowprototype", "SilentSnipWorkflowPrototype")
        self.extension = self.frontend / "Contents/PlugIns/SilentSnipWorkflowExtension.appex"
        self.bundle(self.extension, "local.silentsnip.workflowprototype.extension", "SilentSnipWorkflowExtension")
        self.output = self.root / "build/App/Silent Snip.app"
        self.bundle(self.output, "local.silentsnip.app", "SilentSnip")
        (self.output / "old-marker").write_text("previous app")
        self.archive = self.root / "dist/Silent Snip.zip"
        self.archive.parent.mkdir()
        self.archive.write_text("previous archive")
        script = (REPO / "Scripts/build-app.sh").read_text()
        script = script.replace("/usr/bin/pgrep", '"' + str(self.tools / "pgrep") + '"')
        (self.root / "Scripts/build-app.sh").write_text(script)
        # Package verification has its own full checker tests. This fixture
        # verifies the packaging script supplies the actual worker/frontend pair.
        (self.root / "Scripts/check-workflow-prototype.py").write_text("""
import argparse, json, pathlib, plistlib
p = argparse.ArgumentParser()
p.add_argument('--app', type=pathlib.Path); p.add_argument('--worker', type=pathlib.Path); p.add_argument('--output', type=pathlib.Path)
a = p.parse_args()
def info(path): return plistlib.loads((path/'Contents/Info.plist').read_bytes())
assert info(a.app)['CFBundleIdentifier'] == 'local.silentsnip.workflowprototype'
assert info(a.app/'Contents/PlugIns/SilentSnipWorkflowExtension.appex')['CFBundleIdentifier'] == 'local.silentsnip.workflowprototype.extension'
assert info(a.worker)['CFBundleIdentifier'] == 'local.silentsnip.app'
assert not (a.worker/'Contents/PlugIns/SilentSnipAudio.appex').exists()
a.output.write_text(json.dumps({'verified': True}))
""")
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
        configured = plistlib.loads((self.root / "Config/Info.plist").read_bytes())
        info = {
            "CFBundleIdentifier": identity, "CFBundleExecutable": executable,
            "CFBundleVersion": configured["CFBundleVersion"],
            "SilentSnipContainingApp": {"bundleIdentifier": "local.silentsnip.app", "executable": "SilentSnip", "enabled": True}}
        if identity == "local.silentsnip.helper.candidate":
            info["SilentSnipWorkflowProtocolVersion"] = configured["SilentSnipWorkflowProtocolVersion"]
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
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

    def test_release_archive_contains_au_free_worker_and_workflow_frontend_with_live_share_routes(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads((self.output / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "local.silentsnip.app")
        self.assertEqual(info["CFBundleExecutable"], "SilentSnip")
        configured = plistlib.loads((self.root / "Config/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleVersion"], configured["CFBundleVersion"])
        self.assertEqual(info["SilentSnipWorkflowProtocolVersion"], 1)
        self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], ["silentsnip"])
        self.assertIn("com.apple.proapps.MediaAssetProtocol", info)
        self.assertTrue((self.output / "Contents/Resources/SilentSnip.sdef").exists())
        self.assertFalse((self.output / "Contents/PlugIns").exists())
        with zipfile.ZipFile(self.archive) as archive:
            names = [name for name in archive.namelist() if not name.startswith("__MACOSX/")]
            self.assertTrue(all(name.startswith("Silent Snip/") for name in names))
            self.assertIn("Silent Snip/Silent Snip.app/Contents/MacOS/SilentSnip", names)
            self.assertIn("Silent Snip/Silent Snip Workflow Prototype.app/Contents/PlugIns/SilentSnipWorkflowExtension.appex/Contents/MacOS/SilentSnipWorkflowExtension", names)
            self.assertFalse(any("SilentSnipAudio" in name for name in names))
        self.assertFalse((self.output / "old-marker").exists())

    def test_stage_is_inert_and_preserves_published_app_and_archive(self):
        result = self.run_build("--stage", RUNNING="host")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_previous_preserved()
        candidate = self.root / "build/Candidate/App/Silent Snip.app"
        info = plistlib.loads((candidate / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "local.silentsnip.app")
        self.assertFalse((candidate / "Contents/PlugIns").exists())
        for key in ("CFBundleURLTypes", "CFBundleDocumentTypes", "com.apple.proapps.MediaAssetProtocol", "SilentSnipWorkflowProtocolVersion"):
            self.assertNotIn(key, info)

    def test_missing_frontend_prevents_publication_but_not_worker_staging(self):
        shutil.rmtree(self.frontend)
        self.assertNotEqual(self.run_build().returncode, 0)
        self.assert_previous_preserved()
        result = self.run_build("--stage", RUNNING="host")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_previous_preserved()

    def test_stale_reused_helper_cannot_advertise_the_new_workflow_protocol(self):
        path = self.helper / "Contents/Info.plist"
        original = plistlib.loads(path.read_bytes())
        for field, value in [("CFBundleVersion", "47"), ("SilentSnipWorkflowProtocolVersion", 0)]:
            with self.subTest(field=field):
                info = dict(original); info[field] = value
                path.write_bytes(plistlib.dumps(info))
                result = self.run_build()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("out of date", result.stderr)
                self.assert_previous_preserved()

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

    def test_wrong_frontend_extension_identity_is_rejected_before_publication(self):
        (self.extension / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "other.extension"}))
        self.assertNotEqual(self.run_build().returncode, 0)
        self.assert_previous_preserved()


if __name__ == "__main__":
    unittest.main()
