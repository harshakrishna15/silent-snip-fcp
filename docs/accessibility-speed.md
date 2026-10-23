# Faster Final Cut control lookup

Build 11 reduces repeated host lookups during capture, focus checks, export readiness, and import verification. It preserves the analysis, rendering, editing, recovery, and saved-data behavior.

## What changed

Each Final Cut session retains the route from its pinned project window to the project-name control and timeline. Reuse checks every parent/child edge against fresh Accessibility responses and reads the control's identity and title again. It does not cache project names, selection, enabled state, dialog state, or permission decisions. A readable but detached old control cannot pass route validation.

If a parent or control is replaced, disappears, becomes unreadable, or no longer matches, the route is discarded and the existing bounded search runs again. Searches keep their depth, node, cancellation, time, container, and Inspector-exclusion limits. Timeline lookup is refreshed before reading selection/ranges or checking focus, so a reconstructed timeline can recover through the same discovery path.

Attribute reads used by searches, timeline selection snapshots, and dialog metadata are batched through Apple's Accessibility API. Hosts that do not provide a usable batch retain individual reads as a compatibility fallback. Missing values remain missing; stale attribute values are never substituted.

Project-name comparisons, exact clip/selection checks, keyboard-focus checks, modal-dialog detection, fresh XML/media verification before Apply, and recovery creation remain in place. Menu actions are not cached or replayed. The polling intervals, effects-cache eligibility, detector, and rendering workflow are unchanged.

## Timing

`~/Library/Application Support/Silent Snip/Temporary/<request UUID>/Analysis-Timing.json` keeps the existing end-to-end stages and adds:

- `details`: session discovery, activation, selection before focus, focus before export, selected-clip snapshot, Inspector check, XML exchange, parsing, final project check, focus after export, and final selection snapshot.
- `counters`: project-control full searches, validated cache hits, invalidations, visited search nodes, and route validation attempts.

Details are subdivisions of capture and overlap its top-level duration; do not add them to the stage totals. Timing is recorded for reached steps even when an operation fails. The counters cover project-control lookup within the initial capture session, not every host call made by the app. Reports include no media contents or additional file paths.

## Verification

Deterministic host-tree tests cover a changed title on the same control, readable detached controls, rebuilt parent paths, controls moved under an Inspector, missing values, cancellation, search limits/cycles, unsupported batch reads, per-attribute errors, and failed/async timing. In a 203-node synthetic tree, discovery used 405 read operations and validated reuse used 5. This demonstrates fewer lookup calls; it is not a measurement of native Final Cut latency.

The complete suite passed 366 Swift tests (one skipped, zero failures) and 53 build-script tests. Generated evidence and logs are kept under `build/AccessibilitySpeedEvidence` and `build/accessibility-speed-*.log`, excluded from Git.

Build 11 replaced the stopped copy at `~/Applications/Silent Snip.app`. The previous build is preserved in a backup ZIP. The installed app matches the published bundle and `dist/Silent Snip.zip`; signatures, the extension sandbox, registration, and Apple's Audio Unit validation passed. After refreshing its existing control-access grant, the app launched and reported `ready`. Hashes of all 156 checked saved/library and referenced-media files remained unchanged after installation and startup. No Final Cut project was edited for these checks.

## Live comparison

Only use disposable projects in the existing workspace-root `Cutdown Integration.fcpbundle`, with generated media referenced in place. Preserve media, library contents, saved results, and recovery evidence.

1. Analyze the same selected clip repeatedly with unchanged processing. Compare the `capture` duration and its `details` against prior `Analysis-Timing.json` files. Compare medians across several runs with the same Final Cut layout and cache status.
2. Check that repeated project checks increment `capture.projectLookup.cacheHits` while full-search counts stay low. A rebuilt layout may legitimately trigger additional discovery.
3. Close/reopen Controls, adjust the workspace layout, and Analyze again. Check that selection, project identity, and modal-dialog protection still behave correctly; unrelated dialogs must block input.
4. Test a processing/render case separately, retaining source and post-render project verification. Review previews and selections before any Apply test. Automatic editing requires its own verified pass.

Live end-to-end latency, layout changes inside Final Cut, and automatic Apply remain unverified for this revision. No speedup in seconds or percentage is claimed from the offline lookup fixture.
