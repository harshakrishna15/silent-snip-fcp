# General projects and Analyze performance

October 29–30, 2026. Native Analyze → Apply now passes for a direct linked camera clip inside a larger project, including Noise Gate and Limiter, a leading gap, a following video clip, and connected background music. Full-project copies, editable effects, source fingerprints, manual Analyze, visible review controls, and preview scroll/zoom have been checked in the required workspace library. Measured improvements are scoped below: fresh manual reanalysis exceeds 50% on the audio and mixed-video fixtures; the first mixed-video analysis does not yet meet that target. Connected/nested/retimed targets and arbitrary third-party plugins are not universally supported or certified.

## Output and interaction

Analyze remains an explicit button action. Changing threshold, minimum silence, padding, or output mode invalidates the previous review. Typing, field blur, Return, Save Settings, and status polling do not start another analysis. Apply remains separate and needs a fresh project/source check.

Apply now creates a uniquely named cleaned copy of the **full project** in the original event and library. It retains the project timecode origin, lead-ins, neighboring clips, and representable connections. Selected camera clips keep video and audio linked at matching source trims. Later primary items move by the exact net removed duration; their own source trims, effects, and connection offsets remain intact. The original project is preserved, with recovery XML saved before import.

The selected clip's gain, channel mapping, effect order, bypass states, supported source-time automation, and serialized processing state remain editable on every retained segment. Final Cut renders processing effects for analysis. The known passthrough detector is removed only from the edited segments; exact detection settings are saved with the result. Opaque or incomplete effect state still prevents measurement-cache reuse. A preset name does not authorize a cache hit, and failed render verification never falls back to unprocessed audio.

This does not support every Final Cut topology. Connected targets, compounds, multicam, retiming, split A/V edits, component trims, unsupported video adjustments, transitions in the edited storyline, and nested connections, connected dialogue/fades, and conflicting connected lanes remain guarded. Simple direct connected music and B-roll now ripple through the same cut map, retaining source-time effects and annotations. A third-party effect that fails host round-trip verification cannot be reported as preserved. Stateful effects may respond differently at new boundaries; preserving their XML is not universal sonic certification.

## Measured baseline

The preceding installed app was measured on a generated 16.333-second audio clip with Noise Gate and Limiter, exclusively in the workspace's `Cutdown Integration.fcpbundle`. Analyze was triggered in native Controls. Request `FC3A60DA-2632-4340-A38E-F401F2A68C1E` completed successfully with four cuts, 5.533 seconds removed, and no measurement-cache reuse.

| Stage | Seconds |
| --- | ---: |
| Initial capture and XML | 2.942 |
| Temporary project creation/import | 2.474 |
| Processed Share/render | 5.155 |
| Return to original | 0.214 |
| Original-project XML verification | 2.190 |
| Temporary-project cleanup | 1.365 |
| Controls restoration | 1.462 |
| Audio decode/measurement | 0.087 |
| Detection | 0.0003 |
| **Total** | **15.968** |

Time to verified preview was 13.084 seconds. The total includes cleanup of delivered analysis audio. Evidence is in `build/GeneralProjects/Baseline/Analysis-Timing.json`; original source SHA-256 evidence is in `build/GeneralProjects/Fixtures/Source-Hashes.json`. The old installed bundle is backed up as `Before-General-Projects-App.zip` in the same evidence directory.

Halving this measured total means at most **7.984 seconds**, on the same fixture and settings. A comparison must use completed reviews, unchanged cut ranges, processing effects, source media, and equivalent timing boundaries. A cache hit or merely earlier publication of rows is not an equivalent cold processed analysis.

## Native timing after optimization

All completed runs below used explicit Analyze, the same four frame-aligned cuts, Noise Gate and Limiter, and fresh Final Cut audio renders. Their processing state remained cache-ineligible; these are not PCM-cache hits.

| Fixture and route | Total seconds | Comparison |
| --- | ---: | --- |
| Audio-only original installed baseline | 15.968 | baseline |
| Audio-only initial direct Analyze, final UI bundle | 7.729 | 51.6% lower in this run |
| Audio-only fresh manual reanalysis, three-run median | 4.961 | 68.9% lower |
| Audio-only final UI bundle reanalysis confirmation | 5.060 | 68.3% lower |
| Mixed linked-camera project, isolation route | 16.532 | same-fixture comparison |
| Mixed linked-camera project, initial bounded render | 10.516 | 36.4% lower |
| Mixed linked-camera project, three fresh reanalyses | 5.338 / 5.277 / 6.260 | median 5.338, 67.7% lower |

