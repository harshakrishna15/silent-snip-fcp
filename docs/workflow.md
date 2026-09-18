# Cutdown workflow

Updated September 18, 2026, from the effect window and helper source. This describes the implemented workflow, not a claim that the current build has passed every live integration step. Superseded native-edit and export workflows are archived in `integration-history.md`. The integration overhaul remains marked in progress.

Cutdown is a local, audio-only silence-removal tool for Final Cut Pro. The user adds an audio effect, analyzes one selected clip, reviews proposed cuts, and explicitly applies them to a separate editable project. The effect itself passes audio through unchanged; the helper performs analysis and project creation.

## 1. Install and prepare

For a local development installation, quit Final Cut and the Cutdown helper, then run these commands from the workspace:

```sh
./Scripts/build-helper.sh --release
./Scripts/build-audio-plugin.sh
./Scripts/register-local.sh --check-only
./Scripts/register-local.sh
```

Keep the registered bundles at their build locations. Complete [first-time setup](setup.md) to grant the helper macOS control access and create a Share destination named **Cutdown** targeting `build/Cutdown.app`. Neither step is performed by registration. Reopen Final Cut after registration. The helper has no separate application window; the Audio Unit's Controls window is its interface.

After an ad hoc rebuild, quit and relaunch the helper if an existing permission grant is not recognized. If that does not restore access, refresh its entry in the macOS control-access settings. Changed ad hoc builds can require a new grant; an existing consistent signing identity can be used for development.

Share is part of the helper's implementation. The normal user interaction does not require manually exporting XML, choosing an export method, or sending a project to Cutdown.

XML capture now always uses the Share exchange; the unused Export XML / Go to Folder / Save-dialog driver has been removed. The helper still starts and confirms the Cutdown Share destination through Accessibility. Apple's documented exchange supplies output paths and delivery, but does not provide a command here to initiate sharing without host UI.

Host actions are conditional: range clearing is skipped when the timeline is verified to have no range selection, export tabs already selected are left alone, and opening an already visible imported project skips Libraries navigation and the filmstrip switch. Timeline focus uses the direct Accessibility property first, with a verified menu fallback. Existing selected ranges still use the host's advertised Clear Selected Ranges shortcut (or its menu fallback), followed by verification. Project opening selects the exact browser item through Accessibility, with a hit-tested single-click fallback, verifies sole selection and browser focus, then invokes Clip → Open Clip. It confirms the requested timeline before exporting its XML for identity/content verification.

## 2. Select the audio clip

Open a project and select the particular audio-only clip occurrence in the primary storyline. Add **Cutdown Audio** from the Effects browser. Open **Audio Inspector → Cutdown Audio → Controls**.

The supported target is one normal-speed audio-only clip with available source media. Source trims and repeated uses of the same file are distinguished by the selected timeline occurrence. A target containing video is rejected, although an audio-only insertion can reference a file with an unused video stream.

Other project content is checked for compatibility. Retimed or nested targets, ambiguous selections, disabled audio, unsupported transitions, target connections, connections crossing cuts, and some timed automation/component trims can prevent output. An isolated analysis render does not remove these editing restrictions.

## 3. Set detection and output

The four detection controls live in the Controls window:

| Setting | Default | Meaning |
|---|---|---|
| Silence Threshold | −40 dBFS | Windows below this level in every channel qualify as quiet. Raising it toward zero includes louder quiet material. |
| Minimum Silence | 0.5 seconds | A continuous quiet interval must reach this length before padding is applied. |
| Before Speech | 0.1 seconds | Retain this much quiet audio immediately before speech resumes. |
| After Speech | 0.1 seconds | Retain this much quiet audio immediately after speech ends. |

Choose **Remove Silence** to close the selected pauses, or **Replace with 1-Second Gaps** to replace each selected pause with an editable gap. One second is rounded to the nearest project frame. Gap mode can lengthen a pause that was shorter than one second.

Use **Save Settings** to commit the four values without starting analysis. New effect instances use last-used detection settings saved when Analyze is submitted. Existing instances restore their own saved state. Changing settings or output mode disables Apply until Analyze runs again.

## 4. Analyze

Click **Analyze**. It does not apply cuts. The button disables immediately while the request connects; repeated clicks cannot cancel and replace a pending analysis. A failed launch or response timeout releases it for retry.

