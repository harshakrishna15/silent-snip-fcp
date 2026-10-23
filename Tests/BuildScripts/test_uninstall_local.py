"""Exercise uninstall against disposable bundles and fake macOS services only."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
HELPER = "local.silentsnip.helper"
AUDIO = "local.silentsnip.app"
EXTENSION = "local.silentsnip.app.audio"


class UninstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="silent snip uninstall ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.user_home = self.root / "test user"
        self.library = self.user_home / "Library"
        self.tools = self.root / "tools"
        self.tools.mkdir()
        (self.root / "Scripts").mkdir()
        self.apps = [
            self.bundle("build/SilentSnipHelper.app", HELPER),
            self.bundle("build/Candidate/SilentSnipHelper.app", HELPER + ".candidate"),
            self.bundle("build/AudioPlugin/Build/Products/Debug/CutdownAudio.app", AUDIO),
            self.bundle("build/Candidate/AudioPlugin/CutdownAudio.app", AUDIO),
            self.bundle("build/Diagnostic/Candidate/CutdownAudio.app", AUDIO),
        ]
        self.unrelated = self.bundle("build/Unrelated/CutdownAudio.app", "other.audio")
        self.media = self.root / "build/Fixtures/Recording.wav"
        self.media.parent.mkdir(parents=True)
        self.media.write_bytes(b"source media")
        self.evidence = self.root / "build/XMLReplacementVerification/host.fcpxml"
        self.evidence.parent.mkdir(parents=True)
        self.evidence.write_text("exported evidence")
        self.test_library = self.root / "Cutdown Integration.fcpbundle"
        self.test_library.mkdir()
        (self.test_library / "keep").write_text("user project")
        self.inside_library = self.bundle("build/Fixture.fcpbundle/SilentSnipHelper.app", HELPER)
        self.data = [self.library / "Application Support/Silent Snip", self.library / "Application Support/Silent Snip Audio"]
        for identity in [HELPER, HELPER + ".candidate", AUDIO, EXTENSION]:
            self.data += [self.library / category / (identity + suffix) for category, suffix in [
                ("Containers", ""), ("Caches", ""), ("Saved Application State", ".savedState"),
                ("Application Scripts", "")]]
        for path in self.data:
            path.mkdir(parents=True)
            (path / "keep").write_text("app data")
        results = self.data[0] / "Results/Job"
        results.mkdir(parents=True)
        (results / "Before-Cuts.fcpxml").write_text("recovery XML")
        self.preferences = self.library / f"Preferences/{HELPER}.plist"
        self.preferences.parent.mkdir()
        self.preferences.write_text("app preferences")
        self.other_data = self.library / "Application Support/Unrelated"
        self.other_data.mkdir()
        self.log = self.root / "calls"
        self.script = self.root / "Scripts/uninstall-local.sh"
        script = (REPO / "Scripts/uninstall-local.sh").read_text()
        # Never redirect the real user's HOME or operate on their app services.
        script = script.replace("$HOME", "$TEST_USER_HOME")
        stubs = {
            "pgrep": '''#!/bin/bash
if [[ "$PROCESS_STATUS" != 1 ]]; then exit "$PROCESS_STATUS"; fi
if [[ "$2" == "$RUNNING_APP" ]]; then exit 0; fi
exit 1
''',
            "lsregister": '''#!/bin/bash
printf 'lsregister %s\\n' "$*" >> "$CALL_LOG"
exit "$UNREGISTER_STATUS"
''',
            "pluginkit": '''#!/bin/bash
printf 'pluginkit %s\\n' "$*" >> "$CALL_LOG"
if [[ "$1" == -r ]]; then exit "$EXTENSION_REMOVE_STATUS"; fi
if [[ "$1" == -m ]]; then
  if [[ "$REGISTRY_PRESENT" == 1 ]]; then printf '%s\\n' "$REGISTERED_EXTENSION"; fi
  exit "$REGISTRY_STATUS"
fi
exit 9
''',
            "defaults": '''#!/bin/bash
file="$TEST_USER_HOME/Library/Preferences/$2.plist"
if [[ "$1" == read ]]; then [[ -f "$file" && "$PREFERENCES_READ_STATUS" == 0 ]]; exit; fi
printf 'defaults %s\\n' "$*" >> "$CALL_LOG"
if [[ "$PREFERENCES_DISAPPEAR" == 1 ]]; then
  /bin/rm -f "$file"
  printf "Error: Domain '%s' not found.\\nDefaults have not been changed.\\n" "$2"
  exit 1
fi
[[ "$PREFERENCES_DELETE_STATUS" == 0 ]] || exit 1
/bin/rm -f "$file"
''',
            "rm": '''#!/bin/bash
printf 'rm %s\\n' "$*" >> "$CALL_LOG"
[[ "$REMOVE_STATUS" == 0 ]] || exit 1
exec /bin/rm "$@"
''',
        }
        replacements = {
            "lsregister": "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "pgrep": "/usr/bin/pgrep", "pluginkit": "/usr/bin/pluginkit",
            "defaults": "/usr/bin/defaults", "rm": "/bin/rm",
        }
        for name, source in stubs.items():
            path = self.tools / name
            path.write_text(source)
            path.chmod(0o755)
            script = script.replace(replacements[name], f'"$TEST_TOOL_DIR/{name}"')
        self.script.write_text(script)

    def bundle(self, name, identity):
        app = self.root / name
        plist = app / "Contents/Info.plist"
        plist.parent.mkdir(parents=True)
        plist.write_bytes(plistlib.dumps({"CFBundleIdentifier": identity}))
        if identity == AUDIO:
            self.bundle(str(app.relative_to(self.root)) + "/Contents/PlugIns/SilentSnipAudio.appex", EXTENSION)
        return app

    def run_uninstall(self, *arguments, **overrides):
        env = dict(os.environ, TEST_USER_HOME=str(self.user_home), TEST_TOOL_DIR=str(self.tools), CALL_LOG=str(self.log),
                   PROCESS_STATUS="1", RUNNING_APP="", UNREGISTER_STATUS="0", EXTENSION_REMOVE_STATUS="0",
                   REGISTRY_STATUS="0", REGISTRY_PRESENT="0", REMOVE_STATUS="0", PREFERENCES_READ_STATUS="0",
                   PREFERENCES_DELETE_STATUS="0", PREFERENCES_DISAPPEAR="0",
                   REGISTERED_EXTENSION=str(self.apps[2] / "Contents/PlugIns/SilentSnipAudio.appex"))
        env.update(overrides)
        return subprocess.run(["/bin/bash", str(self.script), *arguments], cwd="/",
                              env=env, capture_output=True, text=True)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def assert_protected_files(self):
        for path in [self.media, self.evidence, self.unrelated, self.test_library / "keep",
                     self.inside_library, self.other_data, REPO / "Scripts/uninstall-local.sh"]:
            self.assertTrue(path.exists(), str(path))

    def test_default_removes_only_owned_apps_after_all_unregistrations(self):
        result = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(not app.exists() for app in self.apps))
        self.assertTrue(all(path.exists() for path in self.data))
        self.assertTrue(self.preferences.exists())
        calls = self.calls()
        self.assertEqual(sum(line.startswith("pluginkit -r ") for line in calls), 3)
        first_delete = next(i for i, line in enumerate(calls) if line.startswith("rm "))
        self.assertTrue(all(not line.startswith(("pluginkit ", "lsregister ")) for line in calls[first_delete:]))
        self.assert_protected_files()

    def test_remove_data_erases_settings_results_and_containers_only_when_requested(self):
        result = self.run_uninstall("--remove-data")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(not path.exists() for path in self.apps + self.data + [self.preferences]))
        self.assertIn(f"defaults delete {HELPER}", self.calls())
        self.assert_protected_files()

    def test_dry_run_is_read_only_even_with_remove_data_and_running_host(self):
        result = self.run_uninstall("--dry-run", "--remove-data", RUNNING_APP="Final Cut Pro")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Would run:", result.stdout)
        self.assertEqual(self.calls(), [])
        self.assertTrue(all(path.exists() for path in self.apps + self.data + [self.preferences]))
        self.assert_protected_files()

    def test_repeating_uninstall_and_data_removal_is_harmless(self):
        for _ in range(2):
            result = self.run_uninstall("--remove-data")
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_protected_files()

    def test_running_apps_or_unreadable_process_list_block_all_changes(self):
        for app in ["Final Cut Pro", "Cutdown", "CutdownAudio", "SilentSnipAudio"]:
            result = self.run_uninstall("--remove-data", RUNNING_APP=app)
            self.assertNotEqual(result.returncode, 0)
        result = self.run_uninstall(PROCESS_STATUS="2")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertTrue(all(path.exists() for path in self.apps + self.data))

    def test_unexpected_extension_identity_blocks_before_any_changes(self):
        plist = self.apps[2] / "Contents/PlugIns/SilentSnipAudio.appex/Contents/Info.plist"
        plist.write_bytes(plistlib.dumps({"CFBundleIdentifier": "other.extension"}))
        result = self.run_uninstall("--remove-data")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertTrue(all(path.exists() for path in self.apps + self.data))

    def test_failed_app_unregistration_keeps_all_bundles_and_data(self):
        result = self.run_uninstall("--remove-data", UNREGISTER_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(path.exists() for path in self.apps + self.data))
        self.assertFalse(any(line.startswith("rm ") for line in self.calls()))

    def test_failed_extension_removal_requires_confirmed_absence(self):
        result = self.run_uninstall(EXTENSION_REMOVE_STATUS="1", REGISTRY_PRESENT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(path.exists() for path in self.apps))
        result = self.run_uninstall(EXTENSION_REMOVE_STATUS="1", REGISTRY_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(path.exists() for path in self.apps))
        result = self.run_uninstall(EXTENSION_REMOVE_STATUS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(not path.exists() for path in self.apps))

    def test_symlinked_build_directory_is_rejected(self):
        build = self.root / "build"
        build.rename(self.root / "external build")
        build.symlink_to(self.root / "external build", target_is_directory=True)
        result = self.run_uninstall()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertTrue(all(app.exists() for app in self.apps))

    def test_nested_build_symlinks_are_not_followed(self):
        outside = self.bundle("outside/SilentSnipHelper.app", HELPER)
        (self.root / "build/linked").symlink_to(outside.parent, target_is_directory=True)
        result = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(outside.exists())
        self.assertFalse(any("/outside/" in call for call in self.calls()))

    def test_symlinked_data_parent_blocks_before_app_unregistration(self):
        support = self.library / "Application Support"
        support.rename(self.user_home / "external support")
        support.symlink_to(self.user_home / "external support", target_is_directory=True)
        result = self.run_uninstall("--remove-data")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertTrue(all(app.exists() for app in self.apps))

    def test_final_data_symlink_is_removed_without_deleting_its_target(self):
        support = self.data[0]
        support.rename(self.user_home / "external data")
        support.symlink_to(self.user_home / "external data", target_is_directory=True)
        result = self.run_uninstall("--remove-data")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(support.is_symlink())
        self.assertTrue((self.user_home / "external data/Results/Job/Before-Cuts.fcpxml").exists())

    def test_symlinked_extension_parent_is_rejected_before_changes(self):
        plugins = self.apps[2] / "Contents/PlugIns"
        external = self.root / "external plugins"
        plugins.rename(external)
        plugins.symlink_to(external, target_is_directory=True)
        result = self.run_uninstall()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertTrue((external / "SilentSnipAudio.appex").exists())
        self.assertTrue(all(app.exists() for app in self.apps))

    def test_domain_disappearing_after_preflight_does_not_fail_removal(self):
        result = self.run_uninstall("--remove-data", PREFERENCES_DISAPPEAR="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(not path.exists() for path in self.apps + self.data + [self.preferences]))
        self.assertIn("Removed local app data.", result.stdout)
        self.assert_protected_files()

    def test_failed_preference_deletion_is_not_reported_as_complete(self):
        result = self.run_uninstall("--remove-data", PREFERENCES_DELETE_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.preferences.exists())
        self.assertNotIn("Removed local app data.", result.stdout)
        self.assert_protected_files()

    def test_unreadable_preferences_fail_before_changes(self):
        result = self.run_uninstall("--remove-data", PREFERENCES_READ_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertTrue(all(path.exists() for path in self.apps + self.data))

    def test_failed_deletion_is_not_reported_as_success(self):
        result = self.run_uninstall(REMOVE_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Removed 5", result.stdout)
        self.assertTrue(all(path.exists() for path in self.apps))

    def test_help_and_unknown_arguments_do_not_change_anything(self):
        for arguments, code in [(["--help"], 0), (["--unknown"], 2), (["--remove-data", "extra"], 2)]:
            result = self.run_uninstall(*arguments)
            self.assertEqual(result.returncode, code, result.stderr)
            self.assertEqual(self.calls(), [])
            self.assertTrue(all(app.exists() for app in self.apps))


if __name__ == "__main__":
    unittest.main()
