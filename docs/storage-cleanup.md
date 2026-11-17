# Storage and cleanup

Silent Snip cleans up its recorded disposable audio automatically at launch and every ten minutes while idle. There is no menu bar cleanup command.

Files become eligible after seven days, or sooner when the recorded disposable cache exceeds 256 MiB. The oldest unpinned copies go first. Active, changed, or uncertain files are kept, so the size target is not a hard limit on total storage.

## Storage locations

Worker files live under `~/Library/Application Support/Silent Snip`:

| Folder | Contents | Automatic cleanup |
| --- | --- | --- |
| `Results/<request UUID>/` | Edited XML, recovery XML, reports, settings snapshots, and receipts | Kept |
| `Processed Audio/<request UUID>/` | Durable rendered audio used by older cleaned projects | Kept |
| `Temporary/<request UUID>/` | Job diagnostics and owned cache copies | Only recorded disposable audio is eligible |
| `Share Inbox/<request UUID>/` | Files delivered through Share | Only recorded, completed processing renders are eligible |
| `Cache Records/` | Ownership records for disposable audio | Records are removed after their file is deleted or absent |

Per-project Workflow settings are stored as `Project-Settings.json` in the frontend's sandbox, under its `Application Support/Silent Snip Workflow Prototype` directory. They are kept during cache cleanup.

## Files to keep

Keep the original media referenced by current cleaned projects. For older rendered-audio results, also keep `Processed Audio/<request UUID>/Processed-Audio.wav`. Moving or deleting it without relinking can leave a project without audio.

Keep original native Final Cut projects and libraries, especially when they contain effects whose private settings are absent from XML. Saved result and recovery folders are useful additional copies; they are not media backups.

Automatic cleanup preserves all XML exports, result folders, recovery files, settings, libraries, original media, durable processed audio, and manual Share exports. It also keeps unknown, unregistered, modified, or incomplete files.

Before manually removing media, archive or relink it and confirm that no remaining project depends on the old path. [Uninstall](setup.md#uninstall) keeps data by default; its optional data-removal mode deletes known settings and recovery reports but still preserves durable processed audio.

## How cleanup chooses files

Only files with recorded ownership are candidates. Cleanup checks the allowed job location, file identity, size, timestamps, and content hash before deleting one file at a time. Symlinks, hard links, changed files, and missing or malformed ownership records are rejected.

It removes an empty job directory only if it is actually empty. It does not recursively purge job folders. New operations stop an active cleanup before using the cache.

## Logs

Share event logs rotate between `Share Inbox/events.jsonl` and `events.previous.jsonl`, each limited to 1 MiB. Other diagnostics and recovery files stay on disk, so saved results and logs can grow over time.
