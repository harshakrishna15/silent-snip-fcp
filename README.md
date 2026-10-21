# Cutdown

Cutdown is a local silence-removal tool for audio-only clips in Final Cut Pro. Add **Cutdown Audio** to one selected audio clip in the primary storyline, open **Controls**, and click **Analyze**. Review the proposed cuts, then use **Apply Cuts** to replace the project in its original event. Cutdown saves recovery XML before replacement; source media stays unchanged.

The Audio Unit passes audio through unchanged. A companion macOS helper measures silence, prepares the edited project, and communicates with Final Cut. Both components must be built and installed together.

**Integration status:** Manual XML replacement probes kept one project in the original event; see [evidence and limits](docs/xml-replacement.md). The full automatic Analyze → Apply workflow, preview, and settings recovery still need live Final Cut verification with matching installed builds. Successful builds and offline tests do not establish that automatic timeline cuts work.

## Requirements

- An Apple Silicon Mac. The audio plug-in build targets `arm64`.
- macOS 14 or later is the project's deployment target; your Xcode and Final Cut versions may require a newer macOS version.
- Full Xcode with first-launch setup completed and its command-line tools selected. Recorded builds used Xcode 27.0 / Swift 6.4; older toolchains have not been verified here.
- Final Cut Pro for the live workflow. Historical integration reports used Final Cut Pro 12.3. Automation currently matches English interface labels.
- Python 3 for build-script tests; FFmpeg and Python 3 for generated integration media. Neither is needed by the installed effect.

The project uses Apple's frameworks and has no external Swift package dependencies. No separate plug-in SDK, Motion installation, or paid signing identity is required for the local ad hoc build.

## Build and install

Clone or download the repository and open Terminal in its root. Quit Final Cut Pro and the Cutdown helper, then run:

```sh
Scripts/build.sh --release
```

This builds both components, verifies their signatures, and registers the generated bundles in place. Keep those bundles at their paths under `build/`. The helper uses Release; the audio plug-in currently uses Xcode's Debug configuration.

Complete [first-time setup](docs/setup.md) to grant macOS access and create the required **Cutdown** Share destination, then follow [the user workflow](docs/workflow.md). The build command does not configure permissions or Share destinations, launch apps, or run tests.

### Development builds

```sh
Scripts/build.sh          # Debug helper and audio plug-in; build and register
Scripts/build.sh --stage  # Build candidates without publishing installed bundles
```

Both commands reuse the existing Swift and Xcode caches. Add `--release` to a staged build for an optimized helper. Xcode may still register a staged audio candidate, so run a normal build before live use. Staged helpers have a separate identity and cannot serve the live workflow.

For individual component commands, registered bundle paths, signing options, and troubleshooting, see [the setup guide](docs/setup.md#build-and-register-both-apps).

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

These are recorded results, not checks rerun for every commit:

| Date | Recorded validation |
| --- | --- |
| September 18, 2026 | Staged Release helper and audio plug-in built and passed signature verification. The audio harness passed 60 mono/stereo render cases and settings-persistence checks; 56 then-current focused Swift tests passed. |
| September 22, 2026 | The full Release Swift suite and both Audio Unit harnesses passed after workflow and fixture cleanup. Manual XML replacement probes verified generated output in Final Cut. |

The manual probes do not verify the full automatic Analyze → Apply workflow. See [XML replacement evidence](docs/xml-replacement.md), [the progress record](docs/overhaul-progress.md), and [integration history](docs/integration-history.md) for scope, counts, and limitations. Generated logs and installed bundles are excluded from Git.

## Capabilities and limits

The implemented workflow supports normal-speed audio-only targets, source trims, per-cut selection, a timeline preview, and either removing silence or replacing selected pauses with one-second gaps. Live verification limits are noted above. Unprocessed clips use source PCM; processed clips use a verified isolated Final Cut render. Matching verified measurements can be reused when only detection settings change. See [analysis and cache behavior](docs/analysis-speed.md).

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
- [Analysis and cache behavior](docs/analysis-speed.md)
- [XML replacement evidence and limits](docs/xml-replacement.md)
- [Implementation progress](docs/overhaul-progress.md)
- [Historical integration evidence](docs/integration-history.md)

Sanitized XML fixtures are included for offline tests. Build products, generated source media, local settings, and Final Cut libraries are not distributed with the repository.
