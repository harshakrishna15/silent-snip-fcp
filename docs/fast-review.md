# Faster XML exports and settings previews

These changes target Final Cut handoffs and repeated settings adjustments. They
do not change the silence detector or skip the final Apply and recovery checks.
Live Analyze and settings tuning passed on the small fixture below. Automatic
Apply and import recovery still require their own complete live editing pass.

## XML-only completion

Final Cut's real Open Document completion event remains supported. For XML-only
exports, Silent Snip can also accept a complete document after confirming that
its read handle is the file's only open reference. It parses an immutable copy,
checks file identity before and after reading, and verifies that the path still
names that same unchanged file. Only the exact pending Share job and permitted
XML filename qualify. Symlinks, ambiguous deliveries, incomplete documents,
changed files, and an open producer cannot use the fast path.

The check uses XNU's `FSIOC_FD_ONLY_OPEN_ONCE` through `ffsctl`. It takes no file
lock and changes no permissions. The SDK omits the constant; unsupported kernels,
filesystems, or permissions keep the existing three-second stability fallback.
Files larger than 128 MiB also use that fallback. Audio renders still require
Final Cut's completion event. Original exports and the accepted XML snapshot are
retained as evidence.

If Final Cut later activates Silent Snip to deliver the real completion event,
an active operation returns only Silent Snip's own activation to Final Cut. It
does not reclaim focus from a different app the user has switched to. Duplicate,
changed, unrelated, and restored historical deliveries cannot repeat this action.

References: Apple's [Share export protocol](https://developer.apple.com/library/archive/documentation/FinalCutProX/Conceptual/FinalCutProXWorkflowsGuide/Exporting/Exporting.html),
the [XNU control definition](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/fsctl.h),
and its [implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_syscalls.c).

## Immediate settings previews

After Analyze, the current review retains the measured audio windows. Detection
and output edits coalesce for 180 ms, then recalculate cuts from those measurements
without decoding or rendering audio again. Provisional rows can be reviewed while
Apply, inclusion changes, and navigation remain disabled.

While a field has an active text editor, verification waits so Final Cut's export
flow cannot take focus while the user types. Press Return or finish editing to
start a fresh XML, baseline, selected-clip, controller-settings, source-media, and
edit-representability check. The latest successful check enables Apply. Rapid
edits replace pending work; cancelled or failed checks and late responses cannot
enable Apply for an older edit. Partial invalid text stays local, with Apply
disabled. A connection timeout requires Analyze to reconnect.

This path applies only to the current retained review. Changes to timeline,
source media, or processing require Analyze again. It does not expand eligibility
for the separate repeat-analysis cache, whose conservative effects checks remain.
The final Apply still exports and verifies fresh state and saves recovery XML
before importing anything. No source or recovery file is deleted by this feature.

## Evidence and limits

Live tests use only the generated ten-second **Silent Snip Fast Review 12 —
Effects** project in the workspace-root **Cutdown Integration.fcpbundle**, with
Noise Gate, Limiter, Silent Snip, and source audio referenced in place.

| Same generated effects clip | Build 11 baseline | Installed build 15 |
| --- | ---: | ---: |
| Preview ready | 17.154 s | 14.674 s |
| Analyze, including cleanup | 18.609 s | 16.449 s |

This is one baseline and one final-build run on the same project and effects,
not a benchmark average. Initial analysis was about 2.16 seconds faster in this
comparison. The effects render still takes about five seconds. Both XML-only
captures used closed-file snapshots, and temporary-project cleanup completed.

Two consecutive Minimum Silence edits (0.5 → 1.5 → 0.5 seconds) updated the same
retained review without another Analyze. The provisional replies arrived 24–38 ms
after the local commands, in addition to the 180 ms edit debounce. This measures
the control channel, not display frame latency. The field retained keyboard focus,
and no host export started until Return. Fresh checks took 4.110 and 4.268 seconds;
native Controls enabled Apply only afterward. The first edit retained the same
1.800-second cut boundary, and restoring 0.5 seconds restored both original cuts
(1.300 and 1.800 seconds).

Switching to one-second gaps and back also passed, with checks taking 2.772 and
3.191 seconds. Controls showed the expected 8.900-second gap output, then the
6.900-second removal output. All four checks reused the retained measurements
and performed no render. Six XML captures used the closed-file fast path; none
needed the stability fallback. Cancel cleared the review and left Analyze
available with Apply disabled. No Apply button was clicked.

Live testing also covered duplicate editor-end events, consistent Float decimal
conversion between Analyze and tuning, and repeated tuning after Share. Native
ownership now checks the focused Controls window and its exact view ID, original
clip and project, rather than relying on Final Cut's potentially stale window
list. The fresh Apply gesture check remains.

**Remaining host UI issue:** Final Cut can leave Controls behind its main window
after Share. Click the selected clip's **Show effect editor** button to restore
it; a hidden editor may require toggling the button twice. This limits the smoothness
of the verification handoff even though cut recalculation is immediate.

Build 15 passed 381 Swift tests (one skipped), 29 native Controls scenarios plus
the shared protocol contract, 60 audio render/persistence cases, 53 build-script
tests, and Audio Unit validation. The installed app matches the published bundle
and ZIP; signatures and extension sandbox were verified. Saved files, original
media, and last-used settings retained their hashes. The test library's metadata
changed during the disposable tests; no other library was used.

Local reports are preserved in `build/FastReviewEvidence`. Offline coverage
includes open-writer, mutation, immutable-snapshot and fallback cases; settings
ordering, typing focus, stale replies, cancellation, failure, and Apply gating.
Builds and analysis timings do not establish successful automatic timeline cuts.
