# Silent Snip

Remove quiet pauses from audio-only clips in Final Cut Pro, with control over which cuts to keep.

Silent Snip combines a passthrough audio effect with a background macOS helper. The effect provides the Controls window; the helper analyzes audio and prepares an editable project that still references your original media.

> **Integration in progress:** Manual XML replacement has been verified. The full automatic Analyze → Apply workflow, preview, and settings recovery still need live Final Cut verification with matching installed builds. Builds and offline tests alone do not establish that automatic cuts work.

## How it works

1. Select one audio-only clip in the primary storyline and add **Silent Snip Audio**.
2. Open **Controls**, adjust silence detection, and click **Analyze**.
3. Review the proposed cuts and choose which to include.
4. Click **Apply Cuts** to replace the project in its original event.

Silent Snip saves recovery XML before replacement. Your source media stays unchanged.

See the [full workflow and recovery guide](docs/workflow.md) for detection settings, preview controls, and recovery steps.

## What it supports

- **Two output modes:** remove selected pauses or replace them with one-second gaps.
- **Review before applying:** per-cut selection and a timeline preview.
- **Audio processing:** measure source audio for unprocessed clips or a verified isolated Final Cut render for processed clips.
- **Faster repeat analysis:** reuse matching verified measurements when only detection settings change.

Detection uses loudness, so quiet breaths can qualify as silence. It does not recognize speech or breaths.

Targets must be normal-speed, audio-only clips. Retimed or nested targets, linked-video cutting, component trims, unsupported connections, and cuts crossing fades are outside scope. See [compatibility details](docs/workflow.md#2-select-the-audio-clip) and [analysis behavior](docs/analysis-speed.md).

## Requirements

- **Apple Silicon Mac** — the audio plug-in targets `arm64`.
- **macOS 14 or later** — the deployment target; Xcode and Final Cut may require a newer version.
- **Full Xcode** — complete first-launch setup and select its command-line tools.
- **Final Cut Pro in English** — automation currently matches English interface labels.

Recorded builds used Xcode 27.0 / Swift 6.4; historical integration reports used Final Cut Pro 12.3. Other toolchain and host combinations have not been verified here.

No external Swift packages, separate plug-in SDK, Motion installation, or paid signing identity are required for a local ad hoc build. Python 3 is needed for build-script tests; generating integration media also requires FFmpeg.

## Build and install

Clone or download the repository, then open Terminal in its root.

1. Quit Final Cut Pro and the Silent Snip helper.
2. Build and register both components:

   ```sh
   Scripts/build.sh --release
   ```

3. Complete [first-time setup](docs/setup.md): grant macOS access and create a Share destination named **Silent Snip**.
4. Reopen Final Cut and follow [the workflow](docs/workflow.md).

The build command verifies signatures and registers bundles in place under `build/`. Keep those bundles at their generated paths. Permissions and Share setup are separate, one-time steps. For an existing setup, rename its Share destination to **Silent Snip**.

<details>
<summary>Development builds and staging</summary>

```sh
Scripts/build.sh                  # Build and register with a Debug helper
Scripts/build.sh --stage           # Build candidates only
Scripts/build.sh --stage --release # Build candidates with a Release helper
```

All modes reuse the existing Swift and Xcode caches. The audio plug-in uses Xcode's Debug configuration in every mode. These commands do not launch apps or run tests.

Staged helpers have a separate identity and cannot serve the live workflow. Xcode may still register a staged audio candidate; run a normal build before live use.

See [the setup guide](docs/setup.md#build-and-register-both-apps) for individual component commands, bundle paths, signing options, and troubleshooting.

</details>

## Uninstall

Quit Final Cut Pro and Silent Snip, then run:

```sh
Scripts/uninstall-local.sh
```

This unregisters and removes this checkout’s app bundles, including staged copies. Saved settings and results are kept. Use `--dry-run` to preview, or `--remove-data` to also erase settings, saved results, and recovery XML.

Follow [the complete removal steps](docs/setup.md#uninstall) to remove the Share destination and macOS privacy entries.

## Tests

Offline tests cover the Swift code, Audio Unit rendering and Controls, and build scripts. They do not edit Final Cut projects.

<details>
<summary>Run the offline tests</summary>

Run from the repository root. Reuse `build/swift` for all Swift builds:

```sh
mkdir -p build/module-cache build/swift-cache
CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/module-cache" \
swift test --disable-sandbox --scratch-path build/swift --cache-path build/swift-cache -c release

AudioPlugin/test-audio.sh
AudioPlugin/test-factory.sh
python3 -B -m unittest discover -s Tests/BuildScripts -p 'test_*.py'
```

Audio decoding requires access to macOS media services. Xcode builds may also need process-list and debug-symbol-generation access. Record sandbox or environment failures separately from test failures.

</details>

**Live Final Cut tests must use `Cutdown Integration.fcpbundle` at the repository root.** A fresh checkout does not include it: create an empty library at that exact path, or reuse the existing one. Use small disposable projects with generated media referenced in place, without copied, optimized, or proxy media.

Follow [integration-test setup](docs/setup.md#integration-test-library) and [AGENTS.md](AGENTS.md) before testing.

## Verified in this repository copy

Recorded validation includes successful builds, offline tests, and manual XML replacement probes. End-to-end automatic editing remains unverified for the current build.

<details>
<summary>Recorded results — September 2026</summary>

**September 18**

- Staged Release helper and audio plug-in built and passed signature verification.
- The audio harness passed 60 mono/stereo render cases and settings-persistence checks.
- 56 then-current focused Swift tests passed.

**September 22**

- The full Release Swift suite and both Audio Unit harnesses passed after workflow and fixture cleanup.
- Manual replacement probes kept one project in the original event and verified generated output in Final Cut.

These are historical results, not checks rerun for every commit. See [XML replacement evidence](docs/xml-replacement.md), [the progress record](docs/overhaul-progress.md), and [integration history](docs/integration-history.md) for scope and limitations.

</details>

## Documentation

| Guide | Covers |
| --- | --- |
| [Setup and troubleshooting](docs/setup.md) | Installation, permissions, Share destination, and test library |
| [Workflow and recovery](docs/workflow.md) | Detection settings, review, Apply, and settings recovery |
| [Analysis and caching](docs/analysis-speed.md) | Source versus processed audio and measurement reuse |
| [Integration evidence](docs/xml-replacement.md) | Manual replacement results and remaining verification |
| [Audio plug-in](AudioPlugin/README.md) | Implementation and [Controls/helper protocol](AudioPlugin/REVIEW_PROTOCOL.md) |

<details>
<summary>Source layout</summary>

| Path | Purpose |
| --- | --- |
| `Sources/CutdownCore` | Time, timeline parsing, detection, and review |
| `Sources/CutdownMac` | Audio analysis, Final Cut integration, XML, verification, and preview |
| `Sources/CutdownApp` | Background helper application |
| `Sources/CutdownVerify` | Offline developer verifier; does not import projects |
| `AudioPlugin` | Passthrough Audio Unit and Controls window |
| `Tests` | Swift fixtures, regression tests, and build-script tests |
| `Scripts` | Build, registration, and generated-media utilities |

Sanitized XML fixtures are included. Build products, generated media, local settings, Final Cut libraries, and validation logs are excluded from Git.

</details>
