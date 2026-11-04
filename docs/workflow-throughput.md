# Workflow throughput and audio preservation

November 4, 2026. The current target is approximately **three seconds of total processing for five minutes of raw clip audio** (100× real time). The three-second target is **not achieved**. Installed build 45 completed a five-minute fixture in **29.72 seconds of helper Analyze plus verified Apply time**, without a manual verification retry. This excludes human review, startup, frontend latency, and optional navigation; complete UI stopwatch timing is not established. The prior build 43 sound-preserving run took 34.38 seconds. Recorded build 37–39 five-minute helper flows took about **19–23 seconds** with the earlier editable-effects output route and remain separate historical measurements. Individual host runs vary; these samples do not establish a general improvement percentage.

The architecture introduced in build 40 changes Apply to retain the continuous native full-project mix, prioritizing identical retained sound after a stateful delay test exposed a real join difference. Its **compiled production writer** has passed native PCM and strict imported-project/source checks for the fixtures below. **Build 45 with unchanged Audio Unit 29 is installed**, with matching built/installed/ZIP executable hashes and deep signature checks. Its five-minute Gate → Limiter fixture completed the native **Analyze → review → Apply** button flow without a manual verification retry, with strict project/source verification and exact retained PCM against its current captured mix. Build 42's custom-role and five-minute results passed only after separate manual read-only retries. These fixture results do not establish complete UI throughput, universal plugin fidelity, or equality to higher-precision live-engine audio.

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

## Earlier performance changes retained in build 45

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

The installed public FxPlug headers were inspected first: `FxAnalysis.h` analyzes video `FxImageTile` frames; `FxProjectAPI.h` exposes a plugin-data folder in a Motion project, document identity, and aspect ratio; `FxCommandAPI.h` provides UI/navigation commands. These interfaces do not supply the arbitrary processed-audio pull needed here. Apple's [analysis documentation](https://developer.apple.com/documentation/professional-video-applications/analyzing-media) and [project API](https://developer.apple.com/documentation/professional_video_applications/fxprojectapi) describe the same scope.

Apple's [offline audio engine](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing) can render an app's own audio-node graph faster than real time, disconnected from audio hardware. Reproducing this exact Final Cut chain would still require the identical externally hostable effect implementations and complete processing state. The inspected native Gate/Limiter capture does not provide that proof, so no offline approximation is enabled. Faster CPU/storage may help measured rendering or reads, but hardware does not remove the host exchanges or make private effects externally hostable. FxPlug's CPU/GPU video-analysis option is not an audio-render bypass.
