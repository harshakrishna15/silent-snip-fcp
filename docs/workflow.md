# Silent Snip workflow

Updated November 5, 2026. The default interface is **Window → Extensions → Silent Snip**. Select one supported clip, Analyze, review, then explicitly Apply to a new cleaned project. You do not add Silent Snip Audio to the clip. The original project and its editable effects stay unchanged; cleaned sound uses retained intervals from Final Cut's continuous processed render.

Worker **55** / frontend **17** adds **Update Cuts**, **Go to Cut**, and **Verify Existing Result…** and packages an AU-free worker with the separate Workflow frontend. These three feature flows passed scoped native validation, including restart recovery and the installed AU-free worker. See the [versioned Workflow evidence](workflow-extension-prototype.md) for current status, and [timings and sound checks](workflow-throughput.md) for fixture-specific audio evidence. Historical Audio Unit, voice-over, and general-project results do not establish the new frontend's behavior, every plugin, or every timeline topology.

## 1. Install and prepare

Copy **Silent Snip.app** and **Silent Snip Workflow Prototype.app** into the same Applications folder and open both once. Follow [first-time setup](setup.md) for the worker's control-access grant, the frontend's Final Cut Automation connection, and the **Silent Snip** Share destination. Keep its action pointing to the worker **Silent Snip.app**. The worker's scissors menu bar icon provides status, saved results, and Quit; the Workflow extension is the working interface.

For source development, quit Final Cut and both Silent Snip apps and run `Scripts/build.sh --release`. It builds and registers the pair in place. Keep both registered bundles there, or copy both into Applications and point Share at the copied worker. Ad hoc worker rebuilds can require refreshing its existing control-access grant.

Share is part of the helper's implementation. The normal user interaction does not require manually exporting XML, choosing an export method, or sending a project to Silent Snip.

Final Cut's native Share interface remains visible. Silent Snip creates no covering or separate progress window. Keep Final Cut in front during host automation; analysis and file processing run in the background, but the Share, project-navigation, and import steps still use its interface.

XML capture now always uses the Share exchange; the unused Export XML / Go to Folder / Save-dialog driver has been removed. The helper still starts and confirms the Silent Snip Share destination through Accessibility. Apple's documented exchange supplies output paths and delivery, but does not provide a command here to initiate sharing without host UI.

Host actions are conditional: range clearing is skipped when the timeline is verified to have no range selection, export tabs already selected are left alone, and opening an already visible imported project skips Libraries navigation and the filmstrip switch. Timeline focus uses the direct Accessibility property first, with a verified menu fallback. Existing selected ranges still use the host's advertised Clear Selected Ranges shortcut (or its menu fallback), followed by verification. Project opening selects the exact browser item through Accessibility, with a hit-tested single-click fallback, verifies sole selection and browser focus, then invokes Clip → Open Clip. It confirms the requested timeline before exporting its XML for identity/content verification.

## 2. Select the audio clip

Open a project and select the particular clip occurrence with audio in the primary storyline. Open **Window → Extensions → Silent Snip**. If shown, use **Connect to Final Cut Pro** to connect the frontend to the current project. No Silent Snip effect is required.

The supported target is one normal-speed direct asset clip with enabled audio and available source media. It can be audio-only or a camera clip with linked video/audio. Cuts trim the selected clip and its linked video together. The cleaned sound comes from the continuously processed audio file. Source trims and repeated uses of the same file are distinguished by the selected occurrence. Split audio/video edits, connected targets, compounds, multicam, and retiming still require additional support.

Other project content is checked for compatibility. Retimed or nested targets, ambiguous selections, disabled audio, unsupported transitions, nested connections, connected dialogue, conflicting lanes, and some timed automation/component trims can prevent output. An isolated analysis render does not remove these editing restrictions.

## 3. Set detection and output

The four detection controls are in the Workflow window:

