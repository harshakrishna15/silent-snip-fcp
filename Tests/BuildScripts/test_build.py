"""Check debug/release orchestration and registration boundaries with fake builders."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class BuildTests(unittest.TestCase):
    def run_build(self, *arguments, fail=""):
        with tempfile.TemporaryDirectory(prefix="cutdown build ") as directory:
            root = Path(directory)
            scripts = root / "Scripts"
            scripts.mkdir()
            (scripts / "build.sh").write_text((REPO / "Scripts/build.sh").read_text())
            for name in ("build-app.sh", "register-local.sh"):
                path = scripts / name
                path.write_text('''#!/bin/bash
printf '%s' "${0##*/}" >> "$STUB_ROOT/calls"
for argument in "$@"; do printf ' <%s>' "$argument" >> "$STUB_ROOT/calls"; done
printf '\\n' >> "$STUB_ROOT/calls"
if [[ "${0##*/}" == "$FAIL_SCRIPT" ]]; then exit 7; fi
''')
                path.chmod(0o755)
            result = subprocess.run(["/bin/bash", str(scripts / "build.sh"), *arguments], cwd="/", capture_output=True, text=True,
                                    env=dict(os.environ, STUB_ROOT=str(root), FAIL_SCRIPT=fail))
            log = root / "calls"
            return result, log.read_text().splitlines() if log.exists() else []

    def test_development_build_registers_only_after_combined_app_succeeds(self):
        result, calls = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["build-app.sh <--debug>", "register-local.sh"])

    def test_release_build_uses_optimized_default(self):
        result, calls = self.run_build("--release")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["build-app.sh", "register-local.sh"])

    def test_stage_never_registers_and_flags_are_order_independent(self):
        for arguments in (("--stage", "--release"), ("--release", "--stage")):
            result, calls = self.run_build(*arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls, ["build-app.sh <--stage>"])

    def test_failed_build_never_registers(self):
        result, calls = self.run_build(fail="build-app.sh")
        self.assertEqual(result.returncode, 7)
        self.assertEqual(calls, ["build-app.sh <--debug>"])

    def test_registration_failure_is_not_success(self):
        result, _ = self.run_build(fail="register-local.sh")
        self.assertEqual(result.returncode, 7)

    def test_help_and_unknown_options_do_not_build(self):
        for option, expected in (("--help", 0), ("--unknown", 2)):
            result, calls = self.run_build(option)
            self.assertEqual(result.returncode, expected)
            self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