**Controls is the single Cutdown interface.** The helper runs in the background and keeps the job when Final Cut recreates the effect view during rendering. After returning to the original project, Cutdown attempts to restore Controls. A recreated view reconnects only after the helper verifies that its unique native control belongs to the original selected clip and project; it then restores the submitted settings and retrieves the latest review. Reopening Controls on that original clip also reconnects. Another clip cannot adopt a global “latest review.” Use Cancel in Controls to discard the current review or stop a running operation. This revised host reconnection still requires live verification.

The helper captures project XML through the configured Share exchange, identifies the target and its Cutdown controller, records project/media state, and selects an audio-analysis route:

- **Unprocessed clip:** decode the original source audio over the selected source interval.
- **Processed clip:** the current source creates an isolated analysis project referencing the original media. It retains the target's audio processing, removes the passthrough Cutdown controller, and excludes neighboring timeline items. It imports that project and requests rendered audio plus XML in one Share exchange. Before using the audio, it verifies that the delivered XML matches the intended isolated project, including timing, media, and rendering effects, and binds Final Cut's newly assigned project UUID. It then returns to and rechecks the original project. The preceding XML-only verification Share was removed because the render already delivers the project XML. It does not silently substitute source audio when rendering or verification fails.

Every Analyze first captures fresh project XML and checks source contents. When those checks, the selected occurrence, host session, and complete supported processing state match the process-local cache, it recalculates cuts from retained measurements using the new threshold, minimum silence, and padding. A cache hit skips decoding and the isolated render. Preset names, omitted settings, partial native parameter lists, and unknown effects are insufficient evidence and force the normal route. See [cache limits and timing reports](analysis-speed.md).

The isolated-render route is part of the current overhaul; historical manual processed-audio tests do not establish a successful automatic run of this newer route. Analysis projects appear in a **Cutdown Analysis** event. After verified rendering and return to the original project, the helper removes only its exact generated project through Final Cut. Unverified or interrupted cleanup leaves the project in place and records `Cleanup-Status.txt` in the analysis job folder.

A processed Analyze cache miss requires three Share exchanges (original XML, isolated audio plus XML, and restored-original XML), down from four. Apply retains its two exchanges for a fresh baseline and imported-result verification. These are source-level operation counts, not measured live speedups. During analysis the captured XML bytes are reused; the missing-callback fallback parses only changed XML while retaining its existing three-second stability requirement. Audio and source-content checks remain in place.

### Using other audio plugins

Apply your Noise Gate, Compressor, EQ, Limiter, or third-party Audio Unit to the same audio-only clip as Cutdown Audio, then click Analyze. Cutdown measures Final Cut's processed output from the complete effect chain. Cutdown itself is passthrough, so its position in the chain does not select which other effects are analyzed. The order of the processing effects still matters and is preserved.

The rendered audio is a temporary analysis file, not replacement media. The edited project continues to reference your original source files and keeps the effects editable on each retained clip segment. Cutdown does not bake the effects into a new audio clip. The Share-delivered rendered media is cleaned up after analysis; an eligible cache retains one verified, bounded copy until eviction or helper shutdown; the analysis project is removed after verified use; any cleanup failure is reported as described above.

A noise gate can make background noise qualify as silence; compression, makeup gain, or limiting can change what falls below the detection threshold. Set those effects first and analyze again after changing their settings, order, presets, or bypass state. Apply retains the effect entries and their settings on each editable audio segment; host re-export verification must pass before success is reported. If Final Cut drops or changes plugin state on import, Cutdown stops verification rather than reporting preserved effects.

This is generic audio-effect handling, not certification of every installed plugin. Source-time keyframes are preserved with all surrounding curve points. Fades stay only on the original outer edges; a proposed cut intersecting a fade is unavailable rather than reshaping that fade. Empty/invalid animations and trimmed audio components still prevent Apply. Retimed clips, compound clips, external sidechain routing, and plugin behavior across new cut boundaries are not established by these compatibility tests. Linked-video cutting remains outside the current audio-only scope.

Detection measures RMS loudness in 10 ms windows. A window is quiet only when every channel is below the threshold. Adjacent quiet windows form candidate pauses. The detector applies minimum duration, retains before/after padding, and rounds removal boundaries inward to project frames. Entirely silent targets are not automatically deleted.

This is level detection, not a speech or breath classifier. Quiet breaths can qualify. RMS values can differ from Final Cut's peak meter readings.

