# Integration overhaul

This record tracks export reliability, isolated clip rendering, verified imports, settings retention, and local build/registration work. All Final Cut tests must use disposable projects in the workspace `Cutdown Integration.fcpbundle`. See [setup](setup.md#integration-test-library) for a fresh checkout.

Earlier entries describe the original development environment. Their installed/staged app state and logs under `build/` are not part of a Git checkout. The project currently provides local ad hoc builds; no release installer or updater is included.

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
