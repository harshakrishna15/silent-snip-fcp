# Storage and safe cache cleanup

The scissors menu includes **Clear Cache…**. It clears optional analysis audio without discarding the current review plan. The command is unavailable during analysis, Share capture, Apply, navigation, verification, or another cleanup. New operations cancel an already-running cleanup and wait for it to stop before using cached files. Hashing checks cancellation between 1 MiB reads, so maintenance does not sit in front of a fresh Analyze or Apply request. Disk traversal and hashing run away from the UI thread.

Automatic cleanup runs at launch and every ten minutes while idle. Recorded, unmodified disposable audio is eligible after seven days, or sooner when the recorded cache exceeds 256 MiB. The oldest unpinned copies go first. The current reusable analysis audio is pinned; a manual clear drops that optional cache first. Active, changed, inaccessible, or uncertain files take precedence over reaching the size target.

## What can be deleted

The app records an inventory only for cache copies it creates and completed, verified, request-owned processing renders. An inventory entry identifies one file directly inside `Temporary/<job UUID>` or `Share Inbox/<job UUID>`, including its device/inode, size, modification time, and content hash. `Temporary` permits only `Cached-Processed-Audio.wav`. Share processing renders permit the PCM audio formats the existing Share exchange accepts.

Before deletion, cleanup validates the permitted location, regular-file type, single link, file identity, and unchanged content hash. It rejects symlinked roots, job directories, registries, audio files, and hard-linked audio. It unlinks one verified file at a time. Empty job directories may be removed with `rmdir`, which cannot remove any directory containing XML or unknown siblings. It never recursively purges job folders.

`Cache Records` contains the small ownership inventory. An entry is removed after its audio is deleted or known to be absent. Missing or malformed ownership information does not authorize deletion.

## What stays

- The entire `Results` directory, including before/after XML, recovery and verification receipts, edit reports, and settings snapshots.
- Every XML/FCPXML/FCPXMLD export, including diagnostic exports in temporary jobs.
- Original media, Final Cut libraries/projects, source files, extension settings, and preferences.
- Manual Share exports. They are user output, not automatically generated analysis cache.
- Unregistered legacy files, incomplete exports whose ownership was not recorded, modified files, and unknown files placed beside a disposable copy.

These exceptions mean total application storage is not hard-capped: saved results and recovery history accumulate deliberately. A crash before an incomplete render is inventoried can also leave an unknown file. The cleanup command does not guess that an audio extension or an old timestamp makes such a file safe to delete. Review these files manually if needed; automated cleanup never trades away recovery or media safety to reclaim more space.

## Logs

Only the Share event log rotates: `Share Inbox/events.jsonl` and `events.previous.jsonl`, each at most 1 MiB. A single oversized event is replaced by a small omission notice. Existing oversized current logs are discarded rather than copied into an oversized backup. Symlinked or hard-linked log paths are not written or rotated. Other diagnostic and recovery files are preserved.

## Verification

Tests run inside private temporary fixtures. They place recovery XML, original media, manual Share output, modified cache content, existing destination files, unknown files, symlinks, and hard links next to disposable entries and verify preservation. Other checks cover age/size eviction, active-file pins, log limits, overlapping cleanup, and operations waiting for cleanup. No Final Cut library is modified by these tests.

Build, installed-app checks, and native menu validation are recorded separately from live Final Cut editing. Storage cleanup does not establish successful automatic Apply.

On October 23, build 10 passed 352 Swift tests (one skipped, zero failures) and 53 build-script tests. The installed app and ZIP matched the published bundle, signatures and extension sandbox were verified, and Apple's Audio Unit validation passed. Launching the installed app removed a synthetic eight-day-old inventoried cache file and its record. SHA-256 checks confirmed that all 142 existing saved/library files and the referenced original source file remained unchanged. After refreshing its existing control-access grant, the copied app reported `ready`. The manual cleanup/controller paths are covered by isolated tests; the native menu command and a live Final Cut editing pass remain separate manual checks.

Local evidence is preserved in `build/StorageCleanupEvidence`, with test/build logs in `build/storage-cleanup-*.log`. These generated files are excluded from Git.
