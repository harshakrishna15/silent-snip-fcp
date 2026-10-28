# Share prototype: current status and evidence

Updated October 28, 2026. The user requested removal of the covering window. The installed development prototype now uses Final Cut's visible Share interface, with no cover or separate progress window. Progress and review remain in the Audio Unit's existing Controls. The former concealment design is retained in [the original plan](quiet-share-plan.md), with its changed scope marked explicitly.

## Implemented behavior

The containing app still supplies background analysis and the sandboxed Audio Unit. Decoding, detection, cut planning, XML generation, source checks, caching, and cleanup are programmatic. Share setup, temporary-project navigation, import, settings recovery, and host re-export verification are automated through Final Cut's interface and require foreground focus. Removing the cover does not make these operations headless or reduce Final Cut's rendering work.

The prototype retains request ownership, bounded waits, cancellation, exact workspace-library checks, verified menu invocation, and the visible legacy path. It never retries a dispatched export after an uncertain result. Processed-audio Share uses the visible Settings and Roles panels to prove Audio Only, WAV, and one All Dialogue output. Audio delivered without that proof is rejected.

The four detection parameters now appear in the native Inspector as approved by the user. Their addresses and native state format are preserved. Main-thread document-state notifications let Final Cut archive unchanged defaults and Inspector edits. Recovery uses numeric fields because native slider writes round some custom values. Fresh automatic recovery still needs a completed live pass; UI text alone is not proof of saved state.

## Native evidence

Environment: Final Cut Pro 12.4, build 454072, on macOS 27.0.1, build 26A434. Every live check used disposable projects in the exact workspace-root `Cutdown Integration.fcpbundle`, with generated audio referenced in place. No other library was used.

Current local evidence is under `build/QuietSharePrototype/Live-ff87b5b/`. That directory name identifies the starting commit, not a claim that the payload contains only that commit. Runtime originals and recovery artifacts remain in the existing Silent Snip application-support directories.

| Case | Observed result |
| --- | --- |
| Source-audio Analyze | Passed through the plugin Controls; native XML returned and review opened. Recorded runs were approximately 3.8–4.6 seconds. These are diagnostic timings, not paired performance comparisons. |
| Noise Gate and Limiter Analyze | Passed through visible Share in request `914B5EF7-5E40-459C-AB43-CFEF3AD7F86B`, including live export-format/role validation, original-project restoration, and owned temporary-project cleanup. Total approximately 17.60 seconds. Evidence: `Processed-Visible-Passed`. |
| Render delivered without live settings proof | Rejected in request `40E33616-2402-449D-83FE-DAAA154A4F29`. The delivered files were preserved. This did not count as successful processed-audio analysis. |
| Existing cut result verification | Request `F3146624-B4BA-4B3C-8E2C-911A58F53E44` passed timeline, effects, controller-state, source-fingerprint, and destination verification after the document-state notification fix. An earlier manual native-parameter probe preceded the successful retry. This is not a fresh unattended Apply pass. Evidence: `Final-Cuts-Verified`. |
| Nondefault cuts | Request `EF01F50B-FA90-40F9-AB56-3586D5B366CA` replaced the disposable project with the expected 2.2667-second timeline. Native slider recovery rounded custom settings, so verification stopped. No second import was attempted. Numeric-entry recovery was added afterward. |
| Current visible flow | Request `B45C1EDF-C4B5-4361-9646-42C9BEC90827` completed Analyze with -42.5 dBFS, 0.25-second minimum, and 0.125-second padding. The user clicked Apply Cuts. Automatic Replace returned AX success and the host timeline matched the intended two audio segments plus one-second gap, totaling 3.2667 seconds. Settings recovery stopped on a selection-ownership check; full verification did not pass. Evidence: `Visible-Share-No-Cover`. |
| Cover removal | The cover/card/window-tracking implementation is removed. The current native operation reports `visible-plugin-prototype` and zero cover transitions. |

Final Cut's 12.4 replacement dialog is handled only for the exact observed Silent Snip sender, required library, question, and button set. `Replacement-Confirmation.json` records the once-only press. Retry Verification has no import or replacement-confirmation step.

The generated source WAV retained SHA-256 `66a8102d26d926b8e7715df3073e9ff404669e7482b88a0935a4dbe581f8436e`. Original media, recovery XML, saved results, manual exports, integration evidence, and rollback ZIPs remain preserved. The exact last-used settings backup from before the nondefault test was restored after Final Cut and the helper exited.

## Build and remaining work

The current Swift suite executed 442 tests with one existing skip and zero failures. The audio harness passed 60 render/persistence cases, Controls passed 35 checks, and the build-script suite passed 53 tests. These are automated checks. The signed prototype ZIP passed integrity checks; the copied app and contained extension passed strict signature verification. `Visible-Share-Installed.json` records the installed executable hash and rollback archive.

The remaining editing gate is a fresh complete cuts-and-gaps pass with exact controller settings and source verification. Current failed/pending result receipts must be retried through verification, not imported again. Full-screen, secondary-display, cancellation, and application-switching behavior have not received a complete native matrix for this revision.

The planned production Share-transaction refactor and the complete single-observation settings fast path have not been implemented. The covering-window work is superseded by the user's visible-Share direction. No background-only export or measured speedup is claimed. See [testing steps](quiet-share-prototype.md).
