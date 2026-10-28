# Visible Share plugin prototype

Use this prototype through the **Silent Snip Audio effect inside Final Cut Pro**. The existing Controls window provides Analyze, review, and Apply. There is no separate test window or Dock application UI.

The user removed the covering-window requirement on October 28, 2026. The prototype now leaves Final Cut's native Share panels and project transitions visible. It creates no cover or separate progress window. Final Cut must still remain in front during host automation. The file and build-script names retain the earlier prototype name.

The containing `Silent Snip.app` registers the Audio Unit and runs the existing background integration. The prototype is packaged as `dist/Silent Snip Prototype.zip`; the regular ZIP remains separate.

## Try it

1. Close Final Cut and quit Silent Snip before replacing the installed copy. Keep the rollback ZIP. Install the prototype's `Silent Snip.app` at the same Applications path, using the existing registration and permissions setup.
2. Open the workspace's existing `Cutdown Integration.fcpbundle`. This development prototype refuses to automate other libraries; close other libraries for this check.
3. Use a disposable project referencing `build/QuietSharePrototype/Generated-quiet-share.wav` in place. The existing `Silent Snip Quiet Prototype Plain` project is suitable. Add the Silent Snip Audio effect if it is absent, then open its Controls.
4. Click **Analyze** and keep Final Cut in front. Silent Snip handles Share automatically using Final Cut's visible interface, then returns to the existing cut review. Progress and Cancel use Controls when that host view is available.

An Audio Unit rebuild may require refreshing Silent Snip's existing control-access entry in System Settings. Keep the Share destination pointing to the installed containing app.

For processed-audio testing, use a separate disposable project with Noise Gate and Limiter before Silent Snip. Keep media referenced in place. Test Apply only in disposable projects in this same library, checking both Remove Silence and one-second gaps. Original media is unchanged; recovery XML remains in the existing Results folders.

## What this prototype establishes

It retains the current analysis, Share validation, review, and recovery code. Menu actions use verified shortcuts, supported Accessibility actions, or a once-only guarded Return on an exact selected command. Legacy visible input remains available when needed. It does not assign shortcuts or change Share defaults. Processed audio uses the visible settings panel to verify Audio Only, WAV, and All Dialogue before accepting a render.

Current native evidence and remaining checks are recorded in [the feasibility report](quiet-share-feasibility.md). Packaging and automated tests do not establish a fresh automatic Apply pass.

Each operation retains the historical `Quiet-Presentation.json` diagnostic filename alongside its existing temporary job evidence under `~/Library/Application Support/Silent Snip/Temporary/<request UUID>/`. New reports identify `visible-plugin-prototype` and zero cover transitions. Existing recovery XML and source media are preserved.

Build it with `Scripts/build-quiet-share-prototype.sh`. The script stages, signs, and packages the Audio Unit and background integration; it does not install or register them. Normal Release builds exclude the development diagnostics. Older isolated probe configurations requesting `covered: true` fail without dispatching host input.
