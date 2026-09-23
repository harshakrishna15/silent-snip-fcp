# Audio effect window review channel

The current window sends Analyze through the local URL handler, then polls this
channel for status. It sends Apply only from the separate button after a valid
review response. The helper now dispatches both operations through the analysis
coordinator. Protocol and unit tests are not proof of a successful live Final Cut import.

The Audio Unit's custom effect window and the Cutdown helper communicate through
`DistributedNotificationCenter` within the current macOS login session. The Audio
Unit remains sandboxed. No network or shared application-group entitlement is
needed. Apple allows sandboxed notifications when `userInfo` is nil; Cutdown uses
a bounded JSON string as the notification's `object`.

- [Apple: sandboxed distributed notifications](https://developer.apple.com/documentation/foundation/distributednotificationcenter/post(name:object:userinfo:))
- [Apple: distributed notification delivery and security](https://developer.apple.com/documentation/foundation/distributednotificationcenter)

`Sources/CutdownMac/ReviewTransport.swift` defines the schema.
`ReviewState.swift` defines typed helper states; the Objective-C
`CutdownReviewConnection` owns validation, cached heartbeats, pending commands,
and acknowledgment state independently of the view. Both implementations check
their state policies against `AudioPlugin/Tests/review-states.json`.
Commands use notification name
`local.cutdown.review.command.v1`. Responses use
`local.cutdown.review.response.v1.<uppercase request UUID>`.

Every payload contains `version: 1` and `request`. Responses also contain a
monotonic `revision`. Payloads are limited to 256 KiB and at most 2,000 cut rows.
Project XML, source paths, and audio samples are not sent through this channel.

The view subscribes before launching the helper and polls the latest revision to
recover lost notifications. Unacknowledged Apply, selection, preview, and verification-retry commands resend the same pending request. The helper applies a job at most once. An acknowledged Apply is only polled. After 15 seconds without an accepted response, the window invalidates the review, warns of any uncertain import, and re-enables Analyze.

The helper validates and serializes each revision once. Identical responses only
refresh the connection heartbeat; they do not decode again or rebuild the table.
Equal revisions cannot acknowledge pending edits, restore an invalidated review,
or clear a timeout notice. While Apply is unacknowledged, the preceding review
does not postpone its timeout. While the same view instance remains alive,
reopening resumes status polling with a fresh response interval. Polls use
common run-loop modes. Terminal states with no pending operation do not require
a heartbeat. A timeout clears pending mutation commands but keeps read-only
status polling, allowing a newer failure to replace the provisional timeout.
This does not restore Apply eligibility. Explicit verification retry and a new
Analyze receive fresh deadlines.
A replacement view does not currently recover an older view's job identifier.
Helpers silently ignore status requests for jobs they do not own. This prevents
another running helper from overwriting the owner's response. If the owner exits,
the existing 15-second timeout enables Analyze again.

Commands are `status`, `cancel`, `include`, `selectAll`, `deselectAll`, `highlight`,
`apply`, `retryVerification`, and `preview`. Changing settings requires Analyze
again so the helper validates fresh project and source state before reusing
measurements. An `analyzing` response can contain verified cut rows while cleanup
runs, but `canApply`, `canChangeSelection`, and `canHighlight` remain false until
`review`. Capability flags from the helper enable each implemented operation.
`canApply` and `canHighlight` default to false. Defining a command does not
establish that its timeline operation is implemented.

Distributed notifications are untrusted. The helper must require an existing
matching job, validate command payloads and current capabilities, and run the
separate project-state and recovery checks before any timeline edit. Receiving a
message itself does not authorize an edit. Rendering never launches the helper
or sends review commands.

## Focused checks

- `AudioPlugin/test-factory.sh`: independent scenarios for settings/native state,
  Analyze connection, heartbeats, lost preview/retry delivery, selection, Apply,
  navigation, and recovery. Each starts with a fresh view, processor, and private
  settings store. The harness also checks the shared protocol state fixture.
- `ReviewTransportTests`: Swift schema round trips, malformed/oversized command
  rejection, settings validation and default-disabled capabilities.
- The current window sends `status`, `cancel` (when replacing a request),
  `preview`, `apply`, `retryVerification`, `highlight`, `include`, `selectAll`, and `deselectAll`. Selection acknowledgments must contain the requested inclusion values before Apply is re-enabled. Other schema commands remain available for future integration.
- All live Final Cut checks use only the workspace integration library.

## Preview visibility

`preview` requires `included` as a JSON boolean (`true`/`false`, not `1`/`0`).
The helper returns optional `previewVisible` in review responses. A new analysis
starts with preview enabled. A pending toggle is retransmitted until a newer
response reports the requested visibility (or leaves review). The checkbox stays
disabled and displays the last confirmed state while acknowledgment is pending.
Visibility does not alter cut inclusion or Apply eligibility. The checkbox is enabled only
for an idle review response that advertises this field. Closing the window does
not cancel analysis or hide the overlay. Apply and cancellation clear it.

## Navigation and verification

`highlight` requires the exact current `cutID` and `canHighlight`; it moves the playhead to the range start after baseline verification, without changing inclusion. The transient `navigating` state blocks Apply, settings, and selection mutations until navigation finishes. Helpers without a navigation implementation leave the capability disabled.

Optional `canRetryVerification` is true only for a failed/cancelled job with a pending imported result. `retryVerification` enters `verifying`, retains single-operation ownership, and invokes a verification-only operation. Duplicate requests while busy do not start another verification, and retry never invokes Apply or import. A later failure remains retryable. Existing job revisions stay monotonic when reopened from a saved result. Controls can adopt a saved verification receipt after restart using the explicit `cutdown://verify` request.

The plug-in includes `expectedRevision` in every verification retry. The helper
accepts it only while that failed/cancelled revision is current. Once the attempt
starts, retransmissions of the old request return the cached status, including
after another failure; they cannot create a repeated verification loop. A newer
response releases the pending button. A rejection because another review owns
the coordinator also publishes a newer explanation. Retry restarts polling if a
previous connection timed out. The helper's reliable in-process command path
may omit `expectedRevision`.

`verifying` and `navigating` are busy states; Controls disables detection fields and Apply for both. Settings recovery uses the exact selected imported occurrence's `cutdown.setting.0`–`.3`, `cutdown.saveSettings`, and `cutdown.status` controls, followed by host re-export checks.


## Single-window reconnection

On appearance, a view with no request publishes a bounded string envelope to
`local.cutdown.review.reconnect.v1`: `{"version":1,"view":"UUID"}`. It retries
while visible and unedited. The view exposes that UUID in its Cancel button's
accessibility identifier, `cutdown.review.reconnect.UUID`.

The helper checks the pinned project, original selected clip and sole Cutdown
Controls window, then locates the exact button identifier in that window. Only
then does it send a reply to `local.cutdown.review.connected.v1.UUID` containing
`version`, `view`, `request`, four `settings` values and `output`. The recreated
view restores those submitted values without rewriting AU document state,
subscribes to the specific request and polls status. Apply remains disabled
until a validated review arrives. Duplicate handshakes cannot reset an existing
connection; edited views do not reconnect. There is no global latest-job adoption.

Verify Existing Result uses `cutdown://verify?view=UUID&result=ENCODED_FILE_URL`.
The helper verifies the requesting native view before loading a local
`Cutdown.fcpxml` recovery receipt, connects the view to the saved request, and
starts verification without importing again. Failures return a view-scoped
error. A view that loses connection after Apply can recover status by returning
to the original clip's Controls, or verify the saved result explicitly.
