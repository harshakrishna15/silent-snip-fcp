# Install and first-time setup

## Copy and open the apps

Extract **Silent Snip.zip** and copy both **Silent Snip.app** and **Silent Snip Workflow Prototype.app** from its `Silent Snip` folder into the same Applications folder (`/Applications` or `~/Applications`). Keep one active copy of each. Users of the prebuilt apps do not need Xcode, Terminal, or the source checkout.

Open **Silent Snip.app** once. It runs in the background without a Dock or menu bar icon. Open **Silent Snip Workflow Prototype.app** once and choose **Done** in its instructions window. In Final Cut, choose **Window → Extensions → Silent Snip** for the working interface. The frontend's filename retains “Workflow Prototype”; the visible Final Cut extension is **Silent Snip**.

The worker performs capture, analysis, preview, Apply, verification and recovery. The separate frontend hosts the sandboxed Workflow interface and per-project settings. The default worker contains no **Silent Snip Audio** Audio Unit, and no effect needs to be added to a clip. Worker **67** / frontend **25** refreshes eligible ranges automatically after detection or output edits, with no separate Update Cuts button. Go to Cut and Verify Existing Result remain available. The installed pair, native typing checks and their limits are recorded in the [Workflow report](workflow-extension-prototype.md#worker-67--frontend-25-automatic-retained-audio-range-updates).

Silent Snip quits automatically after Final Cut quits and interrupted work finishes saving status and cleaning up. Closing a Final Cut window alone does not quit either app. Explicit frontend actions launch the worker when needed; opening the extension also prepares it for window-size restoration. Opening the worker for first-time setup keeps it running until Final Cut has opened and then quit.

## Grant macOS access

Enable the copied **Silent Snip.app** in **System Settings → Privacy & Security → Accessibility**, or the control-access pane named in its error. On macOS 27 that pane is **Device Control and Data Access**. If the app is missing, click **+**, press **Command–Shift–G**, enter its actual Applications path, and choose **Open**. The Workflow extension reports access errors when an operation needs permission.

The Workflow frontend uses a separate Automation grant to inspect the current Final Cut library, project, and playhead. When **Connect to Final Cut Pro** appears in the extension, click it and approve the macOS request. Permissions are granted by you; build and registration tools do not grant them.

Select the actual copied worker, rather than an inert staged candidate. Ad hoc rebuilds can require quitting and reopening it, then refreshing its existing control-access entry if access remains unavailable. The worker keeps the existing `local.silentsnip.app` identity and `SilentSnip` executable. Updating from the previous effect version does not require a new worker identity or a different Share receiver.

## Create the Silent Snip Share destination

Configure the destination once per Mac. Existing users keep the destination pointing to the same installed **Silent Snip.app** worker path.

1. Choose **Final Cut Pro → Settings → Destinations → Add Destination**, add **Export File**, and rename it **Silent Snip**. See Apple's [Create share destinations](https://support.apple.com/guide/final-cut-pro/ver9fd008a21/mac).
2. Set **Format → Audio Only** and **Audio Format → WAV**. Under **Action → Other…**, select **Silent Snip.app**, the worker in Applications. For an in-place developer build, select `build/App/Silent Snip.app`. See Apple's [Export File settings](https://support.apple.com/guide/final-cut-pro/ver13664388c/mac).
3. Confirm **Silent Snip…** appears under **File → Share**. The exact destination name matters.

The worker retains Apple's [Media Asset Protocol](https://developer.apple.com/documentation/professional-video-applications/receiving-media-and-data-through-a-custom-share-destination), Share definitions, document routes, and `silentsnip://` handler. The separate Workflow frontend is not the Share action. Start normal work with **Analyze Audio** in the extension; manual XML export is unnecessary. Native Share panels remain visible during automation.

## Upgrade from the audio-effect version

Quit Final Cut and both Silent Snip apps, then replace the worker at its existing installed path and add or replace the Workflow frontend beside it. Open both once and reopen Final Cut. Keep the existing Share destination and worker control-access entry; refresh the entry only if macOS reports it stale.

The new worker no longer embeds or registers **Silent Snip Audio**. Installation does not edit your projects or remove their saved effect instances. Existing processing effects, libraries, original media, results, recovery XML, and durable processed audio remain on disk. Remove a legacy Silent Snip effect from an original recording in Final Cut when you no longer need that instance; the button workflow does not require it. Legacy source and compatibility tests remain in the repository.

Detection and output settings belong to each library/project identity and are saved in the Workflow frontend's own `Project-Settings.json`. Use **Save Settings** to persist them. After analysis, valid edits refresh eligible ranges automatically after a **250 ms pause**, using the last analyzed audio, including its processed render when present. Editing, Return and Save do not start a fresh Analyze or export. Changes to volume, effects, source media or timeline content require **Analyze Again**. Apply remains manual and verified. Settings from old Audio Unit instances are not automatically copied into that project store; enter the desired values in the extension. Worker results still use `~/Library/Application Support/Silent Snip`.

Historical migration from the retired setup/helper apps is documented in [the earlier single-app plan](single-app-plan.md). Those releases used different identities; keep old data until its results and media have been archived. Updating the apps does not automatically correct a Share action that still points to an obsolete worker.

## Build from source

Use an Apple Silicon Mac with full Xcode selected under **Xcode → Settings → Locations → Command Line Tools**, and complete Xcode's first-launch components and license. Install Apple's Workflow Extensions SDK, by default at `/Library/Developer/SDKs/WorkflowExtensionSDK.sdk`; `SILENT_SNIP_WORKFLOW_SDK` can select another installed SDK. Command Line Tools alone are insufficient. macOS 14 is the deployment target; the installed Xcode and Final Cut can require a newer system. Final Cut automation uses English labels.

Quit Final Cut and both Silent Snip apps, then run:

```sh
xcode-select -p
xcodebuild -version
Scripts/build-app.sh
```

The default Release build produces:

- `build/App/Silent Snip.app`: the worker with its existing Share and URL identity, without an Audio Unit.
- `build/WorkflowPrototype/Products/Silent Snip Workflow Prototype.app`: the separate frontend with its nested Workflow extension.
- `dist/Silent Snip.zip`: a `Silent Snip` folder containing both complete apps.

The build reuses `build/swift`, checks package compatibility and signatures, stages complete products, and refuses to replace running apps. It does not copy apps into Applications, launch them, configure Final Cut, or grant permissions. Copy both apps and follow the setup above. Local signing defaults to ad hoc; `SILENT_SNIP_SIGNING_IDENTITY` and `SILENT_SNIP_DEVELOPMENT_TEAM` accept existing developer settings. No component downloads or external Swift package dependencies are required.

For in-place development, `Scripts/build.sh` builds a Debug worker and Release frontend and registers the pair. `Scripts/build.sh --release` makes the worker Release as well. `Scripts/build.sh --stage` assembles only `build/Candidate/App/Silent Snip.app`, with live URL, Share, document, and Workflow capability routes removed. Staging does not build or register a frontend or replace published apps or the ZIP; a candidate is not distributable.

`Scripts/register-local.sh --check-only` checks the default pair without modifying registrations. To check copied apps, use:

```sh
Scripts/register-local.sh --check-only \
  --app "/absolute/path/Silent Snip.app" \
  --frontend "/absolute/path/Silent Snip Workflow Prototype.app"
```

Omitting `--check-only` registers that exact pair while Final Cut is closed and retires known old local AU registrations without deleting their bundles or modifying libraries. It verifies the selected Workflow registration path before reporting success. Ordinary recipients should not need this diagnostic command. Keep registered products in place, including each frontend's nested extension. Legacy developer Audio Unit builds can still be checked for compatibility when present.

## Integration-test library

Every live test must run only in **Cutdown Integration.fcpbundle** at the repository root. Reuse it if it already exists. On a fresh checkout, create a new empty Final Cut library with that exact name and location before testing. Do not use another library or a real editing project. Libraries are deliberately ignored by Git.

Install FFmpeg and Python 3 to generate test media, then run:

```sh
ffmpeg -version
python3 --version
Scripts/make-fixtures.sh
```

The script writes WAV files, FCPXML bundles, and expected-results JSON under `build/Fixtures`. XML validation expects Final Cut at `/Applications/Final Cut Pro.app` with the FCPXML 1.14 DTD. Resolve a missing DTD before relying on validation.

With the required library open, import `build/Fixtures/Silent Snip Audio Only Basic.fcpxmld` into it. Keep generated media referenced in place; disable copied, optimized, and proxy media. Use a fresh small disposable project for each run. Sanitized files under `Tests/SilentSnipCoreTests/Fixtures` have placeholder media URLs for offline tests; use generated media for live imports. A fixture containing a legacy detector can be tested with that detector removed in the disposable project; the Workflow route itself does not need one.

Follow [the workflow](workflow.md): select the clip, open **Window → Extensions → Silent Snip**, Analyze, review, and Apply. Check retained intervals, processed-media references, audio routing, duration, preview, and recovery. Test automatic range updates on an eligible source/direct-render clip, including rapid edits, invalid input and zero new Share jobs; also test Go to Cut at a nonzero boundary and saved-result verification after restart without reimport. Verify unchanged original media and processing effects. Exported PCM comparisons are separate evidence of sound preservation; an extension loading or analysis passing does not prove automatic cuts. Preserve source media, durable processed audio, and exported evidence separately from caches.

## Keep original and legacy processed media

Current source-backed results reference the original media. Native-effect results created by worker71 must remain native projects in their library to retain advanced settings that XML can omit; the unchanged original native project is the complete recovery copy. Do not use XML reimport as a backup for omitted effect state. Keep original source media referenced and available.

Historical frozen-audio cleaned projects reference `~/Library/Application Support/Silent Snip/Processed Audio/<request UUID>/Processed-Audio.wav`. This continuous Final Cut render preserves processed sound in kept intervals. Keep it when archiving or moving a cleaned project, and relink Final Cut if its location changes. The original project retains source media and editable effects.

Disposable cache cleanup and uninstall data removal preserve **Processed Audio**. Before removing it manually, archive or relink the files and confirm no remaining project depends on their old location.

## Uninstall

1. Remove the **Silent Snip** Share destination in **Final Cut Pro → Settings → Destinations**.
2. Quit Final Cut and both Silent Snip apps, then move the copied **Silent Snip.app** and **Silent Snip Workflow Prototype.app** to Trash.
3. Remove their control-access and Automation entries in System Settings if listed. Remove older app copies separately. If you still use a legacy Silent Snip Audio instance, remove it from the relevant project before uninstalling its old app.

Uninstalling does not undo cuts. Settings, results, recovery XML, and durable media remain by default. Worker data uses `~/Library/Application Support/Silent Snip`; project settings live in the Workflow frontend's sandbox under its `Application Support/Silent Snip Workflow Prototype` directory. The frontend identities are `local.silentsnip.workflowprototype` and `local.silentsnip.workflowprototype.extension`. Older AU settings may remain in `local.silentsnip.app.audio` containers. Keep **Processed Audio** while any cleaned project references it.

For repository builds, `Scripts/uninstall-local.sh --dry-run` previews unregistration and removal. `Scripts/uninstall-local.sh` removes known local app bundles, including the Workflow frontend. `--remove-data` also erases known settings, result reports, recovery XML, and component data while preserving **Processed Audio**; real access failures remain errors. A linked app-support directory is kept if removing the link would break processed-media references. The script does not remove copies outside the checkout. Source, build caches, original and durable media, the required library, and exported evidence are kept. Protected container metadata can require separate review in Finder; app removal does not prove all its data was erased.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Build cannot inspect processes | Use an environment with process-list access; no running app is replaced when inspection fails. |
| Silent Snip is absent from Window → Extensions | Open the complete copied Workflow frontend once, choose Done, and restart Final Cut. Keep only one active frontend copy. |
| Connect cannot inspect Final Cut | Use Connect to Final Cut Pro and review the frontend's Automation entry in System Settings. |
| Analyze cannot launch the worker | Keep the installed worker at the expected Applications path. Inert candidates are intentionally unusable. |
| Analyze cannot open Share | Check exact Silent Snip destination name, Audio Only / WAV, and the action pointing to the worker. |
| Ranges do not update after editing settings | Finish a valid value and pause 250 ms with Final Cut in front. Automatic updates need an eligible source-audio or verified direct-render analysis and a matching worker/frontend pair. Other layouts or changed audio require Analyze Again. |
| Control access is stale after rebuilding | Quit/reopen the worker and refresh its existing access entry if needed. |
| Verify Existing Result rejects a file | Choose the saved result's Silent Snip.fcpxml and open its original or existing cleaned project. Matching artifacts and project identity are required. |
| Protected data cannot be removed | Review the exact folder in Finder; app removal does not establish complete data cleanup. |

Build, unit, package, and discovery checks do not establish native editing. See the [current versioned Workflow evidence](workflow-extension-prototype.md).
