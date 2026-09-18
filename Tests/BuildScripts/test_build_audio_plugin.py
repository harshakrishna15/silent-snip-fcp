"""Simulate a host launching mid-build; never build/register a real extension."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class AudioBuildTests(unittest.TestCase):
    def run_build(self, statuses=(1, 1), stage=False, fail_move=False, fail_sign=False, candidate_status=1):
        with tempfile.TemporaryDirectory(prefix="cutdown-audio-build-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            installed = root / "build/AudioPlugin/Build/Products/Debug/CutdownAudio.app"
            installed.mkdir(parents=True)
            (installed / "old-marker").write_text("registered app")
            tools = root / "tools"
            tools.mkdir()
            stubs = {
                "pgrep": '''#!/bin/bash
if [[ "$1" == -f ]]; then exit "$STUB_CANDIDATE"; fi
count=0
if [[ -f "$STUB_ROOT/probes" ]]; then count=$(cat "$STUB_ROOT/probes"); fi
count=$((count + 1))
echo "$count" > "$STUB_ROOT/probes"
if [[ "$count" == 1 ]]; then exit "$STUB_FIRST"; fi
exit "$STUB_SECOND"
''',
                "xcodebuild": '''#!/bin/bash
echo build >> "$STUB_ROOT/calls"
for arg in "$@"; do
  if [[ "$arg" == CONFIGURATION_BUILD_DIR=* ]]; then output="${arg#*=}"; fi
done
[[ "$output" == "$STUB_ROOT/build/Candidate/AudioPlugin" ]] || exit 9
[[ -f "$STUB_ROOT/build/AudioPlugin/Build/Products/Debug/CutdownAudio.app/old-marker" ]] || exit 10
mkdir -p "$output/CutdownAudio.app/Contents/MacOS"
echo binary > "$output/CutdownAudio.app/Contents/MacOS/CutdownAudio"
''',
                "codesign": "#!/bin/bash\nexit \"$STUB_FAIL_SIGN\"\n",
                "mv": '''#!/bin/bash
if [[ "$STUB_FAIL_MOVE" == 1 && "$1" == *audio-publish.*/CutdownAudio.app ]]; then exit 1; fi
exec /bin/mv "$@"
''',
            }
            for name, contents in stubs.items():
                path = tools / name
                path.write_text(contents)
                path.chmod(0o755)
            script = (REPO / "scripts/build-audio-plugin.sh").read_text()
            script = script.replace("/usr/bin/pgrep", '"$STUB_ROOT/tools/pgrep"')
            path = root / "scripts/build-audio-plugin.sh"
            path.write_text(script)
            env = dict(os.environ, PATH=f"{tools}:/usr/bin:/bin", STUB_ROOT=str(root),
                       STUB_FIRST=str(statuses[0]), STUB_SECOND=str(statuses[1]),
                       STUB_FAIL_MOVE=str(int(fail_move)), STUB_FAIL_SIGN=str(int(fail_sign)),
                       STUB_CANDIDATE=str(candidate_status))
            result = subprocess.run(["/bin/bash", str(path)] + (["--stage"] if stage else []),
                                    env=env, capture_output=True, text=True)
            return (result, (installed / "old-marker").exists(),
                    (installed / "Contents/MacOS/CutdownAudio").exists(),
                    (root / "build/Candidate/AudioPlugin/CutdownAudio.app/Contents/MacOS/CutdownAudio").exists(),
                    (root / "calls").exists())

    def test_loaded_candidate_is_never_rebuilt_even_with_stage(self):
        for stage in (False, True):
            result, preserved, replaced, _, built = self.run_build(stage=stage, candidate_status=0)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("staged audio plug-in", result.stderr)
            self.assertTrue(preserved)
            self.assertFalse(replaced or built)

    def test_candidate_process_inspection_failure_stops_before_build(self):
        result, preserved, replaced, _, built = self.run_build(stage=True, candidate_status=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(preserved)
        self.assertFalse(replaced or built)

    def test_running_host_blocks_before_build(self):
        result, preserved, _, _, built = self.run_build((0, 0))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(preserved)
        self.assertFalse(built)

    def test_host_launching_during_build_does_not_replace_registered_app(self):
        result, preserved, replaced, staged, built = self.run_build((1, 0))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Quit Final Cut", result.stderr)
        self.assertTrue(preserved and staged and built)
        self.assertFalse(replaced)

    def test_unknown_host_status_preserves_registered_app(self):
        for statuses in [(2, 1), (1, 2)]:
            result, preserved, replaced, _, _ = self.run_build(statuses)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(preserved)
            self.assertFalse(replaced)

    def test_stopped_host_replaces_only_after_candidate_build(self):
        result, preserved, replaced, staged, _ = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(preserved)
        self.assertTrue(replaced and staged)

    def test_staging_preserves_registered_bundle(self):
        result, preserved, replaced, staged, _ = self.run_build((0, 0), stage=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(preserved and staged)
        self.assertFalse(replaced)

    def test_failed_signature_does_not_replace_app(self):
        result, preserved, replaced, _, _ = self.run_build(fail_sign=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(preserved)
        self.assertFalse(replaced)

    def test_failed_publication_restores_previous_app(self):
        result, preserved, replaced, _, _ = self.run_build(fail_move=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(preserved)
        self.assertFalse(replaced)


if __name__ == "__main__":
    unittest.main()
