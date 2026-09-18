# Single Controls window and effect-compatible preview

> Historical development record. Build paths, installed/staged app state, and test totals below describe the original run. Generated logs and Final Cut libraries are not included in Git. Use the [README](../README.md) for verification of this repository copy and [setup](setup.md) for a fresh installation.

September 17, 2026. Live testing is reserved for the user.

Follow-up: the [missing-preview correction](preview-connection.md) fixes the
role mismatch found in the user's saved Noise Gate/Limiter render, preserves
real analysis errors and corrects competing candidate registration on install.

The extra helper-owned Analysis and Review window has been removed. Controls is
now the single interface for settings, progress, review, Cancel, Apply,
Retry Verification and Verify Existing Result. The helper still owns jobs in
the background. Recreated Controls asks to reconnect, and the helper checks the
original selected clip, pinned project, sole Controls window and unique native
view identifier before returning that job. The view retrieves the retained
status and restores submitted settings without changing AU document state.

Preview no longer treats a nonmodal effect editor as a modal dialog. Native
window ordering keeps visible effect windows above the dotted boundaries.
Preview sampling no longer scans the Inspector's virtualized effect controls;
a controller below a long Noise Gate/Limiter stack is not evidence of removal.
The September 18 [preview persistence update](preview-persistence.md) adds a
separate bounded removal check using visible section or neighboring headers;
incomplete effect lists still cannot prove deletion.
Modal dialogs and sheets still hide the preview. Closing Controls preserves it;
Cancel, Apply or another Analyze clears/replaces it. If effects are changed or
removed, cancel or reanalyze; Apply still checks a fresh project baseline.

Processed audio continues through Final Cut's complete effect-chain render,
with no source-audio fallback. Regression coverage exercises gate, limiter and
opaque third-party effects with Cutdown at every stack position, verified
isolation and editable output segments. Existing tests cover component effects,
bypass, preset/parameter/opaque-state preservation, processing changes that
invalidate reviews, and generated gated audio. These are offline contracts,
not vendor DSP certification or proof of a live Final Cut round trip.

## Installation and live check

Install both matching builds, with Final Cut and Cutdown closed:

```sh
# Run from the repository root.
Scripts/build-helper.sh && Scripts/build-audio-plugin.sh && Scripts/register-local.sh
```

Use only a small disposable project in this workspace's existing
**Cutdown Integration.fcpbundle**. Reference generated source media in place;
do not copy, optimize or proxy fixture media.

1. Put Noise Gate, Limiter and Cutdown Audio on the same audio-only clip. Set the
   processing first. Open Cutdown Controls and Analyze.
2. Confirm only Controls appears and, after rendering returns to the original
   project, it displays the completed review. If Final Cut does not restore it,
   select the original clip and reopen its Cutdown Controls.
3. With eligible pauses selected and Show Cut Preview enabled, confirm green
   START and orange END dotted/dashed lines. Open a nonmodal effect editor or
   scroll/collapse the Inspector; uncovered lines should remain visible.
4. Close/reopen Controls on the original clip. Confirm the same cut selections,
   submitted settings and preview state return. Controls on a different clip
   must not adopt this review.
5. Apply explicitly and inspect the separate result. Confirm original source
   references and editable gate/limiter effects, order, bypass and settings.
   Treat only the final verification report as a verified import. If Controls
   disappears during Apply, return to the original clip's Controls for status.
   Verify Existing Result can reopen a saved result after a helper restart.
6. Change the processing after a fresh analysis. Apply must reject that stale
   review; Analyze again to measure the new processed output.

Current source fixes do not establish visible preview, host reconnection,
automatic cuts or third-party DSP behavior. Those remain live checks.


## Offline evidence

- `build/SingleWindowEffects/swift-full-access.log`: 340 passing Swift tests
  (263 Mac and 77 Core). `swift-full.log` records the sandbox's AVFoundation
  decoder failures before retrying with macOS media-service access.
- `build/SingleWindowEffects/factory.log`: thirteen independent Controls
  scenarios and the shared protocol state contract passed.
- `build/SingleWindowEffects/audio.log`: 60 exact passthrough render cases plus
  settings/state/persistence checks passed.
- `build/SingleWindowEffects/swift-final-focused.log`: follow-up coverage after
  preventing reconnect during automatic controller-settings writes.
- Candidate build logs: `helper-stage.log` and `plugin-stage.log` in that folder.

Install both products together; the registered bundles have not been replaced.
No live Final Cut operation or permission change was performed in this update.
