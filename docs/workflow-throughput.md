# Workflow throughput and audio preservation

November 2, 2026. The build 37 benchmark target is approximately **one second of processing per minute of raw clip audio**. Native hour-long fixtures completed helper Analyze plus verified Apply in **45.56–46.34 seconds**. Short clips did not meet the proportional target, and **no meaningful end-to-end speedup over build 36 was established**. These results do not establish a universal full-UI timing guarantee or a 50% improvement.

## Measured result

Apple M1, 16 GiB RAM; macOS 27.2 (26B123), Final Cut Pro 12.4. All tests used disposable projects in the required workspace library, referencing generated sources in place. Fixtures are looped generated narration, 48 kHz mono lossless ALAC, with native default Noise Gate/Limiter and stereo project output. These are normal-session fresh analyses, not a diverse real-world recording or a cold-boot benchmark. `GL` means Gate → Limiter → Silent Snip; `LG` means Limiter → Gate → Silent Snip.

| Build / order | Raw duration | Analyze | Verified Apply | Total helper processing | Target |
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

Validation: 484 Swift tests, one opt-in benchmark skipped in the full suite, no failures; 81 Python tests passed. The separate one-hour decoder benchmark also passed and remains a component-only result. Build, installed app, and ZIP helper executable hashes match; signature/packaging checks passed. Native evidence is retained under `build/Throughput`: `Performance-Summary.json`, each `Baseline36-*` / `Updated37-*` directory, `PCM/*Comparison.json`, `Reader37-60m.json`, `Package37.json`, and `Native-Checks.json`. All generated-source and template hashes stayed unchanged. The 32 automated Share jobs retained zero rendered WAVs after cleanup; native PCM comparison exports remain preserved as integration evidence.

## Build 39: observed menu readiness

Build 39 is installed. It replaces fixed submenu sleeps with bounded checks that the exact submenu is visible and the intended command is unique. A scrolling menu can expose a different visible child; the intended item still needs its own hit test before any coordinate input. Completed actions return immediately. A merely selected item retains the existing 200 ms grace before one activation, and uncertain dispatch never retries. Missing or empty aggregate selection metadata falls back to exactly one selected child; conflicting nonempty selection metadata stops. Import quiescence and semantic verification remain required.

Additional native runs used the same generated five-minute Gate → Limiter source and original disposable project in the required library:

| Build | Analyze | Verified Apply | Total helper processing | Target |
| --- | ---: | ---: | ---: | ---: |
| 37 before menu changes | 10.44 s | 10.68 s | 21.11 s | 5 s |
| 38 intermediate candidate | 11.41 s | 9.13 s | 20.54 s | 5 s |
| 39 final menu compatibility corrections | 13.83 s | 9.12 s | 22.95 s | 5 s |

All three created the same 60 cuts and 191.5-second editable result with verified source contents and preserved native processing effects. Recorded Share panel opening stages were shorter with the menu changes, but native rendering varied from 6.03 to 9.42 seconds. **No end-to-end speedup or five-second completion is established.** These totals retain the helper-only measurement boundary described above. Native UI review and the opened cleaned timeline were separately observed; observer scheduling was not used as an exact UI stopwatch. Evidence is under `build/Throughput/MenuLatency`, including each request's XML, timing, verification receipts, and imported result.

An additional generated one-minute Gate → Limiter → AUDelay → Silent Snip chain completed Analyze → explicit Update Cuts → Apply in build 39. The native delay editor showed a one-second delay, 50 percent feedback, and 50 percent wet mix. At a -35 dBFS detection threshold, Apply freshly rendered and verified three cuts, preserving the delay effect in the cleaned result. This establishes the tested chain's functional compatibility; its stateful processed-sample comparison remains separate from XML verification.

Final build checks: 492 Swift tests with one opt-in benchmark skipped and no failures; 81 Python tests; 35 Controls harness groups; 60 exact mono/stereo Audio Unit passthrough cases. Built, installed, and ZIP helper executable hashes match; deep signature checks passed. The processed-PCM comparisons in the build 37 table remain fixture-specific evidence, not a universal plugin certification.

## Stateful delay: measured quality limitation

The additional build 39 delay test exposed a real retained-audio difference. Two full original native renders had exactly matching decoded PCM hashes, so the observed original was deterministic. The normal editable three-cut result had the expected 2,833,600 stereo frames, but its second join at result time 27.766667 s differed: the original processed reference sample was -0.0173425674 and the cleaned sample was 0. This is consistent with lost effect history when the source clip is split; matching effect XML does not prevent it. The difference is in processed output, not a modification of original source media.

