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

The final Release run passed 404 Swift tests with one benchmark skipped and no
failures, 33 Controls checks, 60 audio cases, and 53 build-script tests. The
Release helper, Audio Unit, and combined staged app built successfully. App
signatures, extension sandboxing, candidate route isolation, and matching helper
code were checked.

Logs and the verification summary are in `build/ReviewSafetyFixes`. The combined
candidate is `build/Candidate/App/Silent Snip.app`; it is deliberately inert and
is not an installation package. Installed apps and registrations were unchanged.
Use the normal build and installation instructions for a live copy.