The helper checks whether the proposed edits can be represented in an editable output project before enabling Apply. The window displays operation status, measured decoding progress when available, and elapsed time; host operations can show indeterminate progress.

## 5. Review

Verified cut rows may arrive with “Preview ready” while temporary-project cleanup finishes. Apply, cut selection, and navigation remain disabled until the operation returns to review. Cancellation discards this early result. Each job records time to preview separately from completion time; restoring Controls can still delay when the user sees it.

Read the summary and proposed start/end times and durations. Ineligible ranges are marked unavailable. Use **Show Cut Preview** to show or hide numbered boundaries over the timeline: green START lines and orange END lines. These are helper overlays, not native markers or edits.

Controls keeps the preview checkbox at its last confirmed state while a toggle is pending. It becomes available again when the helper acknowledges the change. Unchanged status polls keep the connection alive without rebuilding the cut list.

Closing Controls leaves the preview active. Turn off the checkbox to hide it. Applying, cancelling, or replacing the review clears its preview. Inspector scrolling or a collapsed effect list does not establish that an effect was removed; those states no longer terminate the preview. After changing or removing effects, cancel or reanalyze before using the review. Apply still checks the fresh project baseline. The overlay is ordered immediately above the verified project window, so macOS composites overlapping windows naturally. Geometry that cannot be verified hides the overlay.

