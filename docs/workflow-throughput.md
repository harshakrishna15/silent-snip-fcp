# Workflow throughput and audio preservation

## November 9 analysis and navigation candidate

The installed worker 78 completed two analyses on the same disposable 24-second Noise Gate → Limiter clip in the workspace's **Cutdown Integration.fcpbundle**. Separate XML and audio exchanges took **7.004 s** and **7.134 s**. Two more analyses using the existing combined exchange took **6.031 s** and **4.299 s**. All four reviews found the same six cuts. The separate XML exchange accounted for **2.231–2.610 s**. The runs were sequential, with different host activation conditions. They measure the installed worker and establish the cost of the exchange this candidate can skip more often.

The baseline Apply verified seven retained source clips and took **21.538 s**, including **0.732 s** reopening the result for verification. Baseline Go to Cut took **1.892 s**, moved the actual playhead to **00:00:08:09**, and preserved clip selection. The other disposable project hit a menu failure twice before render dispatch. Generated source bytes and file identity matched the pretest record. Timing, XML, and result receipts are in `build/AnalysisLatency/Baseline`.

The candidate keeps up to eight exact routing hints, wakes on rendered Share delivery, skips redundant browser work during bulk Apply, and uses the Workflow SDK for Go to Cut when both components support it. Host Swift tests and the offscreen Workflow harnesses passed. Candidate latency, the native menu recovery, and SDK playhead movement still need a live run with an isolated or explicitly approved test setup.

On the generated 652 MB camera fixture, an offline Release benchmark timed the source checks after a combined export. Five trials per route alternated the check order. The median fell from **1.025 s** for two full scans to **0.602 s** for one full scan plus the identity and mutation check. Both routes started with the full hash that Analyze obtains during Share and finished with a full content check. The benchmark excludes host rendering, audio measurement, and their overlap. `SILENT_SNIP_BENCHMARK_SOURCE_MEDIA` enables this comparison in `AnalysisPerformanceTests`; the raw results are in `build/AnalysisLatency/Offline-Combined-Source-Release.json`.

## Worker 71: native effect-preserving cuts

Worker71/frontend27 completed a fresh Analyze → review → Apply on generated 60-second audio in workspace-root **Cutdown Integration.fcpbundle**. **19 cuts** produced **20 original-source clips / 35.300 s**. Both advanced **Noise Gate → Legacy Limiter** editors matched the source on every retained clip; volume remained **−3 dB**. Raw source bytes, identity and mutation stamps, fresh native audio, exact source intervals and native result UID passed. Every rendering filter now requires native preservation and fresh measurements; unsupported layouts/output modes stop.

