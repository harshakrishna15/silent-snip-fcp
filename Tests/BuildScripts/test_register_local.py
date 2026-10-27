"""Registration ordering with fake services; never alter macOS registrations."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class RegistrationTests(unittest.TestCase):
    def run_registration(self, host_running=False, check_only=False, cleanup_failure=False,
                         missing_registration=False, add_failure=False, combined=False, explicit=False, candidate=False):
        with tempfile.TemporaryDirectory(prefix="silentsnip-register-") as directory:
            root = Path(directory)
            (root / "Scripts").mkdir()
            tools = root / "tools"
            tools.mkdir()
            bundles = {
                "build/SilentSnipHelper.app": "local.silentsnip.helper",
                "build/Candidate/SilentSnipHelper.app": "local.silentsnip.helper.candidate",
                "build/AudioPlugin/Build/Products/Debug/SilentSnipAudio.app": "local.silentsnip.app",
                "build/AudioPlugin/Build/Products/Debug/SilentSnipAudio.app/Contents/PlugIns/SilentSnipAudio.appex": "local.silentsnip.app.audio",
                "build/Candidate/AudioPlugin/SilentSnipAudio.app": "local.silentsnip.app",
                "build/Diagnostic/Candidate/SilentSnipAudio.app": "local.silentsnip.app",
                "build/Unrelated/Candidate/SilentSnipAudio.app": "other.audio",
            }
            combined_path = "Copied/Silent Snip.app" if explicit else "build/App/Silent Snip.app"
            if combined:
                bundles[combined_path] = "local.silentsnip.app"
                bundles[combined_path + "/Contents/PlugIns/SilentSnipAudio.appex"] = "local.silentsnip.app.audio"
            for name, identity in bundles.items():
                path = root / name / "Contents/Info.plist"
                path.parent.mkdir(parents=True, exist_ok=True)
                data = {"CFBundleIdentifier": identity}
                if combined and name == combined_path:
                    data.update(CFBundleExecutable="SilentSnip")
                    if not candidate: data["CFBundleURLTypes"] = [{"CFBundleURLSchemes": ["silentsnip"]}]
                    executable = path.parent / "MacOS/SilentSnip"
                    executable.parent.mkdir()
                    executable.write_text("fixture")
                    executable.chmod(0o755)
                    (path.parent / "Resources").mkdir()
                    (path.parent / "Resources/SilentSnip.sdef").write_text("fixture")
                if identity == "local.silentsnip.app.audio":
                    data["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.AudioUnit-UI",
                        "NSExtensionPrincipalClass": "SilentSnipAudioUnitFactory"}
                path.write_bytes(plistlib.dumps(data))
            stubs = {
                "codesign": "#!/bin/bash\nexit 0\n",
                "pgrep": '#!/bin/bash\nexit "$HOST_STATUS"\n',
                "pluginkit": '''#!/bin/bash
printf "pluginkit %s\\n" "$*" >> "$CALL_LOG"
if [[ "$1" == -r ]]; then exit "$CLEANUP_STATUS"; fi
if [[ "$1" == -a ]]; then exit "$ADD_STATUS"; fi
if [[ "$1" == -m && "$MISSING_REGISTRATION" == 0 ]]; then printf '%s\\n' "$REGISTERED_PATH"; fi
exit 0
''',
                "lsregister": '''#!/bin/bash
printf "lsregister %s\\n" "$*" >> "$CALL_LOG"
if [[ "$1" == -u ]]; then exit "$CLEANUP_STATUS"; fi
exit 0
''',
            }
            script = (REPO / "Scripts/register-local.sh").read_text()
            script = script.replace("/bin/sleep 1", ":")
            for name, contents in stubs.items():
                tool = tools / name
                tool.write_text(contents)
                tool.chmod(0o755)
                original = "/usr/bin/" + name if name != "lsregister" else "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
                script = script.replace(original, str(tool))
            path = root / "Scripts/register-local.sh"
            path.write_text(script)
            log = root / "calls"
            options = (["--check-only"] if check_only else []) + (["--app", str(root / combined_path)] if explicit else [])
            registered = (root / combined_path / "Contents/PlugIns/SilentSnipAudio.appex") if combined else (root / "build/AudioPlugin/Build/Products/Debug/SilentSnipAudio.app/Contents/PlugIns/SilentSnipAudio.appex")
            result = subprocess.run(["/bin/bash", str(path)] + options,
                env=dict(os.environ, HOST_STATUS="0" if host_running else "1", CALL_LOG=str(log),
                         CLEANUP_STATUS="1" if cleanup_failure else "0", ADD_STATUS="1" if add_failure else "0",
                         MISSING_REGISTRATION="1" if missing_registration else "0",
                         REGISTERED_PATH=str(registered)),
                capture_output=True, text=True)
            return result, log.read_text().splitlines() if log.exists() else []

    def test_candidate_unregistered_before_installed_extension_selected(self):
        result, calls = self.run_registration()
        self.assertEqual(result.returncode, 0, result.stderr)
        removed = next(i for i, line in enumerate(calls) if line.startswith("pluginkit -r "))
        added = next(i for i, line in enumerate(calls) if line.startswith("pluginkit -a "))
        self.assertLess(removed, added)
        self.assertIn("/build/Candidate/AudioPlugin/", calls[removed])
        self.assertIn("/build/AudioPlugin/Build/Products/Debug/", calls[added])
        self.assertTrue(any(line.startswith("lsregister -u ") and "/Candidate/AudioPlugin/" in line for line in calls))

    def test_diagnostic_candidates_unregistered_before_installed_extension(self):
        result, calls = self.run_registration()
        self.assertEqual(result.returncode, 0, result.stderr)
        removed = next(i for i, line in enumerate(calls) if line.startswith("pluginkit -r ") and "/Diagnostic/" in line)
        added = next(i for i, line in enumerate(calls) if line.startswith("pluginkit -a "))
        self.assertLess(removed, added)
        self.assertFalse(any("/Unrelated/" in line for line in calls))

    def test_running_final_cut_prevents_all_registration_changes(self):
        result, calls = self.run_registration(host_running=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_check_only_does_not_unregister_candidates(self):
        result, calls = self.run_registration(host_running=True, check_only=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_failed_candidate_cleanup_still_restores_installed_registration(self):
        result, calls = self.run_registration(cleanup_failure=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Candidate cleanup did not complete", result.stderr)
        self.assertTrue(any(line.startswith("pluginkit -a ") for line in calls))
        self.assertIn("Registered the Silent Snip", result.stdout)

    def test_zero_exit_without_installed_registry_entry_is_not_success(self):
        result, calls = self.run_registration(missing_registration=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Registered the Silent Snip", result.stdout)
        self.assertEqual(sum(line.startswith("pluginkit -m ") for line in calls), 5)

    def test_failed_add_is_not_reported_as_success(self):
        result, calls = self.run_registration(add_failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Registered the Silent Snip", result.stdout)

    def test_combined_app_registers_one_containing_app_and_its_extension(self):
        result, calls = self.run_registration(combined=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        published = [call for call in calls if call.startswith("lsregister -f ")]
        self.assertEqual(len(published), 1)
        self.assertIn("/build/App/Silent Snip.app", published[0])
        self.assertTrue(any(call.startswith("pluginkit -a ") and "/build/App/Silent Snip.app/Contents/PlugIns/" in call for call in calls))

    def test_copied_app_can_be_checked_and_registered_at_its_explicit_path(self):
        result, calls = self.run_registration(combined=True, explicit=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(call.startswith("lsregister -f ") and "/Copied/Silent Snip.app" in call for call in calls))
        result, calls = self.run_registration(combined=True, explicit=True, check_only=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_inert_combined_candidate_is_rejected_before_any_registration(self):
        result, calls = self.run_registration(combined=True, candidate=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