Select a row in Controls and click **Go to Selected Cut** to move the playhead to that cut’s start. The helper first re-exports and checks the original project against the analysis baseline; navigation cannot run alongside Apply. It uses [Final Cut’s timecode navigation](https://support.apple.com/guide/final-cut-pro/ver1632d762/mac), including project start timecode and drop-frame formatting. It does not change cut inclusion or make edits.

Use the checkbox beside each eligible range, or Select All / Select None, to choose cuts. Apply waits for the helper to acknowledge inclusion changes. Unavailable rows explain their restriction in a tooltip. A settings or output-mode change still requires Analyze again.

Apply requires a valid review, at least one eligible included cut, unchanged submitted settings, and a plan that has not already been consumed. Changing timeline content, processing effects, or source media requires fresh analysis; Apply checks for stale project state before generating output.

If **Go to Cut** detects a changed project, Cutdown discards the stale review and preview and requires Analyze again. A recoverable navigation error keeps the review. Failed or cancelled timecode entry attempts bounded cleanup only while Cutdown still owns the field, project, and keyboard focus.

## 6. Apply Cuts

Click the separate **Apply Cuts** button. The helper:

1. Captures the original project again and compares its identity, timeline, effects, frame rate, duration, and source media with the analyzed baseline.
2. Builds every selected cut in one FCPXML transformation, using the chosen output mode.
3. Saves recovery XML, edited XML, the edit report, and exact detection settings in a new result folder.
4. Sends the edited project to Final Cut once, with a name such as **Original Project — Cutdown ABC123**, in **Cutdown Results** in the source library.
5. In the current source, opens the imported result, re-exports it, and compares its timeline, media references, and rendering effects with the generated project before reporting verified completion.

Import delivery is asynchronous. Before opening the result, Cutdown waits up to 30 seconds for that exact project to appear and the import dialogs to settle. If the result is not exposed, it reveals the Libraries browser once after dialogs settle, while verifying that the original project is still current. It records observed dialogs in `Import-Dialogs.json`. A completed-import warning is acknowledged only when it names the delivered XML and offers only OK; its warnings remain recorded and the full re-export comparison still runs. Other dialogs remain open and are identified in the error. A stopped verification updates `Import-Status.txt` and never resends the edited XML automatically. The initial September 17 import fix is installed. Later browser/helper fixes and the new verification, navigation, and settings-recovery features are staged for installation in matching helper and audio-plugin builds. The user is handling live verification. Automatic Apply success is not yet established for this revision. See `build/ImportCompletionVerification/Notes.md` and `docs/overhaul-progress.md`.

The original project and source media remain unchanged. Retained audio becomes editable segments referencing the existing media; this is not a flattened replacement audio file. Interactive Apply uses XML project creation, not repeated native range-delete commands.

Generated segments include the exact submitted settings as native AU state and scalar values. Host verification separately reports `controllerSettingsPreserved`; timeline/rendering verification never implies that private settings survived. When they were discarded, verification restores them on the affected imported segments and checks another host export. Controls → **Restore Saved Settings…** remains available as a manual fallback. Rendering effect changes still fail verification.

## 7. Continue editing or recover

Open the result, listen around cut boundaries, and continue normal editing in Final Cut. Keep the original project as the unchanged reference.

Result artifacts live under `~/Library/Application Support/Cutdown/Results/<request UUID>/`:

| Artifact | Purpose |
|---|---|
| `Cutdown.fcpxml` | Generated edited project. |
| `Before-Cuts.fcpxml` | Separately named recovery project referencing existing source media. |
| `Edit-Report.json` | Details of the generated edits. |
| `Analysis-Settings.json` | Exact detection settings used. |
| `Import-Status.txt` | Whether import was requested or verification completed. |
| `Import-Dialogs.json` | Observed import dialogs and warnings, when present. |
| `Verification-*.fcpxmld` | Host re-exports for verification and recovery; older runs used `Imported.fcpxmld`. |
| `Verification-Receipt.json` | Saved expected-XML hash, request settings, and bound host project identity for resuming verification. |
| `Import-Verification.json` | Comparison report, when comparison is reached. |

If Apply stops before delivery, no result import was requested. If delivery was attempted but verification fails or is interrupted, a result may already exist: check **Cutdown Results** before importing again. Lost Apply messages are retried using the same job identity and cannot apply a consumed plan twice. After 15 seconds without an accepted response, the window disables the old review and permits fresh Analyze; first check Cutdown Results because an import may already have happened. A running helper operation still blocks a new analysis until it finishes. Existing result folders are not overwritten.

The helper retains progress and review state independently of the view. Controls polls the latest cached response and reconnects after host view recreation. Returning to a hidden view grants a fresh response interval. Terminal errors remain visible without a heartbeat; after a timeout, read-only polling continues so a delayed error can replace the provisional message. Apply remains disabled for that expired review. Invalid or oversized review payloads still stop the review; there is no separate fallback review window. See the [missing-preview correction](preview-connection.md) for the confirmed Noise Gate/Limiter render mismatch and current installation steps.

After an import or verification failure, use **Retry Verification** in Controls. It opens the existing result, exports it again, and performs the comparisons; it has no import step. After a helper restart, select the original clip, open its Controls, and use **Verify Existing Result…**, choosing the result folder’s `Cutdown.fcpxml`. Older results can be adopted from their matching `Edit-Report.json` and `Analysis-Settings.json`. Altered/mismatched artifacts are rejected. Once a host project identity has been verified, later retries must match that identity as well as the complete expected timeline. The helper keeps at most 24 pending receipt locations in memory and releases completed verification data. Older pending results remain on disk and can be reopened with **Verify Existing Result…**.

Controls disables Retry Verification while waiting for acknowledgment and resends a lost request safely. A later failed attempt permits another explicit retry. If another review prevents verification from starting, the helper explains that and releases the button. Use both matching builds from the [current cleanup update](cleanup-fixes.md).

If Final Cut drops Cutdown settings during import, verification plans recovery for each affected imported segment, selects the exact occurrence, opens its controller, restores the saved values, and commits them using **Save Settings**. It then re-exports and verifies the actual settings. Each segment gets its own verified selection identity, including when multiple segments have the same name. Displayed/restored detection values preserve Float32 precision. A controller write alone does not count as success. Interrupted recovery is retryable; segments whose values already match are skipped. The original project is not edited. **Restore Saved Settings…** remains available as a manual fallback if the host cannot expose or persist the controls.

## 8. Verification boundary

Historical evidence establishes editable XML cut structure, source interval preservation, and selected earlier button/native-edit flows. It also records Final Cut dropping Cutdown settings on XML import. These findings do not prove that the current isolated-render and automatic import-verification workflow has passed end to end in the installed build.

Historical September 17 Analyze follow-up (superseded two-window design): after stopping stale helpers, the six-second generated fixture completed automatic processed-audio analysis, render/original verification, and temporary-project cleanup. Its recreated Controls view lost the review, prompting the now-removed helper-owned window. The new window passed focused tests and a subsequent live Analyze completed after restarting the helper to recognize the permission already granted. The helper window visibly showed one selected 1.933-second cut, with selection, preview, and Apply enabled. No permission setting or binary changed during that restart. No Apply was tested. Evidence and limitations: `build/AnalyzeVisibilityVerification/Notes.md`. Any future Final Cut integration test must use a small disposable project in this workspace's existing **Cutdown Integration.fcpbundle**, reference generated source media in place, and avoid copied, optimized, or proxy media.
