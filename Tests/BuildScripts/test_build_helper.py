"""Exercise bundle replacement with fake build tools; never touch running apps."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]


class HelperBuildTests(unittest.TestCase):
    def run_build(self, statuses, stage=False, release=False):
        with tempfile.TemporaryDirectory(prefix="cutdown-build-test-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "Config").mkdir()
            (root / "Config/Info.plist").write_text("fixture")
            (root / "Config/Cutdown.sdef").write_text("fixture")
            installed = root / "build/Cutdown.app"
            installed.mkdir(parents=True)
            (installed / "old-marker").write_text("previous helper")
            bin_dir = root / "tools"
            bin_dir.mkdir()
            stubs = {
                "pgrep": '''#!/bin/bash
count=0
if [[ -f "$STUB_ROOT/probes" ]]; then count=$(cat "$STUB_ROOT/probes"); fi
count=$((count + 1))
echo "$count" > "$STUB_ROOT/probes"
if [[ "$count" == 1 ]]; then exit "$STUB_FIRST"; fi
exit "$STUB_SECOND"
''',
                "swift": '''#!/bin/bash
echo swift >> "$STUB_ROOT/calls"
[[ " $* " == *" -c $STUB_CONFIGURATION "* ]] || exit 12
mkdir -p "$STUB_ROOT/build/bin"
printf '#!/bin/bash\\nexit 0\\n' > "$STUB_ROOT/build/bin/Cutdown"
chmod +x "$STUB_ROOT/build/bin/Cutdown"
if [[ "$*" == *--show-bin-path* ]]; then echo "$STUB_ROOT/build/bin"; fi
''',
                "codesign": "#!/bin/bash\nexit 0\n",
                "PlistBuddy": '''#!/bin/bash
if [[ "$1" == -c && "$2" == 'Print :CFBundleIdentifier' ]]; then
  echo "$STUB_IDENTIFIER"
fi
''',
            }
            for name, content in stubs.items():
                path = bin_dir / name
                path.write_text(content)
                path.chmod(0o755)
            script = (REPO / "scripts/build-helper.sh").read_text()
            script = script.replace("/usr/bin/pgrep", '"$STUB_ROOT/tools/pgrep"')
            script = script.replace("/usr/libexec/PlistBuddy", '"$STUB_ROOT/tools/PlistBuddy"')
            (root / "scripts/build-helper.sh").write_text(script)
            env = dict(os.environ, PATH=f"{bin_dir}:/usr/bin:/bin", STUB_ROOT=str(root),
                       STUB_FIRST=str(statuses[0]), STUB_SECOND=str(statuses[1]), STUB_CONFIGURATION="release" if release else "debug",
                       STUB_IDENTIFIER="local.cutdown.helper" + (".candidate" if stage else ""))
            result = subprocess.run(["/bin/bash", str(root / "scripts/build-helper.sh")]
                                    + (["--release"] if release else []) + (["--stage"] if stage else []), env=env,
                                    capture_output=True, text=True)
            return (result, (installed / "old-marker").exists(),
                    (root / "build/Candidate/Cutdown.app/Contents/MacOS/Cutdown").exists(),
                    (root / "calls").exists())

    def test_release_build_and_binary_lookup_use_same_configuration(self):
        result, preserved, staged, built = self.run_build((0, 0), stage=True, release=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(preserved and staged and built)

    def test_running_helper_blocks_before_build(self):
        result, preserved, _, built = self.run_build((0, 0))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Quit Cutdown", result.stderr)
        self.assertTrue(preserved)
        self.assertFalse(built)

    def test_unreadable_process_list_blocks_replacement(self):
        for statuses in [(2, 1), (1, 2)]:
            result, preserved, _, _ = self.run_build(statuses)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Cannot verify", result.stderr)
            self.assertTrue(preserved)

    def test_helper_launched_during_build_blocks_replacement(self):
        result, preserved, _, built = self.run_build((1, 0))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(preserved)
        self.assertTrue(built)

    def test_stopped_helper_can_be_replaced(self):
        result, preserved, _, built = self.run_build((1, 1))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(preserved)
        self.assertTrue(built)

    def test_staging_preserves_installed_helper(self):
        result, preserved, staged, _ = self.run_build((0, 0), stage=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(preserved)
        self.assertTrue(staged)


if __name__ == "__main__":
    unittest.main()
