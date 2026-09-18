# September 17 audit fixes

> Historical development record. Build paths, installed/staged app state, and test totals below describe the original run. Generated logs and Final Cut libraries are not included in Git. Use the [README](../README.md) for verification of this repository copy and [setup](setup.md) for a fresh installation.

All eight findings in `build/CodeAudit/Code-Audit.md` have implementation fixes. Automated validation is complete; current-build live Final Cut verification remains with the user. No live interaction, permission refresh, registration, or installation was performed for this update.

The current staged candidates also include [three performance optimizations](performance-fixes.md) and [command-delivery fixes plus code cleanup](cleanup-fixes.md), with 337 passing Swift tests and independent Controls scenarios. The validation counts below describe the preceding audit revision; use the cleanup record for current build evidence and its additional live checks.

| Finding | Change | Regression coverage |
|---|---|---|
| Recovery stops at another segment | Recovery binds each verified occurrence independently; ordinary capture still rejects a mismatched suspended review | Same-named segments with different timeline edges; strict capture guard |
| Rapid Analyze clicks lose requests | Analyze disables immediately and rejects another submission while awaiting a response or busy | Actual Controls class, duplicate clicks/direct action, view refresh, launch failure, timeout |
| Stale review becomes actionable | Baseline/project changes discard cuts and preview and disable Apply/navigation | Baseline and project-identity errors; ordinary navigation failure retains valid review |
| Extreme fades crash | Fade durations clamp to clip duration before checked arithmetic | Former crashing XML; whole target stays protected |
| Settings lose precision | Localized nine-significant-digit formatting preserves Float32 values; field limits are checked at AU precision | Tiny/subnormal/normal values, four locales, actual Controls commit, minimum silence boundary |
| Navigation leaves timecode entry | Failure/cancellation runs bounded cleanup in a fresh task; keys require the same project, frontmost window, and owned field | Success, error, cancellation, cleanup error; native focus behavior still requires live checks |
| Build replaces a newly loaded plug-in | Compile/sign a separate candidate and recheck Final Cut immediately before publication; rollback on failed replacement | Host starts mid-build, unreadable process list, signature failure, publication failure, staging |
| Verification data accumulates | Keep at most 24 pending receipt URLs, load XML only for an attempt, release completed entries, prune restored coordinator jobs | Eviction, reopening, completion/removal, shutdown clearing, preserved files, 40 restored jobs |

Validation:

- **327 Swift tests passed:** 250 Mac and 77 Core (`build/AuditFixes/full-swift.log`). These are offline tests; AVFoundation decoding used normal macOS service access.
- Controls/Factory harness passed, including rapid Analyze and precision regressions (`build/AuditFixes/factory.log`).
- Audio Unit harness passed 60 exact mono/stereo render cases and state/persistence checks (`build/AuditFixes/audio.log`).
- **12 build-script tests passed** (`build/AuditFixes/build-scripts.log`).
- Matching candidates: `build/Candidate/Cutdown.app` and `build/Candidate/AudioPlugin/CutdownAudio.app`. Build/signature results are in `build/AuditFixes/helper-stage.log` and `build/AuditFixes/plugin-stage.log`.

For installation, first finish/save work and quit both Final Cut Pro and Cutdown. From this workspace, run:

```sh
./scripts/build-helper.sh
./scripts/build-audio-plugin.sh
./scripts/register-local.sh
```

Use both matching builds. The staged helper deliberately has a candidate identity without the live Analyze URL/Share routes, so opening it directly is not a substitute for installing the matching helper. Keep the registered build paths in place afterward.

Run the following checks together in small disposable projects inside the existing **Cutdown Integration.fcpbundle**. Reference generated source media in place; avoid copied, optimized, and proxy media. Do not use other libraries or projects.

1. Analyze an unprocessed clip and a clip with an audio effect. Click Analyze again immediately during connection. One job should continue to review; repeated clicks should not cancel it.
2. Apply a plan yielding at least three retained segments. If Final Cut resets controller state, all affected segments should recover during one verification attempt. Confirm the imported cuts, original project, and per-segment settings.
3. Use nondefault settings, including a small padding value such as `0.00123456789` and minimum silence `0.1`. Confirm Controls can save/reopen them and verification does not loop on a rounded setting. AU values are stored at Float32 precision.
4. After Analyze, change the original timeline and then choose Go to Cut. The old review/preview should disappear and Apply should remain unavailable until Analyze runs again.
5. Test normal Go to Cut and cancellation while navigation is running. Confirm no timecode field remains awaiting input. If focus moves to another app or a user-owned dialog, Cutdown should leave that surface alone.
6. Interrupt verification after an import, then use Retry Verification. Also reopen a saved result after restarting the helper. These actions should verify/recover the existing project without another import.

The malformed-XML crash, bounded retention, and build-publication race have automated regression coverage. They do not require deliberately crashing the app or replacing a loaded plug-in during live checks. Automated passes do not establish native timeline cuts, settings persistence, navigation cleanup, preview, or processed-render fidelity; those remain the purpose of the checks above.
