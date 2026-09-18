# September 17 command fixes and code cleanup

> Historical development record. Build paths, installed/staged app state, and test totals below describe the original run. Generated logs and Final Cut libraries are not included in Git. Use the [README](../README.md) for verification of this repository copy and [setup](setup.md) for a fresh installation.

Both confirmed command-delivery bugs are fixed, and the eight requested cleanup items are implemented. Current builds remain staged for the user's live Final Cut checks; registered apps and permission entries were not changed.

## Behavior fixes

- **Retry Verification:** the plug-in resends a dropped request with its original `expectedRevision`. A newer response releases its pending button. The helper rejects stale retries after a verification starts or finishes, so retransmission cannot start a repeated-attempt loop. If another review prevents starting, the helper acknowledges that rejection with a newer explanation. Retry also restarts polling after a connection timeout. Verification never imports again.
- **Preview:** a pending toggle resends until a newer response reports the requested visibility or leaves review. The checkbox remains disabled and displays the helper's last confirmed state while waiting. Replayed status messages cannot falsely acknowledge the toggle.

## Cleanup completed

1. Extracted validation, cached heartbeats, pending commands, retry selection, and timeout checking into the AppKit-independent `CutdownReviewConnection`. The view retains control rendering and timer lifecycle.
2. Split the former 1,454-line `FinalCutProjectCapture.swift` into focused capture, session, timecode, selection, policy, menu, timeline, settings-recovery, sharing, browser, and review-window files. The capture entry point is now 85 lines. Session extensions remain internal; shared helpers widened only from private to internal where required. A move audit found zero missing or extra executable lines, allowing visibility changes.
3. Moved historical full-project export helpers and obsolete preview-mask geometry into test fixtures. Historical behavior remains testable without shipping inactive workflow code.
4. Centralized exact Float32 settings equality in `AudioControllerSettings.equivalent` for verification and recovery.
5. Added typed Swift review states and named Objective-C state constants. Both implementations validate busy, terminal, and retry policies against a shared JSON fixture.
6. Resolved the production hashing callback's Sendable warning and a historical test fixture's nested-capture warning.
7. Updated the protocol, workflow, and current-status documentation, including unchanged heartbeats, acknowledgment behavior, automatic settings recovery, and staged-versus-live validation.
8. Replaced the long shared-state plug-in test sequence with eleven independent scenarios, each using a fresh view, processor, private settings file, and request. The harness additionally checks the shared state contract.

## Automated evidence

- **337 Swift tests passed:** 260 Mac and 77 Core (`build/CleanupFixes/full-swift.log`). The final test-fixture warning adjustment was checked separately in `legacy-fixture-check.log`.
- All eleven plug-in scenarios and the shared-state contract passed (`factory.log`). Lost Preview/Retry delivery, exact acknowledgments, stale Apply, retry revision binding, and timeout behavior are covered.
- The Audio Unit harness passed 60 exact mono/stereo render cases plus state and persistence checks (`audio.log`).
- All 12 build-script tests passed (`build-scripts.log`).
- The Final Cut source move is recorded in `capture-move-audit.json`.
- Matching signed candidates are at `build/Candidate/Cutdown.app` and `build/Candidate/AudioPlugin/CutdownAudio.app`; build/signature logs are `helper-stage.log` and `plugin-stage.log`.

Logs above are under `build/CleanupFixes/`. An initial build caught a missing accessibility import after the file split; that was corrected before the successful full run. Tests use offline fixtures; decoding tests had normal macOS media-service access. No Final Cut UI was operated.

## Combined live checks

Install both matching builds using [the audit guide](audit-fixes.md), then run its existing sequence in small disposable projects inside **Cutdown Integration.fcpbundle**, referencing generated source media in place. Add these checks to that same session:

1. Leave a completed review idle for at least 30 seconds, then toggle preview off and on. Confirm the checkbox agrees with the overlay after each acknowledgment.
2. On a recoverable failed import verification, click Retry Verification once. Confirm it becomes available again after a failed attempt and that no additional result is imported.
3. Complete Analyze and Apply for both an unprocessed clip and an effect-bearing clip; verify cuts, retained effects/settings, original-project preservation, and temporary-project cleanup.

Live timeline cuts, native settings persistence, preview placement, and cleanup remain unverified on this revision until the user performs these checks. The 1,000-cut review limit and intentionally unsupported editing cases remain unchanged; those are feature work, not part of this cleanup.
