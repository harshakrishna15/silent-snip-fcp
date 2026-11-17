# Recovery and troubleshooting

If Apply stops after delivery, a cleaned project may already exist. Check the original event before starting another edit. **Retry Verification** and **Verify Existing Result** inspect that result without importing it again.

## Retry an interrupted result

Use **Retry Verification** when it is offered after a failed or interrupted Apply. Silent Snip opens the existing result, exports fresh XML, and compares it with the saved plan and media.

After restarting the worker or frontend:

1. Open the original project or its existing cleaned result in Final Cut.
2. Choose **Window → Extensions → Silent Snip**.
3. Click **Verify Existing Result**.
4. Select `Silent Snip.fcpxml` from the matching saved result folder.

No selected clip or legacy Silent Snip effect is needed. The saved artifacts and current library/project identity must match. This action does not restore an old cut review or repeat a native effects transfer. If an effect transfer did not finish, read-only verification cannot complete it.

## Return to the original edit

Open the unchanged original project in Final Cut. Each Apply creates a separate cleaned project; it does not overwrite the original.

Silent Snip also saves `Before-Cuts.fcpxml` with a distinct recovery identity. It references existing media rather than copying it. Keep the original native project when it contains audio effects: Final Cut can omit private settings from XML, so XML is not a complete backup of those effects.

If an older cleaned result has missing or changed effects, recreate it from the original native project. Keep older processed-audio files while any project still references them.

## Saved result files

Worker data lives in `~/Library/Application Support/Silent Snip`. Each operation has its own `Results/<request UUID>/` folder.

| File | Purpose |
| --- | --- |
| `Silent Snip.fcpxml` | Generated cleaned project; choose this file for saved-result recovery |
| `Before-Cuts.fcpxml` | Separately named recovery copy of the original project |
| `Edit-Report.json` | Cuts and retained source intervals |
| `Analysis-Settings.json` | Exact detection settings used for the edit |
| `Import-Status.txt` | Import and completion information |
| `Import-Dialogs.json` | Import dialogs observed, when present |
| `Verification-Receipt.json` | Saved plan and bound result identity for resuming checks |
| `Import-Verification.json` | Result comparison report, when reached |
| `Verification-*.fcpxmld` | Fresh Final Cut exports used for result checks |
| `Bulk-Effect-Transfer-Journal.json` | Native effects-transfer progress, when that route is used |

Keep files from the same result folder together. Edited or mismatched artifacts are rejected. Diagnostic timing files are described in [architecture](architecture.md#diagnostics); storage and media locations are in [storage](storage-cleanup.md).

## Troubleshooting

| Problem | What to do |
| --- | --- |
| Silent Snip is missing from **Window → Extensions** | Open the complete Workflow app once, choose **Done**, and restart Final Cut. Keep one active frontend copy. |
| The extension cannot connect | Click **Connect to Final Cut Pro** and check the frontend's Automation permission. |
| Analyze cannot launch the worker | Check that the installed worker is still at its expected path. A staged candidate cannot handle live requests. |
| Analyze cannot open Share | Check the exact **Silent Snip** destination name, **Audio Only / WAV**, and the action pointing at the worker. |
| Control access fails after rebuilding | Quit and reopen the worker. Refresh its existing control-access entry in System Settings if needed. |
| Ranges do not refresh after editing settings | Finish a valid value and pause briefly with Final Cut in front. Use **Analyze Again** for an ineligible layout or changed audio. |
| Apply is disabled | Wait for analysis or a settings update to finish, resolve invalid values, and include at least one eligible cut. |
| Apply rejects an old review | Analyze again after timeline, effect, volume, or source-media changes. |
| The preview disappears | Return to the analyzed project in Final Cut. It hides on app switches, project changes, dialogs, or uncertain geometry. Closing the extension clears the review. |
| An operation loses its connection | Check for an existing result, then use saved-result recovery if delivery may have occurred. Otherwise analyze again after the worker is idle. |
| Saved-result recovery rejects a file | Select the matching `Silent Snip.fcpxml`, keep its companion artifacts intact, and open its original or cleaned project in the right library. |
| A cleaned project has missing audio | Relink its original media, or its legacy `Processed-Audio.wav` if it uses rendered audio. |
| A build cannot inspect running processes | Run it in an environment with process-list access. The build refuses to replace an app when it cannot check whether it is running. |
| Uninstall cannot remove protected data | Review the exact folder in Finder. Keep media still referenced by Final Cut projects. |
