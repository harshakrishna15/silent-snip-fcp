# Silent Snip

Remove quiet pauses from clips with audio in Final Cut Pro, with control over which cuts to keep.

Silent Snip opens from **Window → Extensions → Silent Snip** in Final Cut Pro. Select a supported clip, set detection, Analyze, review, and Apply. You do not add Silent Snip to the clip. A background worker captures audio and creates a cleaned copy of the full project.

Worker **64** includes a **disabled-by-default diagnostic** for invoking Share directly through the closed menu item's advertised Accessibility action. Five native analyses completed, including Gate→Limiter; three repeat effects runs had a **4.69 s** median versus **5.24 s** through the normal route on the same installed build. This small, grouped comparison establishes feasibility on the tested host, not general compatibility or Apply behavior. Ordinary use retains worker63's invocation route. See the [direct-action experiment and limits](docs/workflow-extension-prototype.md#worker-64-closed-menu-accessibility-probe).

Worker **63** combines fresh audio/XML capture for eligible repeat effects analyses and reduces repeated Share/import scans and focus changes. On the same 60-second Gate→Limiter fixture, repeat Analyze fell from **8.27 to 5.42 s** of helper time (**34% less time**); plain Analyze and overall Apply showed no material improvement. Native Apply, exact retained PCM and restart capture passed; the Swift suite completed **718 tests**, with three existing skips and zero failures. See the [timings and verification scope](docs/workflow-extension-prototype.md#worker-63-combined-workflow-capture-and-native-exchange-scans).

Worker **61** fixes preview flicker while moving across a clip and clears the overlay immediately when switching apps. Returning to Final Cut restores the same review from fresh geometry. Both behaviors passed the user's native check; the Swift suite completed **693 tests** with three existing skips and zero failures. See the [hover and app-switch verification](docs/workflow-extension-prototype.md#worker-61-immediate-app-switch-clearing).

Worker **57** refines the timeline preview with crisp round dots, small direction brackets, faint removal-range shading and compact numbered badges that avoid collisions. Standard/Retina rendering and native fitted/zoomed previews passed the [preview checks](docs/workflow-extension-prototype.md#worker-57-refined-timeline-preview).

Worker **56** speeds up review-window discovery and restoration. On the same disposable 60-second fixture, three warm Analyze runs had a median helper time of **3.08 s**, down from **5.48 s** (44% less time). Project, selection, focus and gesture checks remain; native Update, navigation and verified Apply passed. See the [scan timing evidence and limits](docs/workflow-extension-prototype.md#worker-56-faster-review-window-scans).

Workflow frontend **18** adds Final Cut-style charcoal sections, compact native controls and a muted header; its empty and 18-cut reviews were visually checked in Final Cut.

Worker **55** / Workflow frontend **17** introduced the three remaining review features: **Update Cuts**, **Go to Cut**, and **Verify Existing Result…**. Detection and output settings persist per project. The default package contains the worker and Workflow frontend, with no Silent Snip Audio effect embedded. Current implementation and verification status are recorded in the [Workflow Extension report](docs/workflow-extension-prototype.md); the three features passed scoped native tests, including a verified 44.6-second result, restart recovery, and an AU-free installed smoke run.

**Update Cuts** reuses retained measurements for eligible source-audio or verified direct-render clips, matching the former effect's eligibility. **Go to Cut** moves the playhead without another Share. **Verify Existing Result…** resumes checks after a restart without importing the result again or requiring a detector on a clip. Changing clip volume, effects, source media, or timeline content requires a fresh **Analyze Audio**.

Historical frontend-8 / worker-53 removal and gap runs placed processed PCM directly in the **audio-only primary storyline**. All **2,865,600 retained frames** matched their captured mix exactly; gap mode added **48,000 positive-zero frames**. This layout applies to fresh results only when no video occurs anywhere in the timeline, including disabled or connected video. Video keeps its existing primary storyline. These fixture results do not establish every effect's compatibility or the three-second throughput target. Later frontend-14 through frontend-16 UI checks are versioned separately in the report.

The build 40 changes prioritize identical retained sound: Apply captures the complete native project mix, including connected Music, Effects, and custom roles, and cuts that continuous lossless PCM instead of restarting live effects at each join. Original video edits stay in the cleaned project. The untouched original project retains its editable audio effects; the cleaned copy uses rendered sound and does not retain a live processing chain on its audio.

> **Historical build 47, Audio Unit 29 verification:** built, installed, and ZIP executable hashes matched; deep signature checks passed. The sound-preserving architecture introduced in build 40 passed native writer PCM, project/source, and durable-media identity checks for generated full-mix, camera/music, custom-role, and fractional-frame-rate fixtures.
>
> **Build 47's five-minute camera flow passed native Analyze → review → Apply without a manual verification retry.** Request `4A294C26` created 60 cuts, reducing 300 seconds to 191.5 seconds, passed strict project/source verification, and preserved all 9,192,000 retained stereo PCM frames exactly against its captured native mix. Helper processing took **9.41 seconds for Analyze plus 19.52 seconds for verified Apply: 28.93 seconds total**, excluding review, startup, frontend latency, and optional navigation. This is not a complete UI stopwatch measurement. The three-second target remains unmet. See [current evidence and limits](docs/workflow-throughput.md#build-47-guard-apply-source-validation-and-new-processed-media).

> **Voice-over milestone verified:** Analyze → Apply created and opened separate editable projects in Final Cut Pro 12.4 for plain narration, narration with Noise Gate and Limiter, and one-second-gap output. Original projects and source media were preserved. See [milestone evidence and limits](docs/voiceover-project.md).

Earlier general-project builds added linked camera clips, full-project copies, a guarded direct-render path, overlapping source validation, and viewport-based preview drawing. Their native Analyze → Apply passes and 64–69% lower fresh-reanalysis timing against the recorded audio baseline are historical results, with a different editable-effects output route. See [those verification notes](docs/general-project-performance.md).

The historical audio-effect manual review update added **Update Cuts** from retained audio and **Go to Cut** without another Share. Nine native setting updates took 82–124 ms in the helper (94 ms median); fresh audio analysis remains separate and Apply verifies current audio. See [timings and verification limits](docs/general-project-performance.md#manual-review-without-repeated-share).

Builds 37–39 improved source decoding, validation overlap, and guarded native menu readiness. Their five-minute runs took about 19–23 seconds of helper Analyze plus verified Apply time using the earlier editable-effects output. On the same 652 MB linked-camera fixture, build 46 took 34.39 seconds and build 47 took 28.93 seconds. Build 45's 29.72-second small audio-only run is a separate workload. The three-second target remains unmet; individual host runs do not establish a general speedup. The [workflow throughput report](docs/workflow-throughput.md) separates these measurements and their verification boundaries.

## How it works

The Workflow window uses the existing sound-preserving worker, Share destination, and verified XML Apply path.

1. Select one normal-speed clip with audio in the primary storyline and open **Window → Extensions → Silent Snip**.
2. Adjust silence detection and output, then click **Analyze Audio**.
3. Review the proposed cuts and choose which to include. After detection or output changes, click **Update Cuts** when available to recalculate from retained measurements. Use **Go to Cut** to inspect a boundary. Use **Analyze Audio** after changing volume, effects, source media, or timeline content.
4. Click **Apply Cuts** to capture the current full native mix, check the reviewed cuts, and create a cleaned copy in the original event. It retains the original video edits and uses continuous processed PCM with the selected ranges removed. Original camera audio is disabled so it cannot play twice.

The original project and source media stay unchanged. Silent Snip also saves the original project's recovery XML before importing the result.

Open the original project to change live sound-processing effects and analyze again. The cleaned copy contains the captured sound, including effect tails, rather than editable effect instances. Detection settings are saved with the result; the Workflow route needs no Silent Snip effect on the recording. Current exact-sample evidence covers native **24-bit stereo 48 kHz WAV exports**, not universal bit identity with Final Cut's live floating-point engine or every plugin.

Final Cut's native Share panels remain visible during automation; no window covers them. Keep Final Cut in front while Silent Snip operates it. Detection settings and output are saved per project in the Workflow frontend, keyed by library and project identity.

See the [full workflow and recovery guide](docs/workflow.md) for detection settings, preview controls, and recovery steps.

See [review and verification fixes](docs/review-safety-fixes.md) for timeout handling,
reconnection, and source-integrity checks, including limits for older saved results.

## What it supports

- **Two output modes:** remove selected pauses or replace them with one-second gaps.
- **Review before applying:** per-cut selection and a timeline preview.
- **Audio processing:** measure source audio for unprocessed clips or a verified Final Cut render for processed clips.
- **Sound-preserving output:** retain the full audible native project mix, with original video and recovery XML. Unverifiable roles, camera channel muting, sample mappings, or delivery stop the operation.
- **Manual analysis:** tweak values freely, then click Analyze Audio or Update Cuts. Old cuts stay inactive until the new analysis finishes; eligible requests can reuse matching verified measurements internally.

Detection uses loudness, so quiet breaths can qualify as silence. It does not recognize speech or breaths.

Targets must be normal-speed direct asset clips with enabled audio in the primary storyline. Linked video and audio are cut together. Retimed or nested targets, split A/V edits, component trims, unsupported connections, and cuts crossing fades remain outside scope. Pacing gaps must also place retained PCM on exact audio samples; unsupported frame-rate/sample-rate combinations stop rather than shift or resample the sound. See [compatibility details](docs/workflow.md#2-select-the-audio-clip) and [analysis behavior](docs/analysis-speed.md).

## Requirements

- **Apple Silicon Mac** — the worker and Workflow frontend target `arm64`.
- **macOS 14 or later** — the deployment target; Xcode and Final Cut may require a newer version.
- **Final Cut Pro in English** — automation currently matches English interface labels.

Recorded builds used Xcode 27.0 / Swift 6.4. Current development checks use Final Cut Pro 12.4 on macOS 27.2; historical reports used earlier macOS releases and Final Cut Pro 12.3. Other combinations have not been verified here.

The prebuilt apps need no Xcode, repository, or Terminal. Building from source requires full Xcode with first-launch setup completed and Apple’s Workflow Extensions SDK as documented in the [frontend guide](docs/workflow-extension-prototype.md). There are no external Swift package dependencies. Python 3 is needed for build-script tests; generating integration media also requires FFmpeg.

## Install

Start with **Silent Snip.zip**. You do not need the repository, Xcode, Terminal, or a separate installer.

1. **Quit Final Cut Pro and both Silent Snip apps** before replacing an earlier copy.
2. **Extract the ZIP** and copy **Silent Snip.app** and **Silent Snip Workflow Prototype.app** into the same Applications folder. Keep one active copy of each.
3. **Open both apps once.** Silent Snip provides the scissors menu bar icon. The Workflow frontend shows instructions; choose **Done**.
4. **Grant worker control access.** In **System Settings → Privacy & Security → Device Control and Data Access** (called **Accessibility** on earlier macOS versions), enable the copied **Silent Snip.app**.
5. **Set up Final Cut Share.** In **Final Cut Pro → Settings → Destinations**, add **Export File**, name it **Silent Snip**, choose **Audio Only → WAV**, and set **Action → Other…** to that same **Silent Snip.app**. Existing users keep the same worker identity and Share action.
6. In Final Cut, choose **Window → Extensions → Silent Snip**. Use **Connect to Final Cut Pro** if shown and approve the frontend's Automation request. Select a supported clip, Analyze, review, then Apply.

The default worker contains no Audio Unit. Existing projects and saved effect instances are not rewritten by installing the new apps. See [setup and migration](docs/setup.md) for details.

<details>
<summary>Build from source</summary>

With full Xcode and Apple’s Workflow Extensions SDK installed, quit Final Cut and both Silent Snip apps, then run:

```sh
Scripts/build-app.sh
```

This produces **`build/App/Silent Snip.app`**, **`build/WorkflowPrototype/Products/Silent Snip Workflow Prototype.app`**, and **`dist/Silent Snip.zip`**. The ZIP contains both apps under a `Silent Snip` folder. The worker retains its background executable and Share definitions; the separate frontend hosts the sandboxed Workflow interface. No Audio Unit is embedded. Both builds use Release by default. Local builds are ad hoc signed; packaging does not bypass macOS security checks.

For development, `Scripts/build.sh` builds a Debug worker plus the Release frontend and registers the pair in place. Add `--release` for a Release worker, or `--stage` to create only an inert worker candidate without changing the published apps, ZIP, or registrations. `Scripts/register-local.sh --check-only` checks the pair without changing registrations. Keep registered build products in place. See [developer setup](docs/setup.md#build-from-source).

</details>

The app also reduces repeated Final Cut control searches while keeping fresh project and selection checks. See [lookup changes and performance verification](docs/accessibility-speed.md).

XML-only exports can finish as soon as a complete, unchanged document is closed by its producer; unsupported systems retain the stability fallback. See [faster exports and manual analysis](docs/fast-review.md) for behavior, measurements, and verification limits.

## Storage and cleanup

Silent Snip checks its recorded disposable audio at launch and every 10 minutes while idle. It removes old copies after seven days and targets a **256 MiB** cache limit, while preserving active or changed files. Share event logs are capped at **2 MiB total**.

Choose **Clear Cache…** from the scissors menu to discard reusable analysis audio. **Recovery XML, saved results, settings, Final Cut libraries, original media, and manual Share exports are preserved.** Unknown or older unregistered files are kept. Recovery and result history can therefore continue to grow until you remove it yourself. See [storage and cleanup details](docs/storage-cleanup.md).

Build 40's retained **Processed Audio** is result media, not disposable analysis cache. Keep it while using a cleaned project: Final Cut references those PCM files in place. Clearing the cache must preserve them.

## Uninstall

Quit Final Cut and both Silent Snip apps, then move **Silent Snip.app** and **Silent Snip Workflow Prototype.app** to Trash. Settings and saved results are kept. Remove its Final Cut Share destination and macOS control-access entry as described in [complete removal](docs/setup.md#uninstall).

Developer builds can be removed with `Scripts/uninstall-local.sh`. Use `--dry-run` to preview or `--remove-data` to erase this account's saved settings, results, and recovery XML. This script only removes app bundles inside the checkout; protected data may require manual removal in Finder.

## Tests

Offline tests cover Swift processing, the Workflow controller and clients, and build scripts. Legacy Audio Unit harnesses remain available for compatibility checks. They do not edit Final Cut projects.

<details>
<summary>Run the offline tests</summary>

Run from the repository root. Reuse `build/swift` for all Swift builds:

```sh
mkdir -p build/module-cache build/swift-cache
CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/module-cache" \
swift test --disable-sandbox --scratch-path build/swift --cache-path build/swift-cache -c release

WorkflowPrototype/Tests/run-controller-tests.sh
WorkflowPrototype/Tests/run-review-client-tests.sh
WorkflowPrototype/Tests/run-window-client-tests.sh
python3 -B -m unittest discover -s Tests/BuildScripts -p 'test_*.py'
```

Audio decoding requires access to macOS media services. Xcode builds may also need process-list and debug-symbol-generation access. Record sandbox or environment failures separately from test failures.

</details>

**Live Final Cut tests must use `Cutdown Integration.fcpbundle` at the repository root.** A fresh checkout does not include it: create an empty library at that exact path, or reuse the existing one. Use small disposable projects with generated media referenced in place, without copied, optimized, or proxy media.

Follow [integration-test setup](docs/setup.md#integration-test-library) and [AGENTS.md](AGENTS.md) before testing.

## Verification status

Worker **55** / frontend **17** implementation adds the three features and AU-free pair packaging. The three review features passed scoped native validation; see the [current evidence record](docs/workflow-extension-prototype.md). The results below belong to their named historical revisions.

Historical frontend **16** header cleanup passed **33 controller groups / 5,304 assertions**, native visible/AX header and saved-settings checks, package/install checks, and all **12** scoped preservation checks. The **615 × 736-point** window, **320-point** pane, worker54/AU29/ZIP, and SDK settings/verification identity are unchanged. Original project/clip, settings, Gate/Limiter, and **75.933-second** playhead were restored; the minimal window remains open. No new Analyze/Apply, PCM, startup, or throughput run was performed. Evidence is under `build/WorkflowPrototype/Window16`; frontend-15 processing proof remains historical.

Historical frontend **15** copy cleanup passed **33 controller groups / 5,304 assertions**, package/install/signature checks, and native empty/18-cut review plus verified Apply at **615 × 736 points** with the **320-point** table retained. The generated result is **44.6 seconds**, with no import differences, verified source media, and **19 primary PCM clips / no gaps**. All **12** scoped preservation checks passed; worker54/AU29/ZIP are unchanged. One-cut, error/warning, and completed-label presentation retain offline coverage only. The original project/clip, Gate/Limiter, and **75.933-second** playhead were restored; the minimal window remains open. Evidence is under `build/WorkflowPrototype/Window15`. No new PCM comparison or performance claim is made.

Historical frontend **14** / worker **54** package/install checks and the scoped native size-restoration/review/Apply run passed. Recorded checks passed **652 Swift tests** (14 Workflow, 570 Mac, 68 Core; three existing opt-in skips), then **8 focused sizing tests** after the final pacing/destruction-callback changes, plus **124 Python tests**. Offline frontend checks passed **33 controller groups / 5,304 assertions**, **7 window-client groups / 158 assertions**, and **15 review-client groups / 143 assertions**, with fake dependencies rather than live helper/Final Cut operations. The final preservation audit passed all **11** scoped checks for package/ZIP identity, unchanged AU29, installed directory identities/signatures, registration, and accessible setup files. Protected preferences and selected defaults remain unverified. The native run adds no PCM comparison or general speed claim; other windows' frames were not measured. Final evidence is in `build/WorkflowPrototype/Window14/{Native14.json,Native14-Evidence-SHA256.json,After14-Preservation.json}`.

Historical worker **53** checks passed **645 Swift tests** (14 Workflow, 563 Mac, 68 Core; three existing opt-in skips, zero failures); the frontend-10 full build-script suite passed **124 Python tests**. Frontend 13 passed **32 groups / 4,384 functional assertions**, with **4,396** optional offscreen geometry assertions; its scoped native layout/Apply checks passed without a new PCM or speed claim. Historical frontend 11 passed **31 controller groups / 1,909 functional assertions** and **19 focused package tests**; optional offscreen image checks reached **1,917 assertions**. Earlier frontend-10 full Python/controller checks and frontend-8 client/fidelity evidence remain separately recorded. The native frontend-11 Apply check adds no new PCM comparison or speed claim. Both native primary-PCM modes passed exact 24-bit stereo 48 kHz comparison, imported-layout checks, notes/marker retention, source/durable identity checks, and fresh post-Apply original XML comparison. The frontend-11 preservation audit passed all 16 checks, including unchanged worker 53 / AU29 / ZIP, installed package/signatures/directory identity, AU registration, and accessible setup-file fingerprints. Protected preferences and selected command-set equality remain unverified. Historical worker 52 / 51 fidelity evidence is retained in the [Workflow frontend report](docs/workflow-extension-prototype.md#milestone-2-checkpoint); native nondefault detector-state and universal effect compatibility remain unestablished.

Historically, build 47 passed 600 Swift tests (532 Mac and 68 Core; three opt-in skips, no failures) and 104 Python tests, with one pre-existing test compiler warning. Regression checks cover historical source-alias binding, concurrent Analyze/Apply source hashing and cancellation, new durable-media protection, persisted routing hints, delayed Share confirmation, strict media history, and exact PCM gap comparison. Build 47/Audio Unit 29 packaging, installed/ZIP executable hashes, and deep signatures passed. Its five-minute linked-camera Gate → Limiter fixture completed the native button flow without a manual verification retry, passed strict project/source checks with one completed result verification capture, and matched all 9,192,000 retained stereo PCM frames against its captured mix. The result opened at 191.5 seconds; original source bytes and all saved identity/mutation stamps stayed unchanged. The new read-only durable WAV also retained its hash and every saved stamp. Helper Analyze plus verified Apply took 28.93 seconds; complete UI stopwatch timing remains unverified, and the three-second target is not met. These fixture checks do not certify every effect or establish a general speedup. See [current camera and Apply evidence](docs/workflow-throughput.md#build-47-guard-apply-source-validation-and-new-processed-media).

Build 47 also passed initial Apply for a one-minute Gate → Limiter → AUDelay fixture with connected Music and custom Room Tone in one-second-gap mode. All 3,323,200 output stereo frames matched exactly: 2,795,200 retained frames and 528,000 positive-zero gap frames. Helper processing took 32.04 seconds; the result passed strict project/source checks with one completed verification capture. This is tested fixture coverage, not universal plugin certification.

Build 45's smaller five-minute audio-only fixture completed verified Apply in 29.72 seconds of helper processing and matched all 9,192,000 retained stereo PCM frames exactly against its captured mix. Its performance remains separate from the build 46–47 camera workload.

Earlier build 43's one-minute Gate → Limiter → AUDelay fixture with connected Music and custom Room Tone passed initial Apply in gap mode: all 2,795,200 retained frames and 528,000 inserted digital-zero frames matched exactly, with 32.31 seconds of helper processing. Build 44's five-minute Apply failed after import and later passed explicit read-only **Retry Verification**, with exact retained PCM; its failed initial Apply is preserved separately and is not successful throughput. Earlier build 42 and 43 attempts also needed explicit read-only verification retries. Native writer fixture proofs and the older milestones below describe their recorded builds.

The October 28 voice-over build passed 436 Swift tests (one existing skip, no failures), 60 audio render/persistence cases, 35 Controls checks, and 53 build-script tests. Fresh native Analyze → Apply runs passed for plain removal, processed removal, and processed gaps in the required integration library. A separate existing-result verification reused the same project UUID without importing again. See [the milestone report](docs/voiceover-project.md) for evidence and remaining limits; quiet Share feasibility remains documented separately in [the prototype report](docs/quiet-share-feasibility.md).

The manual-Analyze update passed 30 Controls scenarios plus startup/protocol checks and the same 436 Swift checks (one skip). Native testing confirmed that edits, field blur, Save, and idle time do not analyze automatically; a manual Analyze Again followed by Apply verified successfully. See [manual Analyze evidence](docs/fast-review.md#manual-analyze-verification--october-28).

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
| [Workflow frontend and verification](docs/workflow-extension-prototype.md) | Current button interface, package, and versioned native evidence |
| [Historical single-app design](docs/single-app-plan.md) | Earlier Audio Unit architecture and migration |
| [Setup and troubleshooting](docs/setup.md) | Installation, permissions, Share destination, and test library |
| [Workflow and recovery](docs/workflow.md) | Detection settings, review, Apply, and settings recovery |
| [Analysis and caching](docs/analysis-speed.md) | Source versus processed audio and measurement reuse |
| [Visible Share prototype](docs/quiet-share-prototype.md) | Automated native Share, testing inside Final Cut, and verification limits |
| [Integration evidence](docs/xml-replacement.md) | Manual replacement results and remaining verification |
| [Legacy audio plug-in](AudioPlugin/README.md) | Earlier effect implementation and shared [review protocol](AudioPlugin/REVIEW_PROTOCOL.md) |

<details>
<summary>Source layout</summary>

| Path | Purpose |
| --- | --- |
| `Sources/SilentSnipCore` | Time, timeline parsing, detection, and review |
| `Sources/SilentSnipMac` | Audio analysis, Final Cut integration, XML, verification, and preview |
| `Sources/SilentSnipApp` | Containing app executable and background workflow |
| `Sources/SilentSnipVerify` | Offline developer verifier; does not import projects |
| `WorkflowPrototype` | Default Workflow frontend, project settings, and review clients |
| `AudioPlugin` | Legacy Audio Unit sources and shared review connection code |
| `Tests` | Swift fixtures, regression tests, and build-script tests |
| `Scripts` | Build, registration, and generated-media utilities |

Sanitized XML fixtures are included. Build products, generated media, local settings, Final Cut libraries, and validation logs are excluded from Git.

</details>
