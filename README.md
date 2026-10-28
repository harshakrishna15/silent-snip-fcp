# Silent Snip

Remove quiet pauses from audio-only clips in Final Cut Pro, with control over which cuts to keep.

Silent Snip combines a passthrough audio effect with a background macOS helper. The effect provides the Controls window; the helper analyzes audio and prepares an editable project that still references your original media.

> **Integration in progress:** Live source analysis, Noise Gate/Limiter analysis through visible Share, and verification of an existing cut result have passed on disposable fixtures. Fresh automatic Apply and precise settings recovery still need a complete live editing pass. Builds and analysis alone do not establish that automatic cuts work.

## How it works

1. Select one audio-only clip in the primary storyline and add **Silent Snip Audio**.
2. Open **Controls**, adjust silence detection, and click **Analyze**.
3. Controls returns to the front when analysis finishes. Review the proposed cuts and choose which to include. Detection or output edits update the current review; finish editing a field or press Return to start verification before Apply becomes available.
4. Click **Apply Cuts** to replace the project in its original event.

Silent Snip saves recovery XML before replacement. Your source media stays unchanged.

Final Cut's native Share panels remain visible during automation; no window covers them. Keep Final Cut in front while Silent Snip operates it. Detection settings are available in both Controls and the Audio Inspector so Final Cut can persist them.

See the [full workflow and recovery guide](docs/workflow.md) for detection settings, preview controls, and recovery steps.

See [review and verification fixes](docs/review-safety-fixes.md) for timeout handling,
reconnection, and source-integrity checks, including limits for older saved results.

## What it supports

- **Two output modes:** remove selected pauses or replace them with one-second gaps.
- **Review before applying:** per-cut selection and a timeline preview.
- **Audio processing:** measure source audio for unprocessed clips or a verified isolated Final Cut render for processed clips.
- **Faster tuning:** update cuts from the current review's retained measurements, with Apply disabled until fresh checks pass. A new Analyze can also reuse matching verified measurements.

Detection uses loudness, so quiet breaths can qualify as silence. It does not recognize speech or breaths.

