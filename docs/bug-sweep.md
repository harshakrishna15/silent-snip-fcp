# Final Cut Pro bug sweep, November 10, 2026

All Final Cut checks used the existing workspace-root `Cutdown Integration.fcpbundle` in Final Cut Pro 12.4 (454072) on macOS 27.2.1 (26B131). The **Disposable Bug Sweep 20261110** event holds six 12-second, 30 fps projects. The two generated 48 kHz WAVs are linked in place from `build/BugSweep/Fixtures`. The event contains no copied, optimized, or proxy fixture media.

## Issues

| Severity | Reproduction | Fix and evidence |
| --- | --- | --- |
| Medium | Analyze **Sweep Limiter Gaps** in Remove Silence mode on worker 78. Change Output to **Replace with 1-Second Gaps**. Cut Review enables Apply and predicts 10.900 seconds. Apply stops before import with an error about missing native Limiter settings. | Worker 79 uses the existing bulk import and effects-only native Paste Attributes for this mode. It verifies gap positions and excludes gaps from the Paste selection and receipt recipient count. The regression tests cover exact source and timeline geometry, leading and trailing gaps, a selected gap, and recovery with gaps. The original failure timing and result inventory are in `build/BugSweep/Evidence/Limiter-Gaps-Reproduction`. |
| Low | Analyze **Sweep Continuous Tone** on frontend 30. Cut Review has zero rows and Apply is disabled, but the extension displays an operation-failed banner. | Frontend 31 shows the empty-review reason for fresh and retained-audio analyses. The raw worker notice remains available and additional cleanup warnings stay visible. `repro-empty-review.log` records the failing regression and `final-controller.log` records the passing run. |
| Low | Run the three frontend test scripts exactly as shown in the README on a clean checkout. Each exits with permission denied. | The three scripts now have execute permission. The three final logs show they pass when called directly. |

## Builds and offline checks

- Baseline source was `42e3b4b758e157f8faeabe08ff8872bcf2faca51`. Both baseline pairs reported worker **78** and frontend **30**. The installer payload and the pre-existing workspace worker had different executable hashes. The package install and its permission check used the per-user pair. The baseline Analyze and Apply checks used the workspace pair with its existing control grant. See `installed-baseline.log`, `live-baseline-processes.log`, `workspace-baseline-builds.log`, and `workspace-baseline-processes.log` in `build/BugSweep`.
- The per-user package installed both apps, and the frontend opened its setup window. The new copy of the baseline worker showed the expected Device Control and Data Access error. The existing workspace worker could analyze and edit the fixtures. The per-user installer also upgraded both apps to worker **79** and frontend **31**. The upgraded apps, the workspace pair, the ZIP, and the expanded package payload match byte for byte. `final-build-identity.log` records the hashes and deep signature checks. The package is locally built and unsigned.
- The README's final release Swift run executed **963 tests** with three opt-in skips and zero failures. The three direct frontend scripts passed **63 controller groups / 9,494 assertions**, **28 review-client groups / 307 assertions**, and **8 window-client groups / 174 assertions**. The Python suite passed **133 tests**. See `build/BugSweep/final-*.log`. The initial sandboxed Swift attempt could not run Xcode's debug-symbol tool. The native rerun used the same `build/swift` scratch path and passed.

## Native checks

| Fixture | Reviewed scope and output | Saved timeline |
| --- | --- | --- |
| Sweep Plain Removal | Whole 12-second clip. Remove 2.300–3.400, 5.300–6.900, and 9.300–10.100 seconds. | **8.500 s**, four source clips. |
| Sweep Plain Gaps | Whole clip. Replace 2.400–3.400, 5.400–6.900, and 9.400–10.100 seconds with one-second gaps. | **11.800 s**, four source clips and three real gaps. |
| Sweep Limiter Removal | Selected range **3.000–10.000 s**. Remove 5.100–6.900 and 9.100–9.900 seconds. | **9.400 s**, three source clips with enabled Limiter and one native effect transfer. |

Each successful result has a different project UID, the reviewed source trims and timeline offsets, the expected project duration, the original media URL, and the retained fixture marker. The originals retain their UIDs, modification dates, 12-second timelines, marker, and effect state in the fresh Final Cut event export. See the per-result folders and `Baseline-Timeline-Audit.json` under `build/BugSweep/Evidence`. The audit reads the actual Final Cut re-exports and uses the boundaries observed in Cut Review.

On worker 78 and frontend 30, no selection produced the selection prompt. The continuous-tone clip produced zero cuts. Switching projects cleared the active review. Cancel cleared three reviewed cuts and disabled Apply. After a separate analysis, increasing clip volume by +1 dB left the old rows visible until Apply rechecked the project. The worker rejected the stale review before import. The failed timing and result inventory are in `Evidence/Stale-Apply`.

Rapid After Speech edits from 0.2 to 0.3 to 0.4 seconds and a subsequent change to gap output updated the same plain-audio review. Apply locked while the update was pending. All three cut starts moved as expected. The Share Inbox and analysis-job directory inventories gained zero entries. The worker's local-preview timing also records zero Share exchanges. See `Evidence/Automatic-Settings/gap-refresh-inventory-diff.json`.

## Native follow-up

The worker 79 and frontend 31 process paths and hashes match the test package before and after relaunch. See `build/BugSweep/final-running-builds.log` and `build/BugSweep/final-running-builds-after-grant-refresh.log`. The rebuilt worker initially failed its control-access check despite an enabled System Settings entry. After the user approved replacing that stale entry, startup and Analyze access recovered. The earlier failure timings and startup reports remain in `build/BugSweep/Evidence/Rebuilt-Worker-Permission`.

The native Limiter gap Apply then completed: the saved result is **10.900 seconds**, with four source clips and three one-second gaps. `Evidence/Final-Timeline-Audit.json` records this fourth result alongside the three earlier fixtures. Read-only verification after relaunch succeeded without another import; the saved result XML and effect-transfer journal hashes remained unchanged. See `Evidence/Limiter-Gaps/Verify-After-Relaunch`.

Frontend 31 displayed the no-silence explanation with Apply disabled, and switching projects cleared a populated review. See `Evidence/No-Silence/Frontend-31/frontend-observation.txt` and `Evidence/project-switch-frontend-31.txt`. These are scoped fixture checks, not a completed audit of every supported timeline or plugin.
