# Review transport

The worker and sandboxed clients exchange review commands through `DistributedNotificationCenter` in the current macOS login session. Messages use a bounded JSON string as `object` and nil `userInfo`; no network connection or shared app group is needed.

The Workflow frontend and legacy Audio Unit share the wire schema and connection validation. Launch, native-view authorization, and reconnection differ between clients. The legacy handshake below applies to the Audio Unit's Controls window.

## Owning code

| File | Responsibility |
| --- | --- |
| `Sources/SilentSnipMac/ReviewTransport.swift` | Schema, payload limits, and command validation |
| `Sources/SilentSnipMac/ReviewState.swift` | Worker review states |
| `AudioPlugin/Extension/SilentSnipReviewConnection.m` | Response validation, heartbeats, pending commands, and acknowledgments |
| `WorkflowPrototype/Extension/WorkflowReviewClient.m` | Workflow launch, capabilities, and review commands |

## Messages

Commands use `local.silentsnip.review.command.v1`. Responses use `local.silentsnip.review.response.v1.<uppercase request UUID>`.

Every payload contains `version: 1` and `request`. Responses include a monotonic `revision`. The limit is 256 KiB and 2,000 cut rows. Audio samples, project XML, and source paths do not travel through this channel.

Clients subscribe before launching the worker and poll its latest revision because notifications can be lost. Review edits, navigation, and Apply carry `expectedRevision`; Apply also carries the native `view` UUID and a fresh `applyGesture` UUID. The worker checks request ownership, current capabilities, the requesting view, project state, and recovery requirements before editing.

Notifications are untrusted input. Receiving a message alone never authorizes an edit. Audio rendering never launches the worker or sends commands.

## Commands

| Command | Purpose |
| --- | --- |
| `status`, `cancel` | Poll an owned request or stop it |
| `include`, `includeGroup`, `selectAll`, `deselectAll` | Change cut inclusion |
| `preview` | Toggle the timeline overlay; `included` must be a JSON boolean |
| `recalculate` | Refresh cuts from retained measurements |
| `adjustCut` | Narrow or reset a cut boundary |
| `audition`, `stopAudition` | Play or stop a source-audio comparison |
| `highlight` | Request worker-managed cut navigation |
| `prepareNavigation`, `navigationFinished` | Coordinate Workflow SDK navigation |
| `apply` | Apply the reviewed plan after a native gesture |
| `retryVerification` | Check an existing result without importing again |

Capabilities advertised by the worker determine which commands are available. Defining a command does not enable it. `canApply` and `canHighlight` default to false.

## Acknowledgments and timeouts

Clients resend an unacknowledged command with the same request, revision, and gesture/edit identity. An acknowledged Apply is only polled. The worker applies a plan at most once; stale retransmissions cannot undo newer choices or start another verification attempt.

Identical responses refresh the connection heartbeat without rebuilding the table. Equal revisions cannot acknowledge pending edits or restore an invalidated review. After 15 seconds without an accepted response, the connection invalidates the review and clears pending mutation commands. Read-only polling can continue, but it cannot restore Apply eligibility. Terminal states with no pending operation need no heartbeat.

Unknown jobs are ignored. A new view cannot adopt a global “latest” job. Saved-result recovery is an explicit action.

## Settings updates

A `recalculate` command includes `expectedRevision`, `view`, `settingsEdit`, increasing per-view `settingsSequence`, typed `settings`, `output`, and `verifySettings`. Workflow automatic updates also require `localPreview: true` and `automaticPreview: true`.

Invalid partial input stays local with Apply disabled. Older edit sequences cannot replace the latest edit. Responses echo the edit identity and settings; provisional rows do not enable selection, navigation, or Apply. Those actions wait for an acknowledged ready review.

The Workflow frontend waits 250 ms after a valid edit before requesting an eligible local refresh. It reuses the last analyzed audio without another Share. Legacy Controls has a separate 180 ms coalescing path and can request host settings verification after editing ends. Both paths retain fresh Apply checks.

Recalculation cannot capture changed audio processing or media. Use a new Analyze after those changes. Local settings refresh does not make an effect chain eligible for cross-Analyze measurement caching.

## Navigation and result recovery

Navigation requires the current cut ID and revision. Workflow navigation also carries a fresh gesture and native view identity. The `navigating` state blocks conflicting actions until the move finishes.

`canRetryVerification` is available only when a failed or cancelled request has a pending result. Retry enters `verifying` under the existing operation owner. It never calls Apply or imports again. Retransmissions from the preceding revision return status rather than starting another attempt.

Saved-result recovery starts an explicit `silentsnip://verify` request. The worker validates the requesting view, matching artifacts, and library/project identity before checking the existing result. See [recovery](../docs/recovery.md).

## Legacy Controls reconnection

A visible, unedited Audio Unit view without a request posts this bounded string to `local.silentsnip.review.reconnect.v1`:

```json
{"version":1,"view":"UUID"}
```

Its Cancel button exposes `silentsnip.review.reconnect.UUID` as an accessibility identifier. The worker checks the pinned project, original selected clip, focused Controls window, and exact identifier before replying to `local.silentsnip.review.connected.v1.UUID`.

The reply contains `version`, `view`, `request`, the four settings values, and `output`. The view restores submitted values without rewriting AU document state, subscribes to the request, and polls. Apply remains disabled until a valid review arrives. Duplicate handshakes cannot reset an existing connection, and edited views do not reconnect.

Legacy saved-result recovery uses `silentsnip://verify?view=UUID&result=ENCODED_FILE_URL`. Failures are returned to that view; the recovery action does not import the result again.
