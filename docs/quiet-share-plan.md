# Quiet Share Integration Rebuild

## Summary

Preserve **Select clip → Controls → Analyze → review → Apply**, while concealing Final Cut’s temporary export panels and project transitions behind one stable progress layer.

Decisions confirmed:
- Use a borderless progress layer covering the active Final Cut workspace.
- Fall back to normal visible Share when concealment cannot operate safely.
- Require **no new setup**, shortcut assignments, or changes to the user’s normal Export shortcut.
- Retain the Audio Unit and Share architecture. FxPlug migration, private APIs, and modifications to Final Cut are excluded.

Start with a feasibility gate. The full presentation rebuild proceeds only after actual XML and processed-audio exports work beneath the cover without intercepting automation input.

## Implementation

### 1. Prove covered operation before refactoring the pipeline

Build an isolated development prototype using the existing integration library and generated media. Test the current host: **Final Cut Pro 12.4, build 454072, on macOS 27.0.1**.

Evaluate these invocation paths in order:
1. An existing shortcut freshly advertised by the exact enabled menu command.
2. A supported direct accessibility action.
3. For menu items that only select themselves: verify the exact menu is open and the intended item is uniquely selected and enabled, then send Return once.

A timeout or ambiguous result after dispatch stops the exchange. It must never trigger another shortcut, Return, click, or export attempt.

The prototype must demonstrate XML-only Share, processed-audio Share, cancellation, and window restoration. If covered activation fails, retain visible Share and record the limitation; do not enable quiet mode by default.

### 2. Centralize Share exchanges

Introduce an internal `FinalCutShareTransaction`, built around the existing request tokens, receipts, completion events, and ownership checks.

- Support XML-only and processed-audio intents.
- Track preparation, panel opening, configuration, delivery, validation, and completion.
- Retain the existing XML/render deadlines and bounded polling fallback for missing completion events.
- Keep `AnalysisReviewCoordinator` as the sole job owner.
- Preserve the existing `exportProjectXML` and rendered-audio interfaces so callers do not require a pipeline rewrite.

Most transaction work belongs in `Sources/SilentSnipMac/FinalCutProjectSharing.swift`.

### 3. Make input compatible with concealment

Update `Sources/SilentSnipMac/FinalCutMenuNavigation.swift` to use the verified invocation paths established by the prototype.

- Read existing shortcut metadata without opening menus where possible.
- Recheck the pinned process, project, focused window, command identity, and enabled state immediately before input.
- Never send a screen-coordinate click while the cover is present.
- If the legacy coordinate path is required, remove the cover **before dispatch** and remain visible for the rest of that operation.
- Do not change keyboard preferences or destination defaults.

### 4. Add one progress presentation

Introduce an internal `QuietPresentationController` and a request-scoped presentation lease, coordinated through `InteractiveAudioSession`.

- Render one opaque, borderless, nonactivating panel over the pinned Final Cut workspace, with a centered progress card.
- Keep Final Cut as the active application. Block clicks through the cover without taking keyboard focus.
- Show the project name, current stage, a spinner or genuine reported progress, **Cancel**, and **Show Final Cut**.
- “Show Final Cut” removes concealment for the remainder of the operation while work continues.
- Use no screenshots, screen-recording permission, global input suppression, or private window APIs.
- Track movement, resizing, application activation, and window destruction. Hide immediately when the user switches applications or the pinned surface becomes uncertain.
- Use request/generation checks so late callbacks cannot resurrect a dismissed cover.

Acquire the lease before the first host interaction and retain it through restoration and cleanup. Release it when review is ready or the operation ends. Apply this to Analyze, Apply, verification retry, and other review actions that actually invoke host automation; purely local recalculation needs no cover.

Pass the same lease through session re-pinning and temporary-project handoffs. Do not weaken existing project checks to keep the cover visible.

### 5. Reduce settings traversal conservatively

Read the live Share panel once before configuring it.

Skip configuration only when that observation proves **Audio Only, WAV, and the existing single-Dialogue-output requirements**. Missing or ambiguous evidence uses the current Settings/ Roles validation.

Do not trust a destination name, previous success, or saved preset alone. Preserve fresh reads after actions that can rebuild controls.

### 6. Integrate cancellation and recovery

Add an optional `InteractiveAudioSession.onCancelRequested(UUID)` callback. Wire it to the coordinator’s existing cancel command; introduce no new serialized commands or review-protocol version.

- Cancel stops further actions and dismisses the cover immediately while existing cleanup unwinds.
- Unexpected dialogs are revealed and stop automation; retain only the existing explicitly verified handling of owned dialogs.
- Losing application focus stops further input and must not automatically steal focus back.
- An uncertain Apply/import preserves its receipt and recovery XML for verification. No automatic reimport is permitted.
- Helper shutdown, host exit, errors, and discarded jobs always release the presentation lease.

## Validation and Rollout

**Automated checks**
- Test transaction ordering, duplicate/late events, deadlines, cancellation, and stale presentation callbacks.
- Test shortcut selection, guarded Return activation, coordinate fallback, and the prohibition on retries after uncertain dispatch.
- Test complete and incomplete settings observations, incorrect formats, ambiguous roles, and rebuilt controls.
- Run the full Swift suite using `build/swift`, plus the Controls, audio, and build-script checks.

**Native checks**
- Use only small disposable projects in the existing workspace-root `Cutdown Integration.fcpbundle`, with generated source media referenced in place.
- Compare paired visible and quiet runs for plain audio and Noise Gate/Limiter processing, including cold and warm analysis.
- Verify windowed, full-screen, secondary-display, resizing, application-switching, and unsupported-layout fallback behavior.
- Exercise Cancel before confirmation, during delivery, and after an import request.
- Run fresh Apply cases for Remove Silence and gaps, verifying project identity, edits, duration, effects/settings, source references, and recovery artifacts.

**Release gates**
- Supported normal operation conceals intermediate panels and transitions without new setup.
- No stranded cover, intercepted automation click, duplicate export, lost recovery artifact, or incorrect result.
- Unsupported cases continue through the visible workflow with an explanatory status.
- Extend `Analysis-Timing.json` with invocation method, presentation mode, fallback reason, and transition counters. Compare total latency and visible transitions; make no speed claim without measurements.
- Stage and verify signed components first. Install a backed-up development build for native checks only after both apps are closed. Enable quiet presentation only on validated host/macOS combinations; other combinations remain visible.

## Constraints

- Work with the current `SilentSnip` source/module names and preserve the rename already in progress.
- Retain processed-audio fidelity, conservative cache eligibility, fresh project/source checks, existing editing scope, and post-import verification.
- Final Cut still creates export UI internally; this rebuild conceals supported interactions rather than introducing a headless export API.
- A failed feasibility gate produces a compatibility report and leaves the existing workflow available. It does not justify shipping unverified concealment.