Helper Analyze was **6.991 s**, verified Apply **125.840 s**. This single scoped run demonstrates correctness and is materially slower than XML reconstruction; it is not a speedup benchmark or a shortened-result PCM comparison. The native route currently supports one whole-project primary audio clip and Remove Silence. The full suite passed **843 tests** (three existing skips). See the [native settings audit and limitations](workflow-extension-prototype.md#native-audio-effect-preservation-correction), with evidence under `build/NativeEffects71/Run1`.

## Worker 69: editable-output native checks

**Correction:** These historical checks proved exported XML state and the outer Amount control only. They missed the advanced Limiter reset confirmed by the user. Worker71’s separate native-instance and advanced-editor proof above supersedes any broader effect-fidelity interpretation.

November 7, 2026. Installed worker69/frontend27 creates editable source clips and effect chains rather than retained intervals from a substituted full-mix WAV. Native tests used generated 60-second mono 48 kHz / 16-bit media referenced in place in **Disposable Editable Effects 69 187CE69C**, workspace-root **Cutdown Integration.fcpbundle**, with **Noise Gate → Limiter / −3 dB**.

| Native request | Verification outcome | Result | Helper timing |
| --- | --- | --- | ---: |
| Remove Run1 / `2E48004B` | Initial post-import focus guard stopped; explicit read-only Retry verified existing result without reimport | 19 source clips / 44.6 s | Retry only: 3.693 s; no automatic Apply total |
| Remove Run2 / `55A31FF7` | Fresh Analyze → Apply verified automatically | 19 source clips / 44.6 s | Apply: 13.067 s |
| Gaps Run1 / `5C8317BE` | Fresh Analyze → Apply verified automatically | 19 source clips + 18 one-second gaps / 62.6 s | Apply: 13.920 s |

Each result retained exact native-before effect order, parameter/archive data and **−3 dB** on all 19 source segments, with strict source/import checks and no substituted result audio. An independent read-only audit verified all **57 source slices**, effect/filter data, volume, source mappings and native result identities. An Inspector **Limiter Amount 5 → 7 → 5** edit confirmed editability on the first removal result. Fresh native verification audio matched each request's analyzed evidence, but no shortened-result render or listening comparison was performed. Source bytes, identity, size and modification time stayed unchanged; a pre-Apply first-Analyze ctime-only update was separately recorded with production guards unchanged.

These are scoped smoke samples, excluding startup, manual review and frontend latency, without a matched baseline or benchmark claim. Stateful effects can respond to new boundaries as after manual cuts. Historical processed-output PCM proofs and worker68's **5.8% fixture Apply saving** below are not measurements or exact-sample guarantees for worker69. Final source hashes/identities/stamps passed against the recorded baselines; exact routing-hint bytes and original host/settings state were restored. The disposable event went to Trash with external media left in place and the user's existing result preserved. Evidence is under `build/Editable69/{Native69,Initial-Apply-Failure,Native-Effect-Edit.json,First-Analyze-Source-Metadata.json,Independent-Native-Audit.json,Source-Preservation.json,Cache-Restoration.json,Restoration.json}`. See the [implementation and full validation limits](workflow-extension-prototype.md#worker-69--frontend-27-editable-audio-cuts-and-operation-stability).

## Worker 68: guarded Apply fixture comparison

November 7, 2026. Installed worker68/frontend26 passed native verified Apply on generated 300-second media referenced in place in disposable projects inside workspace-root **Cutdown Integration.fcpbundle**. Settings were **-40 dBFS / 0.3 s minimum / 0.1 s before / 0.1 s after / Remove Silence**. Effects were **Noise Gate → Limiter**. Original-project Apply Share exchanges used guarded direct Accessibility actions, and retention reused current guarded source hashes while separately hashing the new durable PCM. Fresh native rendering, final full source validation before the last XML exchange, single import and strict result verification remain.

| Build / fixture | Runs | Median verified Apply | Range |
| --- | ---: | ---: | ---: |
| Worker67 / Effects | 3 | 16.503 s | 16.240–18.168 s |
| Worker68 / Effects | 3 | 15.548 s | 14.968–15.765 s |
| Worker68 / Plain | 1 | 15.054 s | Single run |

The Effects median fell **0.956 s (5.8%)**. Runs were grouped sequentially, three baseline then three candidate, without randomization. No plain baseline was recorded. Totals cover helper Apply through native import verification and exclude startup, manual review and frontend notification latency. These fixture results do not establish a general speed guarantee or complete UI stopwatch timing, and the three-second complete-flow target remains unmet.

Candidate Effects result verification had a **7.295 s median**, with session discovery **1.822 s**, imported-project opening **1.994 s**, Share **3.149 s** and source snapshot **0.180 s**. Concurrent media validation overlaps capture, and nested details and stage medians must not be summed. All candidates recorded phase-local source-hash reuse; each original-project exchange made one successful direct attempt with an owned panel and no fallback. Result verification used its ordinary route, one capture and one media-validation pass, with no recovery write or ctime restart.

All seven results passed exact **90-cut / 77-second removal / 223-second result** and native import/source checks. Independent reads verified all archived full native mixes' encoded, PCM and format hashes and media identities. All nine cross-build Effects pairs matched PCM/format exactly; all six Effects Analyze/Apply pairs matched fresh native encoded audio. Plain Analyze used source-backed audio. **The shortened imported result was not independently exported or rerendered**; captured-mix equality and structural result verification do not establish universal effect compatibility or listening quality.

All **797 Swift tests executed, three existing skips, zero failures**. Installed/ZIP signatures, pairing and every-file comparison passed; final package audit passed all **20 checks**. Source preservation passed against the post-initial-import baseline, with the initial ctime-only import change separately recorded and no source-byte change. Prior routing hints, host state and settings were restored; the disposable event went to Trash with external media left in place. Evidence is in `build/Apply68/{Benchmark-Summary.json,Benchmark-Summary.md,Native-Observations.json,Final-Package-Audit.json,Source-Preservation.json,Cache-Restoration.json,Restoration.json}`. See the [implementation and full validation scope](workflow-extension-prototype.md#worker-68-guarded-apply-dispatch-and-phase-local-source-validation). Historical results below retain their original scope.

November 4, 2026. The current target is approximately **three seconds of total processing for five minutes of raw clip audio** (100× real time). The three-second target is **not achieved**. Historical build 47 completed a five-minute, 652 MB linked-camera fixture in **28.93 seconds of helper Analyze plus verified Apply time**, without a manual verification retry; build 46 took 34.39 seconds on the same fixture. This excludes human review, startup, frontend latency, and optional navigation; complete UI stopwatch timing is not established. Build 45 completed a separate small audio-only fixture in 29.72 seconds; the prior build 43 sound-preserving audio run took 34.38 seconds. Recorded build 37–39 five-minute helper flows took about **19–23 seconds** with the earlier editable-effects output route and remain separate historical measurements. Individual host runs and workloads vary; these samples do not establish a general improvement percentage.

The architecture introduced in build 40 changes Apply to retain the continuous native full-project mix, prioritizing identical retained sound after a stateful delay test exposed a real join difference. Its **compiled production writer** has passed native PCM and strict imported-project/source checks for the fixtures below. **Build 47 with Audio Unit 29 passed its recorded packaging/deep-signature checks**. Recorded worker 53 / Workflow frontend 8 retain Audio Unit 29 unchanged and pass primary-PCM removal/gap, packaging/preservation, and scoped native PCM checks. Earlier worker 52 / 51 flows remain separately versioned below. Build 47’s five-minute linked-camera Gate → Limiter fixture completed the native **Analyze → review → Apply** button flow without a manual verification retry, passed strict project/source checks, and matched every retained PCM frame against its captured mix. Build 45's small audio-only fixture separately passed exact retained PCM. Build 42's custom-role and five-minute results passed only after separate manual read-only retries. These fixture results do not establish complete UI throughput, universal plugin fidelity, or equality to higher-precision live-engine audio.

Frontend **13** passed compact empty/one-cut/18-cut review checks and verified Apply to a generated **44.6-second** result (`11D724B6`). The no-effects/cache-eligible one-minute fixture is UI evidence, with no new PCM comparison or throughput claim. The chosen outer size did not persist after restart; fixed/default host sizing and a resize lock were not achieved through the public SDK. Worker **53**, AU29, and the ZIP are unchanged, with no new processing, PCM, or speed claim.

Historical frontend **11** changed only the compact settings/review window. Its generated no-effects 60-second, 18-cut fixture passed native selection/scrolling/Details and Apply verification, opening a **44.6-second** result with **19 primary PCM clips and no gaps** (`25D5A3D7`). Helper Analyze **5.6645 s** + Apply **12.5260 s** totaled **18.1905 s**. This is UI smoke timing, not a throughput benchmark or new PCM export/comparison. Worker **53**, AU29, and the ZIP are unchanged; the frontend-8/worker-53 fidelity timings below retain their original scope. Native narrow resizing, keyboard/VoiceOver and error/recovery checks were not exercised; offscreen geometry checks are separate. `Native11.json`, receipts, package/install records, and the 16-check preservation pass are under `build/WorkflowPrototype/Window11`. Frontend 10’s earlier smoke request `11438CAF` and **33.2017-second helper** timing remain historical under `build/WorkflowPrototype/Window10`.

## Installed worker 53: audio-only primary PCM

Fresh audio-only Apply results now put retained PCM directly in the primary storyline, with real primary pacing gaps in gap mode. Any video occurrence, including disabled or connected video, retains the existing video-primary path. Originals/live effects and prior results are preserved. These audio proofs used frontend 8 and AU29; the frontend-10 UI update leaves worker 53, AU29, and the worker ZIP unchanged. Worker 53 passed **645 Swift tests** (three existing opt-in skips, zero failures) and **120 Python tests**.

Both generated 60-second effects/connected-role runs passed native import and export topology checks with **two direct primary PCM clips and zero connected PCM**. Removal (`EA77C09E`) yielded 59.7 seconds with no gaps; gap output (`62BC31C0`) yielded 60.7 seconds with one real one-second gap. Native stereo 24-bit/48 kHz exports matched every **2,865,600 retained frames** exactly; the gap result additionally matched **48,000 positive-zero frames**, totaling **2,913,600 frames**. The note remains on both PCM clips, and the marker maps to 0.7 seconds in removal / 1.7 seconds with the gap. Fresh post-both-Apply original XML matches initial/pre-import captures except regenerated media bookmarks; source/durable hashes and every identity/mutation stamp match independently.

| Mode | Analyze | Verified Apply | Total helper processing | Scaled target |
| --- | ---: | ---: | ---: | ---: |
| Remove | 13.3944 s | 20.4758 s | **33.8701 s** | 0.6 s for 60 s raw |
| Gaps | 12.9737 s | 20.3002 s | **33.2739 s** | 0.6 s for 60 s raw |

These helper phases exclude frontend/startup latency and human review; the three-second-per-five-minute goal remains unmet. No general speedup, cross-render determinism, or universal plugin compatibility is established. Evidence is under `build/PrimaryStoryline53/Native-{Remove-EA77C09E,Gaps-62BC31C0}`; post-export `After-Final-Native53-Preservation.json` passed installed/ZIP hashes, unchanged frontend 8 / AU29, app-directory identity, deep signatures, AU registration, and accessible setup-file preservation. Protected preferences were not retried; selected/default preference equality remains unverified.

## Historical Workflow frontend 8 / worker 52

The final installed hosted flow (`D2DCF0E7`) passed native Analyze → review → Apply on the 60-second **Gate → Limiter → AUDelay → Silent Snip Audio** project with connected Music/custom Room Tone. Settings were **-45 dBFS / 0.3 s minimum / 0.1 s before / 0.1 s after / Remove Silence**. One **0.3-second** removal yielded **59.7 seconds**; all **2,865,600 native stereo 24-bit/48 kHz frames** exactly matched this request's captured mix. An independent **30-check** audit verified the original's initial/pre-import/post-Apply XML, effects/connections/roles, bare detector, source/durable hashes and stamps, retained mappings, and disabled original audio. Only regenerated source bookmarks were excluded from original XML equality. The imported source's detector was already bare, so native nondefault detector-state preservation is not established.

| Analyze | Verified Apply | Total helper processing | Scaled target |
| ---: | ---: | ---: | ---: |
| 14.6973 s | 19.7392 s | **34.4365 s** | 0.6 s for 60 s raw |

This is helper phase timing, excluding frontend/startup latency and human review; no full UI stopwatch, cross-render determinism, general speedup, or universal plugin certification is claimed. The three-second-per-five-minute target is unmet. Evidence is under `build/WorkflowPrototype/Milestone2/Native52-Effects-Remove`; final post-export package/registration/setup-file preservation passed in `After-Final-Native8-Worker52-Preservation.json`. Earlier version-51 measurements below remain distinct native runs.

## Workflow frontend 7 / worker 51: hosted native flows

The hosted **Analyze → review → Apply** flow passed in the required `Cutdown Integration.fcpbundle` for a generated 300-second linked-camera **Gate → Limiter** project with no Silent Snip detector. Request `5A7F8E8E` acknowledged individual cut selection and Select All, then created a verified **263.166667-second** result with **53 one-second gaps**. Its native 24-bit stereo 48 kHz export matched all **12,632,000 output frames** exactly: **10,088,000 retained frames** plus **2,544,000 positive-zero gap frames**. Strict XML/source/mix-mapping checks passed; source and durable-media hashes and stamps were unchanged. Original XML was compared through final pre-import capture, with no separate post-Apply original-project export. This proves the supplied result against its captured mix, not cross-render determinism or universal plugin compatibility.

| Fixture | Analyze | Verified Apply | Total helper processing | Current target |
| --- | ---: | ---: | ---: | ---: |
| Five-minute Gate → Limiter, no detector, gap output | 16.7816 s | 20.3119 s | **37.0935 s** | 3 s |
| One-minute Gate → Limiter → AUDelay/detector + connected roles, removal | 13.6420 s | 20.5065 s | **34.1485 s** | 0.6 s scaled |

These helper phases exclude frontend/startup latency and human review; complete button-to-finish UI timing was not measured. Different detection settings and gap output make this a separate workload from build 47's removal fixture. No general speedup is claimed. The three-second target remains unmet.

The **Gate → Limiter → AUDelay + Silent Snip Audio + connected Music/custom Room Tone** companion (`C9F23DBB`) also completed in frontend 7 / worker 51. Removing one 0.3-second range from 60 seconds produced a verified 59.7-second result; all **2,865,600 native 24-bit stereo 48 kHz output frames** matched the captured full mix exactly. A 29-check independent audit compared the original before analysis, before import, and after Apply: project/sequence/effects/connections and the native bare detector were unchanged except regenerated media bookmark text, while source and durable hashes/stamps matched. Final Cut had stripped the generator’s nondefault detector state before analysis; native nondefault-state preservation is not established. Separate target-render verification matched the reviewed range; the output uses the full connected-role mix.

Evidence is under `build/WorkflowPrototype/Milestone2/{Native-B-NoAU-Gaps,Native-Effects-Remove}`. These are explicitly version-51 results. See the [Workflow frontend report](workflow-extension-prototype.md#milestone-2-checkpoint) for automated checks, installation/preservation evidence, and native limits.

## Historical build 37 measurements

Apple M1, 16 GiB RAM; macOS 27.2 (26B123), Final Cut Pro 12.4. All tests used disposable projects in the required workspace library, referencing generated sources in place. Fixtures are looped generated narration, 48 kHz mono lossless ALAC, with native default Noise Gate/Limiter and stereo project output. These are normal-session fresh analyses, not a diverse real-world recording or a cold-boot benchmark. `GL` means Gate → Limiter → Silent Snip; `LG` means Limiter → Gate → Silent Snip.

The recorded historical reports used an earlier one-second-per-minute budget. Their target columns below retain that historical budget; current reports use three seconds per five minutes.

| Build / order | Raw duration | Analyze | Verified Apply | Total helper processing | Historical target |
| --- | ---: | ---: | ---: | ---: | ---: |
| 36 / GL baseline | 1 min | 10.07 s | 7.47 s | 17.54 s | 1 s |
| 37 / GL | 1 min | 8.84 s | 8.61 s | 17.45 s | 1 s |
| 37 / LG | 1 min | 8.69 s | 9.51 s | 18.20 s | 1 s |
| 37 / GL | 5 min | 11.47 s | 9.41 s | 20.88 s | 5 s |
| 37 / LG | 5 min | 9.52 s | 9.77 s | 19.30 s | 5 s |
| 36 / GL baseline | 60 min | 27.14 s | 15.55 s | 42.69 s | 60 s |
| 37 / GL | 60 min | 28.81 s | 16.75 s | 45.56 s | 60 s |
| 37 / LG | 60 min | 27.38 s | 18.96 s | 46.34 s | 60 s |

Totals include render/export, detection, generation/import, verification, and helper cleanup. They exclude startup, frontend notification latency, optional review/navigation, and human review. An observed full-UI upper bound for the updated GL hour run was 64.132 seconds after excluding the review interval; it includes observer scheduling delay. It does not prove a precise sub-60-second UI workflow. Native Share/render/import overhead dominates short clips. The one-minute before/after totals are effectively equal; the hour run was slower after the update, with host render/import variation dominating. No improvement percentage is warranted from these samples.

Both hour runs opened fully verified copies (717 GL cuts, 861 LG cuts); the GL hour cut ranges/duration matched build 36 exactly. Native one-minute original/repeat/cleaned WAV exports passed **exact decoded PCM equality in both effect orders**, including every retained sample and join. GL baseline and updated cleaned PCM hashes also match. This proof covers those default chains/fixtures only; arbitrary plugins, non-default settings, effect tails, and nondeterministic processing are not universally certified.

The advertised-shortcut counter was zero in these native runs: this command set has no qualifying shortcut for Silent Snip. The new route therefore used the existing visible menus. The shortcut dispatch policy has automated coverage; a live shortcut speedup is not established and no user command set was changed.

Recorded build 37 validation: 484 Swift tests, one opt-in benchmark skipped in the full suite, no failures; 81 Python tests passed. The separate one-hour decoder benchmark also passed and remains a component-only result. That build's installed app and ZIP helper executable hashes matched; signature/packaging checks passed. Native evidence is retained under `build/Throughput`: `Performance-Summary.json`, each `Baseline36-*` / `Updated37-*` directory, `PCM/*Comparison.json`, `Reader37-60m.json`, `Package37.json`, and `Native-Checks.json`. All generated-source and template hashes stayed unchanged. The 32 automated Share jobs retained zero rendered WAVs after cleanup; native PCM comparison exports remain preserved as integration evidence.

## Historical build 39: observed menu readiness

Build 39's installed native tests replaced fixed submenu sleeps with bounded checks that the exact submenu is visible and the intended command is unique. A scrolling menu can expose a different visible child; the intended item still needs its own hit test before any coordinate input. Completed actions return immediately. A merely selected item retains the existing 200 ms grace before one activation, and uncertain dispatch never retries. Missing or empty aggregate selection metadata falls back to exactly one selected child; conflicting nonempty selection metadata stops. Import quiescence and semantic verification remain required.

Additional native runs used the same generated five-minute Gate → Limiter source and original disposable project in the required library:

| Build | Analyze | Verified Apply | Total helper processing | Historical target |
| --- | ---: | ---: | ---: | ---: |
| 37 before menu changes | 10.44 s | 10.68 s | 21.11 s | 5 s |
| 38 intermediate candidate | 11.41 s | 9.13 s | 20.54 s | 5 s |
| 39 final menu compatibility corrections | 13.83 s | 9.12 s | 22.95 s | 5 s |

All three created the same 60 cuts and 191.5-second editable result with verified source contents and preserved native processing effects. Recorded Share panel opening stages were shorter with the menu changes, but native rendering varied from 6.03 to 9.42 seconds. **No end-to-end speedup or completion within either the historical five-second budget or current three-second budget is established.** These totals retain the helper-only measurement boundary described above. Native UI review and the opened cleaned timeline were separately observed; observer scheduling was not used as an exact UI stopwatch. Evidence is under `build/Throughput/MenuLatency`, including each request's XML, timing, verification receipts, and imported result.

An additional generated one-minute Gate → Limiter → AUDelay → Silent Snip chain completed Analyze → explicit Update Cuts → Apply in build 39. The native delay editor showed a one-second delay, 50 percent feedback, and 50 percent wet mix. At a -35 dBFS detection threshold, Apply freshly rendered and verified three cuts, preserving the delay effect in the cleaned result. This establishes the tested chain's functional compatibility; its stateful processed-sample comparison remains separate from XML verification.

Recorded build 39 checks: 492 Swift tests with one opt-in benchmark skipped and no failures; 81 Python tests; 35 Controls harness groups; 60 exact mono/stereo Audio Unit passthrough cases. That build's built, installed, and ZIP helper executable hashes matched; deep signature checks passed. The processed-PCM comparisons in the build 37 table remain fixture-specific evidence, not a universal plugin certification.

## Stateful delay: measured quality limitation

The additional build 39 delay test exposed a real retained-audio difference. Two full original native renders had exactly matching decoded PCM hashes, so the observed original was deterministic. The normal editable three-cut result had the expected 2,833,600 stereo frames, but its second join at result time 27.766667 s differed: the original processed reference sample was -0.0173425674 and the cleaned sample was 0. This is consistent with lost effect history when the source clip is split; matching effect XML does not prevent it. The difference is in processed output, not a modification of original source media.

Two independent disposable output experiments used the exact same retained source ranges in the required library:

| Output representation | Exact retained PCM | First difference |
| --- | --- | --- |
| Normal split asset clips with live effects | Fail | 27.766667 s; expected -0.0173425674, actual 0 |
| One full processed compound source, cut through outer references | Fail | Same join; actual -0.0173296928 |
| Original native lossless processed WAV referenced in place, with no additional processing | Pass | None across all retained samples and joins |

All comparison inputs were native 24-bit stereo 48 kHz WAVs. The processed-WAV experiment preserved the sound of this tested native export, while the untouched original project retained its live editable effects. The captured default AUDelay XML contained its exact effect identity but no serialized parameters/archive; native PCM, not an inferred settings archive, supplied the sound evidence. These experiments motivated the build 40 output change below. The experiment alone did not validate the app's production button flow, universal plugin compatibility, or the throughput target.

Evidence remains under `build/Throughput/StatefulQuality`: `PCM/Split39-Deterministic-Comparison.json`, `PCM/Compound39-Comparison.json`, `PCM/Baked39-Comparison.json`, original/repeat/result native exports, and the independent experiment XML/manifests. Every fixture references generated sources in place; no existing user project or external library was used.

## Build 40: preserve the continuous native mix

The user chose identical retained sound over live effect instances in the cleaned copy. Build 40 implements that choice by rendering **the entire audible native project mix**, including connected Music, Effects, and custom roles, before creating cuts. It stores durable lossless PCM, removes only the selected project-time sample ranges, and disables every original audible source in the cleaned project to prevent doubled audio or a second DSP pass. Original video, its source ranges/transforms, and supported connected video edits remain in place. The original project, original source files, and recovery XML remain unchanged; edit live effects in the original project and Analyze again to make a new result. The cleaned copy contains the captured mix rather than editable sound-processing effects.

Manual control is unchanged: **Analyze Audio → review → Apply Cuts**. **Update Cuts** recalculates retained measurements only after its explicit click. Typing, Return, blur, Save Settings, and polling do not analyze or apply. Apply obtains fresh native project/audio evidence and checks that the reviewed candidates remain valid; a mixed project still needs a separate target/Dialogue check rather than treating Music as reviewed speech. A final fresh XML/settings baseline check follows durable-media hashing immediately before the once-only import, so a timeline/effect edit during file work must stop delivery.

The current native evidence uses the real compiled production writer, disposable projects, original media referenced in place, and native full-project WAV exports in the required library:

| Native writer fixture | Imported project/source verification | Exact retained native PCM | Original → cleaned stereo frames |
| --- | --- | --- | ---: |
| Linked camera AV + connected Music + connected video; Gate → Limiter → AUDelay | Pass | Pass | 720,000 → 648,000 |
| Dialogue + Music + custom `Room Tone` role | Pass | Pass | 2,880,000 → 2,833,600 |
| 29.97 fps, 1,796-frame project | Pass | Pass | 2,876,473 → 2,788,385 |
| 29.97 fps, 1,797-frame project | Pass | Pass | 2,878,075 → 2,789,987 |
| Full mix with final minimal container identity | Pass; intended new PCM URL | Pass | 2,880,000 → 2,833,600 |
| 29.97 fps, 1,797 frames with final minimal container identity | Pass; intended new PCM URL | Pass | 2,878,075 → 2,789,987 |

Every retained decoded sample and join matched the supplied uncut native reference with the declared cut samples omitted. These comparisons used native **24-bit stereo 48 kHz WAVs**, with no alignment shift, gain normalization, resampling, or tolerance matching. The later fixture comparisons do not include a repeated original export; the earlier stateful-delay original/repeat test established determinism only for that original fixture. This is exact equality at the native export's precision, not a universal bit-for-bit assertion about Final Cut's live floating-point engine, higher-precision source processing, arbitrary plugins, or every routing topology.

Two important native behaviors were tested rather than inferred from DTD-valid XML:

- Final Cut 12.4 dropped `srcEnable="video"` during camera import and made an intended video-only connection audible. The writer now explicitly disables **every known source audio channel**, preserves video processing, and fails if the complete channel count is unavailable. Native verification must prove those channels stay disabled; the connected Dialogue protection was retained.
- Final Cut can reuse an older equal-byte WAV asset and substitute its old media URL. The full-mix v2 fixture passed PCM equality but correctly **failed strict media-reference verification** for this substitution. A fresh XML asset UID did not prevent it. The final production helper now adds minimal non-audio container identity (`FILE_UID`, `PROJECT`, title, and UUID padding), and the full-mix and 1,797-frame native writer runs both passed strict verification at their intended new PCM URLs plus exact retained-sample comparison. Descriptive `NOTE`/comment fields were removed after the host imported them as unexpected clip notes; those differences were not normalized away. Container identity intentionally changes the encoded WAV/file hash while preserving its native `fmt` and PCM `data` payloads. Native-source, durable-file, format, and PCM hashes remain separate evidence; no encoded-byte identity claim is made for the decorated file. An unverified URL substitution is not accepted as success.

Audio cuts use a common video-frame/audio-sample grid. Continuous PCM spans cross visual primary boundaries without extra splits. At fractional frame rates, the physical native final sample count can be just below the logical project end: both tested 29.97 fps exports used the floor, including the case with a 0.6-sample remainder. Only that proved physical final tail is accepted; no sample is manufactured. A pacing gap that would place retained sound between audio samples stops explicitly rather than changing the requested gap or resampling the sound. The tested 48 kHz/29.97 fps one-second gap is aligned; an unaligned 44.1 kHz combination is not silently approximated.

**Verification boundary:** writer fidelity, media identity, packaging, and install checks are separate from a successful complete installed button flow. Current build 43 integration status is recorded below. No three-second claim or improvement percentage is warranted. The continuous full-mix render and durable-media verification add host/file work, so the historical build 37–39 numbers cannot be relabeled as the new route's timing.

Build 43's full offline Swift suite ran **565 tests: 497 Mac and 68 Core, three opt-in skips, zero failures**; **103 Python tests** passed. It includes the observed Share footer variants, narrowly typed durable-PCM history checks, one completed-XML metadata recapture, and exact PCM replacement-gap comparison. These checks are separate from the installed build 43 native button-flow and PCM runs below.

Evidence is retained under `build/Throughput/StatefulQuality`: `PCM/Native-Camera-v2-Strict-v1.json`, `PCM/Native-Custom-Strict-v1.json`, `PCM/Native-Fractional1796-Strict-v1.json`, `PCM/Native-Fractional1797-Strict-v1.json`, `PCM/Production-FullMix-Minimal-{Comparison,Strict}.json`, `PCM/Production-Fractional1797-Minimal-{Comparison,Strict}.json`, the earlier `PCM/Production-*-Comparison.json` reports and native exports, pre-writer `Source-Media-Snapshot.json` files, writer manifests/reports, `PCM/Metadata-Identity-Comparison.json`, and `MediaIdentityExperiment/Metadata-35E16AC7/Native-Observed.json`. Failed older fixtures and their native exports are preserved as diagnostic evidence.

Durable **Processed Audio** is result media and must remain while Final Cut references it. It is excluded from disposable audio cleanup and Clear Cache. Temporary analysis/Share renders can still be cleaned after their durable result media is retained and verified.

## Build 43 installed integration status

The installed build 40/Audio Unit 29 fractional 1,797-frame fixture passed manual **Analyze Audio** at -35 dBFS, producing three cuts in **11.444754 seconds** of helper time. Native Controls opened, and saving settings did not start analysis automatically. Apply then stopped during full-project Share-panel verification **before result generation or import**. The Roles header reported one audio file, while the panel footer reported two delivery attachments: WAV plus XML. The previous global file-summary check treated that legitimate footer as a second audio output. This was not a verified Apply or a complete-flow performance result; the original project remained unchanged.

Build 41 scopes the file-summary count to the Roles header. It still requires the complete expected role set in one stereo WAV and keeps duplicate WAV/track checks strict across the whole panel. Verification failures record bounded diagnostics rather than guessing that the mix is correct. The regression includes the real one-audio-file/two-attachment layout; all 11 focused Share-panel tests passed after the fix.

Installed build 41 then passed the 1,797-frame Analyze with three cuts in **8.579838 seconds**. Apply took **11.647526 seconds**, created and imported the cleaned result, and **completed its first native verification XML export**. Its accompanying source mutation guard then failed: the durable WAV's `ctime` changed during that capture, shortly before XML delivery. Its encoded hash, device, inode, size, and modification time were unchanged; original raw media stayed unchanged. A separately exported native result matched **all 2,846,043 retained stereo PCM frames exactly**, with no differing join. This is a native PCM success, **not a verified source/XML round trip or a completed Apply**. Evidence is `Installed41-Fractional1797/Native-Status.json` and `Native-PCM-Comparison.json`.

The separate build 41 custom-role Analyze produced 11 cuts. Its Apply stopped **before import** because that panel's footer used an `AXStaticText` value `.wav` with exact description `kind`, rather than the two-attachment count. Counting that legitimate footer as a second WAV caused another false rejection; its actual controls and status are preserved in `Installed41-CustomRoles` and the request's bounded diagnostic.

Build 42 accepts either observed footer representation without weakening the mix proof: the Roles header still requires exactly one WAV and one audio-output summary; only one extra static `.wav` with exact description `kind` may appear after the unique Roles boundary. Unknown/duplicate WAV labels, all duplicate tracks, incorrect stereo layout, stale separate-file presets, and missing or extra roles remain rejected. The real sanitized custom-role control snapshot is a regression test.

Build 42 also permits a **prior import-phase `ctime` change only for typed, proven durable PCM** whose encoded/PCM/format/identity evidence, device, inode, size, and modification time still match. Original raw sources and generic snapshots retain their strict checks. A new current-phase mutation guard, including `ctime`, spans subsequent hashing/XML capture and rejects modification even if bytes are restored. This does not accept a changed audio payload, a different file, or arbitrary historical metadata changes.

Installed build 42's custom-role Analyze passed in **11.195884 seconds**, producing 11 cuts (request `648EC5E1-4DDA-4645-98A9-1E4F634B9CE2`). Its first Apply created and imported the result, completed the first native XML export, then failed the current-phase mutation guard when durable `ctime` changed during that capture. **Retry Verification** later passed strict project/source verification without another import. A native result export matched **all 2,795,200 retained frames exactly against the current captured Apply mix**. Comparison against a different historical native render failed by one 24-bit LSB at frame 7,134; the two uncut native files had different hashes. That failure remains preserved: no cross-render determinism, tolerance, or universal plugin guarantee is claimed.

The build 42 five-minute Gate → Limiter run likewise produced 60 cuts, imported once, and failed the first completed XML capture's metadata guard. Its explicit **Retry Verification** passed strict project/source verification; its native result matched **all 9,192,000 retained frames exactly against that request's captured native mix**. These are verified results after manual read-only retries, not successful initial Apply attempts or complete-flow timing measurements. Evidence is retained under `Installed42-CustomRoles` and `Installed42-GL-5m`, including their `Result-VerifiedRetry` directories and `Native-PCM-vs-Captured-Mix.json`; the custom historical-reference failure remains in `Native-PCM-Comparison.json`.

Build 43 addresses the observed metadata arrival **during one completed read-only XML capture**. Only when that first XML has already passed semantic and destination checks, every original source remains unchanged, and the sole stamp delta is `ctime` on the already-bound durable mix may it discard that phase. A fresh full scan must prove the historical encoded-file, PCM, format, and container identity before one new read-only XML capture. The actual project and host-assigned audio identities are bound locally from the first capture; the accepted second phase and final receipt require strict current-phase guards. A thrown or uncertain capture exits immediately. Import and settings recovery are never automatically retried, and changed payloads, source identities, raw-source metadata, destination, or XML semantics are not accepted.

Build 43 with unchanged Audio Unit 29 is installed. Built, installed, and ZIP helper hashes match (`7a354f92…42088b8`), and their Audio Unit hashes match (`cf42cb18…369cd`); deep signature checks passed for all three bundles. Evidence is `build/Throughput/StatefulQuality/Package43.json`. Earlier failed attempts and their completed native exports remain preserved.

Its first five-minute attempt, request `F9A1A1EE-000A-4E16-8C8C-B87FAF2FDF7E`, passed Analyze in **13.654742 seconds** and imported its 60-cut result, but Apply stopped on a keyboard-focus check **before any verification XML capture**. The failed Apply timing was **14.612677 seconds**. A later explicit read-only **Verify Existing Result** passed strict project/source verification with two completed XML captures and no further import. This establishes recovery of that existing result, not successful initial Apply or whole-flow throughput. The successful retry replaced its original status/verification files before the evidence snapshot; `Installed43-GL-5m` preserves the failed timing, verified-retry result, and that limitation explicitly.

A fresh request, `AE0AFEF2-14EE-4E2A-B01E-BF81590A5075`, then completed **Analyze → review → Apply without a manual verification retry**, using the same disposable five-minute Gate → Limiter project in the required integration library. It created the expected **60 cuts, reducing 300 seconds to 191.5 seconds**. Both completed verification XML captures were byte-identical and bound the same imported project and new processed-audio asset. Strict project/source verification passed. The raw source retained every saved stamp and its encoded hash; the durable WAV retained its encoded bytes, device, inode, size, and modification time, with only the expected `ctime` change. This exercised the bounded completed-capture metadata recheck in the installed app.

| Build 43 native fixture | Analyze | Verified Apply | Total helper processing | Current target |
| --- | ---: | ---: | ---: | ---: |
| Gate → Limiter, 5 min, request `AE0AFEF2` | 12.05 s | 22.34 s | **34.38 s** | 3 s |
| Gate → Limiter → AUDelay with custom roles, 1 min, gap mode, request `17D78B26` | 10.35 s | 21.95 s | **32.31 s** | 0.6 s |

The official throughput reporter accepted this successful Apply and its matching project/source receipts. The preserved reports used the historical one-second-per-minute budget; the table above compares their unchanged measured times with the current goal. This is **helper processing time**, including cleanup; it excludes human review, optional updates/navigation, frontend latency, and startup. It is not a complete UI stopwatch measurement. Native rendering and host exchanges still dominate: this does not meet the three-second goal or establish a speedup over the older editable-effects route.

A separate native export of that automatically verified result matched **all 9,192,000 retained stereo PCM frames exactly** against the request's captured continuous mix, including every join. Both comparison inputs were native 24-bit stereo 48 kHz WAVs. No repeated original export was supplied for this run, so it does not establish cross-render determinism, arbitrary plugin fidelity, or identity to Final Cut's higher-precision live engine. Evidence is `Installed43-GL-5m-Automatic`: `Result`, `Temporary`, `Workflow-Throughput.json`, `Evidence-Audit.json`, `Share-Events.jsonl`, `Native Export`, and `Native-PCM-vs-Captured-Mix.json`.

The additional one-minute request `17D78B26-1E66-4EF7-B2F6-0AB75156A548` passed the same initial button flow in **Replace with 1-Second Gaps** mode. Its original target used Gate → Limiter → AUDelay → Silent Snip, with connected Music and custom Room Tone. The captured original XML records those connections at -30 dB and -36 dB respectively; Analyze still measured Dialogue separately, while Apply retained the complete native project mix. Eleven reviewed cuts removed 1.766667 seconds and inserted eleven seconds, producing **69.233333 seconds** of output. Two completed verification XML captures retained the same imported project and processed-audio identities, and final strict project/source verification passed without a manual retry. Raw-source stamps and encoded hash stayed unchanged, and only the durable WAV's `ctime` changed.

The separate native gap-result export matched **all 3,323,200 output stereo frames exactly**: 2,795,200 retained mix frames plus **528,000 positive-zero gap frames** (11 × 48,000). The comparator checked each declared gap and every retained sample without a timing shift or tolerance. This native 24-bit stereo 48 kHz fixture establishes the tested mixed-role delay chain's gap behavior, not every plugin, role configuration, or higher-precision path. Evidence is `Installed43-CustomRoles-Gaps`, with its result, temporary timing, native export, throughput, source audit, and `Native-PCM-vs-Captured-Mix.json`. The helper's generic Integration status had already been replaced by the later manual Share notification, so it is labeled `Integration-After-NativeExport.json`; the result's verification receipt/status supply Apply completion proof. **Pending:** additional effect-chain coverage, complete UI timing, and the original throughput target.

## Build 44 routing and build 45 delayed Share observation

Build 44 persists one bounded routing hint across helper launches. The next explicit Analyze consumes it before use, hashes the current sources, and requests fresh rendered audio and project XML together. The delivered XML must independently prove the selected scope and source set. Missing, stale, or invalid hints use the ordinary capture path; this stores no PCM, effect settings, or authorization to reuse an opaque effect's measurements. The existing Final Cut Controls flow remains unchanged.

Two native five-minute Gate → Limiter analyses ran in the required integration library, with the same 60 reviewed cuts reducing 300 seconds to 191.5 seconds:

| Build 44 Analyze route | Request | Helper Analyze time |
| --- | --- | ---: |
| Initial ordinary capture | `254F7BAC` | 12.4462881 s |
| Combined fresh audio/XML after a full Final Cut and helper restart | `627C77DD` | 9.6281626 s |

The second run exercised the persisted hint after restart and removed the separate initial XML exchange. These two observations do not establish a general speedup or the three-second complete-flow target. Its Apply took **15.1533 seconds and failed after import**, losing keyboard focus before verification XML capture. The actual **Silent Snip** Share panel, with **Next** and **Cancel**, had opened. An explicit **Retry Verification** subsequently passed; a separate native result export matched **all 9,192,000 retained stereo PCM frames exactly** against that request's captured continuous mix. This establishes recovery and retained sound for that result, not a successful initial Apply or a complete-flow timing result. Evidence is under `build/Throughput/Routing44`: `Initial-GL-5m`, `Relaunched-GL-5m-FailedApply`, and `Package44.json`.

Build 45 observes the exact expected Share confirmation when the final menu action was attempted but focus was lost as the panel arrived. The dispatch marker is set immediately before the final AX action, after its input checks. Observation requires the same pinned project, host/helper foreground, and the exact Silent Snip panel with Next and Cancel. Earlier menu failures, unrelated apps/dialogs, and cancellation still stop. It does not repeat menu inputs or import. Menu failure messages now identify the last input boundary.

Installed build 45 completed a new **Analyze → review → Apply** run, request `4218CAFA-F910-4E76-8E30-6BB086F1F4E0`, without a manual verification retry:

| Build 45 five-minute Gate → Limiter fixture | Helper seconds |
| --- | ---: |
| Fresh Analyze using combined audio/XML | 8.7695311 |
| Verified Apply, including cleanup | 20.9539510 |
| **Total helper processing** | **29.7234821** |
| Current complete-flow target | 3 |

It retained the same 60 cuts and 191.5-second result. Strict imported project/source verification passed, and the raw source's hash, device, inode, size, modification time, and change time stayed unchanged. A separate native result export matched **all 9,192,000 retained stereo PCM frames exactly** against that request's captured continuous mix, including every join, at native 24-bit/48 kHz precision. This does not establish identity to higher-precision live audio, cross-render determinism, or universal effect compatibility. Native review and the opened cleaned timeline were observed; the saved UI observation times include observer/tool delays and are upper bounds, not precise frontend timing. No three-second completion is established.

This successful run did not exercise the exceptional panel-observation counter; its no-repeat and rejection boundaries have automated regressions. An earlier build 45 ordinary analysis took 12.2514667 seconds; a local ad hoc rebuild initially required refreshing the existing macOS control grant. The permission-blocked attempts stopped before export or editing and are not performance samples. Normal use still stays in Final Cut Controls.

The full build 45 Swift suite passed **580 tests (512 Mac and 68 Core), three opt-in skips, zero failures**. All **104 Python tests** passed. Built, installed, and ZIP helper hashes match (`3112aa01…acb211`), as do their unchanged Audio Unit hashes; deep signatures passed. Evidence is under `build/Throughput/Routing44`: `Installed45-GL-5m/{Result,Temporary,Workflow-Throughput.json,Evidence-Audit.json,UI-Observed-Upper-Bounds.json,Native Export,Native-PCM-vs-Captured-Mix.json}`, `Build45-Initial`, `Package45.json`, and `Swift45.log`.

## Build 46: overlap source hashing for large camera clips

Build 46 removes build 44–45's 256 MiB source-size exclusion for persisted routing hints. It pins a `ReadGuard` containing source identities and mutation stamps **before Share**, then overlaps full asynchronous source hashes with that single native render. Both operations must finish, and the original guard must still pass before the audio/XML is accepted. Bounded record size, source count, canonical local paths, and regular-file checks remain required. A failure or cancellation drains the structured source task and cleans a delivered receipt; it never repeats Share. Fresh XML still proves scope and source references, and no opaque-effect PCM cache is introduced.

The new generated fixture is a **651,772,205-byte**, five-minute 1280×720 Motion JPEG camera file. Its original 48 kHz mono ALAC stream was copied losslessly. All native runs used the required workspace library, referencing generated media in place without copied, optimized, or proxy media. The same Gate → Limiter target produced 60 reviewed cuts and a 191.5-second result from 300 seconds:

| Large-camera Analyze route | Request | Helper Analyze time |
| --- | --- | ---: |
| Build 45 baseline, ordinary capture | `22529B40` | 13.0674902 s |
| Build 46 initial ordinary capture | `D910ADA2` | 12.2889195 s |
| Build 46 combined fresh audio/XML after full Final Cut and helper restart | `3FE27EA4` | 9.5934862 s |

Request `3FE27EA4-B363-41E4-A693-0666481E0B22` recorded `capture.sourceHashOverlapsRender: 1` and no initial XML exchange. Its initial **Apply passed strict project/source verification without a manual retry** in **24.7930725 seconds**, for **34.38655875 seconds of total helper Analyze plus verified Apply processing**. The cleaned linked-camera result opened in Final Cut at 191.5 seconds. Fresh XML proved the camera source stayed referenced in place; its encoded bytes, device, inode, size, modification time, and change time matched the saved pre-test snapshot.

A separate native export of the cleaned result matched **all 9,192,000 retained stereo PCM frames exactly** against that request's captured continuous mix, including every join, at native **24-bit/48 kHz** precision. This does not establish identity to higher-precision live audio, cross-render determinism, or universal effect compatibility.

The three-second target remains unmet. Helper measurements exclude startup, frontend latency, human review, and optional navigation; they do not establish complete UI timing. These individual runs do not establish a general improvement percentage. Build 45's 29.72-second small audio-only flow and its exact PCM result remain separate historical evidence for a different workload.

The full Swift suite passed **587 tests (519 Mac and 68 Core), three opt-in skips, zero failures**; a later focused 17-test run passed without warnings. All **104 Python tests** passed. Built, installed, and ZIP helper hashes match (`c827eada…f77fe5`), as do their unchanged Audio Unit hashes; deep signatures passed. Evidence is under `build/Throughput/ConcurrentHints46`: `Baseline45-Large-Camera`, `Initial46-Large-Camera`, `Fixture.json`, `Source-Before46.json`, `Package46.json`, and `Installed46-Large-Camera/{Result,Temporary,Integration.json,Evidence-Audit.json,Workflow-Throughput.json,Native Export,Native-PCM-vs-Captured-Mix.json}`.

## Build 47: guard Apply source validation and new processed media

Build 47 overlaps Apply's full historical source-content validation with its fresh native full-mix render. It first proves the saved reference mapping, file identities, and every mutation stamp, then joins the full hashes and rechecks that same guard before accepting the render. Later work retains the same source guard and required content checks; it never adopts a new source baseline. Cancellation drains the structured source task and cleans a delivered receipt, without repeating Share or import. Legacy direct-file receipts retain the full-content preflight fallback.

The preceding source-binding repair (`248530c`) records each original URL's historical canonical target. A deterministic isolated test had shown that exchanging two aliases could leave the old unordered hashes and stamps unchanged. Validation, import validation, and snapshot restriction now verify each reference's binding. Legacy receipts without a provable alias mapping require fresh Analyze; they cannot authorize the new overlap route. The before-fix reproduction is preserved in `build/Throughput/ApplySource47/Alias-Permutation-Before-Fix.{swift,txt}`.

Only each **newly created durable WAV** is made read-only (`0444`) before source snapshots and import. Original media and older processed files are untouched. The hash, PCM, format, media identity, and mutation checks remain authoritative; read-only mode does not replace them or promise that all host metadata stays fixed. The bounded completed-XML metadata recheck remains available when its strict conditions hold.

Installed request `4A294C26-A3D3-46E1-9B58-D3E44960D53B` completed **Analyze → review → Apply without a manual verification retry** on the same five-minute, 651,772,205-byte camera fixture used for build 46, referenced in place in the required integration library. It kept the same 60 cuts, reducing 300 seconds to 191.5 seconds:

| Same camera fixture | Analyze | Verified Apply | Total helper processing |
| --- | ---: | ---: | ---: |
| Build 46, `3FE27EA4` | 9.5934862 s | 24.7930725 s | 34.38655875 s |
| Build 47, `4A294C26` | 9.408218125 s | 19.521597583 s | **28.9298157083 s** |

The new Apply recorded `apply.sourceHashOverlapsRender: 1`. Strict imported project/source verification passed with **one completed result-verification XML capture**, compared with two in the build 46 run. The cleaned linked-camera result opened at 191.5 seconds. The original camera file stayed `0644`, with identical encoded hash, device, inode, size, modification time, and change time. The new durable WAV stayed `0444`, with its encoded hash and every saved identity/mutation stamp, including change time, unchanged.

A separate native export matched **all 9,192,000 retained stereo PCM frames exactly** against this request's captured mix, including every join, at native **24-bit/48 kHz** precision. No repeated original export was supplied: cross-render determinism, equality to higher-precision live audio, and universal plugin compatibility are not established. The three-second target remains unmet. These helper times include cleanup but exclude startup, frontend latency, human review, and optional navigation; saved UI observations are scheduling upper bounds. The single same-camera comparison does not establish a general improvement percentage.

A fresh disposable one-minute project, **Disposable Roles47 5B9F8A33**, also passed initial Apply in **Replace with 1-Second Gaps** mode, request `6DBC5ACF-9733-469E-9969-CA11813FE4A3`. Its Gate → Limiter → AUDelay target had connected Music and custom Room Tone. Eleven cuts removed 1.766667 seconds and inserted eleven seconds, producing **69.233333 seconds**. Analyze took **12.588308208331 seconds** and verified Apply **19.450478250000742 seconds**, totaling **32.03878645833 helper seconds**. Strict project/source checks passed with one completed result-verification capture; raw-source hashes/stamps and the read-only durable WAV's hash/stamps stayed unchanged. A separate native export matched **all 3,323,200 stereo output frames exactly** at 24-bit/48 kHz: **2,795,200 retained frames plus 528,000 positive-zero gap frames**. This verifies the supplied mixed-role delay fixture, not every plugin or routing setup. Evidence is `build/Throughput/ApplySource47/Installed47-CustomRoles-Gaps`, including its result, timing, source/evidence audits, native export, and `Native-PCM-vs-Captured-Mix.json`.

An earlier ordinary Analyze, `80B701F9`, took 15.404254 seconds and is saved separately; the successful timed request used a subsequent explicit fresh Analyze with combined audio/XML, not reused opaque-effect PCM. Two pre-render attempts stopped for a stale control grant after the local ad hoc rebuild; re-adding the existing macOS control-access entry recovered access. Those attempts are excluded from performance samples. Normal use continues in Final Cut Controls with the same manual buttons.

An additional attempt on the existing custom-role project, `314C18F2`, stopped before Apply with a review-selection/unsupported-return error. That project's current timeline contains one-second head and tail Cross Dissolve transitions absent from the captured build 43 baseline. This changed, unsupported fixture does not establish a build 47 regression or a successful Apply. Its failure evidence is preserved in `build/Throughput/ApplySource47/Existing47-CustomRoles-Transitions-Failed`.

The full suite passed **600 Swift tests (532 Mac and 68 Core), three opt-in skips, zero failures**, and **104 Python tests**. One pre-existing async-wait compiler warning remains in `StorageCleanupTests.swift:218`. Built, installed, and ZIP helper hashes match (`2e04f539…648df`), as do their unchanged Audio Unit 29 hashes; deep signatures passed. Evidence is under `build/Throughput/ApplySource47`: `Package47.json`, `Initial47-Large-Camera`, and `Installed47-Large-Camera/{Result,Temporary,Integration.json,Workflow-Throughput.json,Source-Audit.json,Share-Events-Before-NativeExport.jsonl,UI-Observed-Upper-Bounds.json,Native Export,Native-PCM-vs-Captured-Mix.json}`.

## Earlier performance changes retained in build 47

- Source decoding reads bounded blocks rather than issuing a file read for every 10 ms measurement window. The existing window boundaries, per-channel RMS calculation, detector, and sample-range checks remain in use.
- Imported-result verification overlaps a full source-content validation with its XML capture. A file identity/change-time guard spans both operations and the remaining read-only verification, removing a redundant full scan. Settings recovery still requires its own final full-content validation.
- Share can use the shortcut currently advertised by the exact **File → Share → Silent Snip…** command. Missing or incomplete metadata selects the visible menu route before dispatch. An uncertain dispatch is never retried. Share settings, roles, delivery receipts, and project checks remain required; no command set, default destination, or preference is changed.

The existing direct-render routes and explicit **Update Cuts** avoid additional host work when their safety checks permit it. **Analyze Audio** remains a manual fresh-analysis action. Supported **Update Cuts** recalculates from retained measurements only when clicked. Typing, Return, blur, Save Settings, and polling do not analyze. Changes to media, timeline content, gain, effects, order, or bypass require fresh Analyze; Apply checks current project and processing evidence before creating the cleaned copy.

## Existing effects and the audio guarantee

Processed analysis uses **Final Cut's rendering of the existing effect chain**. It does not replace the native Noise Gate or Limiter with similar DSP or load private effect bundles into another engine. Gate → Limiter → Silent Snip and Limiter → Gate → Silent Snip retain their respective processing order. Order can affect sound, as Apple's [effect-order guide](https://support.apple.com/guide/final-cut-pro/ver761c7810/mac) explains.

The host-render path has no gate/limiter-only allowlist: existing chains can use it when the current clip, routing, timeline, and preservation checks support them. This is not a claim that every third-party plugin or project topology has passed native testing. Unsupported or unverifiable cases stop rather than silently analyzing dry source audio. Analyze's target render is measurement material; build 40 Apply's continuous full mix becomes durable result media. Original live effects remain editable in the original project, while the cleaned copy references captured sound and original video. Apple's [custom Share interface](https://developer.apple.com/documentation/professional-video-applications/receiving-media-and-data-through-a-custom-share-destination) explicitly supports receiving rendered media and project FCPXML together.

Preserved effect XML does not establish identical processed samples: the build 39 split-effect output and compound-source experiment demonstrated this. The developer comparator below tests the original processed render with the selected silence samples removed against the entire cleaned processed render. For the app's uniform replacement-gap mode, it also compares every inserted frame against exact positive-zero PCM; total gap duration/count must be sample aligned and agree with the complete retained-segment mappings. Ambiguous or nonuniform mapping evidence is rejected. A supplied repeated original render separately checks determinism. It accepts only uncompressed WAV exports with integer PCM up to 24 bits or Float32 PCM, requiring the same declared PCM format, sample rate, channels, layout, frame counts, and exact rational interior cut boundaries. The native floor policy permits only the final physical sample tail; it never rounds an interior cut. Higher-precision PCM and compressed inputs are rejected because Float32 decoding could conceal source differences. Reports include exact decoded Float32 equality, hashes, gap boundaries, and the first differing frame/time. It performs no alignment shift, gain correction, resampling, or tolerance matching. Passing applies only to the supplied exports and settings; the build 43 native gap result above is a separate host test from the offline gap regressions.

## Reproducible native measurement

Use only the workspace's existing **Cutdown Integration.fcpbundle**; create the empty library first on a fresh checkout as described in [setup](setup.md#integration-test-library). Keep generated sources referenced in place, without copied, optimized, or proxy media. Use disposable projects and preserve exported evidence.

Generate 1-, 5-, and 60-minute lossless fixtures in both effect orders. Supply a generated mono 48 kHz integer PCM narration WAV of at most 24-bit precision under `build` whose name begins `Generated `, a native integration `Info.fcpxml` containing exactly the three effects with saved Silent Snip state, and a new output directory:

```sh
python3 Scripts/make-throughput-fixtures.py \
  --source "$generated_narration" --effects-template "$native_effect_template" \
  --output-dir "$fresh_fixture_directory" --durations 60 300 3600
```

Import the generated `Throughput.fcpxml` into the required library. Run manual Analyze → review → Apply in each disposable project. Record cold/fresh versus retained-measurement runs separately; compare the same effect order and source. The looped narration is a repeatable synthetic workload, not an hour of diverse speech.

Record stopwatch time from Analyze to usable review and from Apply to verified completion, identifying startup and frontend latency. Exclude the user's review pause explicitly. The helper report is a narrower corroborating metric; it sums successful Analyze and fully verified Apply, including their cleanup, but excludes startup, frontend delivery latency, optional review actions, and human review:

```sh
python3 Scripts/report-workflow-throughput.py \
  --analysis "$analysis_timing" --apply "$apply_timing" \
  --result-directory "$result_directory" --raw-seconds 3600 \
  --output "$new_throughput_report"

python3 Scripts/compare-processed-audio.py \
  --original "$original_processed_wav" --cleaned "$cleaned_processed_wav" \
  --repeated-original "$repeated_original_wav" \
  --edit-report "$result_directory/Edit-Report.json" --output "$pcm_comparison_report"
```

The first command rejects failed or mismatched timing/verification evidence and does not assert sonic equality. The second is a separate diagnostic using native full-project WAV exports, not an extra render added to normal use. It streams PCM with bounded memory and writes only JSON. Exit codes are 0 for equality, 1 for a difference, and 2 for invalid inputs/decode failure. Retain leading/trailing project material in both exports; do not export only the target clip.

## Offline rendering and hardware boundary

The November 4 public-interface audit found **no supported faster interface for rendering an arbitrary existing Final Cut audio chain with its complete processing state**. This is a finding about the inspected APIs, not proof that three-second completion is physically impossible.

The installed public headers under `/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks/FxPlug.framework/Versions/A/Headers/` define the relevant limits: `FxAnalysis.h:3` specifies video analysis, and line 66 takes an `FxImageTile`; `FxProjectAPI.h` exposes a plugin-data folder in a Motion project, document identity, and aspect ratio; `FxCommandAPI.h` enumerates navigation, playback, Undo/Redo, and UI commands, without an audio-render/export command. Apple's [analysis documentation](https://developer.apple.com/documentation/professional-video-applications/analyzing-media) and [project API](https://developer.apple.com/documentation/professional_video_applications/fxprojectapi) describe the same scope. FxPlug's CPU/GPU video-analysis option is not an audio-render bypass.

The [Workflow Extension SDK](https://developer.apple.com/documentation/professional-video-applications/interacting-with-the-final-cut-pro-timeline) supplies limited timeline proxies: [FCPXHost](https://developer.apple.com/documentation/professional_video_applications/fcpxhost) exposes host identity and its timeline; [FCPXTimeline](https://developer.apple.com/documentation/professional_video_applications/fcpxtimeline) supplies sequence/range observation and playhead access; [FCPXSequence](https://developer.apple.com/documentation/professional_video_applications/fcpxsequence) provides sequence timing and name. Their documented interfaces expose no processed-audio pull or access to other effect instances. The installed `/Applications/Final Cut Pro.app/Contents/Resources/ProEditor.sdef:148` similarly declares library inspection through `get`, with no Final Cut-specific render/export command. The [custom Share protocol](https://developer.apple.com/documentation/professional-video-applications/responding-to-apple-events-from-final-cut-pro) delivers native media/XML after Final Cut initiates Share; its callbacks and Apple-event interaction flags do not document a headless export-start command.

Apple's [offline audio engine](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing) can render an app's own audio-node graph faster than real time. It does not obtain Final Cut's current graph. Exact external reconstruction would require identical hostable implementations, routing, automation, and complete effect state. The installed build 45 capture at `build/Throughput/Routing44/Installed45-GL-5m/Temporary/Project-3767DD3C-705D-407F-9F91-8A627830D4A2.fcpxmld/Info.fcpxml:15` identifies the Noise Gate AU and native `Limiter.Levels.audio.effectBundle`; lines 26–27 contain empty processing-filter elements, without a complete state archive. AU [fullStateForDocument](https://developer.apple.com/documentation/audiotoolbox/auaudiounit/fullstatefordocument) describes state available from an AU instance to its host; it does not expose Final Cut's sibling instances to this extension. No offline approximation is enabled.

[Compressor integration](https://support.apple.com/guide/final-cut-pro/ver1ff89071/mac) also does not establish a faster interface under the current workflow: Compressor presets use Share, while Send to Compressor opens a batch for configuration and starting. Apple states that FCP-sent jobs cannot use distributed processing. The documented [Compressor command line](https://support.apple.com/guide/compressor/submit-a-job-to-compressor-in-terminal-cpsr9be73312/mac) accepts a source file, preset, and destination; it does not document directly pulling the active Final Cut audio graph.

In the successful build 45 five-minute run, the two render exchanges alone totaled **14.77 seconds**, including their setup. The nonoverlapping combined Analyze exchange, Apply render/project check, final original-project XML check, and import/result verification stages totaled about **27.28 seconds of the 29.72-second helper flow**. These values come from `Installed45-GL-5m/Temporary/{Analysis,Apply}-Timing.json` under `build/Throughput/Routing44`; nested detail timings are not added again. They are observed costs, not invariant hardware lower bounds. Faster CPU/storage and overlapping guarded file work may help, but these measurements and the public-interface audit do not establish a path to the three-second complete-flow target.

## Native controller overhead and rejected in-process probe

A further November 4 diagnostic used two disposable five-minute camera projects in the required integration library. Project A contained Gate → Limiter → Silent Snip Audio; B removed only the Silent Snip filter and its unused resource. Common media, timing, gain, routing, and processing state were checked against their generated fixtures and native exports. Source media remained referenced in place, with its encoded hash and every saved identity/mutation stamp unchanged. Background tasks were idle before the first export. One warmup per variant preceded the timed A/B/B/A order.

These measurements bracket the native **Next** command through the completed Share manifest's filesystem timestamp. They exclude opening/configuring Share, Analyze, review, Apply, import, and verification. Command dispatch is bracketed by CUA timestamps; neither boundary is an exact native render timestamp. They are diagnostics, not full-flow timings or fixed host lower bounds.

| Audio Unit 29 sample, dispatch start → manifest | A: with controller | B: without controller | A minus B |
| --- | ---: | ---: | ---: |
| First timed pair | 6.2242 s | 4.7365 s | 1.4877 s |
| Second timed pair | 5.7240 s | 4.7251 s | 0.9989 s |
| Median of two samples | **5.9741 s** | **4.7308 s** | — |

All six original native exports, including warmups, had **exactly identical native format and all 14,400,000 stereo PCM frames** at 24-bit/48 kHz. The difference intervals remain positive after accounting for each command's dispatch bracket. This supports investigating controller-associated overhead on this fixture; it does not isolate IPC as its cause or predict a general speedup. The controller's serialized archive became empty during native fixture import and remained stable across A captures. This limitation is recorded explicitly: PCM equality does not certify custom Controls, settings persistence, or the complete product flow.

An isolated **47P / Audio Unit 30** experiment moved the AU code into a separate framework and declared `AudioComponentBundle`, following Apple's [in-process packaging guidance](https://developer.apple.com/documentation/avfaudio/creating-custom-audio-effects). Render instrumentation used lock-free counters, with process identification and bounded logging outside the render callback. The strict containing-app resolver was adapted to the framework layout; these generated changes stayed outside production source. Direct process-local framework registration rendered all synthetic samples exactly in process, but that test bypasses system discovery and cannot prove native host loading. After supplying the working build's platform metadata and restoring the extension's declared sandbox entitlements during candidate signing, normal system registration found version 65547 and flags `0x1e`, including `CanLoadInProcess`. Nevertheless, three public-system instantiation tests requesting `LoadInProcess` returned `AUAudioUnit_XH` with `isLoadedInProcess == false`. Matching the official Xcode UI template's factory metadata and explicitly naming the framework principal class did not resolve that fallback. No private loading mechanism or security bypass was used.

The same A project then completed one native candidate warmup export, job `F4A2A107-0D44-46C4-85BE-490B6473BF36`. Its Next-to-manifest bracket was **6.4477–6.7927 seconds**. This single warmup is not a performance comparison. Its native format and all 14,400,000 PCM frames exactly matched the AU29 A1 export; common project state, native identities, source bytes, and source stamps also matched. Session-associated off-render summaries recorded full 14,400,000-frame allocations in process **83165**, distinct from the pinned Final Cut process **83143**, with `loadedInProcess=0`. The log's sender path names the staging framework; its executable bytes match the pinned runtime framework everywhere outside the code-signature blob, and both strict signatures verify. Their different signed-file hashes and matching runtime image UUID are retained in the final audit. Multiple allocation summaries from one host session are not separate export runs. In-process DSP was therefore **not established in Final Cut**, and this experiment was rejected for production. It does not prove that every possible supported packaging arrangement must fail.

The exact pre-experiment **build 47 / Audio Unit 29** app was restored by replacing the entire bundle, then registered again. Original helper/AU executable hashes and deep signatures passed; the system registry returned version 65546/flags `0x0e`, and both full five-minute synthetic passthrough checks passed. Native Controls reopened with **Ready** and **Analyze Audio** in the required library. The built app and distributable ZIP were unchanged. The experiment is not a build 48 release and does not add native Controls/settings or Analyze/Apply compatibility coverage. The three-second complete-flow goal remains unmet.

Preserved local evidence is under `build/Throughput/InProcess48`: `Camera-AB-2B590C53/Manifest.json`, `Native-AB47/Native-AB-Audit.json`, all seven native Share jobs, the isolated probe sources/tests and public-system reports, `Native-AU30-Host.json`, `Native-AU30-Runtime-After-Quit.json`, `Native-AU30-Audit.json` (initial audit), `Native-AU30-AfterQuit-Audit.json` (final render/provenance audit), and `Rollback47.json`. Generated media, the Final Cut library, and probe bundles remain excluded from Git.
