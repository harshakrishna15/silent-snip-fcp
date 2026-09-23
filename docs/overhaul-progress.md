# Integration overhaul

This record tracks export reliability, isolated clip rendering, verified imports, settings retention, and local build/registration work. All Final Cut tests must use disposable projects in the workspace `Cutdown Integration.fcpbundle`. See [setup](setup.md#integration-test-library) for a fresh checkout.

Earlier entries describe the original development environment. Their installed/staged app state and logs under `build/` are not part of a Git checkout. The project currently provides local ad hoc builds; no release installer or updater is included.

## September 23 live preview validation

After the final helper rebuild, the user restored its macOS Device Control and
Data Access permission and live-tested Cutdown in Final Cut. The user reports
that the dotted guidelines now stay visible as expected while interacting with
the timeline. The final source passed 68 focused Swift tests and all 18 Audio
Unit Controls harness scenarios; local build products and signatures passed
the registration check. This user validation resolves the reported preview
flicker. Automatic timeline cuts remain unverified.

## September 23 click flicker follow-up

A later live Analyze in `Cutdown Preview Scrub 0923` completed and produced
two selected cuts (3.167 seconds total). Cutdown's separate transparent panel
contained four rendered boundary lines. A temporary WindowServer probe placed
that panel above the verified Final Cut project window and confirmed that its
retained vector layers remained attached while selecting the other clip.
Final Cut's Controls window sometimes sat directly over all four line positions;
its layer was above the panel, so a window-only capture could show an empty
panel where Controls covered it. The probe and a forced repaint experiment were
removed after capture. These checks do not yet prove the on-screen lines never
flicker during clicking or hover skimming. Later ad hoc helper rebuilds again
lost macOS Device Control and Data Access approval; the diagnostic evidence is
retained under `~/Library/Application Support/Cutdown/Integration`.

A later live retry found an intermittent false dialog blocker during Analyze.
Final Cut's nonmodal Cutdown Controls sometimes appears as `AXDialog` while its
child accessibility controls are temporarily unreadable. A gated diagnostic
captured `modal=false` and missing review/status IDs during the failure.
Capture and preview validation now treat an explicitly nonmodal window as
nonblocking even when its children disappear. After rebuilding and relaunching
the helper, repeated Analyze attempts reached the macOS Device Control and
Data Access permission message instead of the false dialog error.

The effect-removal path was also too eager: two complete-looking Inspector
reads without a Cutdown row, only 0.35 seconds apart, could permanently
dismiss a valid preview. After observing the Cutdown row, removal now requires
at least three bounded absence reads over 2.5 seconds. If the row was never
observed, the reader waits for five bounded absence reads over six seconds;
this still detects deletion immediately after analysis. Short Inspector
rebuilds retain the lines. All 68 focused Swift tests pass. A live
line-persistence check remains blocked
by the local helper's macOS Device Control and Data Access permission.

Clicking around Final Cut exposed two remaining preview dismissal paths. The
helper could classify Cutdown's own Controls window as a modal dialog, and the
preview hid after 2.5 seconds of temporary Accessibility read failures or
immediately when a window snapshot could not be matched. Controls is now
identified by its Cutdown accessibility IDs even when Final Cut reports it as
modal. Temporary reads, open sheets/dialogs, and unmatched WindowServer
snapshots retain the last verified drawing. A different project or analyzed
clip outside the timeline viewport must remain verified for 2.5 seconds before
the overlay hides. Confirmed Cutdown effect removal still dismisses it, as
does Apply through the existing review lifecycle.

WindowServer can omit an overlay fully covered by Final Cut's raised project
window. Each geometry sample now orders the overlay back above the verified
project while it remains absent, even if the returned window list is unchanged.

A further coordinator audit found that clicking a proposed cut to move the
playhead briefly changed the job to `navigating` and published a nil preview.
The analyzed review remains valid during that operation, so navigation now
retains its lines. A regression test holds the navigation operation open and
checks that the preview remains present throughout. All 66 focused coordinator,
preview, and Final Cut window tests pass after this change.

The review window's Show Preview checkbox was another path that could hide a
valid analysis, contrary to the requested persistent guidelines. The compact
window no longer offers that toggle, and the helper ignores a hide command
from an older Audio Unit window. The 66 focused Swift tests and all 18 Controls
harness scenarios pass. Both apps were rebuilt and registered. The updated
Controls window was verified on the reimported disposable two-clip project in
the workspace integration library; its source WAVs are linked in place. A new
Analyze attempt still stops at macOS Device Control and Data Access permission,
so line persistence during live clicking remains unverified.

The window-order correction now also runs on the preview's 30 Hz display
timer, independently of the slower Final Cut Accessibility geometry read. It
can restore an overlay that Final Cut covers between geometry samples and
reattach drawing layers replaced by AppKit during ordering. A local
WindowServer timing sample averaged about 0.9 ms per listing. All 66 focused
Swift tests pass after this change; the helper was rebuilt and installed again.

All 37 focused Mac tests pass, covering modal Controls recognition, temporary
read gaps, and sustained unavailability. The Release helper was installed,
relaunched, and its bundle signature verified. In the disposable `Cutdown Preview Scrub 0923`
project inside the required integration library, the rebuilt helper got past
the prior "open Final Cut dialog" error. Analysis then stopped at macOS Device
Control and Data Access permission for this local build, so this run could not
produce a new review overlay or verify click behavior visually. Automatic
timeline cuts remain unverified.

## September 23 hover skimming preview follow-up

Moving the pointer off and back onto an analyzed clip can rebuild Final Cut's
timeline accessibility tree without changing the selected clip. The preview
reader previously treated every temporary read failure as a reason to restart
the full clip-identity scan. When that scan failed during a hover transition,
it retried on each sample and could briefly hide the dotted lines. The reader
now retains a verified clip handle for at most five seconds during transient
identity failures and spaces full scans at least one second apart. It still
checks the project title and target geometry on each successful sample.

Final Cut can also reorder its project window on pointer entry without an
accessibility notification. The reader now samples the current WindowServer
order on each geometry read, while keeping the slower dialog and project-window
safety check on its prior interval. The 16 focused preview tests pass,
including a hover read-gap regression. The Release helper was rebuilt,
installed, relaunched, and its bundle signatures checked. Live hover-only
skimming remains unverified because this run did not establish that the
rebuilt helper has Device Control and Data Access permission, and the UI
automation cannot send a mouse move without a click. This code change does
not establish automatic timeline cuts.

## September 23 preview stability while scrubbing

The preview could stay behind Final Cut after scrubbing raised the project
window. Its ordering check saw the panel behind, but skipped correcting the
same window-order snapshot twice. It now raises the panel whenever a verified
snapshot places it behind the project, while still avoiding repeated raises
when a new panel is simply missing from a cached snapshot. Transient
Accessibility gaps retain the last verified drawing for up to 2.5 seconds;
confirmed project changes, offscreen clips, modal dialogs, and effect removal
still dismiss it immediately. An Inspector scan now clears pending removal
evidence when selection moves to another clip.

The 15 focused preview tests pass. The updated helper was built and installed.
A live two-clip check was attempted only inside the workspace
`Cutdown Integration.fcpbundle`, with source WAVs referenced in place. Final
Cut quit during XML import, but the disposable project appeared after it
reopened. The project and Cutdown Controls opened; Analyze then stopped at
macOS Device Control and Data Access permission for the rebuilt helper.
The on-screen scrub behavior therefore remains unverified in this run. The
previous timeline was restored; no Apply or automatic timeline cuts were tested.

## September 23 Analyze feedback for duplicate effects

Three recent Analyze attempts on an existing project in the integration library
reached project capture, then stopped after about four seconds. The exported
clip contains two direct Cutdown Audio effects, so the helper correctly refused
to choose one. No measurement or timeline edit ran. The user can remove the
extra instance in Final Cut’s Audio Inspector and Analyze again.

The failure was easy to miss when Final Cut displaced Controls for export:
reopening an effect editor is deliberately ambiguous with two instances, and
the helper discarded the resulting reopen guidance. The helper now checks for
visible duplicates before Share, preserves guidance when restoration fails,
and writes failures that occur during initial capture to the job directory.
Controls shows a specific failure reason in Review as well as the status line.
XML validation remains the authoritative duplicate check when the Inspector
does not expose both effects. Automatic Apply and timeline cuts were not tested
in this investigation.

## September 23 Controls window verification

The compact Controls window was checked in Final Cut using the disposable ten-second
`Cutdown Audio Only Basic` project in the workspace `Cutdown Integration.fcpbundle`.
The rebuilt Audio Unit opens, exposes the detection tooltips, shows the simplified
More menu, and saves settings from its icon button. A live Analyze retry exposed
an Accessibility mismatch that made the helper mistake Controls for an unrelated
Final Cut dialog. Matching the window by its stable Cutdown accessibility IDs
fixes that regression: Analyze now passes the dialog check. Long status messages
wrap within the window, including the full permission recovery instructions.

Analysis still stops at macOS Device Control and Data Access permission for the
rebuilt helper. No cut review, automatic Apply, or timeline cuts were verified in
this run. The existing permission was not changed.

## September 23 first-import navigation repair

An observed Analyze attempt on the integration library stopped immediately after
delivering its temporary `Cutdown Analysis` project; the next attempt on the same
clip reached review. The first job's timing report ended after render preparation,
and its generated project remained in the original event. Final Cut's import log
showed transient event creation. The previous error message was overwritten by
the succeeding job, so the exact thrown error cannot be recovered.

Import navigation now tolerates a temporarily empty timeline title, re-pins to
the current Final Cut accessibility objects after delivery, and accepts an
in-flight switch only to the exact generated project. Unrelated projects and
windows remain rejected. Analyze also saves its failure message per job to
`Analysis-Failure.txt` so a later success cannot erase the diagnostic. Ten
focused import tests pass. The changed helper has not been installed or tested
with a fresh disposable Final Cut project; automatic first-run Analyze and Apply
remain unverified for this change.

## September 18 repository copy and privacy verification

The copied repository includes the helper and Audio Unit source, build configuration, Swift tests, sanitized XML fixtures, build-script tests, and documentation. Local Release helper and Debug audio candidates built and passed signature verification with Xcode 27.0 / Swift 6.4 on Apple Silicon. The audio harness passed 60 render cases plus its settings checks. Sandbox restrictions on process inspection and debug-symbol creation required access-enabled build retries.

After fixture sanitization, 56 focused Release Swift tests passed: 36 `TimelineTests`, seven `NativeTimelineEditTests`, and 13 `EditedProjectWriterTests`. The full Swift suite was not rerun during this audit. Personal paths, a private recording title, encoded filesystem bookmarks, original fixture identifiers and timestamps, and copied Python caches were removed or replaced with neutral values. Fixture timeline behavior remains covered by those focused tests.

No live Final Cut test was performed for this copy. Automatic Analyze/Apply, stable preview, host settings recovery, and fresh-machine setup still require live verification. Build success must not be reported as successful automatic cutting. See the [README](../README.md) for current entry points and [setup](setup.md) for installation.

## September 18 analysis speed — current source

Added per-stage timing reports, a bounded process-local cache of verified measurements and eligible rendered audio, fresh source/content/effect validation before reuse, early read-only cut rows during cleanup, and `build-helper.sh --release`. Unknown or incomplete processing state rerenders. In particular, the user's saved preset-only Noise Gate and settings-omitted Limiter are ineligible; effect processing is retained through the full render route.

Evidence: 358 full Release Swift tests (281 Mac + 77 Core), 357 Debug tests before the extra host-session case, 16 Controls scenarios plus the shared-state contract, and 22 build/registration checks pass. The final stricter policy rejects partial native parameter lists; eight focused cache/timing checks cover it. Logs and matching signed candidate-build evidence are under `build/AnalysisSpeed/`. The sandboxed helper build failed while creating dSYM data; the access-enabled retry is recorded separately.

The five-minute stereo PCM benchmark produces identical 60 candidate ranges in Debug and Release. Release measurement is 5.2–6.5× faster; cached recalculation is 0.50 ms. These exclude Final Cut operations and are not end-to-end Analyze measurements. No extra decoder rewrite is justified by the remaining 44–52 ms CPU measurement cost on this fixture. Stage timing reports will identify remaining host bottlenecks during the user's live testing.

No live Final Cut test was run for this update; installed bundles were not replaced. Xcode may discover an audio candidate automatically, so rebuild/register with Final Cut closed before testing. Automatic Analyze/Apply, visible preview timing, and cache behavior in the host remain unverified. See [details and test sequence](analysis-speed.md).

## September 18 preview persistence — current source

The helper now retains its drawing through bounded transient AX failures,
removes periodic window reordering, and dismisses previews on confirmed effect
removal from the analyzed clip's visible Inspector. Complete section boundaries
or previously observed neighboring headers distinguish deletion from incomplete
or scrolled-off controls. Dismissal stops polling and latches against the old
session. 33 focused Swift checks pass; a signed helper candidate is staged.
The installed helper is unchanged and live deletion/preview/Apply behavior is
not yet verified. See [behavior, limits and live checks](preview-persistence.md).

## September 17 registration recovery

After installation, the user reported that Cutdown disappeared from Final Cut.
The installed bundle signatures pass, but both PlugInKit discovery and `auval -a`
show no Cutdown extension. The candidate-cleanup code could abort on a failed
removal before registering the installed copy. Cleanup now warns and continues
to installation; actual registration failures remain fatal. The script also
requires the installed extension path in PlugInKit discovery before reporting
success, with a bounded wait for discovery to catch up. Twenty-one simulated
build/registration tests pass, including failed cleanup, a failed add and a
zero-exit add that never appears in discovery.

At this update's handoff, registration restoration was pending Final Cut being
closed. A subsequent September 18 read-only inspection shows Cutdown Audio in
the Effects browser again. No Final Cut project was opened or modified by this
repair. Logs are in `build/RegistrationRecovery/`.

## September 17 missing-preview correction

The user's saved Noise Gate/Limiter render failed strict comparison because
Final Cut expanded the isolated component role to `dialogue.dialogue-1`.
Generating that host-stable spelling makes the comparison pass against the
actual saved export without relaxing effect checks. Controls now preserves
terminal errors, grants returning views a fresh response interval, and keeps
read-only polling after a timeout to recover a delayed failure.

42 focused Swift checks, nine transport checks, 15 Controls scenarios plus the
shared-state contract, and 18 build/registration checks pass. Both apps build
and pass signature verification. The helper candidate is updated; the audio
build is in `build/PreviewConnection/Candidate/` because Final Cut was running
the standard candidate. Xcode registered that diagnostic app; stopped-host
registration now removes competing candidates before selecting the installed
copy. The loaded standard candidate and installed bundles were not replaced.
No live Final Cut analysis or Apply was run. See [the evidence and install
steps](preview-connection.md).

## September 17 single-window and effects update

The helper-owned review window is removed. Controls now reconnects to retained
helper state after verifying its unique native control and the original project
and selected clip. Cancel and saved-result verification are in Controls. The
preview no longer hides for nonmodal effect editors or infers controller removal
from an incomplete/virtualized Inspector list. Full audio-effect render routing
and effect preservation checks remain in place, with additional Noise Gate,
Limiter and opaque third-party stack coverage at every controller position.

340 offline Swift tests passed (263 Mac, 77 Core) with media-service access.
The first sandboxed run could not start AVFoundation readers; both logs are in
`build/SingleWindowEffects/`. Thirteen independent Controls scenarios plus the
shared state contract passed, including reconnection, malformed/stale replies,
Cancel and layout. All 60 audio passthrough cases and state checks passed.
Matching signed helper and audio-plugin candidates are staged. The final 56 focused Swift checks passed after the controller-settings restoration guard. Registered app bundles are not replaced
by this update. The user will handle live Final Cut testing. No current-build
visible-preview, host-reconnection or automatic-Apply success is claimed.
See [the changes and live check](single-window-effects.md).

## September 17 command fixes and cleanup — current staged revision

The dropped Retry Verification and preview-toggle bugs are fixed. Connection state is separated from the plug-in view, Final Cut integration is split into focused files, legacy-only helpers are in test fixtures, settings equality and review states are centralized, compiler warnings are addressed, and plug-in tests use independent scenarios. See [the cleanup record](cleanup-fixes.md) for details and combined live checks.

337 offline Swift tests, eleven plug-in scenarios plus the shared-state contract, 60 audio render cases, and 12 build-script tests passed. Matching signed candidates are staged; registered apps and permission entries were not changed. Live Final Cut testing remains with the user.

## September 17 performance fixes

Unchanged status messages reuse validated wire bytes and skip plug-in decoding/table updates. Rendered PCM borrows aligned contiguous decoder memory and reuses scratch storage for fallback copies. Import comparison, settings-recovery planning, and occurrence selection share parsed snapshots within each attempt; recovery still verifies a fresh host export.

333 offline Swift tests passed (256 Mac, 77 Core), and the Controls harness passed. Matching signed candidates are staged; registered apps and permissions were not changed. See [the performance note](performance-fixes.md) for regression coverage, logs, and the added idle-review check. Live Final Cut testing remains with the user.

## September 17 audit fixes

All eight findings from the later deep code audit are implemented, with live checks left to the user. See [the combined check guide](audit-fixes.md) for the finding-to-fix mapping, installation steps, and one end-to-end live check sequence.

- 327 offline Swift tests passed (250 Mac, 77 Core): `build/AuditFixes/full-swift.log`.
- Controls harness passed including duplicate Analyze, precision, and minimum-boundary regressions: `build/AuditFixes/factory.log`.
- Audio harness passed 60 render cases plus state/persistence checks: `build/AuditFixes/audio.log`.
- 12 build-script regressions passed, including host launch during compilation and replacement rollback: `build/AuditFixes/build-scripts.log`.
- Matching signed candidates built successfully at `build/Candidate/Cutdown.app` and `build/Candidate/AudioPlugin/CutdownAudio.app`; logs are `build/AuditFixes/helper-stage.log` and `build/AuditFixes/plugin-stage.log`.
- No current registered bundle, permission entry, or live Final Cut project was changed during this update. Current-build native Analyze, Apply, settings recovery, and navigation cleanup still require the user's checks in `Cutdown Integration.fcpbundle`.

## September 17 feature completion

Implemented at the user's request, with live testing left to the user:
- Retry Verification has a separate operation with no import callback. It reuses
  immutable expected XML, compares the existing result, and persists its bound
  host UID and expected-XML hash. Verify Existing Result resumes after restart
  and adopts older matching result/report/settings artifacts. Busy and duplicate
  retries are gated independently of the consumed Apply plan.
- Go to Cut / Go to Selected Cut verifies the original timeline baseline and
  moves the playhead through Final Cut's documented timecode entry. It supports
  nonzero project start timecodes and drop-frame formatting, verifies focus and
  the displayed result, and leaves inclusion choices unchanged.
- Settings recovery first verifies the imported timeline, plans exact occurrence
  corrections, opens each affected controller, commits its saved values, and
  checks a fresh host export. Partial recovery resumes only remaining mismatches.
  Same-name/different-UID results, changed artifacts, and unretained settings
  cannot produce a successful verification.

Validation: 97 focused Swift tests pass (`build/feature-completion-tests.log`),
including verification-only retries, restart/legacy recovery, partial restoration,
identity/artifact rejection, navigation ownership, and existing capture/settings
checks. The Controls harness passes (`build/feature-completion-factory.log`),
including Save Settings without Analyze, invalid input, cut identity, and separate
retry command delivery. Helper and audio-plugin signed candidates are staged
(`build/feature-completion-helper-stage.log`, `build/feature-completion-plugin-stage.log`).
The installed bundles were not replaced. These features require both new builds.
No live Final Cut or permission actions were performed. Actual host timecode
navigation, per-segment AX selection/setting writes, native persistence, and full
Apply remain user-verification boundaries; no live success is claimed.

## September 17 helper ownership follow-up

Three further code-review fixes are implemented:
- Import readiness can reveal the Libraries browser once, after the dialog-free
  interval and only on the original project, before requiring result visibility.
- The default helper build refuses to replace a running helper and fails closed
  if process inspection fails. It checks both before building and before swapping
  bundles; staged builds preserve the installed bundle.
- Helper review delivery is independent of plugin publication. Transport failure
  retains local selection/Apply and cached status; payload validation still fails
  closed, and duplicate Apply still runs once.

Validation: 58 focused Swift tests passed (`build/three-followup-tests.log`),
including hidden-browser readiness, dialog/identity gating, transport failure,
selection, status recovery, single Apply, and oversized-payload rejection.
`python3 Tests/BuildScripts/test_build_helper.py` passed five tests using fake
process/build tools, covering running/unreadable/late-started processes, stopped
installation, and staging. Shell syntax passed. The sandbox could not read the
process list, so the new default-build guard stopped without replacing the app
(`build/three-followup-build.log`). The signed candidate is built with `--stage`
(`build/three-followup-stage.log`); these three fixes are not installed yet.
No live tests or permission changes were performed. User-owned live testing
remains pending after installation with the helper stopped.

Import-completion follow-up: reproduced the user's post-import dialog failure on
the disposable six-second Cutdown Import Completion 0917 fixture. Added bounded
import readiness, exact-file completed-warning acknowledgment with saved dialog
evidence, and accurate persisted post-import failure status. All 52 focused tests
passed and the helper is installed. The user is handling further live testing
and permissions. The new Apply path remains unverified in Final Cut; do not
count the already imported pre-fix fixture result as verified. Evidence:
`build/ImportCompletionVerification/Notes.md`.

Subsequent Analyze visibility follow-up: stopped both stale processes and launched
the installed helper. The disposable six-second fixture completed processed-audio
Analyze, but Final Cut recreated the Controls view and lost its job identity.
Added an independent helper-owned review window; 17 focused tests passed. The
rebuilt helper is installed. Restarting it recognized the access the user had
already enabled, with no permission or binary changes. Request
014C4F7A-A982-446B-BF39-5E3ABD359711 completed processed Analyze and visibly
showed one selected 1.933-second cut in the helper window. No Apply was tested. See `build/AnalyzeVisibilityVerification/Notes.md`.

Live process inspection found both `build/Cutdown.app` and the older staged
`build/Candidate/Cutdown.app` running. Both received broadcast status requests;
the non-owning helper sent an `Int.max` failure revision that displaced the real
owner's responses. Helpers now ignore commands for unknown jobs. The Controls
timeout remains responsible for recovering after an owner exits. Staged helper
builds now use a distinct bundle identifier and omit URL/document/Share handler
metadata; local registration removes the candidate's cached registration first.

All 15 coordinator tests passed, including both delivery orders with two helper
instances (`build/helper-ownership-tests.log`). A temporary build-script harness
verified installed versus candidate bundle metadata with build/signing commands
stubbed, and shell syntax checks passed. The stale processes were subsequently
replaced and the Analyze path tested as described above.

## Design and acceptance
- One request-owned Share exchange for XML and rendered media, persistent ownership prevents late/restarted delivery invoking another workflow.
- Temporary isolated XML project referencing original media, controller removed (passthrough only), other processing preserved; XML delivered with the host render verified against the intended isolation before PCM is used. No silent source fallback. The render delivery now performs the initial imported-project identity binding, avoiding a preceding XML-only Share.
- Apply captures and verifies imported result, writes durable verification report; delivery alone never succeeds. Actual rendering effects must survive.
- Interactive request settings are authoritative for detection; validate controller identity and saved state shape, not stale host values as detection truth. Keep strict developer artifact verification.
- Configurable signing/build validation; no new keychain or trust settings.
- Extract XML recovery from native edit utilities; one interactive app coordinator. Retire obsolete production edit code only after call-site audit.

## September 17 fixes and verification

The source now addresses the review findings with these changes:

| Finding | Implementation | Verification boundary |
|---|---|---|
| Non-Dialogue projects cannot Apply | Ignore only the obsolete Dialogue warning for source/isolated analysis; retain all other warnings | Coordinator regression covers Music-role source and isolated contexts |
| Dropped Apply locks Controls | Retry the same job until acknowledgment; timeout invalidates review and enables Analyze with uncertain-import guidance | Factory harness covers retries, acknowledgment, timeout, and stale replies; coordinator still applies once |
| Missing preview lines | Native window ordering above the exact project window replaces rectangular occlusion masks | Geometry and drawing tests pass; on-screen live verification pending |
| Current automatic Analyze/Apply | Current source builds into signed candidates | New-build live integration remains pending; no current automatic cuts claim |
| Imported settings disappear | Embed submitted AU state/scalars; report `controllerSettingsPreserved` separately; restore the exact saved JSON from Controls | Archive-only readback and host-state-loss reporting tests pass; native host retention remains unverified |
| No per-cut selection | Checkbox rows and Select All / Select None, with acknowledgment before Apply | Factory harness checks exact cut identity and acknowledgment; coordinator tests verify selected cuts |
| Temporary projects accumulate | Delete only the exact request-owned, verified analysis project after returning to the original; bounded cleanup on interruption | Ownership rejection tests pass; host deletion path pending live validation; unresolved cleanup leaves a named status file |
| Fades/keyframes reject all Apply | Preserve full source-time keyframe curves; keep fades only at original outer edges and protect cuts intersecting fades | Cut and gap fixtures verify source coordinates/outer fades; host animation render equivalence pending |
| Contradictory documentation | Current README/workflow/plugin docs reconciled; previous README preserved in `integration-history.md` | Source review |

Evidence so far:
- `build/all-fixes-tests-access.log`: 298 Swift tests passed (222 Mac, 76 Core). The earlier sandbox run could not start AVFoundation readers; preserved in `build/all-fixes-tests.log`.
- `build/all-fixes-final-focused.log`: 97 focused tests passed after import-report parsing was changed to parse each document once.
- `build/all-fixes-factory-tests.log`: Controls harness; `build/all-fixes-audio-tests.log`: 60 exact passthrough cases plus state/persistence checks.
- Signed candidates: `build/Candidate/Cutdown.app`, `build/Candidate/AudioPlugin/CutdownAudio.app`; build logs `build/all-fixes-helper-stage.log` and `build/all-fixes-plugin-stage-safe.log`.
- Automatic approval review rejected quitting Final Cut because closing it might interrupt unsaved work. Installation and live testing await the user's explicit choice.
- The initial candidate plugin build reused the old Xcode build graph, which unexpectedly pruned the registered products. The signed candidate survives. The staging script now uses `build/AudioPluginStage` to prevent pruning registered products. The corrected staging build passed without stale-product pruning. Installation/registration now fail closed if the process list cannot be read. Restoring the registered bundle is pending Final Cut closure; no library/project media was deleted by this build.

Remaining limitations must not be labeled fixed by unit tests: cuts through an existing fade curve are intentionally unavailable; Final Cut may still discard private settings, in which case explicit JSON restoration is provided; live preview, temporary project deletion, animation import/render fidelity, and full current-build Analyze/Apply must still be observed inside the required integration library.

## Earlier progress (through September 16)
- Existing code audited. Implementation in progress.
- September 16, reduced analysis work: combine initial isolated-project verification with XML delivered by the audio Share. Verify the intended isolation directly before using PCM; no separate pre-render XML export. Processed Analyze uses three Share exchanges rather than four. Reuse immutable capture bytes across routing/isolation/analysis/preflight, and parse unchanged fallback XML once instead of on every 100 ms read. Stability waiting, source-content validation, restored-original checks, fresh Apply checks, and final host verification remain.
- Validation: 86 focused tests passed with macOS media-service access (`build/reduced-analysis-work-tests-access.log`); the sandboxed run failed to start AVFoundation readers. Added tests cover combined render/identity verification with incorrect effects/media/timing/roles, cached-byte analysis with stale-project rejection, and XML completion stability across invalid/replaced/missing data. Helper rebuild log: `build/reduced-analysis-work-build.log`. Live reduced-exchange Analyze/Apply remains unverified; no measured speedup is claimed.
- September 16, menu/input cleanup: removed the unused XML Save-dialog route and its Go to Folder / Return keystrokes; XML capture always uses the existing programmatic Share exchange. Skip range-clear input when no range exists (unreadable AX state stops), skip already-selected export tabs, and skip Libraries navigation/view switching when the imported project is already exposed. Timeline-focus fallback now verifies actual focus. Remaining host UI: Share initiation/confirmation and format controls, conditional range clearing, and project navigation. No direct start-share command was found in the installed Final Cut scripting dictionary or Apple's documented custom Share exchange.
- Validation for this cleanup: 67 focused capture, range-preparation, export, Share, and XML Apply tests passed (`build/programmatic-actions-tests.log`). No live Final Cut test was run for these changes; automatic Analyze/Apply and visible-project navigation remain unverified for this revision. This does not complete the overall integration overhaul.
