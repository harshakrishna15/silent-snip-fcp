# Silent Snip

Remove quiet pauses from clips with audio in Final Cut Pro, with control over which cuts to keep.

Silent Snip opens from **Window → Extensions → Silent Snip** in Final Cut Pro. Select a supported clip, set detection, Analyze, review, and Apply. You do not add Silent Snip to the clip. A background worker captures audio and creates a cleaned copy of the full project.

Installed Workflow frontend **30** passed the generated Analyze/update/Cancel/reopen/Apply/Verify lifecycle. Native logs show **five system-arrow → Final Cut artwork repairs**, including **three while the extension window was not key** during recalculation, Analyze and Apply. This is lifecycle/repair evidence; screen captures omit the pointer, so visible-shape confirmation remains pending. The cursor-policy baseline passed **51 controller groups / 9,337 assertions** before frontend30's logging-only refinement. Packaged worker78/frontend30 files match the installed apps, and the entire worker bundle is unchanged. **Toolbar highlight opacity remains unfixed**; no supported control for that host-drawn highlight was found. See the [cursor evidence and limits](docs/workflow-extension-prototype.md#frontend30-cursor-refresh-across-operation-states) and [toolbar limitation](docs/workflow-extension-prototype.md#frontend28-extension-pointer-artwork-and-toolbar-opacity-limit).