| Setting | Default | Meaning |
|---|---|---|
| Silence Threshold | −40 dBFS | Windows below this level in every channel qualify as quiet. Raising it toward zero includes louder quiet material. |
| Minimum Silence | 0.5 seconds | The proposed removal must reach this length after padding and frame rounding. |
| Before Speech | 0.1 seconds | Retain this much quiet audio immediately before speech resumes. |
| After Speech | 0.1 seconds | Retain this much quiet audio immediately after speech ends. |

Minimum Silence accepts 0.0001–10 seconds. Analysis measures audio in 0.01-second windows, and cuts snap inward to boundaries shared by project frames and audio samples. At 29.97 fps with 48 kHz audio, that grid is five video frames. With the default 0.1-second padding on each side, a quiet interval generally needs at least Minimum Silence plus 0.2 seconds, and inward alignment can require more.

Choose **Remove Silence** to close the selected pauses, or **Replace with 1-Second Gaps** to replace each selected pause with an editable gap. One second is rounded to the nearest project frame. Gap mode can lengthen a pause that was shorter than one second.

Use **Save Settings** to persist the four detection values and output for the current project without analyzing. Settings are keyed by library URL and project UID in the frontend's own store, so separate projects keep separate values. Reopening the extension or returning to the original project loads its saved values; it does not restore an old review or authorize Apply. Existing Audio Unit instance settings are not automatically migrated.

Changing detection or output invalidates the current review and disables selection, navigation, and Apply. For eligible analyses, click **Update Cuts** to recalculate explicitly from retained measurements; otherwise click **Analyze Audio**. Typing, Return, leaving a field, Save Settings, and polling never analyze or export. Changes to volume, processing effects, source media, or timeline content always require a fresh **Analyze Audio**.

## 4. Analyze

Click **Analyze Audio**. It does not apply cuts. The button disables immediately while the request connects; repeated clicks cannot cancel and replace a pending analysis. A failed launch or response timeout releases it for retry.

The window reserves a **320-point** review pane with Start, End, and Duration columns. Long lists scroll within it; project information and primary actions remain outside the body scroll area. The existing helper attempts to restore the outer window to **615 × 736 points**; this requires its control-access grant and does not disable Final Cut's resize handles or Zoom.

The background worker owns the operation while the frontend displays progress and review. Closing the extension or changing the active project invalidates the view's review; reopening loads saved project settings and requires fresh Analyze. Use **Cancel** to discard a review or stop an operation. A stopped or interrupted import can be checked with **Verify Existing Result…**. Another project cannot adopt a global latest review.

The worker captures fresh project XML through Share and verifies the SDK-reported library/project identity and selected occurrence before accepting audio. It selects an analysis route:

- **Unprocessed clip:** decode the original source audio over the selected source interval.
- **Processed clip filling the entire project:** when the XML proves that this is the only timeline item and every enabled audio component belongs to Dialogue, the app renders directly in the original project. The render’s fresh XML must match project identity, effects, media, timing, and full scope. No temporary project is imported or deleted.
- **Mixed project:** direct primary clips and gaps can use a verified Dialogue render, with simple direct connected music and B-roll retained in the edit. Small edits with no earlier or overlapping Dialogue use a full-project render when extra duration is at most 30 seconds and no longer than the target; the app checks the whole duration and measures only the selected interval. Longer edits and clips with preceding Dialogue use an exact native selected range, verified against the clip's edges and duration before Share. The full-project XML still accompanies the selected-range audio. Other overlapping Dialogue prevents this direct route. Explicit Music/Effects export files are excluded through the verified native role layout. The historical Audio Unit route can supply an optional routing hint for the next explicit Analyze, including after restarting the helper: new audio and new XML arrive together, with fresh source hashes and a matching render scope. The persisted hint is consumed once and contains no audio, hashes, or effect state. Workflow Analyze obtains fresh XML before routing and does not consume this hint as capture authority. Source identities are pinned before Share; full hashing overlaps the render and must finish with unchanged mutation stamps before acceptance. Large camera originals have no byte-size exclusion. Missing, unreadable, or stale preflight sources use the ordinary capture path; failures after dispatch stop and clean the delivered render without retrying Share. Clear Cached Audio removes the hint. No prior PCM is reused for opaque effects.
- **Other processed clips:** the app creates an isolated analysis project referencing the original media. It retains the target's audio processing, removes the passthrough Silent Snip controller, and excludes neighboring timeline items. It imports that project and requests rendered audio plus XML in one Share exchange. Before using the audio, it verifies that the delivered XML matches the intended isolated project, including timing, media, and rendering effects, and binds Final Cut's newly assigned project UUID. It then returns to and rechecks the original project. The preceding XML-only verification Share was removed because the render already delivers the project XML. It does not silently substitute source audio when rendering or verification fails.

