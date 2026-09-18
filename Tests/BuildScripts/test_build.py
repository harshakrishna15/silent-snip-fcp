"""Check orchestration with stub builders; never build or register real apps."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]


class BuildTests(unittest.TestCase):
    def run_build(self, *arguments, host_status=1, helper_status=1, fail=""):
        with tempfile.TemporaryDirectory(prefix="cutdown build ") as directory:
            root = Path(directory)
            scripts = root / "Scripts"
            scripts.mkdir()
            probe = root / "pgrep"
            probe.write_text('''#!/bin/bash
if [[ "$2" == 'Final Cut Pro' ]]; then exit "$HOST_STATUS"; fi
exit "$HELPER_STATUS"
''')
            probe.chmod(0o755)
            script = (REPO / "Scripts/build.sh").read_text()
            script = script.replace("/usr/bin/pgrep", '"$STUB_ROOT/pgrep"')
            (scripts / "build.sh").write_text(script)
            for name in ("build-helper.sh", "build-audio-plugin.sh", "register-local.sh"):
                path = scripts / name
                path.write_text('''#!/bin/bash
name="${0##*/}"
printf '%s' "$name" >> "$STUB_ROOT/calls"
for argument in "$@"; do printf ' <%s>' "$argument" >> "$STUB_ROOT/calls"; done
printf '\\n' >> "$STUB_ROOT/calls"
if [[ "$name" == "$FAIL_SCRIPT" ]]; then exit 7; fi
''')
                path.chmod(0o755)
            result = subprocess.run(
                ["/bin/bash", str(scripts / "build.sh"), *arguments],
                cwd="/", capture_output=True, text=True,
                env=dict(os.environ, STUB_ROOT=str(root), HOST_STATUS=str(host_status),
                         HELPER_STATUS=str(helper_status), FAIL_SCRIPT=fail))
            log = root / "calls"
            return result, log.read_text().splitlines() if log.exists() else []

    def test_default_build_registers_both_from_any_directory(self):
        result, calls = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["build-helper.sh", "build-audio-plugin.sh", "register-local.sh"])

    def test_release_only_changes_helper_configuration(self):
        result, calls = self.run_build("--release")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["build-helper.sh <--release>", "build-audio-plugin.sh", "register-local.sh"])

    def test_stage_forwards_flags_without_registration_or_live_app_gate(self):
        for arguments in [("--stage", "--release"), ("--release", "--stage")]:
            with self.subTest(arguments=arguments):
                result, calls = self.run_build(*arguments, host_status=0, helper_status=0)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, ["build-helper.sh <--release> <--stage>",
                                         "build-audio-plugin.sh <--stage>"])

    def test_running_apps_or_failed_process_probe_prevent_all_builds(self):
        for host, helper in [(0, 1), (1, 0), (2, 1), (1, 2)]:
            with self.subTest(host=host, helper=helper):
                result, calls = self.run_build(host_status=host, helper_status=helper)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])

    def test_failure_stops_before_next_step_and_does_not_report_success(self):
        steps = ["build-helper.sh", "build-audio-plugin.sh", "register-local.sh"]
        for index, step in enumerate(steps):
            with self.subTest(step=step):
                result, calls = self.run_build(fail=step)
                self.assertEqual(result.returncode, 7)
                self.assertEqual(calls, steps[:index + 1])
                self.assertNotIn("Build and registration complete", result.stdout)

    def test_help_does_not_build(self):
        result, calls = self.run_build("--help", host_status=0)
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stdout)
        self.assertEqual(calls, [])

    def test_unknown_option_does_not_build(self):
        result, calls = self.run_build("--clean")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
