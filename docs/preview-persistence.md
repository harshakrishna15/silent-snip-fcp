# Preview persistence and effect removal

> Historical development record. Build paths, installed/staged app state, and test totals below describe the original run. Generated logs and Final Cut libraries are not included in Git. Use the [README](../README.md) for verification of this repository copy and [setup](setup.md) for a fresh installation.

September 18, 2026. This update changes the helper only.

The preview previously hid on every accessibility error and after half a
second without a sample. It also reordered its window every half-second, even
when it was already above the Final Cut project. Brief host layout updates
could therefore repeatedly hide and show otherwise unchanged lines.

Transient read failures now retain the last verified drawing for at most 1.5
seconds. A confirmed different project, modal dialog, offscreen clip or hidden
project window still hides it immediately. The overlay only orders itself when
it is not visible or WindowServer reports it behind the project; it no longer
periodically raises itself. Existing vector layers remain reusable.

Effect removal detection is restored with its own bounded Inspector-read
budget after geometry collection. It checks the exact analyzed timeline
occurrence is the sole selection before and after reading an unchanged list of
Inspector children. Missing data, collapsed sections, and partial/offscreen
effect lists are unknown, not evidence of deletion. Confirmed absence requires
either visible native section headers bounding the effect list or previously
observed visible headers on both sides of Cutdown with unchanged scrolling.
Two qualifying samples at least 0.35 seconds apart dismiss the preview and stop
its observer and timer. The same old review cannot revive it after Undo or
re-adding the effect; a new Analyze creates a fresh session.

Removal detection depends on Final Cut exposing those Inspector boundaries.
If the Inspector is hidden, inaccessible, or the user switches selection before
absence can be confirmed, the helper cannot yet establish removal. The current
live check must cover the user's actual effect stack and removal interaction.

33 focused Swift checks pass (11 preview and 22 Final Cut capture/policy
checks). Coverage includes transient read gaps, native window ordering,
retained drawing pixels/layers, last-effect deletion, deletion between gate and
limiter headers, incomplete/hidden/scrolled Inspector reads, collapsed Effects,
and stale-result suppression. Evidence: `build/PreviewPersistence/swift.log`.
The signed helper candidate is `build/Candidate/Cutdown.app`; build evidence is
`build/PreviewPersistence/helper-stage.log`. The installed helper was not replaced.

No live analysis, effect deletion or Apply test was performed. A read-only
inspection found Cutdown Audio listed in Final Cut's Effects browser again.
All live tests remain with the user, using disposable projects in the existing
workspace `Cutdown Integration.fcpbundle` and generated media referenced in
place without copying, optimized media or proxies.

With Final Cut and Cutdown closed, install the helper and refresh registration:

```sh
# Run from the repository root.
pkill -x Cutdown
Scripts/build-helper.sh && Scripts/register-local.sh
```

Analyze, then click around the timeline, other clips, Controls and effect
windows; boundaries should persist on the analyzed clip while its geometry is
available. Scroll/zoom and confirm their positions follow the clip. Delete
Cutdown in the Audio Inspector and confirm the lines disappear and stay gone
after clicking elsewhere or undoing removal. Repeat with Noise Gate and Limiter
above/below Cutdown. Reanalyze after restoring Cutdown. Modal dialogs/project
switches and preview cancellation should still hide the overlay.