Installed worker **78** passed native Analyze → Apply: **19 XML cuts produced 20 source clips**, using **one Copy, one bulk effect transfer and zero native range deletions**. Helper Analyze took **5.067 s** and verified Apply **21.129 s** on the generated fixture. All exposed Gate and Legacy Limiter advanced controls match on **all 20 clips / 40 effect instances**, with both effects enabled and **−3 dB** volume throughout. **Verify Existing Result** passed in **5.973 s** without repeating import, Copy or Paste. **924 Swift tests** passed with three existing skips and zero failures; installed/built/ZIP worker bytes match and source media is unchanged. Programmatic command lookup is attempted first; this run used one menu fallback each for Copy and Paste Attributes because shortcut metadata was unusable. This is a scoped native pass, not a universal plugin or matched speed benchmark. See the [worker78 evidence and limits](docs/workflow-extension-prototype.md#worker78-bulk-xml-apply-and-guarded-native-effect-transfer).

**Matching effect settings does not establish sample-for-sample lossless output.** Explicitly authorized native exports of the actual original and cleaned result showed no attenuation in matched retained speech: active RMS differed by **+0.00000518 dB**, with identical peaks. A matched four-second phrase has identical PCM bytes; the full-length strict comparison still failed on small sample differences. The reported playback/monitoring experience remains unexplained; these exports do not identify its cause. The earlier advanced-control audit retains its fixture scope. See the [audio-level investigation and limits](docs/workflow-extension-prototype.md#worker78-scoped-audio-level-investigation).

Installed worker **77** passed **917 Swift tests** with three existing skips and zero failures; installed, built and packaged files match. Its native trial imported **19 XML cuts into 20 source clips**, with **one Copy and zero native range deletions**, then stopped at the Paste Attributes dialog **before Paste dispatch** because its own helper held foreground focus. The dialog was canceled without Paste, the partial effect-free result was retained, and the original was unchanged. Analyze took **5.254 s**; failed Apply took **15.893 s**, which excludes effect transfer and final verification and is not a speed result. See the [worker77 failure and limits](docs/workflow-extension-prototype.md#worker77-pinned-workspace-activation-and-comparison-framing).

Worker **76** retains bulk XML cuts and one native effect transfer, and fixes a focus handoff from the exact requesting Workflow window plus comparison of reordered native AU-state dictionaries. Its first native trial analyzed **19 cuts in 7.49 s**, then Apply stopped after **7.04 s** at post-render activation, **before Copy, XML import or Paste**; the original was unchanged. That trial did not establish successful Apply or a result advanced-control audit. The **911-test Swift suite** passed with three existing skips and zero failures, and the saved 20-clip worker75 result now matches its expected timeline, source ranges and serialized effects. Those saved-file checks do not prove settings omitted from XML, and the failed Apply time is not a throughput result. See the [worker76 evidence and limits](docs/workflow-extension-prototype.md#worker76-bulk-transfer-focus-and-effect-state-comparison).

Worker **75** introduced all cuts through **one XML import**, then **one native Copy and one effects-only Paste Attributes operation**, with no per-cut native deletions or project duplication. Its first installed trial produced **20 source clips from 19 XML cuts** and one bulk Paste, then stopped at semantic verification because equivalent AU-state dictionaries had different archive ordering. Advanced controls were checked on **12 of the 20 clips** before interruption; a complete advanced-effect audit was not finished. The supported scope remains static effects on one whole-project audio clip in Remove Silence mode, up to **8,192 cuts**; unsupported animation/layouts stop without a direct-cut fallback. The **901-test Swift run** passed with three existing skips and zero failures. No worker75 verified-Apply timing or universal preservation claim follows. See the [bulk XML implementation and verification limits](docs/workflow-extension-prototype.md#worker75-bulk-xml-cuts-and-a-single-native-effect-transfer).

Worker **73** / frontend **27** passed native Apply starting with the library selected: one **39-frame cut** reduced a generated **12-second** clip to **10.7 seconds**, retaining two original-source clips. **Verify Existing Result** then passed without repeating cuts or import, leaving the completed journal unchanged. The engine returns only its own helper's focus handoff, keeps strict host checks, and uses verified advertised range shortcuts. Both clips retained enabled, editable Limiter controls and **−3 dB** volume; worker73 did not repeat worker71's advanced private-effect audit. The **871-test suite** passed before the final range change, and **84 focused checks** passed after it. See the [worker73 evidence and limits](docs/workflow-extension-prototype.md#worker-73-owned-focus-handoffs-and-native-range-readiness).

Worker **72** / Workflow frontend **27** introduced exact source-event selection when Final Cut leaves its library selected, and native-result journal/status completion before reporting successful verification. Its package bytes, signatures and app identities passed checks. A native library-selected trial passed exact-event selection and duplicate identity checks, then a focus guard stopped it **before any deletion**. Full worker72 Apply and live verification retry were not completed; that earlier trial's focus-loss cause remains undiagnosed. The **854-test Swift suite** and **11 focused checks** passed. These fixes remain in worker73. See the [worker72 evidence and limits](docs/workflow-extension-prototype.md#worker-72-exact-source-event-selection-and-retry-finalization).

The recorded worker **71** / Workflow frontend **27** proof preserved audio effects through guarded native project duplication and range cuts for a single whole-project audio clip in **Remove Silence** mode. Every applied audio filter, including third-party and bypassed effects, requires native preservation; unsupported layouts/output modes stop rather than reconstructing effects from incomplete XML. Effects analyses always obtain fresh measurements. Its live **19-cut / 20-clip** result kept the full **Noise Gate → Legacy Limiter** chain: both effects’ advanced controls matched the source on **all 20 clips**, and the raw source remained unchanged. **843 Swift tests** passed (three existing skips). Native Apply took **125.840 s** on this 60-second fixture; this correctness route is slower than XML reconstruction. That advanced-control proof remains separate from worker73's smaller regression above. See the [correction, checks and limits](docs/workflow-extension-prototype.md#native-audio-effect-preservation-correction). Worker69’s earlier XML-only checks did not prove advanced effect-state preservation; existing affected results should be regenerated from their original native project.

Historical worker **68** added guarded direct Accessibility Share for eligible original-project Apply exchanges, reused freshly hashed source evidence only within the same protected Apply phase, and exposed detailed result-verification timings. On the generated five-minute Noise Gate → Limiter fixture, three runs per build reduced median verified Apply **16.503 → 15.548 s**, saving **0.956 s (5.8%)**. Fresh rendering, final source/XML checks, one import attempt and strict result verification remained. The captured full-mix PCM matched exactly across builds; this scoped, sequential comparison did not rerender the shortened result and does not measure worker69's editable output. See the [Apply implementation and validation scope](docs/workflow-extension-prototype.md#worker-68-guarded-apply-dispatch-and-phase-local-source-validation).

Workflow frontend **26** adds clearer visual hierarchy: distinct headings, quieter field labels, tabular timing values, alternating review rows, and an accent on the available primary action. The installed welcome window and native analysis, automatic updates and review controls passed scoped checks. Native controls and timestamp-only scrolling remain. See the [styling and native checks](docs/workflow-extension-prototype.md#frontend-26-clearer-visual-hierarchy).

Worker **67** / Workflow frontend **25** replaces the **Update Cuts** button with automatic range updates. After analysis, valid detection or output edits refresh eligible ranges after a **250 ms pause**, using retained measurements of the last analyzed audio, including its captured volume and effects. Editing, Return and **Save Settings** do not start a fresh analysis or export. **Analyze Again** is still required after volume, effects, media or timeline changes; **Apply Cuts** remains manual and verified. Native typing checks passed on plain audio and Gate→Limiter fixtures with no new Share or Analyze requests; see the [automatic-update checks and limits](docs/workflow-extension-prototype.md#worker-67--frontend-25-automatic-retained-audio-range-updates).

Worker **66** reuses freshly checked Share-menu paths and enables the direct Accessibility action for eligible Workflow Analyze requests. In three warm repeats on each generated 60-second fixture, median helper Analyze fell **3.76 → 3.18 s** for plain audio and **5.44 → 4.63 s** for Gate→Limiter (**about 15% less time**). Audio-effects rendering, source checks and verified Apply remain intact. The Swift suite completed **760 tests**, with three existing skips and zero failures, and both plain/processed native results preserved every retained PCM frame exactly. These scoped timings exclude startup, review and Apply; first analyses did not establish a speedup. See the [Share speed and quality checks](docs/workflow-extension-prototype.md#worker-66-share-invocation-speed-with-unchanged-audio-verification).

Worker **64** includes a **disabled-by-default diagnostic** for invoking Share directly through the closed menu item's advertised Accessibility action. Five native analyses completed, including Gate→Limiter; three repeat effects runs had a **4.69 s** median versus **5.24 s** through the normal route on the same installed build. This small, grouped comparison establishes feasibility on the tested host, not general compatibility or Apply behavior. Worker64's ordinary route retained worker63's invocation. See the [direct-action experiment and limits](docs/workflow-extension-prototype.md#worker-64-closed-menu-accessibility-probe).

Worker **63** combines fresh audio/XML capture for eligible repeat effects analyses and reduces repeated Share/import scans and focus changes. On the same 60-second Gate→Limiter fixture, repeat Analyze fell from **8.27 to 5.42 s** of helper time (**34% less time**); plain Analyze and overall Apply showed no material improvement. Native Apply, exact retained PCM and restart capture passed; the Swift suite completed **718 tests**, with three existing skips and zero failures. See the [timings and verification scope](docs/workflow-extension-prototype.md#worker-63-combined-workflow-capture-and-native-exchange-scans).

Worker **61** fixes preview flicker while moving across a clip and clears the overlay immediately when switching apps. Returning to Final Cut restores the same review from fresh geometry. Both behaviors passed the user's native check; the Swift suite completed **693 tests** with three existing skips and zero failures. See the [hover and app-switch verification](docs/workflow-extension-prototype.md#worker-61-immediate-app-switch-clearing).

Worker **57** refines the timeline preview with crisp round dots, small direction brackets, faint removal-range shading and compact numbered badges that avoid collisions. Standard/Retina rendering and native fitted/zoomed previews passed the [preview checks](docs/workflow-extension-prototype.md#worker-57-refined-timeline-preview).

Worker **56** speeds up review-window discovery and restoration. On the same disposable 60-second fixture, three warm Analyze runs had a median helper time of **3.08 s**, down from **5.48 s** (44% less time). Project, selection, focus and gesture checks remain; native Update, navigation and verified Apply passed. See the [scan timing evidence and limits](docs/workflow-extension-prototype.md#worker-56-faster-review-window-scans).

Worker **65** / Workflow frontend **22** standardize interface wording, action names and capitalization, and remove the ellipsis from **Verify Existing Result**. See the [copy and compatibility checks](docs/workflow-extension-prototype.md#worker-65--frontend-22-consistent-interface-wording).

Workflow frontend **21** keeps the main content stationary: only analyzed timestamp rows scroll. The list uses the remaining window height, with a higher minimum height to keep controls visible. Native Analyze and list-only scrolling passed. See the [fixed-body checks](docs/workflow-extension-prototype.md#frontend-21-timestamp-only-scrolling).

Workflow frontend **20** aligns the header, settings, review and footer to matching edges and padding, including scrollbar gutters. See the [uniform-edge checks](docs/workflow-extension-prototype.md#frontend-20-uniform-section-edges).

Workflow frontend **19** puts Output, its selector, Save Settings and Verify Existing Result on one horizontal row when the full choices fit, retaining the narrow-window fallback. Both output modes were checked in Final Cut. Frontend **18** introduced the charcoal sections, compact native controls and muted header. See the [output-row verification](docs/workflow-extension-prototype.md#frontend-19-single-output-action-row).

Worker **55** / Workflow frontend **17** introduced the three remaining review features: **Update Cuts**, **Go to Cut**, and **Verify Existing Result…**. Detection and output settings persist per project. The default package contains the worker and Workflow frontend, with no Silent Snip Audio effect embedded. Current implementation and verification status are recorded in the [Workflow Extension report](docs/workflow-extension-prototype.md); the three features passed scoped native tests, including a verified 44.6-second result, restart recovery, and an AU-free installed smoke run.

Automatic range updates reuse retained measurements for eligible source-audio or verified direct-render clips. Other layouts require **Analyze Again** after detection or output changes. **Go to Cut** moves the playhead without another Share. **Verify Existing Result** resumes checks after a restart without importing the result again or requiring a detector on a clip. Changing clip volume, effects, source media, or timeline content requires a fresh analysis: use **Analyze Again** when a review is open, or **Analyze Audio** when starting a new review.

Historical frontend-8 / worker-53 removal and gap runs placed processed PCM directly in the **audio-only primary storyline**. All **2,865,600 retained frames** matched their captured mix exactly; gap mode added **48,000 positive-zero frames**. That layout applied when no video occurred anywhere in the timeline, including disabled or connected video; video kept its existing primary storyline. These fixture results do not establish worker69's editable output, every effect's compatibility or the three-second throughput target. Later frontend-14 through frontend-16 UI checks are versioned separately in the report.

Historical builds 40–68 prioritized identical retained rendered samples: Apply captured the complete native project mix, including connected Music, Effects and custom roles, and cut that continuous lossless PCM instead of restarting live effects at each join. Original video edits stayed in the cleaned project. The original kept its editable audio effects; the cleaned copy used rendered sound. Those saved results and their verification remain supported. Worker69 changes new output to editable source clips; stateful effects can respond at new boundaries as they do after manual cuts, so the historical exact-PCM-after-joins promise does not apply.

> **Historical build 47, Audio Unit 29 verification:** built, installed, and ZIP executable hashes matched; deep signature checks passed. The sound-preserving architecture introduced in build 40 passed native writer PCM, project/source, and durable-media identity checks for generated full-mix, camera/music, custom-role, and fractional-frame-rate fixtures.
>
> **Build 47's five-minute camera flow passed native Analyze → review → Apply without a manual verification retry.** Request `4A294C26` created 60 cuts, reducing 300 seconds to 191.5 seconds, passed strict project/source verification, and preserved all 9,192,000 retained stereo PCM frames exactly against its captured native mix. Helper processing took **9.41 seconds for Analyze plus 19.52 seconds for verified Apply: 28.93 seconds total**, excluding review, startup, frontend latency, and optional navigation. This is not a complete UI stopwatch measurement. The three-second target remains unmet. See [current evidence and limits](docs/workflow-throughput.md#build-47-guard-apply-source-validation-and-new-processed-media).

> **Voice-over milestone verified:** Analyze → Apply created and opened separate editable projects in Final Cut Pro 12.4 for plain narration, narration with Noise Gate and Limiter, and one-second-gap output. Original projects and source media were preserved. See [milestone evidence and limits](docs/voiceover-project.md).

Earlier general-project builds added linked camera clips, full-project copies, a guarded direct-render path, overlapping source validation, and viewport-based preview drawing. Their native Analyze → Apply passes and 64–69% lower fresh-reanalysis timing against the recorded audio baseline are historical results, with a different editable-effects output route. See [those verification notes](docs/general-project-performance.md).

The historical audio-effect manual review update added **Update Cuts** from retained audio and **Go to Cut** without another Share. Nine native setting updates took 82–124 ms in the helper (94 ms median); fresh audio analysis remains separate and Apply verifies current audio. See [timings and verification limits](docs/general-project-performance.md#manual-review-without-repeated-share).

Builds 37–39 improved source decoding, validation overlap, and guarded native menu readiness. Their five-minute runs took about 19–23 seconds of helper Analyze plus verified Apply time using the earlier editable-effects output. On the same 652 MB linked-camera fixture, build 46 took 34.39 seconds and build 47 took 28.93 seconds. Build 45's 29.72-second small audio-only run is a separate workload. The three-second target remains unmet; individual host runs do not establish a general speedup. The [workflow throughput report](docs/workflow-throughput.md) separates these measurements and their verification boundaries.

## How it works

The Workflow window uses the background worker, Share destination and verified XML Apply path. The steps below describe worker69's editable output; scoped native checks are recorded in the linked report.

1. Select one normal-speed clip with audio in the primary storyline and open **Window → Extensions → Silent Snip**.
2. Adjust silence detection and output, then click **Analyze Audio**.
3. Review the proposed cuts and choose which to include. Valid detection or output changes automatically refresh eligible ranges after a 250 ms pause; selection, navigation and Apply wait for the newest acknowledged result. Use **Go to Cut** to inspect a boundary. Use **Analyze Again** when a fresh analysis is required, including after changing volume, effects, source media, or timeline content.
4. Click **Apply Cuts** to capture the current native audio for verification, check the reviewed cuts, and create a cleaned copy in the original event. Retained clips reference their original media and keep their audio effects, volume and supported automation. Linked video and supported connections follow the same cuts.

The original project and source media stay unchanged. Silent Snip also saves the original project's recovery XML before importing the result.

Continue editing audio effects in the cleaned copy. Analyze again before making further Silent Snip cuts after changing audio or timeline content. Detection settings are saved with the result; the Workflow route needs no Silent Snip effect on the recording. Unmodified source files and preserved effect settings do not imply identical rendered samples across new cuts: delays and other stateful effects can react to those boundaries as with manual edits.

Final Cut's native Share panels remain visible during automation; no window covers them. Keep Final Cut in front while Silent Snip operates it. Detection settings and output are saved per project in the Workflow frontend, keyed by library and project identity.

See the [full workflow and recovery guide](docs/workflow.md) for detection settings, preview controls, and recovery steps.

See [review and verification fixes](docs/review-safety-fixes.md) for timeout handling,
reconnection, and source-integrity checks, including limits for older saved results.

## What it supports

- **Two output modes:** remove selected pauses or replace them with one-second gaps.
- **Review before applying:** per-cut selection and a timeline preview.
- **Audio processing:** measure source audio for unprocessed clips or a verified Final Cut render for processed clips.
- **Editable output:** new worker69 results retain original media references, editable audio effects, linked video and supported connections, with recovery XML. Unsupported edits or unverifiable effects, sources or delivery stop the operation. Native audio-only removal and gap fixtures passed; broader layouts retain their separately scoped evidence.
- **Manual analysis and Apply:** start with **Analyze Audio**, review the ranges, then click **Apply Cuts**. Eligible detection/output edits update the ranges automatically from the last analyzed audio; stale cut actions stay disabled until the latest update is acknowledged. Fresh audio changes require **Analyze Again**.

Detection uses loudness, so quiet breaths can qualify as silence. It does not recognize speech or breaths.

Targets must be normal-speed direct asset clips with enabled audio in the primary storyline. Linked video and audio are cut together. Retimed or nested targets, split A/V edits, component trims, unsupported connections, and cuts crossing fades remain outside scope. Detection retains its shared frame/audio boundary checks; output edits reference original source intervals. See [compatibility details](docs/workflow.md#2-select-the-audio-clip) and [analysis behavior](docs/analysis-speed.md).

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
3. **Open both apps once.** Silent Snip runs in the background without a Dock or menu bar icon. The Workflow frontend shows instructions; choose **Done**.
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

Cache cleanup runs automatically; there is no menu bar cleanup command. **Recovery XML, saved results, settings, Final Cut libraries, original media, and manual Share exports are preserved.** Unknown or older unregistered files are kept. Recovery and result history can therefore continue to grow until you remove it yourself. See [storage and cleanup details](docs/storage-cleanup.md).

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

Historical worker **55** / frontend **17** introduced the three review features and AU-free pair packaging. Those features passed scoped native validation; see the [versioned evidence record](docs/workflow-extension-prototype.md) for current status. The results below belong to their named historical revisions.

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
