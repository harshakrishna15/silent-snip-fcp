# Review and verification fixes

The October 23 code update addresses five reproduced bugs and the recovery
window-list inconsistency. Offline checks exercise the native Controls class,
coordinator state, receipt persistence, and recovery-window selection policies.
They do not establish a completed live Final Cut Analyze → Apply editing pass.

## Behavior

- A connection timeout consumes the local review. Delayed progress or settings
  success cannot enable Apply, navigation, or inclusion changes. Final outcomes
  can still arrive, and an explicit verification retry gets a fresh connection
  deadline. Timed-out commands are never retransmitted.
- Reconnection uses the Audio Unit's actual parameter bounds, including Minimum
  Silence values from 0.0001 seconds. Validation uses the same Float32 values as
  the effect's fields and saved parameters.
- Menu and double-click navigation both require clean, verified settings.
- A recreated Controls view reconnects only to its exact retained job, using the
  latest detection settings and output mode. Cancelling an ordinary review
  revokes that connection. Pending imported-result verification remains retryable.
- Settings recovery validates the focused editor's native controls and clip
  title even when Final Cut omits that editor from its window list. A different
  focused editor, changed selection/project, or another matching live editor
  prevents recovery writes. A retained editor is freshly identified before close.

## Project window recovery after import

An Apply failure reported “Open a project in the main Final Cut window” before
verification could inspect the imported result. Session creation previously
required a nonempty `AXMainWindow` attribute, which can disappear during host
transitions even while the project workspace remains available.

Session creation now identifies the workspace by its standard, nonmodal window
and project toolbar. Replacement recovery can also identify an empty workspace
by its Libraries sidebar. When the main-window attribute is missing or refers to
another kind of window, discovery requires exactly one workspace; effect
editors, secondary viewers, duplicate references, and ambiguous workspaces are
handled explicitly. Discovery is bounded and refuses an incomplete window scan.
Import verification briefly waits for a temporarily missing workspace, without
redelivering XML or reconfirming a replacement. Browser navigation after import
must remain in the same process and window.

The reported result's receipt and XML were inspected without modifying them.
The required integration library was visible in Final Cut, but its timeline
still showed a single five-minute clip while the generated result contained
249 storyline items and about 192 seconds. This is not evidence of a successful
replacement. No live Apply, reimport, or verification retry was performed during
this investigation. The existing result remains unverified.

## Source integrity

New Apply receipts retain the source-content snapshot already checked against
the analyzed project. Source contents are checked again immediately before
import. The receipt preserves the original URLs, canonical paths, and SHA-256
hashes so retries after restart can detect missing media, content replacement,
and changed aliases. Evidence must cover every enabled source in the result.

Verification reads current source contents before exporting the host timeline
for comparison, rechecks them before settings recovery, and checks them again
before success. Hashing runs
off the UI thread and is independent of the number of recovered segments.
Failure keeps recovery XML and the pending receipt and writes an unsuccessful
verification report; it never triggers another import.

Older receipts remain readable. They require available media that stays unchanged
during the verification attempt, but cannot establish historical source integrity.
Their status explicitly states that limitation, and the verification report's
`sourceMediaVerified` field is false. New receipts that match their saved source
evidence report true. Other semantic-only reports may omit the field.

## Live follow-up

Use small disposable projects only in the workspace-root
`Cutdown Integration.fcpbundle`, with generated media referenced in place.
Check timeout recovery, tuned-review cancellation/reopening, small Minimum
Silence settings, invalid-text navigation, imported settings recovery, and
changed/missing source refusal. Include recovery with a focused remote editor
omitted from the host's window list. Preserve recovery and exported evidence.

These changes do not alter the supported clip/effect scope or expand cache
eligibility. Live automatic Apply and remote-editor behavior remain separate
validation from offline regression success.

## Offline verification

The earlier review-safety Release run passed 404 Swift tests with one benchmark skipped and no
failures, 33 Controls checks, 60 audio cases, and 53 build-script tests. The
Release helper, Audio Unit, and combined staged app built successfully. App
signatures, extension sandboxing, candidate route isolation, and matching helper
code were checked.

Logs and the verification summary are in `build/ReviewSafetyFixes`. The combined
candidate is `build/Candidate/App/Silent Snip.app`; it is deliberately inert and
is not an installation package. That earlier review-safety run did not change
installed apps or registrations.

The window-recovery follow-up passed 411 Swift tests (347 Mac and 64 Core), with
one benchmark skipped and no failures. Seven new regressions cover missing and
invalid main-window attributes, host main-window precedence, ambiguous
workspaces, duplicate window references, bounded discovery, and modal/editor
rejection. Logs for this follow-up are kept in `build/WindowRecoveryFix`.
The Release helper and combined inert candidate were rebuilt and their strict
code signatures passed. Candidate routes are absent and its embedded launch
contract remains disabled; this candidate remains an inert build artifact.

## Installed follow-up

After the user approved installation and reopening, Final Cut and Silent Snip
were closed. The live combined app and ZIP were published using the verified
components. The app at `~/Applications/Silent Snip.app` was replaced, with the
previous app retained as the verified archive
`build/WindowRecoveryFix/Installed-Previous.zip`. Project, media, result and
recovery files were preserved.

The installed helper and extension bytes match the published build and strict
signature verification passes. Both processes were confirmed running from the
installed app. Final Cut reopened the exact workspace integration library, and
its Silent Snip Controls opened with Minimum Silence still at 0.0001 seconds.
The saved result remains pending: after restart, use **More → Verify Existing
Result…** and choose its edited XML. This action immediately begins verification;
it was not invoked during this installation check. Live automatic Apply and
the reported result's successful replacement remain unverified.

## Quit with Final Cut

Silent Snip now watches Final Cut's application lifecycle. Once Final Cut has
been observed, quitting it also ends the helper session. Interrupted work is
cancelled once and allowed to finish recording its outcome and cleaning up
before the helper exits. New requests are refused during shutdown. Closing a
project window alone does not end the session. A helper opened manually before
Final Cut stays available for setup; Analyze launches it again when needed.

The Release suite passed 416 tests (352 Mac and 64 Core), with one benchmark
skipped and no failures. Five new lifecycle tests cover setup without a host,
idle exit, an open host with no project window, cancellation/draining, and quick
host relaunch during shutdown. The helper and combined app were rebuilt,
signed, and installed. The installed binaries match the published build. The
previous app is archived in `build/HostLifetimeFix/Installed-Previous.zip`.

A live idle shutdown check opened the installed helper before Final Cut, then
opened the required integration library. Both processes remained running until
Final Cut was quit using Command-Q; both then exited without process signals or
a separate helper Quit command. Final Cut was reopened to the same integration
library afterward. No analysis, Apply, reimport, or verification retry was run.
Active-operation shutdown is covered by offline policy tests, not a live edit.
Evidence and build logs are in `build/HostLifetimeFix`.
