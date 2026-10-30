# Silent Snip workflow

Updated October 29, 2026. The general-project changes have passed offline checks; see [current live status and performance evidence](general-project-performance.md). The following voice-over results describe the preceding revision. The selected voice-over new-project flow passed native removal and gap tests in Final Cut Pro 12.4, including Noise Gate and Limiter. This does not establish every plugin or timeline topology. Superseded native-edit and export workflows are archived in `integration-history.md`; broader integration work remains in progress.

Silent Snip is a local silence-removal tool for Final Cut Pro. The user adds an audio effect, analyzes one selected clip with audio, reviews proposed cuts, and explicitly applies them by creating a new cleaned project through XML. The original project stays unchanged. The effect itself passes audio through unchanged; the helper performs analysis and creates the editable result. The [new-project milestone](voiceover-project.md) records verification and remaining limits.

## 1. Install and prepare

Copy **Silent Snip.app** into Applications, open it once, then follow [first-time setup](setup.md) to grant macOS control access and create a **Silent Snip** Share destination with that copied app as its action. The app contains the background workflow and audio extension. The scissors menu bar icon shows that Silent Snip is running and provides status, saved results, and Quit. Controls is the main interface; a separate app window is not expected.

For source development, quit Final Cut and Silent Snip and run `Scripts/build.sh --release`. It builds and registers `build/App/Silent Snip.app` in place. Keep that bundle there while using it, or copy it into Applications and update the Share action. Ad hoc rebuilds can require a fresh control-access grant.

Share is part of the helper's implementation. The normal user interaction does not require manually exporting XML, choosing an export method, or sending a project to Silent Snip.

Final Cut's native Share interface remains visible. Silent Snip creates no covering or separate progress window. Keep Final Cut in front during host automation; analysis and file processing run in the background, but the Share, project-navigation, and import steps still use its interface.

XML capture now always uses the Share exchange; the unused Export XML / Go to Folder / Save-dialog driver has been removed. The helper still starts and confirms the Silent Snip Share destination through Accessibility. Apple's documented exchange supplies output paths and delivery, but does not provide a command here to initiate sharing without host UI.

Host actions are conditional: range clearing is skipped when the timeline is verified to have no range selection, export tabs already selected are left alone, and opening an already visible imported project skips Libraries navigation and the filmstrip switch. Timeline focus uses the direct Accessibility property first, with a verified menu fallback. Existing selected ranges still use the host's advertised Clear Selected Ranges shortcut (or its menu fallback), followed by verification. Project opening selects the exact browser item through Accessibility, with a hit-tested single-click fallback, verifies sole selection and browser focus, then invokes Clip → Open Clip. It confirms the requested timeline before exporting its XML for identity/content verification.

## 2. Select the audio clip

Open a project and select the particular clip occurrence with audio in the primary storyline. Add **Silent Snip Audio** from the Effects browser. Open **Audio Inspector → Silent Snip Audio → Controls**.

The supported target is one normal-speed direct asset clip with enabled audio and available source media. It can be audio-only or a camera clip with linked video/audio. Cuts split and trim both linked streams together. Source trims and repeated uses of the same file are distinguished by the selected occurrence. Split audio/video edits, connected targets, compounds, multicam, and retiming still require additional support.

Other project content is checked for compatibility. Retimed or nested targets, ambiguous selections, disabled audio, unsupported transitions, nested connections, connected dialogue, conflicting lanes, and some timed automation/component trims can prevent output. An isolated analysis render does not remove these editing restrictions.

## 3. Set detection and output

The four detection controls are available in Controls and the native Audio Inspector. Both edit the same parameters; the Inspector exposure lets Final Cut persist their state:

| Setting | Default | Meaning |
|---|---|---|
| Silence Threshold | −40 dBFS | Windows below this level in every channel qualify as quiet. Raising it toward zero includes louder quiet material. |
| Minimum Silence | 0.5 seconds | The proposed removal must reach this length after padding and frame rounding. |
| Before Speech | 0.1 seconds | Retain this much quiet audio immediately before speech resumes. |
| After Speech | 0.1 seconds | Retain this much quiet audio immediately after speech ends. |

