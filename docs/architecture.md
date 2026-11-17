# Architecture

Silent Snip has two apps. **Silent Snip Workflow Prototype.app** hosts the sandboxed interface inside Final Cut. **Silent Snip.app** is the background worker that captures audio, analyzes it, draws previews, and creates and checks the cleaned project.

The worker keeps the `local.silentsnip.app` identity, `SilentSnip` executable, Share receiver, and `silentsnip://` URL handler. The frontend uses `local.silentsnip.workflowprototype` and `local.silentsnip.workflowprototype.extension`. The current package does not embed the legacy Audio Unit.

## Request flow

1. The frontend identifies the library, project, and selected clip through the Workflow SDK.
2. A user action starts a request in the worker. The coordinator owns one operation at a time.
3. The worker captures fresh project XML through the **Silent Snip** Share destination and checks it against the requested identity and selection.
4. It obtains audio, detects quiet ranges, and publishes a review.
5. An explicit Apply rechecks the baseline, saves recovery files, creates the cleaned project, and checks the imported result.

Share initiation, project navigation, native effect transfer, and import use Final Cut's visible interface and require foreground focus. Audio decoding, detection, XML editing, hashing, and file processing run in the worker.

Review commands use bounded, versioned messages with request IDs and monotonic revisions. Stale responses cannot restore an invalid review. Apply also requires a fresh gesture tied to the requesting native view. The worker handles retransmissions without applying a consumed plan twice. See the [review transport notes](../AudioPlugin/REVIEW_PROTOCOL.md).

## Audio capture

Unprocessed clips can be measured directly from their source files. Processing that changes the sound requires a native Final Cut render; a failed or unverifiable render does not fall back to unprocessed source audio.

For an eligible whole-project audio clip, the worker renders in the original project. Some mixed projects can use a checked Dialogue render or an exact selected-range render. Role, scope, duration, media, and project identity must match before the audio is accepted. Reconstructable layouts can use an isolated analysis project. XML isolation rejects rendering audio effects because their complete native state cannot be proved.

Eligible repeat requests can reuse a routing hint to obtain fresh audio and XML in one Share exchange. The worker still checks source contents and the returned project. A routing hint is not an audio cache and cannot authorize a repeated Share after an uncertain dispatch.

## Retained measurements and caching

There are two kinds of reuse:

- **Settings updates within one review:** eligible detection/output edits recalculate from the last analyzed audio after a 250 ms pause. They do not export new audio or capture later processing changes. Cut actions remain disabled until the latest update is acknowledged.
- **A new Analyze request:** the process-local cache can reuse one eligible measurement set only after fresh project and source-content checks. Its key includes project identity and fingerprint, selected occurrence and range, host session, source contents, and measurement window size.

Any rendering audio filter in the project prevents cross-Analyze measurement reuse, including bypassed, component, and third-party effects. The known passthrough Silent Snip controller is exempt. Exported names, preset references, parameters, or opaque state do not prove complete native effect state. Some fully serialized volume, panning, channel, and fade adjustments can still qualify.

The cache holds at most one analysis, with limits of 360,000 measurement windows, eight channels, and a 256 MiB owned rendered file. Owned audio is content-checked before reuse. The cache is not restored after worker restart. Apply always performs its own current-project and media checks.

## Creating the cleaned project

For supported source-backed edits, the XML writer trims retained intervals from original media. Linked video and audio use the same cut map; compatible surrounding items and connections follow that map. It saves a separately named recovery project and creates a uniquely named cleaned copy in the original event.

Final Cut XML can omit private audio effect settings. The native transfer route therefore requires one whole-project audio-only clip, with static effects directly on it and a valid original-project Dialogue render. The worker imports all cut geometry once, then uses one Copy and one effects-only Paste Attributes operation. Real gaps are excluded from the recipient selection. This bulk route is bounded to 8,192 removals.

The effects-transfer journal binds the operation to its source, clipboard state, generated XML, recipient count, library, event, and new host project identity. Unsupported animation, component effects, or broader layouts stop the edit. XML reconstruction does not substitute for omitted native settings.

Result checks compare the expected identity, timeline, source intervals, media, and supported serialized processing state. They do not guarantee identical rendered samples at new effect boundaries. Keep the original native project to retain effect state absent from XML.

## Recovery and diagnostics

If delivery or native transfer becomes uncertain, the worker preserves the result artifacts. Verification retry only inspects an existing result; it does not import or paste again. See [recovery](recovery.md).

### Diagnostics

Files are stored under `~/Library/Application Support/Silent Snip`:

| File | Location and purpose |
| --- | --- |
| `Analysis-Timing.json` | `Temporary/<request UUID>/`; capture, hashing, rendering, measurement, cache use, and cleanup stages |
| `Apply-Timing.json` | `Temporary/<request UUID>/`; Apply stages and result-check details |
| `Verification-Share-Timing-*.json` | Result folder; individual result-check Share exchanges |
| `Result-Verification-Timing-*.json` | Result folder; standalone verification retries |

Nested and concurrent timings overlap; do not add them as sequential stages. File and cache ownership rules are described in [storage](storage-cleanup.md).