Initial audio-only direct runs also ranged from 8.023 to 8.103 seconds, just below a 50% reduction. Host Share latency varies, so a single 7.729-second run does not establish a universal first-analysis guarantee. The first bounded mixed render remains below the requested 50% improvement. Arbitrary larger projects can still take the isolation route and do not inherit these speedup claims.

Evidence: `build/GeneralProjects/Baseline`, `Final-Bundle-ABF7C543`, `Final-Bundle-27C07CAD`, `Combined-*`, `Mixed-Final-7E2AE4DE`, and `Mixed-Bounded-*`. Every test used `Cutdown Integration.fcpbundle`, generated media referenced in place, and disposable projects.

## Installed build confirmation

Build 31 is installed at `~/Applications/Silent Snip.app`; its helper executable matches the built app and distributable ZIP. Deep signature verification passes. On macOS/Xcode 27.2 with Final Cut 12.4, the audio fixture's initial Analyze took 8.344 seconds. Three fresh combined reanalyses took 5.601, 5.746, and 6.013 seconds (median 5.746, about 64% lower than the earlier recorded 15.968-second baseline). The earlier baseline was not rerun in this final session, so this is a confirmation against recorded evidence, not a new same-session A/B benchmark. Every completed review retained the four expected cuts.

Adaptive routing was observed natively: the camera-with-music fixture chose `projectSlice` (9.590 seconds initially, 7.074 after field edits), while the longer edit with preceding Dialogue chose `selectedRange` (11.178 seconds initially). Both passed Apply with no imported fingerprint differences, unchanged originals, and verified source contents. Evidence: `Adaptive-Music-*/Applied`, `Adaptive-Middle-2F5C9CDA/Applied`, and `Adaptive-Audio-*` under `build/GeneralProjects`.

Changing Minimum Silence invalidated the review and disabled Apply without starting analysis; the next explicit Analyze produced fresh rendered audio. This is recorded in `Adaptive-Manual-Analyze.json`. The task-owned preview diagnostics flag was removed at closeout. Original media, result/recovery XML, manual exports, and integration evidence remain preserved.

## Changes targeting latency

1. **Native selected-range render.** Fresh XML must prove a direct primary-storyline target whose enabled audio components are all Dialogue. A sole full-project target is measured directly. Longer edits and clips with earlier Dialogue use Final Cut's native Go to Range Start and Set Clip Range commands, with exact start/end/duration and selected-occurrence checks before dispatch. This avoids exporting the rest of a longer edit. Small edits with no earlier Dialogue retain the verified full-project slice route when extra duration is at most 30 seconds and no longer than the target; avoiding range setup/restoration saves about two seconds on the native fixture. Primary items must be direct assets or gaps, connections must have understood timing, and no other enabled Dialogue may overlap the target. Explicit Music/Effects components can be excluded; missing, mixed, or unknown labels cannot establish exclusion. A native reverb probe confirmed that ordinary asset bounds gate a preceding clip's DSP tail; expanded audio, transitions, retiming, and nested routing remain guarded. The WAV must match the selected duration to approximately one sample. Delivered XML still contains the full project and must match its identity, effects, timing, and sources. The owned range is cleared after delivery, preserving the selected clip. The range commands passed installed-build Analyze → Apply on a 33.667-second edit with earlier reverberant dialogue, a 16.333-second camera target, and a one-second following video. Initial Analyze took 10.914 seconds and fresh combined reanalysis 8.020 seconds. The 28.133-second full-project result matched its imported timeline/effect fingerprint, with unchanged source hashes (`Middle-Range-15BCD161`, `Middle-Range-818BF896/Applied`). This is a new topology with no equivalent measured baseline; no 50% claim is made for it. Ineligible projects retain isolation. Scope proof remains independent of cache eligibility; opaque effects still render in Final Cut.
2. **Fresh combined capture on subsequent manual Analyze.** After a verified direct render, retain only a process-local routing hint for that exact project/selection. The next click hashes the hinted source files before requesting new audio plus new XML in one Share exchange. Current XML must independently prove eligible Dialogue scope, selected occurrence, and exactly the source set hashed before render. The hint retains the exact render scope, including full-project versus selected-range duration. A changed scope discards the rendered mix and keeps the normal isolation route; a failed hint is consumed so it cannot loop. No previous PCM or cut authorization is reused, including when a gate/limiter preset cannot qualify for caching.
3. **Overlap independent work.** When complete processing state cannot qualify for measurement reuse, hash source media away from the UI thread while Final Cut imports/renders. Capture file identities and nanosecond change stamps before either task starts; verify them after hashing and rendering, then validate full contents again before publishing review. Metadata never substitutes for a content hash. The full-project media snapshot remains part of Apply and imported-result verification.
4. **Viewport-based preview drawing.** Index cut positions once when the review changes. Binary-search the visible interval during scrolling/zooming and create reusable Core Animation layers only for visible boundaries. Global cut numbers are retained. A regression with 10,001 boundaries at 200× zoom needs 51 line layers rather than 10,001. The native AppKit/Core Animation benchmark measured initial drawing at 250.376 ms before and 1.346 ms after (99.46% lower), and median scroll redraw at 1.025 ms before and 0.846 ms after (17.44% lower). This excludes Final Cut Accessibility sampling and visible host latency; it is not a frame-rate claim. Zooming out restores all boundaries. Evidence and the extracted old/new implementation benchmark are in `build/GeneralProjects/Preview-Benchmark.json` and `benchmark-preview.swift`.