Minimum Silence accepts 0.0001–10 seconds. Analysis measures audio in 0.01-second windows, and cuts snap to project frames. With the default 0.1-second padding on each side, a quiet interval generally needs at least Minimum Silence plus 0.2 seconds, and frame rounding can require more.

Choose **Remove Silence** to close the selected pauses, or **Replace with 1-Second Gaps** to replace each selected pause with an editable gap. One second is rounded to the nearest project frame. Gap mode can lengthen a pause that was shorter than one second.

Use **Save Settings** to commit the four values without starting analysis. New effect instances use last-used detection settings saved when Analyze is submitted. Existing instances restore their own saved state. Changing threshold, minimum silence, padding, or output mode marks the previous review **Settings changed—Analyze again.** Its cuts remain visible but inactive. Typing, Return, leaving a field, Save Settings, and polling never recalculate cuts or start a Final Cut export. Click **Analyze Again** manually to capture and analyze the current settings. Apply and cut navigation remain disabled until that fresh request completes; see [manual analysis behavior](fast-review.md).

## 4. Analyze

Click **Analyze**. It does not apply cuts. The button disables immediately while the request connects; repeated clicks cannot cancel and replace a pending analysis. A failed launch or response timeout releases it for retry.

Controls reserves review space from first opening so Final Cut's fixed host window can show detection settings, four cut rows, and the footer actions together. Longer lists scroll within the table; smaller fixed hosts can scroll the inspector.

**Controls is the single Silent Snip interface.** The helper runs in the background and keeps the job when Final Cut recreates the effect view during rendering. After returning to the original project, Silent Snip attempts to restore Controls. A recreated view reconnects only after the helper verifies that its unique native control belongs to the original selected clip and project; it then restores the submitted settings and retrieves the latest review. Reopening Controls on that original clip also reconnects. Another clip cannot adopt a global “latest review.” Use Cancel in Controls to discard the current review or stop a running operation. Native plain and processed runs restored Controls automatically. The helper reveals the exact controller button when it is below the Inspector viewport, then rechecks its native identity before opening it.

The helper captures project XML through the configured Share exchange, identifies the target and its Silent Snip controller, records project/media state, and selects an audio-analysis route:

- **Unprocessed clip:** decode the original source audio over the selected source interval.
- **Processed clip filling the entire project:** when the XML proves that this is the only timeline item and every enabled audio component belongs to Dialogue, the app renders directly in the original project. The render’s fresh XML must match project identity, effects, media, timing, and full scope. No temporary project is imported or deleted.
- **Mixed project:** direct primary clips and gaps can use a verified Dialogue render, with simple direct connected music and B-roll retained in the edit. Small edits with no earlier or overlapping Dialogue use a full-project render when extra duration is at most 30 seconds and no longer than the target; the app checks the whole duration and measures only the selected interval. Longer edits and clips with preceding Dialogue use an exact native selected range, verified against the clip's edges and duration before Share. The full-project XML still accompanies the selected-range audio. Other overlapping Dialogue prevents this direct route. Explicit Music/Effects export files are excluded through the verified native role layout. A successful render supplies only a process-local routing hint for the next explicit Analyze: new audio and new XML arrive together, with fresh source hashes and a matching render scope. No prior PCM is reused for opaque effects.
- **Other processed clips:** the app creates an isolated analysis project referencing the original media. It retains the target's audio processing, removes the passthrough Silent Snip controller, and excludes neighboring timeline items. It imports that project and requests rendered audio plus XML in one Share exchange. Before using the audio, it verifies that the delivered XML matches the intended isolated project, including timing, media, and rendering effects, and binds Final Cut's newly assigned project UUID. It then returns to and rechecks the original project. The preceding XML-only verification Share was removed because the render already delivers the project XML. It does not silently substitute source audio when rendering or verification fails.

Every Analyze captures fresh project XML and checks source contents. For effects that cannot safely reuse measurements, source hashing overlaps host rendering; the app joins it and revalidates before publishing review. When those checks, the selected occurrence, host session, and complete supported processing state match the process-local cache, it recalculates cuts from retained measurements using the new threshold, minimum silence, and padding. A cache hit skips decoding and the isolated render. Preset names, omitted settings, partial native parameter lists, and unknown effects are insufficient evidence and force the normal route. See [cache limits and timing reports](analysis-speed.md).

