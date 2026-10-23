# Preview tracking and numbered review

The October 22 update keeps Controls inside Final Cut. The plug-in requests a compact 580 × 220 point view before analysis, then a wider 680 point view with 180–304 points reserved for review rows. Final Cut owns the enclosing window and may choose how to honor these preferred sizes. Its bottom product label and outer clip title remain host UI; removing them would require a different window architecture, which the user declined.

Review rows now display their cut number before the time range. The timeline's START and END markers use that same full-review number. Excluding an earlier cut does not renumber later markers.

## Tracking changes

- Geometry sampling targets 30 Hz without notifications and up to 60 Hz while activity or changing geometry is detected. The previous intervals were 0.15 seconds and 1/15 second. Activity can shorten the next idle wait, while a single in-flight request prevents queued, stale geometry updates.
- Clip position and size are read together in one Accessibility request. Periodic identity checks first validate the previously verified clip handle; a failed identity check falls back to the full timeline search. Project, clip name, duration, and both timeline edges are still checked.
- Inspector controls are read in batched snapshots and traversal resumes in smaller slices with a 12 ms request budget, instead of the previous 100–350 ms budgets. Selection/setup and final stability checks have a separate 50 ms allowance; a control snapshot may finish after its slice expires so slow controls cannot permanently block effect-removal detection. Individual macOS Accessibility calls can still take longer. A cached Inspector handle avoids repeating its discovery search for each complete scan.
- Window-order maintenance is sampled separately at 10 Hz. Geometry updates no longer enumerate every on-screen window between the slower window-validation snapshots. Vector layers remain retained, and implicit layer animation remains disabled so lines track measured positions directly.

Project/viewport validation, modal checks, effect-removal detection, transient-read tolerance, selection acknowledgments, and Apply authorization remain in place.

## Verification

332 Swift tests executed with one skipped and no failures. The 23 Controls scenarios include compact/expanded sizing and stable row numbering. Regression coverage checks that notification bursts cannot exceed the requested cadence, periodic reads continue without notifications, late responses cannot revive a dismissed preview, and excluding cut 1 leaves cut 2's START/END labels numbered 2.

Native preview checks cover two cuts and a scrolling list of 16 cuts in dark and light appearance. These preview windows are developer fixtures, not Final Cut's host window. The Release app and ZIP were built and the installed copy was replaced after both apps closed. Its files match the app and ZIP, signatures and extension sandbox pass, the extension is registered, Apple’s Audio Unit validation passes, and the copied app reports `ready` after its existing control-access grant was refreshed. Actual tracking frequency, visible scroll latency, and Final Cut’s response to the larger preferred size remain live measurements; the timer targets are not measured frame-rate claims.

For a live check, use a disposable project only inside the workspace's `Cutdown Integration.fcpbundle`. Analyze, then scroll horizontally, zoom, scrub, and select/deselect cuts. Check number matching and stationary alignment after movement stops. Preserve integration evidence. This check does not establish successful automatic timeline editing.
