# Counted Apply button confirmation

The compact Controls redesign changed the action title to `Apply 1 Cut` or `Apply 35 Cuts`. The helper still required the literal Accessibility title `Apply Cuts`, so a valid click was rejected with “Apply was not confirmed in the selected Silent Snip Controls window.” That rejection clears the review before starting the edit operation; it does not import a changed project.

Build 9 removes the presentation-title dependency. Confirmation requires the exact fresh gesture identifier exposed by the clicked button, with that button disabled while awaiting acknowledgment. The existing checks still bind it to the sole Silent Snip Controls window, its view UUID, the selected clip, the pinned project, and the current review revision. Apply replay protection and recovery handling remain unchanged.

333 Swift tests execute with one skipped and no failures. The new confirmation policy rejects missing, ordinary, stale, prefixed, or suffixed identifiers and enabled or unreadable button states. The 24 Controls scenarios check singular and plural counted actions, fresh gesture exposure, retransmission, acknowledgment, and uncertain timeouts. These checks establish the corrected handshake contract, not a completed live Final Cut editing pass.

The installed app must be replaced with Final Cut and Silent Snip closed. After replacement, Analyze again to create a fresh review before retrying Apply. Run every live editing test only in a disposable project inside the workspace's `Cutdown Integration.fcpbundle`; preserve recovery XML and exported evidence.

## Installed verification — October 23

Build 9 is installed at `~/Applications/Silent Snip.app`; build 8 is preserved in a backup ZIP. Installed files match the published app and ZIP, signatures and the extension sandbox were verified, and macOS registered the installed extension. The first validation ran before Audio Unit discovery caught up; validation passed after the component appeared in the list. The copied app reports `ready` after refreshing its existing control-access permission. Live Apply remains unverified on this fix.
