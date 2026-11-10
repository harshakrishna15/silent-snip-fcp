# Silent Snip feature queue

These nine requests are listed in priority order. A checked item has an implementation and automated regression coverage. Live Final Cut checks are recorded separately below.

1. [ ] **Improve timeline overlay responsiveness.** Keep the current drawing style and make the cut preview follow scroll and zoom more closely. Schedule geometry reads as soon as they are due, with one read in flight. Separate window-order checks from redraws and recheck immediately when the overlay appears or is covered. Measure tracking latency before and after in a disposable project in `Cutdown Integration.fcpbundle`.
2. [x] **Preserve review choices when settings change.** Keep inclusion decisions for unchanged ranges in the same analyzed clip. If a kept pause splits or merges, leave the affected cuts unchecked and flag them for review.
3. [x] **Audition cuts before Apply.** Add **Play Original** and **Play Proposed Cut** to the active row. Start with plain source clips. Play both versions at the same level, using the exact proposed cut boundaries and including a little audio on either side of the join.
4. [x] **Add keyboard review and jump-to-cut.** Jump to the timeline directly from a cut row. When the list has focus, use the arrow keys to move between rows, Space to toggle inclusion, and Return to jump to the cut. Keep focus and scroll position steady as the worker acknowledges each change.
5. [x] **Shorten long pauses to a target length.** Let editors choose how much original room tone to retain. For example, reduce a two-second pause to roughly 400 ms by trimming the middle and keep pauses that are already shorter than the target.
6. [x] **Adjust individual cut boundaries.** Add start and end steppers and a reset action. Begin by letting editors narrow a proposed removal on the valid cut grid so they can preserve a breath or word ending without changing padding for the whole clip.
7. [x] **Put the selected clip in the top bar.** Show the verified name of the currently selected clip in the extension's top bar in place of the project name and live playhead readout.
8. [x] **Keep or cut a group of pauses.** Shift-select consecutive review rows, then use **Keep Selected** or **Cut Selected** to change inclusion for just those cuts.
9. [x] **Analyze just part of a clip.** Use a selected Final Cut Pro timeline range within one supported clip. Show the analyzed time span in Cut Review and constrain proposed and applied cuts to that range.

## Regression coverage

| Request | Commit | Coverage |
| --- | --- | --- |
| Overlay | `854ebbe` | Read deadlines, at most one read in flight, and independent window-order maintenance. |
| Review choices | `bef8a4f` | Exact matches, split and merged pauses, and refresh from retained measurements. |
| Audition | `9cf9a02` | Exact source spans in the AVFoundation composition and gesture-bound playback. |
| Keyboard review | `bb7954b` | Active row, native timeline navigation, focus and scroll preservation. |
| Target pause | `c77c51a` | Speech padding, grid rounding, shorter pauses, and settings round trip. |
| Boundaries | `7354d92` | Edit grid, reset, refreshed proposals, and applied cut bounds. |
| Clip title | `6fe119d` | Verified selection and stale-reply rejection across project changes. |
| Group selection | `edad7c3` | Contiguous selection, atomic updates, and acknowledgement. |
| Selected range | `76f140f`, `eb14848` | Native range parsing, scoped source and rendered audio, and edited XML. |

## Final Cut verification

The 24-second **Disposable Queue Overlay** project in the workspace's **Cutdown Integration.fcpbundle** references generated audio in place. The baseline produced eight cuts and a visible overlay after the Share action was repointed to the workspace worker. Median time from input dispatch to the first changed geometry written by the overlay was 34.8 ms for 12 zoom actions and 163.9 ms for 10 horizontal scroll actions after a warm-up pair. The measurement includes input dispatch and the diagnostic write. The candidate comparison and live Analyze → Apply check are pending.
