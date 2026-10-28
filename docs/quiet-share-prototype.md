# Quiet Share prototype

Use this prototype through the **Silent Snip Audio effect inside Final Cut Pro**. The existing Controls window provides Analyze, review, and Apply. There is no separate test window or Dock application UI.

The containing `Silent Snip.app` registers the Audio Unit and runs the existing background integration. The prototype is packaged as `dist/Silent Snip Prototype.zip`; the regular ZIP remains separate.

## Try it

1. Close Final Cut and quit Silent Snip before replacing the installed copy. Keep the rollback ZIP. Install the prototype's `Silent Snip.app` at the same Applications path, using the existing registration and permissions setup.
2. Open the workspace's existing `Cutdown Integration.fcpbundle`. This development prototype refuses to automate other libraries; close other libraries for this check.
3. Use a disposable project referencing `build/QuietSharePrototype/Generated-quiet-share.wav` in place. The existing `Silent Snip Quiet Prototype Plain` project is suitable. Add the Silent Snip Audio effect if it is absent, then open its Controls.
4. Click **Analyze** and keep Final Cut in front. Expect a progress cover, then the existing cut review. **Show Final Cut** reveals the host for the remainder of the operation. **Cancel** uses the existing cancellation path.

An Audio Unit rebuild may require refreshing Silent Snip's existing control-access entry in System Settings. Keep the Share destination pointing to the installed containing app.

For processed-audio testing, use a separate disposable project with Noise Gate and Limiter before Silent Snip. Keep media referenced in place. Test Apply only in disposable projects in this same library, checking both Remove Silence and one-second gaps. Original media is unchanged; recovery XML remains in the existing Results folders.

## What this prototype establishes

It connects the experimental cover to existing effect actions and retains the current analysis, Share validation, review, and recovery code. Unproven menu paths and browser clicks reveal Final Cut **before** the legacy input route. Once revealed, that operation cannot recreate its cover. It does not assign shortcuts or change Share defaults.

This is a manual-test build. Current native evidence and remaining checks are recorded in [the feasibility report](quiet-share-feasibility.md). Packaging and automated tests do not establish a successful covered Noise Gate/Limiter pass or automatic Apply.

Each operation records `Quiet-Presentation.json` alongside its existing temporary job evidence under `~/Library/Application Support/Silent Snip/Temporary/<request UUID>/`. Existing recovery XML and source media are preserved.

Build it with `Scripts/build-quiet-share-prototype.sh`. The script stages, signs, and packages the Audio Unit and background integration; it does not install or register them. Normal Release builds exclude the prototype code.