Mixed projects outside the verified direct range scope still isolate audio to avoid music, neighboring speech, or effect tails contaminating silence detection. It retains its original-project recheck and precise temporary-project ownership checks. Further latency reduction there needs another verified export route, not weaker source/effect validation.

## Connected background media

`ConnectedProjectRipple` applies the same removals (and inserted gap durations) to simple direct connected assets. It captures each exact XML occurrence before detaching siblings, writes the primary edit, trims connected copies at matching source times, preserves complete effect curves, keeps fades only at original outer edges, trims annotations, and attaches retained pieces to compatible surviving primary items. It validates segment counts, lanes, enabled state, source trims, media identity, stream flags, effects, and fades before import. Final Cut's full-project re-export must then match the generated semantic fingerprint.

A native camera-with-music test passed Analyze → Apply. The original project was 19.333 seconds with a continuous generated music bed, a two-second lead-in, Noise Gate/Limiter on the camera clip, and gain/Limiter on the music. Analysis returned the same four cuts as the fixture without music. The cleaned full project was 13.8 seconds with five linked camera pieces and five synchronized music pieces; the neighboring one-second video and leading gap remained. Imported timeline/effect fingerprints matched, source hashes passed, and the original stayed unchanged. Evidence: `build/GeneralProjects/Connected-Music-A08EC29C/Applied`.

The initial analysis took 9.783 seconds, including automatic role-layout configuration. It is not a measured 50% result against an equivalent music-project baseline. The timing counters prove one role-preset reset and one non-Dialogue output removed. The app selects Final Cut's native separate-files layout and verifies exactly one stereo WAV containing All Dialogue; it changes export outputs, never project roles or source media. The earlier mixed-WAV rejection is preserved as `Connected-Music-E031BA8B`. A subsequent field-edit focus race is preserved as `Connected-Music-92105CE1`; the correction restores only the pinned project while Final Cut or Silent Snip owns the foreground. Later field-edit reanalysis passed in 6.719 seconds and a post-Apply field-edit Analyze passed in 8.401 seconds, both with fresh native audio. The intermittent restoration counter was not exercised in those runs, so they do not prove that exact race branch.

## Algorithm, parallelism, and hardware

The measured detector cost is about 0.002% of baseline elapsed time. Even eliminating both decoding and detection would save under 0.6% on this short fixture. A detector rewrite or GPU kernel cannot plausibly produce a 50% end-to-end improvement here. Longer media should be profiled separately.

Audio measurement already uses Apple's Accelerate/vDSP (`vDSP_rmsqv` and `vDSP_svesq`), which provides processor-optimized vector routines. The overlay already uses retained Core Animation vector layers. Apple’s [vDSP documentation](https://developer.apple.com/documentation/accelerate/vdsp) describes that hardware-optimized library. No GPU/Neural Engine speedup is claimed. Hardware video encoders would not remove the audio-only WAV Share, host menus, or project import/navigation costs.