Every Analyze captures fresh project XML and checks source contents. For effects that cannot safely reuse measurements, source hashing overlaps host rendering; the app joins it and revalidates before publishing review. When those checks, the selected occurrence, host session, and complete supported processing state match the process-local cache, it recalculates cuts from retained measurements using the new threshold, minimum silence, and padding. A cache hit skips decoding and the isolated render. Preset names, omitted settings, partial native parameter lists, and unknown effects are insufficient evidence and force the normal route. See [cache limits and timing reports](analysis-speed.md).

The isolated-render route passed fresh processed removal and gap runs with Noise Gate and Limiter; see the milestone evidence. The uniquely named analysis project imports into the original event. After verified rendering and return to the original project, the helper removes only its exact generated project through Final Cut. Unverified or interrupted cleanup leaves the project in place and records `Cleanup-Status.txt` in the analysis job folder.

An ineligible mixed-project processed Analyze cache miss requires three Share exchanges (original XML, isolated audio plus XML, and restored-original XML), down from four. Apply captures fresh processed audio and project XML, with a separate imported-result verification exchange. A locally updated processed preview can also need its selected-clip audio recheck. These are source-level operation counts, not measured live speedups. During analysis the captured XML bytes are reused; the missing-callback fallback parses only changed XML while retaining its existing three-second stability requirement. Audio and source-content checks remain in place.

Simple direct connected music and B-roll follow the same project-time cuts as the target. The cleaned copy keeps the surrounding visual edit and plays retained intervals from the project's processed sound, including its enabled audio roles. Original audio paths in that copy are disabled to prevent double playback. The unchanged original project retains editable gains, effects, source-time curves, and annotations. Gap output leaves the corresponding intervals empty. Connected dialogue and fades remain protected; nested/retimed connections, overlapping lane conflicts, and unsupported trims are rejected before Apply. See [verified scope and timing](workflow-throughput.md).

### Using other audio plugins

Apply your Noise Gate, Compressor, EQ, Limiter, or third-party Audio Unit to the selected clip, then click **Analyze Audio** in the Workflow window. Silent Snip measures Final Cut's processed output from the complete effect chain without adding its own effect. Processing order matters: Final Cut renders the existing chain in that order.

Apply captures the current continuous processed sound and preserves every native PCM audio byte and its format unchanged. It gives the WAV container a unique media identity so Final Cut keeps the intended durable file linked. The cleaned project uses kept intervals from this file, so stateful effects such as delays do not restart at each new cut. The preserved sound has the precision supplied by Final Cut's render; this does not recover precision absent from that render. The original project keeps its source media and editable processing effects. To change the processing later, return to that original project, update the effects, and Analyze and Apply again.

The durable audio lives under `~/Library/Application Support/Silent Snip/Processed Audio/<request UUID>/Processed-Audio.wav`. New retained files are made read-only before import; original sources and older processed media are untouched. Keep the durable file with the project's other media when archiving or moving the edit. Disposable Share deliveries and analysis caches can still be cleaned after use; the durable processed audio is excluded from that cleanup and from uninstall data removal. The analysis project is removed after verified use; cleanup failures are reported as described above.

