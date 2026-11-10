# Silent Snip feature queue

These nine requests are listed in priority order. A checked item has an implementation and automated regression coverage. Live Final Cut checks are recorded separately below.

1. [x] **Improve timeline overlay responsiveness.** Keep the current drawing style and make the cut preview follow scroll and zoom more closely. Schedule geometry reads as soon as they are due, with one read in flight. Separate window-order checks from redraws and recheck immediately when the overlay appears or is covered. Measure tracking latency before and after in a disposable project in `Cutdown Integration.fcpbundle`.
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
| Overlay | `854ebbe`, `e98cd01`, `64a80e0`, `df81f21` | Read deadlines, at most one geometry read in flight, and immediate order repair that supersedes a pending periodic snapshot. |
| Review choices | `bef8a4f` | Exact matches, split and merged pauses, and refresh from retained measurements. |
| Audition | `9cf9a02` | Exact source spans in the AVFoundation composition and gesture-bound playback. |
| Keyboard review | `bb7954b`, `098ec81` | Active row, native timeline navigation, focus and scroll preservation, and recovery when the host briefly omits the project after navigation. |
| Target pause | `c77c51a` | Speech padding, grid rounding, shorter pauses, and settings round trip. |
| Boundaries | `7354d92` | Edit grid, reset, refreshed proposals, and applied cut bounds. |
| Clip title | `6fe119d`, `098ec81` | Verified selection in the project workspace when the extension is the main window, and stale-reply rejection across project changes. |
| Group selection | `edad7c3` | Contiguous selection, atomic updates, and acknowledgement. |
| Selected range | `76f140f`, `eb14848` | Native range parsing, scoped source and rendered audio, and edited XML. |

## Final Cut verification

The 24-second **Disposable Queue Overlay** project in the workspace's **Cutdown Integration.fcpbundle** references generated audio in place. The back-to-back baseline and final runs used the same project, eight-cut review, and input sequence. Timing starts at input dispatch and ends at the first changed geometry written by the worker, before display compositing. The scrolling cadence measures the gap between consecutive geometry updates while the clip position changes.

| Median | Baseline rerun | Final build |
| --- | ---: | ---: |
| Menu zoom, 12 actions | 60.2 ms | 46.7 ms |
| Command–Minus zoom, 12 actions | 63.9 ms | 48.8 ms |
| Horizontal scroll, 10 actions after one warm-up pair | 199.0 ms | 172.7 ms |
| Update gap during horizontal scrolling | 30.5 ms | 17.9 ms |

The first baseline run measured 34.8 ms for menu zoom and 163.9 ms for scroll. Its median scrolling update gap was 31.8 ms. The difference between baseline runs limits the interpretation of absolute dispatch-to-update latency. The full traces and timing comparison are under `build/FeatureQueue/`.

In Cut Review, a one-frame boundary step moved the first cut start from `00:00:02:09` to `00:00:02:10`. Keyboard group selection kept two pauses. After changing Target Pause to 0.4 seconds, those two rows stayed unchecked with a **Review** flag and the other six cuts totaled 2.400 seconds. Return moved the playhead to `00:00:05:12` through the timeline SDK with zero Share exchanges. On the final build, **Go to Cut** reached `00:00:05:09` and preserved the review through a focus change. The title updated on selection and cleared on deselection before a fresh Analyze. Both audition controls ran on plain source audio, with exact source spans and natural playback rate covered by the AVFoundation composition test.

Native range Analyze → Apply passed for `00:00:03:00`–`00:00:10:01` on both the plain clip and a second disposable project with Limiter. Each 22.800-second re-export removed only source spans `5.300–5.900 s` and `8.300–8.900 s` and kept the original media references. Final Cut verified the cleaned copies and the unchanged 24-second originals. The processed case rendered through Final Cut and transferred effects in one operation. Limiter remained enabled in the Inspector on each of the three retained segments. Evidence is saved under `build/FeatureQueue/`.