Audio decoding, hashing, and host rendering can overlap when their inputs and cancellation lifetimes remain explicit. Final Cut focus, Share, project switching, and imports share mutable host state and must stay serialized. Running those UI operations in parallel risks exporting or editing the wrong project. Recreating arbitrary native and third-party effects outside Final Cut is not a safe replacement when their full state, automation, external resources, and routing are unavailable.

Apple documents [Audio Units, workflow extensions, FCPXML, and media exchange](https://developer.apple.com/documentation/professional_video_applications) as different integration mechanisms. This implementation keeps Controls in Final Cut and generates cuts programmatically through FCPXML. It still uses visible native Share and import operations; this update does not establish a new headless export/edit API or automatically configure a Share destination.

## Storage

Original media is referenced in place, never copied into optimized/proxy media for fixtures or replaced by the analysis WAV. The direct route creates no temporary Final Cut project. Request-owned rendered audio is removed after analysis; an eligible process-local cache retains at most one verified bounded copy. XML, source media, result/recovery receipts, registered app bundles, and exported integration evidence remain protected. Unknown or changed files are preserved rather than guessed to be disposable. See [cleanup ownership and limits](storage-cleanup.md).

The final storage audit found no remaining WAVs from 33 completed/request-owned analysis deliveries for these general-project fixtures. Manual deliveries were preserved. Last-used detection settings remained byte-identical to the saved pre-test file; original narration, camera source, and music source hashes matched.

## Verification status

- Full Swift suite: 465 tests, one existing opt-in benchmark skip, zero failures, under Xcode 27.2. Source-evidence coverage includes mutation before/during hashing, mutation followed by byte restoration, aliases, cancellation, and legacy recovery receipts.
- Controls harness: 33 scenarios plus the shared-state protocol contract passed, including stable initial sizing, scrolling in a fixed smaller host, and explicit Analyze invalidation.
- Audio Unit harness: 60 rendering/persistence cases passed; build-script suite: 53 tests passed.
- Release app and ZIP built and signed; the installed app's existing macOS grant was refreshed through System Settings without requesting a user password.
- Direct audio-only Apply passed: a separate 10.8-second project retained editable processing effects and verified source hashes.
- Mixed linked-camera Analyze → Apply passed on the isolation route: original 19.333-second project retained; cleaned full project 13.8 seconds, including unchanged two-second lead-in and one-second following clip. The target's video and audio trims remained linked, and imported semantic fingerprints and original-media hashes matched with no differences. Request `7E2AE4DE-1A5E-43E2-B495-75DB24153A4E`.
- Bounded mixed-project fresh renders reproduced all four exact cut ranges and Apply passed with no semantic differences: request `415B8C32-D816-49F4-B8C4-BE34279A7B8E`. Connected-music Apply also passed as detailed above.
- Native Controls showed every detection setting, all four cut rows, Analyze Again, and Apply together. Timeline preview was observed at zoomed and scrolled positions: cut numbers 1–3 changed to 3–4 when scrolled, and zoom-to-fit restored all four pairs. Separate overlay screenshots were inspected because Final Cut's own window capture excludes the helper-owned overlay.
- Settings edits invalidated Apply without creating a new job; another explicit Analyze was required. This was checked natively and in the Controls harness.

The user accepted the tested main workflow as complete on October 30, 2026. Known limitations retained for future work include first-analysis latency in mixed projects, isolation-path latency, connected/nested/retimed targets, and broader plugin/topology certification. Acceptance does not establish “any project” support or a universal 50% reduction.

## Additional native experiments

- Export XML through the native File menu preserved project semantics but took 3.807 seconds after tuning (10.493 seconds total Analyze), so it did not beat the custom Share exchange and was removed from shipping code. Its prototype and evidence remain under `build/GeneralProjects/Rejected-Experiments` and `Native-XML-*`.
- Solo did not isolate the audio export in the tested host. Solo-on and Solo-off WAVs decoded to the same PCM SHA-256 with overlapping same-role music. Solo was restored off; this route was rejected (`Solo-Scope-Probe.json`).
- A selected clip range exported exactly 16.333 seconds while the accompanying XML retained the full 19.333-second project, UID, and semantic fingerprint (`Range-XML-Scope-Probe.json`).
- A Cathedral 2 reverb tail measured -34.863 dBFS RMS after the beep inside a three-second clip. Splitting that first clip at one second gated the tail completely in the following silent clip. This supports ordinary, unexpanded clip boundaries only (`Reverb-Boundary-Probe.json`).
