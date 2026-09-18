# Cutdown

Cutdown is a local, audio-only silence-removal tool for Final Cut Pro. Add **Cutdown Audio** to one selected primary-storyline audio clip, open **Controls**, and click **Analyze**. Review the proposed cuts, then use **Apply Cuts** to create a separate editable project. Original projects and source media stay unchanged.

The Audio Unit passes audio through unchanged. A companion macOS helper measures silence, prepares the edited project, and communicates with Final Cut. Both components must be built and installed together.

**Status:** the copied source builds on Apple Silicon with Xcode 27. Current-build automatic Analyze/Apply, preview, and settings recovery still need live Final Cut verification. Successful builds and offline tests do not establish that automatic timeline cuts work.

## Requirements

- An Apple Silicon Mac. The audio plug-in build targets `arm64`.
- macOS 14 or later is the project's deployment target; your Xcode and Final Cut versions may require a newer macOS version.
- Full Xcode with first-launch setup completed and its command-line tools selected. The repository copy was built with Xcode 27.0 / Swift 6.4; older toolchains have not been verified here.
- Final Cut Pro for the live workflow. Historical integration reports used Final Cut Pro 12.3. Automation currently matches English interface labels.
- Python 3 for build-script tests; FFmpeg and Python 3 for generated integration media. Neither is needed by the installed effect.

The project uses Apple's frameworks and has no external Swift package dependencies. No separate plug-in SDK, Motion installation, or paid signing identity is required for the local ad hoc build.

## Build and install

Clone or download this repository, open Terminal in its root, and quit Final Cut Pro and the Cutdown helper before installing:

```sh
Scripts/build-helper.sh --release
Scripts/build-audio-plugin.sh
Scripts/register-local.sh --check-only
Scripts/register-local.sh
```

The helper is built in Release; the audio script currently builds the Xcode Debug configuration. Registration uses the bundles in `build/` in place. Keep those bundles at their generated paths.

Next, follow [first-time setup](docs/setup.md) to grant macOS access and create the required **Cutdown** Share destination. Registration does not perform those steps. Then follow [the user workflow](docs/workflow.md).

For build validation without replacing the installed bundles:

```sh
Scripts/build-helper.sh --stage --release
Scripts/build-audio-plugin.sh --stage
```

Staged helpers have a separate identity and cannot serve the live workflow. Xcode can automatically register an audio candidate. Before live testing, quit Final Cut, run the normal build/install commands above, and reopen Final Cut. The scripts refuse to replace a running helper or a loaded candidate, and stop if they cannot inspect the process list.

## Tests

Run from the repository root. All Swift builds reuse `build/swift`:

```sh
mkdir -p build/module-cache build/swift-cache
CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/module-cache" \
swift test --disable-sandbox --scratch-path build/swift --cache-path build/swift-cache -c release

AudioPlugin/test-audio.sh
AudioPlugin/test-factory.sh
python3 -B -m unittest discover -s Tests/BuildScripts -p 'test_*.py'
```

These are offline tests and do not edit Final Cut projects. Audio decoding tests require access to macOS media services; Xcode builds may also need process-list and debug-symbol-generation access. Record environment failures separately from test failures when running under an automation sandbox.

Live tests must use small disposable projects only in **Cutdown Integration.fcpbundle** at the repository root, referencing generated media in place with no copied, optimized, or proxy media. A fresh checkout does not include that library. See [integration-test setup](docs/setup.md#integration-test-library) before running any host tests and follow [AGENTS.md](AGENTS.md).

## Verified in this repository copy

On September 18, 2026:

- The staged Release helper and staged audio plug-in built successfully and passed signature verification.
- The audio harness passed 60 mono/stereo render cases plus its settings-persistence checks.
- After fixture privacy cleanup, 56 focused Swift tests passed: `TimelineTests`, `NativeTimelineEditTests`, and `EditedProjectWriterTests`.

The full Swift suite was not rerun during that copy/privacy audit. Earlier larger test totals and live observations are recorded in [the progress record](docs/overhaul-progress.md) and [integration history](docs/integration-history.md); they are historical evidence, not a new run against this checkout. Generated logs and installed bundles are excluded from Git.

## Capabilities and limits

Cutdown supports normal-speed audio-only targets, source trims, per-cut selection, a timeline preview, and either removing silence or replacing selected pauses with one-second gaps. Unprocessed clips use source PCM; processed clips use a verified isolated Final Cut render. Matching verified measurements can be reused when only detection settings change. See [analysis and cache behavior](docs/analysis-speed.md).

Detection is based on loudness, not speech or breath recognition. Retimed/nested targets, linked-video cutting, component trims, unsupported connections, and cuts crossing fades remain outside scope. Imported effects and settings are checked separately; the workflow includes recovery when Final Cut discards settings. See [workflow and recovery](docs/workflow.md) for the complete restrictions.

## Project layout and documentation

| Path | Purpose |
| --- | --- |
| `Sources/CutdownCore` | Time, timeline parsing, detection, and review |
| `Sources/CutdownMac` | Audio analysis, Final Cut integration, XML writing, verification, and preview |
| `Sources/CutdownApp` | Background helper application |
| `Sources/CutdownVerify` | Offline developer verifier; it does not import projects |
| `AudioPlugin` | Passthrough Audio Unit and Controls window |
| `Tests` | Swift fixtures, regression tests, and build-script tests |
| `Scripts` | Build, registration, and generated-media utilities |

- [First-time setup and troubleshooting](docs/setup.md)
- [User workflow and recovery](docs/workflow.md)
- [Audio plug-in implementation](AudioPlugin/README.md)
- [Controls/helper protocol](AudioPlugin/REVIEW_PROTOCOL.md)
- [Implementation progress](docs/overhaul-progress.md)
- [Historical integration evidence](docs/integration-history.md)

Sanitized XML fixtures are included for offline tests. Build products, generated source media, local settings, and Final Cut libraries are not distributed with the repository.