The isolated-render route passed fresh processed removal and gap runs with Noise Gate and Limiter; see the milestone evidence. The uniquely named analysis project imports into the original event. After verified rendering and return to the original project, the helper removes only its exact generated project through Final Cut. Unverified or interrupted cleanup leaves the project in place and records `Cleanup-Status.txt` in the analysis job folder.

An ineligible mixed-project processed Analyze cache miss requires three Share exchanges (original XML, isolated audio plus XML, and restored-original XML), down from four. Apply retains its two exchanges for a fresh baseline and imported-result verification. These are source-level operation counts, not measured live speedups. During analysis the captured XML bytes are reused; the missing-callback fallback parses only changed XML while retaining its existing three-second stability requirement. Audio and source-content checks remain in place.

Simple direct connected music and B-roll follow the same project-time cuts as the target. Their surviving source intervals, gains, effects, source-time curves, and annotations remain editable. Gap output leaves the corresponding connected intervals empty. Connected dialogue and fades remain protected; nested/retimed connections, overlapping lane conflicts, and unsupported trims are rejected before Apply. See [verified scope and timing](general-project-performance.md).

### Using other audio plugins

Apply your Noise Gate, Compressor, EQ, Limiter, or third-party Audio Unit to the same clip with audio as Silent Snip Audio, then click Analyze. Silent Snip measures Final Cut's processed output from the complete effect chain. Silent Snip itself is passthrough, so its position in the chain does not select which other effects are analyzed. The order of the processing effects still matters and is preserved.

The rendered audio is a temporary analysis file, not replacement media. The edited project continues to reference your original source files and keeps the effects editable on each retained clip segment. Silent Snip does not bake the effects into a new audio clip. The Share-delivered rendered media is cleaned up after analysis; an eligible cache retains one verified, bounded copy until eviction or helper shutdown; the analysis project is removed after verified use; any cleanup failure is reported as described above.

A noise gate can make background noise qualify as silence; compression, makeup gain, or limiting can change what falls below the detection threshold. Set those effects first and analyze again after changing their settings, order, presets, or bypass state. Apply retains the effect entries and their settings on each editable audio segment; host re-export verification must pass before success is reported. If Final Cut drops or changes plugin state on import, Silent Snip stops verification rather than reporting preserved effects.

This is generic audio-effect handling, not certification of every installed plugin. Source-time keyframes are preserved with all surrounding curve points. Fades stay only on the original outer edges; a proposed cut intersecting a fade is unavailable rather than reshaping that fade. Empty/invalid animations and trimmed audio components still prevent Apply. Retimed clips, compound clips, external sidechain routing, and plugin behavior across new cut boundaries are not established by these compatibility tests. Normal-speed direct camera clips are supported by cutting linked video and audio together; split audio/video edits and retiming remain unsupported.

Detection measures RMS loudness in 10 ms windows. A window is quiet only when every channel is below the threshold. Adjacent quiet windows form candidate pauses. The detector retains before/after padding, rounds removal boundaries inward to project frames, and applies Minimum Silence to the resulting removal. Entirely silent targets are not automatically deleted.

This is level detection, not a speech or breath classifier. Quiet breaths can qualify. RMS values can differ from Final Cut's peak meter readings.

The helper checks whether the proposed edits can be represented in an editable output project before enabling Apply. The window displays operation status, measured decoding progress when available, and elapsed time; host operations can show indeterminate progress.

## 5. Review

Verified cut rows may arrive with “Preview ready” while temporary-project cleanup finishes. Apply, cut selection, and navigation remain disabled until the operation returns to review. Cancellation discards this early result. Each job records time to preview separately from completion time; restoring Controls can still delay when the user sees it.

Read the summary and proposed start/end times and durations. Ineligible ranges are marked unavailable. The timeline automatically shows numbered boundaries for the included cuts: green START lines and orange END lines. These are helper overlays, not native markers or edits.

Unchanged status polls keep the connection alive without rebuilding the cut list.

