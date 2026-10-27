# Install and first-time setup

## Copy and open the app

Extract **Silent Snip.zip**, copy **Silent Snip.app** into Applications (either `/Applications` or your home folder's `Applications`), and open that copy once. Users of a prebuilt app do not need Xcode, Terminal, or the source checkout. A scissors icon appears in the menu bar while the app is running. Click it for control-access status, **Open Results Folder**, and **Quit Silent Snip**. Quit is unavailable during an active operation. Use **Silent Snip Audio → Controls** in Final Cut for analysis and review.

Silent Snip quits automatically when you quit Final Cut Pro, after interrupted work finishes saving its status and cleaning up. Closing a Final Cut window alone does not quit either app. **Analyze** in Controls starts Silent Snip again when needed. Opening Silent Snip by itself for first-time setup keeps it running until Final Cut has been opened and then quit.

The app contains both the existing background executable and `Contents/PlugIns/SilentSnipAudio.appex`. The extension remains sandboxed; the containing app performs Final Cut capture, analysis, preview, Apply, verification, and recovery. There is no separate setup app or separately installed helper. See [the design and verification record](single-app-plan.md).

## Grant macOS access

Opening the copied app requests control access. Enable **Silent Snip** in **System Settings → Privacy & Security → Accessibility**, or the control-access pane named in Silent Snip's error on your macOS version. On macOS 27 the code names that pane **Device Control and Data Access**. macOS may also request Automation access when needed. Permissions are granted by you, not by the build or registration tools.

If Silent Snip is missing from the list, click **+**, press **Command–Shift–G** in the app picker, enter `~/Applications/Silent Snip.app` (or `/Applications/Silent Snip.app` if you copied it there), and choose **Open**. Enable the resulting entry. Version 0.2 uses a fresh app identity and appears as **Silent Snip**. Remove permission entries for obsolete app copies separately. The menu bar status confirms whether the new app has access.

Select the actual copied app, rather than a staged candidate. Ad hoc rebuilds may require quitting and reopening the app, then refreshing its control-access entry if access remains unavailable. No signing or privacy protections are disabled by these instructions.

## Create the Silent Snip Share destination

A Share destination must be configured once on each Mac. This is the remaining Final Cut setup step after copying and opening the app.

1. Choose **Final Cut Pro → Settings → Destinations → Add Destination** and add **Export File**. Rename it **Silent Snip**. See Apple's [Create share destinations](https://support.apple.com/guide/final-cut-pro/ver9fd008a21/mac).
2. Set **Format** to **Audio Only** and **Audio Format** to **WAV**. Under **Action → Other…**, select the copied **Silent Snip.app** in Applications. For an in-place developer build, choose `build/App/Silent Snip.app`. See Apple's [Export File settings](https://support.apple.com/guide/final-cut-pro/ver13664388c/mac).
3. Confirm **Silent Snip…** appears under **File → Share**. The exact destination name matters.

The containing app declares Apple's [Media Asset Protocol](https://developer.apple.com/documentation/professional-video-applications/receiving-media-and-data-through-a-custom-share-destination), so Final Cut can deliver XML and requested media. Normal use begins from **Analyze** in Controls; you do not manually export XML for each analysis.

## Migrate from two apps

Quit Final Cut and the old helper first. Keep your libraries, media, results, and recovery files. Remove old application copies separately after confirming the combined app works; do not erase saved data during migration. Copies from the retired setup app may be under `~/Applications/Silent Snip/`. Legacy repository builds may be removed with `Scripts/uninstall-local.sh` in their original checkout; its default preserves saved data.

Version 0.2 starts fresh: the containing app is `local.silentsnip.app`, its process is `SilentSnip`, and the sandboxed extension is `local.silentsnip.app.audio` (`SilentSnipAudio.appex`). It uses the `silentsnip://` URL scheme and stores new results in `Application Support/Silent Snip`. Old settings are not migrated. Existing app data and libraries are left on disk.

Open the copied app and grant access to **Silent Snip**. Reselect `~/Applications/Silent Snip.app` as the **Silent Snip** Share action in Final Cut. Remove obsolete app entries from Device Control and Data Access. Re-add the **Silent Snip Audio** effect if an existing project still references an older installation.

The extension sends analysis and saved-result verification requests to its own containing app, avoiding a competing legacy URL handler. This does not make an old Share action point at the new app automatically.

## Build from source

Use an Apple Silicon Mac with full Xcode selected under **Xcode → Settings → Locations → Command Line Tools**, and complete Xcode's first-launch components and license. Command Line Tools alone are insufficient for the extension target. macOS 14 is the deployment target; the installed Xcode and Final Cut versions can require a newer system. Final Cut automation uses English labels.

```sh
xcode-select -p
xcodebuild -version
Scripts/build-app.sh
```

The build produces `build/App/Silent Snip.app` and `dist/Silent Snip.zip`, both containing one app. It uses Release by default, reuses `build/swift` and Xcode's extension build cache, verifies signatures, stages complete products, and guards against replacing running app copies. It does not copy an app into Applications, launch it, configure Final Cut, or grant permissions. Copy the app and follow the user setup above.

For in-place development, `Scripts/build.sh` builds Debug and registers the combined app. `Scripts/build.sh --release` uses Release. `Scripts/build.sh --stage` assembles `build/Candidate/App/Silent Snip.app` with live URL, Share, and document routes removed; it does not replace the published app or ZIP or explicitly register the candidate. A staged build is not a distributable app.

`Scripts/register-local.sh --check-only` checks the combined build. For a copied app, use `Scripts/register-local.sh --check-only --app "/absolute/path/Silent Snip.app"`. Omitting `--check-only` registers that exact copy while Final Cut is closed; ordinary recipients should not need this diagnostic command. If the combined build is absent, legacy developer helper/wrapper builds can still be inspected or registered for migration. Do not leave multiple app copies active in different locations.

`SILENT_SNIP_SIGNING_IDENTITY` and `SILENT_SNIP_DEVELOPMENT_TEAM` accept existing developer signing settings; defaults are local ad hoc signing. Signing and notarization service setup is outside this change. No component downloads or external Swift dependencies are required.

## Integration-test library

Every live test must run only in **Cutdown Integration.fcpbundle** at the repository root. Reuse it if it already exists. On a fresh checkout, create a new empty Final Cut library with that exact name and location before testing. Do not use another library or a real editing project. Libraries are deliberately ignored by Git.

Install FFmpeg and Python 3 if you want to generate the test media, then run:

```sh
ffmpeg -version
python3 --version
Scripts/make-fixtures.sh
```

The script writes generated WAV files, FCPXML bundles, and expected-results JSON under `build/Fixtures`. Its XML validation currently expects Final Cut at `/Applications/Final Cut Pro.app` with the FCPXML 1.14 DTD. A missing DTD is an environment/setup issue to resolve before relying on that validation.

With the integration library open, import `build/Fixtures/Silent Snip Audio Only Basic.fcpxmld` into that library. Keep source files in place; disable copied, optimized, and proxy media. Use a fresh disposable test project for each run. The sanitized files under `Tests/SilentSnipCoreTests/Fixtures` use placeholder media URLs for offline regression tests; use the generated `build/Fixtures` files for live imports.

Follow [the workflow](workflow.md) to add Silent Snip Audio, open Controls, Analyze, review, and Apply. Check the resulting project's editable segments, source references, effects/settings, and total duration, as well as whether preview and recovery work. Merely seeing the effect or passing analysis is not evidence that automatic cuts work. Preserve exported evidence separately from build caches.

## Uninstall

1. Remove **Silent Snip Audio** from projects you intend to keep using. Uninstalling does not undo applied cuts.
2. Remove the **Silent Snip** Share destination in **Final Cut Pro → Settings → Destinations**.
3. Quit Final Cut, choose **Quit Silent Snip** from its menu bar icon, then move the copied **Silent Snip.app** to Trash. Remove its control-access and Automation entries in System Settings if listed. Previously installed setup apps and old app copies must be removed separately.

Settings, results, and recovery XML are kept by default. New data uses `~/Library/Application Support/Silent Snip`; the extension keeps its settings in its `local.silentsnip.app.audio` sandbox. To erase all new data manually, review those locations and the matching preferences, caches, saved-state, and application-script folders for `local.silentsnip.app`, `local.silentsnip.app.audio`, and developer helper IDs under `local.silentsnip.helper`.

Earlier versions may have left data under former app names and identities. Installing this release does not migrate or erase those files. Back up old results and recovery XML before removing legacy data manually. macOS can deny access to protected container metadata; removing an app does not establish that all its data was removed.

For repository builds, `Scripts/uninstall-local.sh --dry-run` previews unregistration and removal, and `Scripts/uninstall-local.sh` performs it. `--remove-data` additionally erases this account's settings, results, recovery XML, and known component data; missing preferences are already clean, but real access failures remain errors. The script does not remove app copies outside the checkout. Source code, build caches, media, `Cutdown Integration.fcpbundle`, and exported integration evidence are kept.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Build cannot inspect processes | Retry from an environment with process-list access; no running app is replaced when inspection fails. |
| Silent Snip Audio is missing | Quit Final Cut, open the complete copied app once, then reopen Final Cut. Check the extension's discovery record before inferring a successful install. |
| Analyze cannot open its app | Keep the extension inside its complete containing app. Reopen Final Cut after moving or replacing that app. Inert candidates are intentionally not usable. |
| Analyze cannot open Share | Check the destination's exact **Silent Snip** name, **Audio Only / WAV**, and action pointing to the combined app. |
| Control access is missing after migration | Grant access to the copied combined app and retire the old helper entry; the app identity changed. |
| A protected data container cannot be removed | Review the exact folder in Finder. macOS may require consent. Do not treat app removal as completed data cleanup. |
| Imported settings differ | Follow [settings recovery](workflow.md); document-state persistence does not prove XML-import settings retention. |

Build, render, and discovery checks alone do not establish automatic Final Cut editing. Current results are recorded in [single-app verification](single-app-plan.md).
