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
                         missing_registration=False, add_failure=False):
        with tempfile.TemporaryDirectory(prefix="cutdown-register-") as directory:
            root = Path(directory)
            (root / "Scripts").mkdir()
            tools = root / "tools"
            tools.mkdir()
            bundles = {
                "build/Cutdown.app": "local.cutdown.helper",
                "build/Candidate/Cutdown.app": "local.cutdown.helper.candidate",
                "build/AudioPlugin/Build/Products/Debug/CutdownAudio.app": "local.cutdown.audio",
                "build/AudioPlugin/Build/Products/Debug/CutdownAudio.app/Contents/PlugIns/CutdownAudioExtension.appex": "local.cutdown.audio.extension",
                "build/Candidate/AudioPlugin/CutdownAudio.app": "local.cutdown.audio",
                "build/Diagnostic/Candidate/CutdownAudio.app": "local.cutdown.audio",
                "build/Unrelated/Candidate/CutdownAudio.app": "other.audio",
            }
            for name, identity in bundles.items():
                path = root / name / "Contents/Info.plist"
                path.parent.mkdir(parents=True, exist_ok=True)
                data = {"CFBundleIdentifier": identity}
                if identity == "local.cutdown.audio.extension":
                    data["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.AudioUnit-UI",
                        "NSExtensionPrincipalClass": "CutdownAudioUnitFactory"}
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
            result = subprocess.run(["/bin/bash", str(path)] + (["--check-only"] if check_only else []),
                env=dict(os.environ, HOST_STATUS="0" if host_running else "1", CALL_LOG=str(log),
                         CLEANUP_STATUS="1" if cleanup_failure else "0", ADD_STATUS="1" if add_failure else "0",
                         MISSING_REGISTRATION="1" if missing_registration else "0",
                         REGISTERED_PATH=str(root / "build/AudioPlugin/Build/Products/Debug/CutdownAudio.app/Contents/PlugIns/CutdownAudioExtension.appex")),
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
        self.assertIn("Registered the Cutdown", result.stdout)

    def test_zero_exit_without_installed_registry_entry_is_not_success(self):
        result, calls = self.run_registration(missing_registration=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Registered the Cutdown", result.stdout)
        self.assertEqual(sum(line.startswith("pluginkit -m ") for line in calls), 5)

    def test_failed_add_is_not_reported_as_success(self):
        result, calls = self.run_registration(add_failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Registered the Cutdown", result.stdout)


if __name__ == "__main__":
    unittest.main()
