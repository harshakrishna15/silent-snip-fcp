# Analysis speed and cache validation

> Historical development record. Build paths, installed/staged app state, and test totals below describe the original run. Generated logs and Final Cut libraries are not included in Git. Use the [README](../README.md) for verification of this repository copy and [setup](setup.md) for a fresh installation.

September 18, 2026. Implemented and checked offline; the user is performing live Final Cut testing.

## Behavior

Analyze captures fresh project XML and hashes source contents before checking a single process-local cache entry. A matching entry reuses audio measurements to recalculate threshold, minimum silence, and before/after padding. It creates a new review plan for the new request; it never reuses an old Apply authorization or cut selection.

The key includes the project fingerprint and identity, selected occurrence, measurement window size, host process and launch time, and source content snapshot. Cutdown controller settings are excluded from the rendering fingerprint. Processing order, bypass, serialized settings, trim, timing, volume, fades, automation, and channel changes invalidate reuse. Source files changed without changing their size or timestamp also invalidate it. Apply retains its separate fresh-project and media checks.

Processed-audio reuse is deliberately narrow. Supported built-in volume/panning/channel/fade data and Apple's Noise Gate with serialized `effectState` can qualify. Preset-only state, missing effect state, partial native parameter lists, other effects, nested mixes, extra audio references, and retiming cannot qualify. These use the existing full Final Cut render workflow, which retains the complete supported effect chain; there is no source-audio fallback.

The saved Noise Gate/Limiter export inspected for this update contains a gate preset reference and a limiter with omitted settings. That combination always rerenders under this policy. A preset name does not establish that the preset contents are unchanged, and a partial parameter list does not establish complete state. Further effect types require evidence of complete serialized state before enabling their cache reuse.

An eligible cache retains at most one analysis, capped at 360,000 measurement windows, eight channels, and a 256 MiB rendered file. Rendered audio is copied into the owning job directory and content-verified before the Share-delivered file is cleaned up. Every reuse verifies that copy again. A mismatch, eviction, or normal helper shutdown removes only the owned cache copy. Source media is never deleted. There is no disk-cache restoration after helper restart; an abrupt termination can leave an unused job artifact.

After render, source, restored-project, and edit-representability checks pass, verified cut rows are published while temporary-project cleanup finishes. Apply, selection changes, and navigation remain disabled until review is ready. Cancel discards early results. Controls restoration can still delay visibility even though the result has been published.

## Timing evidence

Each run writes `Analysis-Timing.json` under `~/Library/Application Support/Cutdown/Temporary/<request UUID>/`. It records outcome, cache status, total seconds, time to verified preview, and stage durations. Stages distinguish capture, source validation, cache validation/recalculation, render preparation, rendering, render verification, returning to the original, measurement, detection, original-project verification, cache storage, cleanup, and Controls restoration. Failed and cancelled attempts also write reports; only reached stages appear.

The offline fixture is 300 seconds of stereo 48 kHz PCM. Three decoding/hash runs and thirty detector recalculations were measured per build configuration. Debug and Release produced identical 60 cut ranges, and both source and rendered-file decoding paths agreed.

| Stage | Debug median | Release median |
| --- | ---: | ---: |
| Source content hash | 33.63 ms | 32.37 ms |
| Rendered PCM decode and measure | 274.69 ms | 52.39 ms |
| Source PCM decode and measure | 282.92 ms | 43.55 ms |
| Recalculate retained measurements | 25.73 ms | 0.50 ms |

This benchmark excludes Final Cut exports, effect rendering, project transitions, cleanup, and the extra validation surrounding an actual cache hit. It is not a promise that Analyze finishes in these times. The remaining decoder CPU cost does not justify another implementation rewrite based on this fixture. Live stage reports are needed to identify the next host bottleneck.

Evidence is in `build/AnalysisSpeed/`: `Benchmark-Summary.json`, raw `benchmark-debug.json` and `benchmark-release.json`, full test logs, Controls/build-script logs, and candidate-build logs. The opt-in benchmark test takes `CUTDOWN_BENCHMARK_INPUT` and `CUTDOWN_BENCHMARK_OUTPUT`; otherwise it skips. Reuse `build/swift` for sequential Debug/Release runs.

Offline verification: 358 full Release Swift tests pass (281 Mac, 77 Core); eight focused cache/timing checks pass after the final policy adjustment; 16 independent Controls scenarios plus the shared-state contract pass; 22 build/registration tests pass. The earlier full Debug run passed 357 tests before the host-session/alias case was added.

## Install and test

Candidates are build artifacts; the installed bundles have not been replaced by this update. Xcode can discover audio candidates automatically. Quit Final Cut, then run from this workspace:

```sh
pkill -x Cutdown
Scripts/build-helper.sh --release && Scripts/build-audio-plugin.sh && Scripts/register-local.sh
```

For build-only validation, `Scripts/build-helper.sh --stage --release` leaves the installed helper alone. Its candidate identity does not receive the live Share route.

Use small disposable projects only in the existing workspace `Cutdown Integration.fcpbundle`, referencing generated source media in place without copied, optimized, or proxy media.

1. Analyze an unprocessed clip, change only Cutdown detection settings, then Analyze again. Check fresh rows and a cache hit in the timing report.
2. Change volume, trim, or other processing and Analyze again. Check that the cache misses and the displayed results match the changed audio.
3. Use the preset-only gate and limiter chain. Confirm every Analyze rerenders and includes the effects; caching must not silently substitute original audio.
4. Observe early rows during cleanup if Controls is visible. Apply must remain disabled until review is ready. Cancel must clear rows and prevent a late response from restoring them.
5. Check preview persistence, effect-removal dismissal, and Apply to a separate result project. Offline tests do not establish these host behaviors.

Live Analyze/Apply correctness and end-to-end speed remain unverified for this revision.