Targets must be normal-speed, audio-only clips. Retimed or nested targets, linked-video cutting, component trims, unsupported connections, and cuts crossing fades are outside scope. See [compatibility details](docs/workflow.md#2-select-the-audio-clip) and [analysis behavior](docs/analysis-speed.md).

## Requirements

- **Apple Silicon Mac** — the audio plug-in targets `arm64`.
- **macOS 14 or later** — the deployment target; Xcode and Final Cut may require a newer version.
- **Final Cut Pro in English** — automation currently matches English interface labels.

Recorded builds used Xcode 27.0 / Swift 6.4. Current development checks use Final Cut Pro 12.4 on macOS 27.0.1; historical reports used Final Cut Pro 12.3. Other combinations have not been verified here.

A prebuilt app needs no Xcode, repository, or Terminal. Building from source requires full Xcode with first-launch setup completed. There are no external Swift packages or separate plug-in SDKs. Python 3 is needed for build-script tests; generating integration media also requires FFmpeg.

## Install

Start with **Silent Snip.zip**. You do not need the repository, Xcode, Terminal, or a separate installer.

1. **Quit Final Cut Pro and Silent Snip** before replacing an earlier copy.
2. **Extract the ZIP** and drag **Silent Snip.app** into Applications. Choose **Replace** if prompted. Keep one main app copy there.
3. **Open Silent Snip once.** A scissors icon appears in the menu bar. Its menu shows access status and provides saved results and Quit.
4. **Grant control access.** Open **System Settings → Privacy & Security → Device Control and Data Access** (called **Accessibility** on earlier macOS versions). Enable **Silent Snip**. If it is missing, click **+** and select the app you copied into Applications.
5. **Set up Final Cut Share.** In **Final Cut Pro → Settings → Destinations**, add **Export File**, name it **Silent Snip**, and choose **Audio Only → WAV**. Under **Action → Other…**, select that same **Silent Snip.app** in Applications.
6. **Add the effect.** In Final Cut’s Effects browser, add **Silent Snip Audio** to an audio-only clip. Open **Controls**, adjust detection, and choose **Analyze**. Review the ranges before choosing **Apply Cuts**.

**Upgrading from an older version:** this release uses a fresh app identity. Grant access to **Silent Snip**, remove obsolete app permission entries, and reselect the new app as the Share action. Old settings are not migrated; old files are left on disk.

See [setup and troubleshooting](docs/setup.md) for detailed steps, migration, and complete removal. The Audio Unit’s **Controls** window is the main interface; the menu bar app stays running in the background.

<details>
<summary>Build from source</summary>

With full Xcode installed, quit Final Cut and Silent Snip, then run:

```sh
Scripts/build-app.sh
```

This produces **`build/App/Silent Snip.app`** and **`dist/Silent Snip.zip`**, with both components in Release. The app includes the background executable, sandboxed Audio Unit, and Share definitions. Local builds are ad hoc signed; packaging does not bypass macOS security checks.

For development, `Scripts/build.sh` builds a Debug app and registers it in place. Add `--release` for Release, or `--stage` to create an inert candidate without changing the published app, ZIP, or registrations. `Scripts/register-local.sh --check-only` checks the combined build without changing registrations. Keep registered build products in place. See [developer setup](docs/setup.md#build-from-source).

</details>

The app also reduces repeated Final Cut control searches while keeping fresh project and selection checks. See [lookup changes and performance verification](docs/accessibility-speed.md).

XML-only exports can finish as soon as a complete, unchanged document is closed by its producer; unsupported systems retain the stability fallback. See [faster exports and settings previews](docs/fast-review.md) for behavior, measurements, and verification limits.

## Storage and cleanup

Silent Snip checks its recorded disposable audio at launch and every 10 minutes while idle. It removes old copies after seven days and targets a **256 MiB** cache limit, while preserving active or changed files. Share event logs are capped at **2 MiB total**.

Choose **Clear Cache…** from the scissors menu to discard reusable analysis audio. **Recovery XML, saved results, settings, Final Cut libraries, original media, and manual Share exports are preserved.** Unknown or older unregistered files are kept. Recovery and result history can therefore continue to grow until you remove it yourself. See [storage and cleanup details](docs/storage-cleanup.md).

## Uninstall

Quit Final Cut and Silent Snip, then move the copied **Silent Snip.app** to Trash. Settings and saved results are kept. Remove its Final Cut Share destination and macOS control-access entry as described in [complete removal](docs/setup.md#uninstall).

Developer builds can be removed with `Scripts/uninstall-local.sh`. Use `--dry-run` to preview or `--remove-data` to erase this account's saved settings, results, and recovery XML. This script only removes app bundles inside the checkout; protected data may require manual removal in Finder.

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

Recorded validation includes 442 Swift tests (one existing skip, no failures), 60 audio render/persistence cases, 35 Controls checks, and 53 build-script tests. Current native results and their limits are recorded in [the prototype report](docs/quiet-share-feasibility.md). A verified retry of an existing result does not establish a fresh unattended Analyze → Apply pass.

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
| [Single-app design and verification](docs/single-app-plan.md) | Architecture, migration, and current verification |
| [Setup and troubleshooting](docs/setup.md) | Installation, permissions, Share destination, and test library |
| [Workflow and recovery](docs/workflow.md) | Detection settings, review, Apply, and settings recovery |
| [Analysis and caching](docs/analysis-speed.md) | Source versus processed audio and measurement reuse |
| [Visible Share prototype](docs/quiet-share-prototype.md) | Automated native Share, testing inside Final Cut, and verification limits |
| [Integration evidence](docs/xml-replacement.md) | Manual replacement results and remaining verification |
| [Audio plug-in](AudioPlugin/README.md) | Implementation and [Controls/helper protocol](AudioPlugin/REVIEW_PROTOCOL.md) |

<details>
<summary>Source layout</summary>

| Path | Purpose |
| --- | --- |
| `Sources/SilentSnipCore` | Time, timeline parsing, detection, and review |
| `Sources/SilentSnipMac` | Audio analysis, Final Cut integration, XML, verification, and preview |
| `Sources/SilentSnipApp` | Containing app executable and background workflow |
| `Sources/SilentSnipVerify` | Offline developer verifier; does not import projects |
| `AudioPlugin` | Passthrough Audio Unit and Controls window |
| `Tests` | Swift fixtures, regression tests, and build-script tests |
| `Scripts` | Build, registration, and generated-media utilities |

Sanitized XML fixtures are included. Build products, generated media, local settings, Final Cut libraries, and validation logs are excluded from Git.

</details>
