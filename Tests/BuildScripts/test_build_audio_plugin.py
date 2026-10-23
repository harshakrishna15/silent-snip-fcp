"""Check extension-only compilation without touching registrations or app copies."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class AudioBuildTests(unittest.TestCase):
    def run_build(self, *args, process_status=1, fail_build=False, fail_sign=False):
        with tempfile.TemporaryDirectory(prefix="cutdown audio build ") as directory:
            root = Path(directory)
            (root / "Scripts").mkdir()
            tools = root / "tools"
            tools.mkdir()
            stubs = {
                "pgrep": '#!/bin/bash\nexit "$PROCESS_STATUS"\n',
                "xcodebuild": '''#!/bin/bash
printf '%s\\n' "$@" > "$STUB_ROOT/arguments"
[[ "$FAIL_BUILD" == 0 ]] || exit 7
for arg in "$@"; do
  if [[ "$arg" == CONFIGURATION_BUILD_DIR=* ]]; then output="${arg#*=}"; fi
done
mkdir -p "$output/SilentSnipAudio.appex/Contents/MacOS"
echo binary > "$output/SilentSnipAudio.appex/Contents/MacOS/SilentSnipAudio"
''',
                "codesign": '#!/bin/bash\n[[ "$FAIL_SIGN" == 0 ]]\n',
            }
            for name, contents in stubs.items():
                path = tools / name
                path.write_text(contents)
                path.chmod(0o755)
            script = (REPO / "Scripts/build-audio-plugin.sh").read_text().replace('/usr/bin/pgrep', '"$STUB_ROOT/tools/pgrep"')
            path = root / "Scripts/build-audio-plugin.sh"
            path.write_text(script)
            env = dict(os.environ, PATH=f"{tools}:/usr/bin:/bin", STUB_ROOT=str(root),
                       PROCESS_STATUS=str(process_status), FAIL_BUILD=str(int(fail_build)), FAIL_SIGN=str(int(fail_sign)))
            result = subprocess.run(["/bin/bash", str(path), *args], env=env, capture_output=True, text=True)
            arguments = root / "arguments"
            return result, arguments.read_text().splitlines() if arguments.exists() else []

    def test_builds_release_extension_without_launch_services_registration(self):
        result, arguments = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(arguments[arguments.index("-configuration") + 1], "Release")
        self.assertIn("DONT_REGISTER_WITH_LAUNCH_SERVICES=YES", arguments)
        self.assertIn("SilentSnipAudio.appex", result.stdout)
        self.assertNotIn("CutdownAudio.app", result.stdout)

    def test_debug_and_legacy_stage_flags_are_supported(self):
        result, arguments = self.run_build("--stage", "--debug")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(arguments[arguments.index("-configuration") + 1], "Debug")
        self.assertNotIn("--stage", arguments)

    def test_running_candidate_or_unknown_process_state_blocks_before_build(self):
        for status in (0, 2):
            result, arguments = self.run_build(process_status=status)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(arguments, [])

    def test_compilation_or_signature_failure_never_reports_product(self):
        for option in ({"fail_build": True}, {"fail_sign": True}):
            result, _ = self.run_build(**option)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("SilentSnipAudio.appex", result.stdout)


if __name__ == "__main__":
    unittest.main()
