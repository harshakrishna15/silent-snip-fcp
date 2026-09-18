# Missing preview and misleading helper timeout

> Historical development record. Build paths, installed/staged app state, and test totals below describe the original run. Generated logs and Final Cut libraries are not included in Git. Use the [README](../README.md) for verification of this repository copy and [setup](setup.md) for a fresh installation.

September 17, 2026. Live Final Cut testing remains with the user.

Registration follow-up: candidate cleanup now continues if an old registration
cannot be removed and verifies discovery of the installed extension before
reporting success. The user reported Cutdown missing after installation; see
the current [registration recovery status](overhaul-progress.md).

The reported Controls screenshot had no review rows and said the helper was not
responding. Read-only diagnostics found a running helper and a failed analysis:
the isolated render was rejected before cut detection. The saved Noise Gate and
Limiter render expanded the generated component role `dialogue` into
`dialogue.dialogue-1`. Its gain, gate preset and limiter settings matched.

Isolation now emits the host's explicit default component subrole. The original
clip's roles remain unchanged. Comparing newly generated isolation against that
same saved host export now passes; the old isolation fails. Strict comparison
still rejects changed processing, media, timing, or roles. Effected clips still
use Final Cut's full render without falling back to unprocessed audio.

Controls now grants a fresh response interval after returning from a hidden
view, polls in common run-loop modes, and preserves terminal errors instead of
replacing them with an idle heartbeat timeout. After a timeout it continues
read-only status polling so a delayed failure can explain the missing preview.
Apply and pending edit commands are cleared; a stale review cannot restore Apply.
New Analyze and explicit verification retry receive fresh connection deadlines.

Read-only process inspection also found Final Cut running the standard staged
extension. Xcode automatically registers its built app. The build now refuses
to overwrite a loaded candidate, including with `--stage`. Registration removes
competing standard/diagnostic candidate registrations before selecting the
installed app, with Final Cut stopped. Bundles remain on disk.

## Evidence

Logs are in `build/PreviewConnection/`:

- `saved-render-replay.log`: old isolation fails and corrected isolation passes
  against the actual saved render. This is an offline XML replay.
- `swift-media-access.log`: 42 focused Swift checks pass for isolation, effects,
  analysis routing, audio analysis and preview geometry. The separate
  `swift-focused.log` run includes nine passing transport checks (21 total,
  overlapping the isolation/effects checks).
- `factory.log`: 15 independent Controls scenarios plus the shared state
  contract, including hidden-view deadlines, late failures and retry timeouts.
- `build-scripts.log`: 18 simulated build/registration checks pass.
- `helper-stage.log` and `plugin-build.log`: successful builds and signed bundle
  verification. The helper is at `build/Candidate/Cutdown.app`; the diagnostic
  audio build is at `build/PreviewConnection/Candidate/CutdownAudio.app` because
  Final Cut was using the standard candidate. Xcode registered that diagnostic
  build; the next stopped-host registration removes the competing registration.

The installed bundles and loaded standard candidate were not replaced. No new
Final Cut analysis or Apply was run. An earlier saved analysis also failed an
active-window/project check; this XML fix does not establish that every host
transition succeeds. Visible dotted lines, reconnection and automatic cuts on
the corrected builds still require the user's live check.

## Install and retest

Quit Final Cut Pro, then run:

```sh
# Run from the repository root.
pkill -x Cutdown
Scripts/build-helper.sh && Scripts/build-audio-plugin.sh && Scripts/register-local.sh
```

Open the existing workspace **Cutdown Integration.fcpbundle** and use a small
disposable project referencing generated media in place, with no copying,
optimized media or proxies. Set Noise Gate and Limiter, open Cutdown Controls,
then Analyze. Once analysis completes, check that the cut list appears and
**Show Cut Preview** is enabled and checked; dotted boundaries require detected,
included cuts. Follow the [single-window live check](single-window-effects.md)
for preview, effect preservation and Apply verification.
