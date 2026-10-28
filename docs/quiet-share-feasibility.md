# Quiet Share feasibility

Status: focus-required plugin prototype built, signed, installed, and registered for manual testing on October 28, 2026. Its existing macOS control-access grant was refreshed and background startup reports Ready. Quiet presentation is not enabled in normal Release builds. The production gate remains open.

The installed prototype remains commit `9ed26ad`. The later source hardening described below is queued for the next build and has not replaced that installed copy.

The full requirements remain in [the implementation plan](quiet-share-plan.md). The current user-requested checkpoint is a prototype operated from Final Cut's existing Silent Snip controls. The discarded standalone test-window approach is not part of the prototype.

## Environment and retained evidence

The host inspected for the isolated probes was Final Cut Pro 12.4, build 454072, on macOS 27.0.1, build 26A434. All generated projects and exports belong to the exact workspace-root `Cutdown Integration.fcpbundle`. Generated source media, Share deliveries, reports, and rollback ZIPs remain preserved under `build/QuietSharePrototype` and the existing application-support Share Inbox.

- `plain-visible-xml-8/Report.json` records a completed, parsed XML capture with verified project/library identity. Final Cut delivered XML without a confirmation panel; the prototype now recognizes the exact owned response instead of timing out waiting for that panel.
- `plain-covered-xml-2/Report.json` records foreground movement from Final Cut to `local.silentsnip.app` and safe cancellation with the cover dismissed. The probe was launched through Computer Use app selection. A manual test without selecting the helper during the cover is still needed to distinguish host activation from a harness effect. This is not proof of a general platform restriction.
- Earlier covered audio produced late XML/WAV files after cancellation. Those files were preserved as evidence, but their processing settings were not verified. They do not count as a passed processed-audio test.
- The later visible-audio check was stopped at the user's request to continue offline, before any new Share activity. It has no successful result.

These isolated probes precede the current plugin-connected prototype. They do not establish that its complete Analyze or Apply flow works.

## Prototype behavior

The prototype ZIP retains the normal background containing app and sandboxed Audio Unit. Analyze, review, Apply, and errors remain in the existing Final Cut effect controls. Only the prototype build enables the experimental presentation; Release excludes it.

A request-scoped development lease wraps existing coordinator operations. It attaches to a freshly checked Final Cut workspace, follows the same surface across session re-pinning, and releases on completion/error/cancellation. Cancel routes the same request UUID through the existing coordinator command. Cancellation blocks further host input before the main-actor panel dismissal is scheduled. Late callbacks cannot restart a finished or revealed cover.

Menu dispatch uses a freshly advertised shortcut or a supported Accessibility action. Return is allowed once for the exact uniquely selected enabled command in its verified open menu. An accepted Share request prevents another Return. No dispatch is retried after ambiguity or timeout.

Unproven menu paths and browser-coordinate fallbacks reveal Final Cut before dispatch and remain visible for the rest of the operation. Show Final Cut does the same without cancelling. External focus loss stops the operation; an already matched Share response activating its own receiver reveals the host for the existing verified return path. Keep Final Cut in front for this prototype.

The prototype verifies the sole open library before host actions and checks returned XML again. Existing processed-audio settings validation, conservative cache eligibility, source verification, recovery files, and import verification remain in use. An audio delivery without a verified live settings panel is rejected.

## Verification limits

Automated checks cover exact library restriction, guarded Return, request ownership, cancellation, late callbacks, and visible fallback selection. Full Swift, Audio Unit, Controls, and build-script results are recorded with the packaged prototype. Bundle/signature and ZIP verification are separate from editing verification.

The final Swift suite executed 431 tests with one existing skip and no failures. The 53 build-script tests passed. The unchanged Audio Unit and Controls sources retain the earlier passing 60-case audio and 33-check factory/Controls evidence; those are offline harness results. The installed containing app and its sandboxed extension passed strict signature checks, and the ZIP passed integrity checks. `build/QuietSharePrototype/Plugin-Prototype-Package.json` records the payload and verified rollback archive; check logs are preserved under `build/QuietSharePrototype/Checks`.

| Native case | Current evidence |
| --- | --- |
| Isolated visible XML | Passed before plugin-connected prototype |
| Current plugin-connected covered XML | Manual check needed |
| Covered Noise Gate/Limiter audio | Not verified |
| Cancel before confirmation / during delivery | Not verified in the current plugin-connected build |
| Show Final Cut, application switching, moved/resized windows | Manual checks needed |
| Full-screen / secondary display / unsupported layout | Not verified |
| Fresh Apply: cuts and gaps, recovery and source checks | Not verified for this build |
| Paired cold/warm latency and transition measurements | Not verified; no speed claim |

The full `FinalCutShareTransaction` refactor, conservative settings-observation shortcut, production timing schema, validated-host enablement, and production rollout remain gated work. This prototype is not a claim that the complete implementation plan has passed. See [manual test steps](quiet-share-prototype.md).

## Source hardening after installation

An offline review found that the presentation held its current session weakly even when a project-handoff caller could discard the returned session. The source now retains that pin for the request, releases it at finish, and re-pins a newly focused session before host input even when no activation call was needed. This prevents a temporary session's lifetime or an outdated project name from deciding cover behavior.

The source also verifies the exact workspace library in both returned XML-only and rendered-audio XML before the plugin prototype accepts them. A new test rejects a different library with the same filename and XML without a library location. The resulting Swift suite executes 432 tests with one existing skip and no failures.

These are source checks, not a new installed build or a native editing pass. The user has not yet tested the installed prototype. The covered XML, processed-audio, cancellation, restoration, and Apply gate remains pending that manual test.
