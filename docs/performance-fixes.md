# September 17 performance fixes

> Historical development record. Build paths, installed/staged app state, and test totals below describe the original run. Generated logs and Final Cut libraries are not included in Git. Use the [README](../README.md) for verification of this repository copy and [setup](setup.md) for a fresh installation.

The three requested optimizations are implemented. They reduce repeated CPU work, memory allocation, and copying. No measured SSD-write reduction or end-to-end speedup is claimed; retained audio exports, recovery receipts, and build-cache cleanup were outside this change.

| Area | Change | Preserved behavior |
|---|---|---|
| Unchanged status polls | The coordinator validates/serializes once per revision and retains that bounded wire payload with its job. The plug-in recognizes an identical validated message before JSON decoding; equal revisions update the heartbeat without rebuilding rows. | Helper-window delivery remains independent, status retries remain available, pending selection needs a newer acknowledgment, and an old review cannot acknowledge Apply or postpone its timeout. |
| Rendered audio | Contiguous, aligned Float32 blocks are borrowed only during synchronous measurement. Segmented or unaligned blocks copy into reusable scratch storage without zero-initialization. Channel sum accumulators reset in place. | Exact sample counts, per-channel RMS, partial windows, finite-sample checks, duration/timestamp checks, cancellation, and detector settings remain intact. Decoder memory stays alive during measurement. |
| Import verification | Each expected/actual snapshot runs semantic parsing and controller-settings extraction once. The comparison, recovery plan, and occurrence selection share those results. A second host capture after restoration gets a new snapshot, while the immutable expected snapshot is reused within that attempt. Render verification also reads its delivered XML bytes once. | Every attempt checks the saved output, host identity, timeline/media/effects, and settings. Recovery still requires a fresh host capture; snapshots are not cached across attempts or project edits. |

Validation:

- **333 Swift tests passed:** 256 Mac and 77 Core in `build/PerformanceFixes/full-swift.log`.
- The Controls/Factory harness passed in `build/PerformanceFixes/factory.log`, including unchanged heartbeats, pending selection, Apply acknowledgment, replay prevention, and timeout behavior.
- New PCM regressions verify borrowed addresses, aligned reusable fallback storage for segmented/unaligned blocks, invalid/nonfinite sample rejection, and six-channel RMS against an independent PCM reference at 44.1 and 48 kHz, including partial windows.
- New recovery coverage changes host identity or source media after settings restoration and requires the fresh verification to reject it. Existing retry, restart, interruption, tamper, and missing-settings regressions also pass.
- The initial sandboxed focused run could not start AVFoundation for five audio tests (`focused-swift.log`). The successful full run used normal macOS media-service access. No Final Cut UI was operated.

Matching helper and plug-in candidates are staged at `build/Candidate/Cutdown.app` and `build/Candidate/AudioPlugin/CutdownAudio.app`; staging/signature logs are `helper-stage.log` and `plugin-stage.log` in `build/PerformanceFixes`. Registered apps and permissions were not changed.

Use the installation steps and combined live sequence in [the audit check guide](audit-fixes.md). During that sequence, leave a completed review open for at least 30 seconds, confirm it stays connected, change an inclusion choice, and confirm Apply still waits for acknowledgment. Check both direct-source and processed-render analysis, and verify the existing result after settings recovery. All live checks remain with the user, in disposable projects within **Cutdown Integration.fcpbundle**. Automated success does not establish native cuts or host settings persistence.
