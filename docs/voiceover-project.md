# Editable voice-over project milestone

October 28, 2026. The selected voice-over milestone passed offline checks and fresh native Analyze → Apply tests in Final Cut Pro 12.4 (454072). The installed app and distributable ZIP contain the tested helper.

## Behavior

Detection or output changes now invalidate the prior review and require a manual Analyze click. Return, field blur, Save Settings, and idle polling do not start recalculation or host verification. See [manual Analyze behavior](fast-review.md).

Select one supported normal-speed, audio-only primary-storyline clip, open Silent Snip Controls, and choose Analyze. Review the cuts and choose Apply. Apply creates a project named `<clip> — Cleaned — <request prefix>` in the source event and library, then opens and verifies it. The request retains its name through verification retries; another Analyze gets another name. No Replace decision is authorized for new voice-over results.

The new project contains only the retained segments of that selected occurrence and optional one-second gaps. It starts at zero, while source trims keep their original media-time coordinates. Leading timeline gaps, neighboring clips, and unrelated project content are not copied into the result. The original project remains intact. Full original recovery XML, edited XML, cut reports, settings, and verification receipts remain in the result folder.

Existing audio processing participates in analysis. Unprocessed clips use their source audio; adjusted or processed clips use the verified isolated Final Cut render. There is no source-audio fallback after a failed render. Output segments reference the original media and retain gain, channel configuration, effect order, bypass states, parameters, and supported source-time automation. The effects are editable rather than baked into replacement media. Only the known passthrough Silent Snip detector is omitted from the cleaned segments. It stays on the original recording, and exact detection settings are saved in `Analysis-Settings.json`. The new-project flow therefore needs no per-segment detector-state recovery or extra Controls windows during Apply.

Apply still checks fresh project, selected occurrence, effects, and source-media evidence. Result verification checks exact edits, original source references, intended event/library, and all processing effects. The selected recording's saved media fingerprints are retained even when the input project references additional media. A failed verification offers verification of the existing result, never another automatic import. Reopen Controls on the original recording to verify a saved new-project result after a helper restart. Older results that retained a detector on every segment continue to use the legacy settings-recovery path.

Final Cut's Share interface remains visible during XML capture and processed-audio rendering. This milestone does not establish a new background export API. Existing compatibility restrictions still apply; it does not add linked-video, compound, multicam, retiming, or arbitrary connection support.

## Offline evidence

`VoiceOverProjectTests` covers a trimmed selected recording at a nonzero timeline offset and nonzero project timecode, surrounded by other timeline content. Checks cover separate-project identity, original event, output duration, source mapping, effects/gain/bypass retention, removal and gap modes, original recovery contents, selected-source fingerprints, and rejection of changed processing or destinations. The existing render-routing, isolation, and import-recovery suites remain applicable.

Logs are `build/voiceover-focused-tests.log`, `build/voiceover-full-tests.log`, `build/voiceover-controls-tests.log`, `build/voiceover-audio-tests.log`, and `build/voiceover-build-script-tests.log`. Test results are recorded after each run; successful builds and offline checks alone do not prove native editing.

The current run passed 436 Swift tests (one existing skip, zero failures), including 36 focused output/isolation/import checks; 35 Controls scenarios and the protocol contract; 60 audio render/persistence cases; and 53 build-script tests. The initial sandbox run could not generate Xcode debug symbols. The successful Swift runs used the same `build/swift` cache with access to the required macOS tooling and media services.

## Native verification

All live work must use the existing workspace-root `Cutdown Integration.fcpbundle`. `Scripts/make-voiceover-fixture.py` generates synthesized narration with deliberate pauses, a source trim, a leading gap, and a disposable neighbor. It refuses to overwrite existing fixture folders. Media is referenced in place. An optional owned effects-template XML supplies Noise Gate and Limiter to the processed fixture.

The final build completed these actual Controls Analyze → Apply runs. Each result opened automatically in the original event of the required library. Verification exported the host result and matched its complete semantic timeline, processing effects, and original-media fingerprints.

| Run | Request prefix | Result duration | Editable output | Verification |
| --- | --- | --- | --- | --- |
| Plain removal | `7835EFC8` | 11.467 s | Four original-media segments | Passed |
| Noise Gate + Limiter removal | `33B22B4F` | 11.400 s | Four segments with both effects | Passed |
| Noise Gate + Limiter gaps | `22D4B8FE` | 14.400 s | Four processed segments and three exact one-second gaps | Passed |

The selected recording was 16.333 s within a 19.333 s source project with a leading gap and neighboring clip. Every cleaned project starts at zero, excludes those unrelated items, and retains original source trims. Processed runs used decimal detection settings: -42.5 dBFS, 0.25 s minimum, and 0.125 s padding on each side. `Analysis-Settings.json` retained those exact values. Render verification matched the isolated project's Noise Gate and Limiter before the rendered audio was analyzed; final-result verification independently matched the editable effect chain after import. The cleaned segments contain no Silent Snip detector.

Plain analysis took 3.334 s in the final run; processed removal took 19.339 s and processed gaps 16.711 s. These are individual generated-fixture observations, not general performance guarantees. Processing state remained ineligible for measurement-cache reuse rather than relaxing effect fidelity checks.

A separate **Verify Existing Result…** operation opened the completed `33B22B4F` result from the original recording's Controls. It retained host UUID `ACCF8D86-DA2B-49A2-B08A-238632C57D34`, passed verification again, and left one matching browser project without another import.

Post-Apply native XML exports of both originals matched their pre-Apply timeline, media references, and DSP state. The comparison normalized export-local resource IDs, numeric time spelling, bookmarks, dates, and the known passthrough detector. Generated narration SHA-256 remained `7f41ba048564a5d5876bc7d9e9611657fc8eb4cedd927750a7d95c9351c74bc8`. The prior global last-used settings were restored byte-for-byte after closing the host.

Evidence is preserved under `build/VoiceOverMilestone/`: `Native-Evidence.json`, `Original-Preservation.json`, post-Apply original exports, screenshots, and separate `Plain-Final-7835EFC8`, `Effects-Final-33B22B4F`, and `Gaps-Final-22D4B8FE` folders containing analysis timing, render comparisons, output/recovery XML, settings, receipts, and verification exports. Earlier diagnostic failures are preserved separately and are not counted as passing final-build runs. The published app, installed helper, and ZIP executable hashes match.

## Remaining limits

Final Cut's Share panels remain visible. The tests establish this supported audio-only voice-over flow with the tested effects, not universal plugin, timeline, or host-version compatibility. One processed gap run could not confirm temporary-project removal after a keyboard-focus interruption during cleanup; its review and final cleaned result still verified successfully. The final browser no longer showed that exact analysis copy. The conservative warning and `Cleanup-Status.txt` were preserved. Automatic cleanup confirmation therefore remains susceptible to focus changes. No user library or project outside the required integration library was tested.