A noise gate can make background noise qualify as silence; compression, makeup gain, or limiting can change what falls below the detection threshold. Set those effects first and analyze again after changing their settings, order, presets, or bypass state. Apply verifies the original project, current processing, source contents, saved audio, and imported project before reporting completion. It preserves rendered samples in the cleaned sound; editable effect state remains in the original project.

Final Cut renders supported effect chains; each installed plugin and routing setup still needs to be renderable and verifiable in the host. This does not certify every plugin or timeline. The original project retains source-time automation. A proposed cut intersecting a protected fade is unavailable. Empty/invalid animations and trimmed audio components still prevent Apply. Retimed clips, compound clips, and external sidechain routing remain outside the verified scope. New cut boundaries use the shared video/audio grid. A fractional full-project endpoint keeps only the native WAV's verified physical samples; no extra sample is created for the remaining fraction. Normal-speed direct camera clips are supported with linked video cuts; split audio/video edits and retiming remain unsupported.

Detection measures RMS loudness in 10 ms windows. A window is quiet only when every channel is below the threshold. Adjacent quiet windows form candidate pauses. The detector retains before/after padding, rounds removal boundaries inward to project frames, and applies Minimum Silence to the resulting removal. Entirely silent targets are not automatically deleted.

This is level detection, not a speech or breath classifier. Quiet breaths can qualify. RMS values can differ from Final Cut's peak meter readings.

The helper checks whether the proposed edits can be represented in an editable output project before enabling Apply. The window displays operation status, measured decoding progress when available, and elapsed time; host operations can show indeterminate progress.

## 5. Review

Verified cut rows may arrive with “Preview ready” while temporary-project cleanup finishes. Apply, cut selection, and navigation remain disabled until the operation returns to review. Cancellation discards this early result. Each job records time to preview separately from completion time; restoring the Workflow window can still delay when the user sees it.

Read the summary and proposed start/end times and durations. Ineligible ranges are marked unavailable. The timeline automatically shows numbered boundaries for the included cuts: green START lines and orange END lines. These are helper overlays, not native markers or edits.

Unchanged status polls keep the connection alive without rebuilding the cut list.

Closing the Workflow window invalidates its review and clears the preview. Applying, cancelling, replacing the review, or editing settings also clears its old preview. The overlay is ordered immediately above the verified project window, so macOS composites overlapping windows naturally. Geometry that cannot be verified hides the overlay.