Closing Controls leaves the preview active. Cancel the review to clear it. Applying, cancelling, or replacing the review clears its preview. Inspector scrolling or a collapsed effect list does not establish that an effect was removed; those states no longer terminate the preview. After changing or removing effects, cancel or reanalyze before using the review. Apply still checks the fresh project baseline. The overlay is ordered immediately above the verified project window, so macOS composites overlapping windows naturally. Geometry that cannot be verified hides the overlay.

Select a row in Controls and choose **More → Go to Selected Cut** to move the playhead to that cut’s start. The helper first re-exports and checks the original project against the analysis baseline; navigation cannot run alongside Apply. It uses [Final Cut’s timecode navigation](https://support.apple.com/guide/final-cut-pro/ver1632d762/mac), including project start timecode and drop-frame formatting. It does not change cut inclusion or make edits.

Use the checkbox beside each eligible range, or **More → Select All Cuts / Select No Cuts**, to choose cuts. Apply waits for the helper to acknowledge inclusion changes. Unavailable rows explain their restriction in a tooltip. A settings or output-mode change invalidates the old review and disables selection, navigation, and Apply until the user clicks Analyze again and that new analysis finishes. Changing timeline content, source media, or audio processing requires Analyze again.

Apply requires a valid review, at least one eligible included cut, unchanged submitted settings, and a plan that has not already been consumed. Changing timeline content, processing effects, or source media requires fresh analysis; Apply checks for stale project state before generating output.

If **Go to Cut** detects a changed project, Silent Snip discards the stale review and preview and requires Analyze again. A recoverable navigation error keeps the review. Failed or cancelled timecode entry attempts bounded cleanup only while Silent Snip still owns the field, project, and keyboard focus.

## 6. Apply Cuts

Click the separate **Apply Cuts** button. The helper:

1. Captures the original project again and compares its identity, timeline, effects, frame rate, duration, and source media with the analyzed baseline.
2. Builds every selected cut in one FCPXML transformation, using the chosen output mode. The result copies the full project, preserves its timecode origin and surrounding content, and cuts the selected clip while retaining source trims and editable effects. Later primary items and their connections move by the exact removed duration.
3. Saves recovery XML, edited XML, the edit report, and exact detection settings in a new result folder.
4. Sends exactly one uniquely named cleaned project to the original event and library. The name contains the clip name and a stable request suffix. No **Replace** or **Keep Both** decision is authorized for a new cleaned-project result.
5. Opens the new project, re-exports it, and verifies the intended event/library, host project identity, timeline, media references, and processing effects before reporting completion.

Import delivery is asynchronous. The helper waits for the uniquely named result to become available. It records dialogs in `Import-Dialogs.json`. Only an identified completed-import warning is acknowledged automatically for a new cleaned-project result; replacement and unrecognized dialogs remain open. Retry Verification never imports again or accepts a replacement prompt. Historical pending replacement receipts retain their separately scoped verification rules.

The original project and source media remain unchanged. Each new analysis can create a separately named result project in the original event; retrying verification never creates another project. Final Cut assigns a new internal project identity. The pre-Apply project is also saved as `Before-Cuts.fcpxml` on disk. Retained audio stays editable and references the existing media. Unrelated timeline clips remain in both the original and the cleaned project copy. The writer verifies their source trims, effects, and expected positions.

**September 22 validation:** manual host XML replacement probes in this checkout’s required integration library kept one project across repeated replacements. This establishes the host’s name-based replacement behavior, not an automatic Analyze/Apply run of the updated helper. See [replacement evidence and limitations](xml-replacement.md).

The cleaned segments retain all sound-processing effects. The known passthrough Silent Snip detector stays on the original recording instead of being duplicated onto every cut. Exact submitted detection settings are saved in `Analysis-Settings.json`. Apply therefore does not open extra detector Controls windows to recover settings. Rendering effect changes still fail verification. Older saved results that include the detector retain their separate `controllerSettingsPreserved` and settings-recovery checks.

## 7. Continue editing or recover

Listen around cut boundaries and continue editing in the new cleaned project. Open the unchanged original project to return to the pre-Apply edit. The saved `Before-Cuts.fcpxml` is an additional recovery copy with a distinct recovery name and identity. Recovery history stays in the result folders until explicitly imported.

Result artifacts live under `~/Library/Application Support/Silent Snip/Results/<request UUID>/`:

| Artifact | Purpose |
|---|---|
| `Silent Snip.fcpxml` | Generated edited project. |
| `Before-Cuts.fcpxml` | Separately named recovery project referencing existing source media. |
| `Edit-Report.json` | Details of the generated edits. |
| `Analysis-Settings.json` | Exact detection settings used. |
| `Import-Status.txt` | Whether import was requested or verification completed. |
| `Import-Dialogs.json` | Observed import dialogs and warnings, when present. |
| `Verification-*.fcpxmld` | Host re-exports for verification and recovery; older runs used `Imported.fcpxmld`. |
| `Verification-Receipt.json` | Saved expected-XML hash, request settings, and bound host project identity for resuming verification. |
| `Import-Verification.json` | Comparison report, when comparison is reached. |

If Apply stops before delivery, no result import was requested. If delivery was attempted but verification fails or is interrupted, the cleaned project may already exist: check it before importing again. The original project stays unchanged. Lost Apply messages are retried using the same job identity and cannot apply a consumed plan twice. After 15 seconds without an accepted response, the window disables the old review and permits fresh Analyze; first check for the existing result. A running helper operation still blocks a new analysis until it finishes. Existing result folders are not overwritten.

The helper retains progress and review state independently of the view. Controls polls the latest cached response and reconnects after host view recreation. Returning to a hidden view grants a fresh response interval. Terminal errors remain visible without a heartbeat; after a timeout, read-only polling continues so a delayed error can replace the provisional message. Apply remains disabled for that expired review. Invalid or oversized review payloads still stop the review; there is no separate fallback review window. See the [missing-preview correction](preview-connection.md) for the confirmed Noise Gate/Limiter render mismatch and current installation steps.

After an import or verification failure, use **Retry Verification** in the original recording's Controls. It opens the existing result, exports it again, and performs the comparisons; it has no import step. After a helper restart, return to the original project and recording, open its Controls, and use **Verify Existing Result…**, choosing the result folder’s `Silent Snip.fcpxml`. Older results can be adopted from their matching `Edit-Report.json` and `Analysis-Settings.json`. Altered/mismatched artifacts are rejected. Once a host project identity has been verified, later retries must match that identity as well as the complete expected timeline. The helper keeps at most 24 pending receipt locations in memory and releases completed verification data. Older pending results remain on disk and can be reopened with **Verify Existing Result…**.

Controls disables Retry Verification while waiting for acknowledgment and resends a lost request safely. A later failed attempt permits another explicit retry. If another review prevents verification from starting, the helper explains that and releases the button. Use both matching builds from the [current cleanup update](cleanup-fixes.md).

If Final Cut drops Silent Snip settings during import, recovery selects each exact imported occurrence and restores the four native numeric fields, then re-exports and verifies the actual state. Numeric entry avoids the native sliders' rounding of values such as 0.125 seconds on Final Cut 12.4. The custom Controls fields and **Save Settings** remain a fallback when native fields are unavailable. Each segment gets its own verified selection identity, including when multiple segments have the same name. A controller write alone does not count as success. Interrupted recovery is retryable; matching segments are skipped. Settings recovery writes only to the verified result. **Restore Saved Settings…** remains available as a manual fallback.

## 8. Verification boundary

Historical evidence establishes editable XML cut structure, source interval preservation, and selected earlier button/native-edit flows. It also records Final Cut dropping Silent Snip settings on XML import. These findings do not prove that the current isolated-render and automatic import-verification workflow has passed end to end in the installed build.

Historical September 17 Analyze follow-up (superseded two-window design): after stopping stale helpers, the six-second generated fixture completed automatic processed-audio analysis, render/original verification, and temporary-project cleanup. Its recreated Controls view lost the review, prompting the now-removed helper-owned window. The new window passed focused tests and a subsequent live Analyze completed after restarting the helper to recognize the permission already granted. The helper window visibly showed one selected 1.933-second cut, with selection, preview, and Apply enabled. No permission setting or binary changed during that restart. No Apply was tested. Evidence and limitations: `build/AnalyzeVisibilityVerification/Notes.md`. Any future Final Cut integration test must use a small disposable project in this workspace's existing **Cutdown Integration.fcpbundle**, reference generated source media in place, and avoid copied, optimized, or proxy media.