Two independent disposable output experiments used the exact same retained source ranges in the required library:

| Output representation | Exact retained PCM | First difference |
| --- | --- | --- |
| Normal split asset clips with live effects | Fail | 27.766667 s; expected -0.0173425674, actual 0 |
| One full processed compound source, cut through outer references | Fail | Same join; actual -0.0173296928 |
| Original native lossless processed WAV referenced in place, with no additional processing | Pass | None across all retained samples and joins |

All comparison inputs were native 24-bit stereo 48 kHz WAVs. The processed-WAV experiment preserves the sound of this tested native export, while the untouched original project retains its live editable effects. Its cleaned copy contains rendered sound rather than live processing. It is **an experiment, not the production output route**, and does not establish universal plugin compatibility or the five-second workflow target. Production still preserves editable effect instances and cannot promise identical stateful tails at joins. The captured default AUDelay XML contained its exact effect identity but no serialized parameters/archive; native PCM, not an inferred settings archive, supplied the sound evidence.

Evidence remains under `build/Throughput/StatefulQuality`: `PCM/Split39-Deterministic-Comparison.json`, `PCM/Compound39-Comparison.json`, `PCM/Baked39-Comparison.json`, original/repeat/result native exports, and the independent experiment XML/manifests. Every fixture references generated sources in place; no existing user project or external library was used.

## What changed

- Source decoding reads bounded blocks rather than issuing a file read for every 10 ms measurement window. The existing window boundaries, per-channel RMS calculation, detector, and sample-range checks remain in use.
- Imported-result verification overlaps a full source-content validation with its XML capture. A file identity/change-time guard spans both operations and the remaining read-only verification, removing a redundant full scan. Settings recovery still requires its own final full-content validation.
- Share can use the shortcut currently advertised by the exact **File → Share → Silent Snip…** command. Missing or incomplete metadata selects the visible menu route before dispatch. An uncertain dispatch is never retried. Share settings, roles, delivery receipts, and project checks remain required; no command set, default destination, or preference is changed.

The existing direct-render routes and explicit **Update Cuts** avoid additional host work when their safety checks permit it. **Analyze Audio** remains a manual fresh-analysis action. Supported **Update Cuts** recalculates from retained measurements only when clicked. Typing, Return, blur, Save Settings, and polling do not analyze. Changes to media, timeline content, gain, effects, order, or bypass require fresh Analyze; Apply checks current project and processing evidence before creating the cleaned copy.

## Existing effects and the audio guarantee

Processed analysis uses **Final Cut's rendering of the existing effect chain**. It does not replace the native Noise Gate or Limiter with similar DSP or load private effect bundles into another engine. Gate → Limiter → Silent Snip and Limiter → Gate → Silent Snip retain their respective processing order. Order can affect sound, as Apple's [effect-order guide](https://support.apple.com/guide/final-cut-pro/ver761c7810/mac) explains.

The host-render path has no gate/limiter-only allowlist: existing chains can use it when the current clip, routing, timeline, and effect-preservation checks support them. This is not a claim that every third-party plugin or project topology has passed native testing. Unsupported or unverifiable cases stop rather than silently analyzing dry source audio. The rendered WAV is analysis material; the cleaned project references original media and retains editable processing effects. Apple's [custom Share interface](https://developer.apple.com/documentation/professional-video-applications/receiving-media-and-data-through-a-custom-share-destination) explicitly supports receiving rendered media and project FCPXML together.

Preserved effect XML is necessary but does not establish identical processed samples. Cutting a clip into retained segments may change a stateful effect's history at a join, including a gate envelope or limiter lookahead/release. The developer comparator below tests the original processed render with the selected silence samples removed against the entire cleaned processed render. A repeated original render checks determinism. It accepts only uncompressed WAV exports with integer PCM up to 24 bits or Float32 PCM, requiring the same declared PCM format, sample rate, channels, layout, frame counts, and exact rational sample boundaries. Higher-precision PCM and compressed inputs are rejected because Float32 decoding could conceal source differences. It rejects gap output and reports exact decoded Float32 equality, hashes, and the first differing frame/time relative to a cut. It performs no alignment shift, gain correction, resampling, or tolerance matching. Passing applies only to the supplied exports and settings.

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