Choose a range from the **Go to Cut** menu to move the playhead to its start. The worker checks the current project and selected occurrence without another Share; navigation cannot run alongside Apply. It uses [Final Cut's timecode navigation](https://support.apple.com/guide/final-cut-pro/ver1632d762/mac), including project start timecode and drop-frame formatting. It does not change inclusion choices or edit the timeline.

Use each eligible row's checkbox, or **Select All / Deselect All**, to choose cuts. Apply waits for the worker to acknowledge changes. Unavailable ranges explain their restrictions. After a detection or output change, **Update Cuts** explicitly recalculates from retained audio measurements when the analysis used source audio or a verified render directly in the original project. This matches the former effect's eligibility. Isolated-render and unsupported layouts require **Analyze Audio**; Update Cuts is hidden when unavailable. A settings draft cannot authorize Apply or navigation.

Update Cuts performs no Share exchange. It checks the current project and selected occurrence before returning review; Apply later obtains fresh project/audio evidence and requires the reviewed cut candidates to match. Update Cuts does not substitute for Analyze after changes to timeline content, source media, volume, processing effects, presets, or bypass state.

Apply requires a valid review, at least one eligible included cut, unchanged submitted settings, and a plan that has not already been consumed. Changing timeline content, processing effects, or source media requires fresh analysis; Apply checks for stale project state before generating output.

If **Go to Cut** detects a changed project, Silent Snip discards the stale review and preview and requires Analyze again. A recoverable navigation error keeps the review. Failed or cancelled timecode entry attempts bounded cleanup only while Silent Snip still owns the field, project, and keyboard focus.

## 6. Apply Cuts

Click the separate **Apply Cuts** button. The helper:

1. Captures the original project again and compares its identity, timeline, effects, frame rate, duration, and source media with the analyzed baseline. Current processed sound is rendered continuously, including the project's enabled audio roles.
2. Preserves the verified PCM and format bytes in durable media with a unique container identity, then builds every selected cut in one FCPXML transformation using the chosen output mode. The result keeps the full visual edit and timecode origin, disables its old audible paths, and plays kept intervals from that processed audio. Later primary items and their connections move by the exact removed duration.
3. Saves recovery XML, edited XML, the edit report with processed-audio provenance, and exact detection settings in a new result folder.
4. Sends exactly one uniquely named cleaned project to the original event and library. The name contains the clip name and a stable request suffix. No **Replace** or **Keep Both** decision is authorized for a new cleaned-project result.
5. Opens the new project, re-exports it, and verifies the intended event/library, host project identity, timeline, media references, and expected processed-audio routing. Original media and the durable processed file are checked before completion.

The worker-53 architecture places processed PCM clips directly in the primary storyline for **new audio-only results**, with real primary gaps in one-second-gap mode. This applies only when the timeline has no video occurrences, including disabled or connected video; video projects keep their existing primary storyline. Original projects/live effects and already-created results stay as they are. The recorded frontend-8/worker-53 native removal and gap fixtures verified two direct primary PCM clips with zero connected PCM; gap mode added one real one-second gap. Exact retained PCM, positive-zero gap samples, notes/marker placement, and fresh post-Apply original/source checks passed. See [worker-53 evidence](workflow-extension-prototype.md#worker-53-audio-only-pcm-in-the-primary-storyline).

Import delivery is asynchronous. The helper waits for the uniquely named result to become available. It records dialogs in `Import-Dialogs.json`. Only an identified completed-import warning is acknowledged automatically for a new cleaned-project result; replacement and unrecognized dialogs remain open. Retry Verification never imports again or accepts a replacement prompt. Historical pending replacement receipts retain their separately scoped verification rules.

The original project and source media remain unchanged. Each new analysis can create a separately named result project in the original event; retrying verification never creates another project. Final Cut assigns a new internal project identity. The pre-Apply project is also saved as `Before-Cuts.fcpxml` on disk. Kept processed audio remains trimmable in the cleaned timeline and references its durable WAV. Surrounding visual content remains in the cleaned copy; its original audio paths are disabled. The original project retains independently editable source audio and effects.

**September 22 validation:** manual host XML replacement probes in this checkout’s required integration library kept one project across repeated replacements. This establishes the host’s name-based replacement behavior, not an automatic Analyze/Apply run of the updated helper. See [replacement evidence and limitations](xml-replacement.md).

The cleaned sound contains Final Cut's processed samples, including effect history at the kept intervals. Processing effects stay editable in the unchanged original project. A legacy Silent Snip detector already present there remains part of that original; the Workflow route does not add or require one. Exact submitted detection settings are saved in `Analysis-Settings.json`; processed-audio identity and timing are saved in `Edit-Report.json`. Older saved results that include the detector retain their separate `controllerSettingsPreserved` and settings-recovery checks.

## 7. Continue editing or recover

Listen around cut boundaries and continue editing in the new cleaned project. Open the unchanged original project to return to the pre-Apply edit. The saved `Before-Cuts.fcpxml` is an additional recovery copy with a distinct recovery name and identity. Recovery history stays in the result folders until explicitly imported.

Result artifacts live under `~/Library/Application Support/Silent Snip/Results/<request UUID>/`:

| Artifact | Purpose |
|---|---|
| `Silent Snip.fcpxml` | Generated edited project. |
| `Before-Cuts.fcpxml` | Separately named recovery project referencing existing source media. |
| `Edit-Report.json` | Generated edits; processed-audio path, native/durable file hashes, PCM/format hashes, media identity, timing, and scope. |
| `Analysis-Settings.json` | Exact detection settings used. |
| `Import-Status.txt` | Whether import was requested or verification completed. |
| `Import-Dialogs.json` | Observed import dialogs and warnings, when present. |
| `Verification-*.fcpxmld` | Host re-exports for verification and recovery; older runs used `Imported.fcpxmld`. |
| `Verification-Receipt.json` | Saved expected-XML hash, request settings, and bound host project identity for resuming verification. |
| `Import-Verification.json` | Comparison report, when comparison is reached. |

The cleaned project also references `Processed Audio/<request UUID>/Processed-Audio.wav` beside the `Results` directory. Preserve that media along with the result artifacts and original sources. Moving or deleting it without relinking the project can make cleaned audio unavailable. Uninstalling the app, clearing disposable caches, and `Scripts/uninstall-local.sh --remove-data` keep this durable media. Manual deletion is appropriate only after it has been archived or relinked and no remaining project depends on that location.

If Apply stops before delivery, no result import was requested. If delivery was attempted but verification fails or is interrupted, the cleaned project may already exist: check it before importing again. The original project stays unchanged. Lost Apply messages are retried using the same job identity and cannot apply a consumed plan twice. After 15 seconds without an accepted response, the window disables the old review and permits fresh Analyze; first check for the existing result. A running helper operation still blocks a new analysis until it finishes. Existing result folders are not overwritten.

The worker retains operation progress independently of the frontend. The connected view polls its latest revision, rejects stale responses, and disables a timed-out review. Reopening the Workflow window requires a fresh analysis for editing; saved-result recovery is separate and cannot turn an old plan into an applicable review.

After an import or verification failure, use **Retry Verification** when offered. It opens the existing result, exports it again, and compares its timeline and media; it never imports another project. A lost retry message can be resent safely with its original revision.

After restarting the helper or frontend, open the original project **or its existing cleaned result**, open **Window → Extensions → Silent Snip**, choose **Verify Existing Result…**, and select `Silent Snip.fcpxml` from the saved result folder. No selected clip or Silent Snip detector is required for this recovery action. The worker verifies the fresh native gesture, current library/project identity, matching saved artifacts, and a fresh XML capture before navigating to the saved result. Once a host result identity is bound, later comparisons must match it and the complete expected timeline. Recovery does not import, apply cuts, or restore an old review. A recoverable failure offers another Retry Verification.

Older result adoption requires matching saved artifacts; altered or mismatched files are rejected. The worker keeps at most 24 pending receipt locations in memory, while older results remain on disk and can be chosen again. For historical results containing detector instances, the retained settings-recovery code writes only to exact verified imported occurrences and re-exports to check host retention. It is compatibility behavior, separate from per-project Workflow settings. See the [legacy effect guide](../AudioPlugin/README.md) for its retired Controls interface.

## 8. Verification boundary

Historical evidence establishes editable XML cut structure, source interval preservation, and selected earlier button/native-edit flows. It also records Final Cut dropping Silent Snip settings on XML import. Those early findings alone do not establish a later build’s automatic analysis/import verification; versioned native results are recorded separately below and in the Workflow frontend report.

Historical September 17 Analyze follow-up (superseded two-window design): after stopping stale helpers, the six-second generated fixture completed automatic processed-audio analysis, render/original verification, and temporary-project cleanup. Its recreated Controls view lost the review, prompting the now-removed helper-owned window. The new window passed focused tests and a subsequent live Analyze completed after restarting the helper to recognize the permission already granted. The helper window visibly showed one selected 1.933-second cut, with selection, preview, and Apply enabled. No permission setting or binary changed during that restart. No Apply was tested. Evidence and limitations: `build/AnalyzeVisibilityVerification/Notes.md`. Any future Final Cut integration test must use a small disposable project in this workspace's existing **Cutdown Integration.fcpbundle**, reference generated source media in place, and avoid copied, optimized, or proxy media.

Historical build 47 passed Analyze → review → Apply on the five-minute linked-camera Gate → Limiter fixture in the required library, without a manual verification retry. It retained the same 60 cuts, passed strict project/source verification with one completed result verification capture, and matched all 9,192,000 retained stereo frames against the captured native 24-bit/48 kHz mix. Helper processing took 28.93 seconds on this 652 MB camera source; build 46 took 34.39 seconds on the same fixture. These individual runs do not establish a general speedup. The three-second complete-flow target remains unmet. See [current timing and sound evidence](workflow-throughput.md#build-47-guard-apply-source-validation-and-new-processed-media).

That build also passed a separate one-minute Gate → Limiter → AUDelay fixture with connected Music and custom Room Tone in one-second-gap mode. Strict project/source verification and exact native PCM comparison passed for all 2,795,200 retained stereo frames and 528,000 inserted positive-zero frames. This fixture took 32.04 seconds of helper processing and does not certify every plugin or project layout.

## Manual snapshot review update

Worker 55 / frontend 17 exposes the retained-measurement update in the Workflow window. It preserves the bound project identity and uses an explicit native gesture. The source/direct-render eligibility and fresh Apply validation described above remain; scoped native validation of these controls is recorded in the [current report](workflow-extension-prototype.md).

Historical build 36 introduced explicit **Update Cuts** for source-audio and verified direct-render clips. That Audio Unit flow used retained 10 ms RMS measurements and the detector; typing, Return, blur, Save, and status polling never start it. **Analyze Audio** always performs a fresh project/audio analysis, subject to the verified cache reuse described above. Changing clip volume, processing effects, or source media requires that fresh analysis. Dirty previews hide their old timeline overlay and cannot authorize Apply. Closing Controls with an unsubmitted draft requires a fresh audio analysis on reopening.

For a locally updated processed preview, Apply obtains current processed audio and full-project XML together, checks the original project/selection/source contents, reruns detection using the reviewed settings, and requires the same candidate ranges and protection states. A mismatch stops before project creation/import and requires Analyze Audio again. User include/exclude choices remain attached to matching reviewed ranges. Apply also preserves the continuous current project sound in durable media and verifies the cleaned routing. Disposable delivery WAVs are cleaned after use; durable processed media stays available to the cleaned project.

Go to Cut uses the retained analysis timecodes with current project, selection, and boundary checks. It moves only the playhead and performs no Share exchange. Apply verifies full project state, original sources, and durable processed audio.

The build-36 native Analyze → Update Cuts → Apply tests passed for a sole linked-camera target and a target inside a larger edit, both with Noise Gate and Limiter. Those earlier results matched processed-audio hashes, reviewed ranges, imported fingerprints, editable effects, and source contents. Changing the target volume after review stopped Apply before project creation/import; restoring volume and explicitly analyzing again recovered successfully. Go to Cut reached two exact nonzero timecodes without Share and restored the original selected clip. All live tests used disposable projects in the required workspace library. See [historical results](general-project-performance.md#manual-review-without-repeated-share) and [current sound-preservation checks](workflow-throughput.md).

For that build-36 milestone, the Swift suite (471 tests, one existing benchmark skip), Controls harness (48 groups), and passthrough audio harness (60 cases) passed. The measured local-update gain concerns retained-audio preview work; it does not establish faster initial renders, universal project support, or a sonic guarantee for arbitrary third-party effects. Current processed-media output and native sound comparisons are recorded in [workflow throughput](workflow-throughput.md).
