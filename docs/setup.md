# First-time setup

This guide covers a fresh checkout on an Apple Silicon Mac. Run shell commands from the repository root. The build and offline-test results are in the [README](../README.md#verified-in-this-repository-copy); these instructions do not claim a newly verified end-to-end Final Cut run.

## Prepare Xcode

Install full Xcode, launch it, accept its license, and complete component installation. In Xcode's Settings → Locations, select that Xcode installation under Command Line Tools. Confirm Terminal sees it:

```sh
xcode-select -p
xcodebuild -version
swift --version
```

Command Line Tools alone are insufficient for the Xcode app-extension project. The copied source was built with Xcode 27.0 / Swift 6.4. The package and app deployment target is macOS 14; this does not establish compatibility with every macOS, Xcode, or Final Cut combination. The audio project targets Apple Silicon. Final Cut automation currently uses English menu and control names.

## Build and register both apps

For the same Release-helper installation in one command, use
`Scripts/build.sh --release`. For faster development builds, use
`Scripts/build.sh`, which uses a Debug helper. Both reuse build caches and
register the resulting apps; quit Final Cut and Silent Snip first. Add `--stage`
to build candidates only, with the Xcode registration caveat described below.

Quit Final Cut Pro and any running Silent Snip helper, then run:

```sh
Scripts/build-helper.sh --release
Scripts/build-audio-plugin.sh
Scripts/register-local.sh --check-only
Scripts/register-local.sh
```

The scripts use local ad hoc signing by default. An existing signing identity can be supplied through `CUTDOWN_SIGNING_IDENTITY`; the audio script also accepts `CUTDOWN_DEVELOPMENT_TEAM`. Certificate setup is optional and is not performed by the scripts.

| Component | Registered location relative to the repository |
| --- | --- |
| Background helper | `build/Cutdown.app` |
| Audio Unit wrapper | `build/AudioPlugin/Build/Products/Debug/CutdownAudio.app` |
| Embedded extension | `build/AudioPlugin/Build/Products/Debug/CutdownAudio.app/Contents/PlugIns/CutdownAudioExtension.appex` |

Registration checks signatures and bundle identities, then registers these paths with macOS. It does not copy them to Applications, configure Final Cut destinations, or grant permissions. Keep the registered apps in place. If you move the checkout, rebuild/register from the new location and reselect the helper in the Share destination below.

The visible app and effect names are **Silent Snip** and **Silent Snip Audio**. Existing build paths, bundle identifiers, URL schemes, and settings locations retain their original names so saved projects and settings keep the same identities.

## Grant macOS access

Launch the installed helper once:

```sh
open "$PWD/build/Cutdown.app"
```

The helper runs in the background; its lack of a separate window is expected. Its launch code requests access to control Final Cut. Enable **Silent Snip** in System Settings → Privacy & Security → Accessibility, or the control-access pane named in Silent Snip's error on your macOS version. The current code names that pane **Device Control and Data Access** on macOS 27.

Use the installed helper, not `build/Candidate/Cutdown.app`. If a rebuild leaves a previously granted helper reporting missing access, quit and relaunch it first. If necessary, remove its stale permission entry and add the current `build/Cutdown.app`. Ad hoc rebuilds can change the app's signing identity.

## Create the Silent Snip Share destination

Reopen Final Cut after registering the apps. A destination must be configured once on each Mac; it is not included in a Git checkout. If upgrading from the previous name, rename your existing **Cutdown** destination to **Silent Snip** and keep its action pointed at this checkout’s helper.

1. Choose **Final Cut Pro → Settings → Destinations → Add Destination** and add an **Export File** destination. Rename it **Silent Snip**. Apple documents adding and renaming destinations in [Create share destinations](https://support.apple.com/guide/final-cut-pro/ver9fd008a21/mac).
2. Set **Format** to **Audio Only** and **Audio Format** to **WAV**. Under **Action**, choose **Other…**, select this checkout's `build/Cutdown.app`, and confirm. See Apple's [Export File destination settings](https://support.apple.com/guide/final-cut-pro/ver13664388c/mac).
3. Confirm **Silent Snip…** appears under **File → Share**. The exact name matters: the helper looks up that menu item and the matching confirmation panel.

This combines Apple's documented destination controls with Silent Snip's source requirements. A fresh-machine setup using these steps still needs live verification. The registered helper declares Apple's [Media Asset Protocol](https://developer.apple.com/documentation/professional-video-applications/receiving-media-and-data-through-a-custom-share-destination) so Final Cut can deliver XML and requested media. During an analysis, Silent Snip requests XML alone or configures the isolated audio render automatically. Normal use starts from **Analyze** in the effect's Controls window; there is no manual export step for each analysis.

## Integration-test library

Every live test must run only in **Cutdown Integration.fcpbundle** at the repository root. Reuse it if it already exists. On a fresh checkout, create a new empty Final Cut library with that exact name and location before testing. Do not use another library or a real editing project. Libraries are deliberately ignored by Git.

Install FFmpeg and Python 3 if you want to generate the test media, then run:

```sh
ffmpeg -version
python3 --version
Scripts/make-fixtures.sh
```

The script writes generated WAV files, FCPXML bundles, and expected-results JSON under `build/Fixtures`. Its XML validation currently expects Final Cut at `/Applications/Final Cut Pro.app` with the FCPXML 1.14 DTD. A missing DTD is an environment/setup issue to resolve before relying on that validation.

With the integration library open, import `build/Fixtures/Silent Snip Audio Only Basic.fcpxmld` into that library. Keep source files in place; disable copied, optimized, and proxy media. Use a fresh disposable test project for each run. The sanitized files under `Tests/CutdownCoreTests/Fixtures` use placeholder media URLs for offline regression tests; use the generated `build/Fixtures` files for live imports.

Follow [the workflow](workflow.md) to add Silent Snip Audio, open Controls, Analyze, review, and Apply. Check the resulting project's editable segments, source references, effects/settings, and total duration, as well as whether preview and recovery work. Merely seeing the effect or passing analysis is not evidence that automatic cuts work. Preserve exported evidence separately from build caches.

## Uninstall

1. In projects you intend to keep using, remove **Silent Snip Audio** (or its older **Cutdown Audio** label) from the Audio Inspector. Uninstalling does not remove effects from existing projects or undo cuts already applied.
2. In **Final Cut Pro → Settings → Destinations**, delete the **Silent Snip** Share destination. Remove the old **Cutdown** destination too if it is still present.
3. Quit Final Cut Pro and the Silent Snip helper. From the repository root, preview and run removal:

   ```sh
   Scripts/uninstall-local.sh --dry-run
   Scripts/uninstall-local.sh
   ```

The command unregisters verified Silent Snip app bundles from Launch Services and PlugInKit, then deletes those bundles from this checkout’s `build/` directory. It includes installed, staged, and diagnostic app copies. It checks for running apps and stops on an unreadable process list; it never quits apps automatically. If an unregistration step fails, app bundles are kept for a retry. You can also rebuild and rerun `Scripts/register-local.sh` to restore registration.

### Remove saved app data

The default keeps settings and recovery files. To erase them as well, use:

```sh
Scripts/uninstall-local.sh --dry-run --remove-data
Scripts/uninstall-local.sh --remove-data
```

**`--remove-data` permanently deletes saved results and recovery XML.** Copy anything you want to retain before running it. The flag removes:

- `~/Library/Application Support/Cutdown` — saved results, recovery XML, shared deliveries, temporary analysis files, and diagnostics.
- `~/Library/Application Support/Cutdown Audio` — saved detection defaults, when stored outside the sandbox.
- The app’s `local.cutdown.*` preference domains, sandbox containers, caches, saved window state, and application-script folders, using the exact helper, candidate, wrapper, and extension identifiers.

These settings are shared by checkouts using the same app identities. App bundles outside this checkout are left in place; uninstall those copies separately. Source code, developer build caches, original media, Final Cut libraries (including `Cutdown Integration.fcpbundle`), and exported integration evidence under `build/` are preserved. No shared Final Cut or Audio Unit cache is reset.

### Finish removal

In **System Settings → Privacy & Security**, remove Silent Snip’s entries from Accessibility or the control-access pane named by your macOS version, and Automation if listed. Older entries may still use the Cutdown name. The script does not change macOS privacy settings or Final Cut’s saved preferences.

After preserving any libraries, media, or evidence you need, you can delete the repository folder to remove the source and remaining developer build caches. Removal is validated with disposable bundles and stubbed macOS services; a live uninstall/reinstall round trip has not been verified.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Build cannot inspect processes | Run from a Terminal with process-list access. The scripts intentionally stop when they cannot check whether an app is running. |
| Xcode fails while creating debug symbols | Check the build environment's filesystem/process permissions; record any sandbox failure separately from a normal Terminal retry. |
| Silent Snip Audio is missing or unresponsive | Quit Final Cut, rebuild both apps, rerun registration, then reopen it. Xcode may have registered a staged audio candidate. |
| Analyze cannot open Share | Confirm the destination is named exactly `Silent Snip`, targets the installed helper, and Final Cut is using English labels. Close other dialogs. |
| The helper reports missing access | Follow the macOS access steps above, including restarting the helper after a rebuild. |
| Effect appears but Analyze cannot connect | Confirm both matching components are installed. A staged helper has a different identity and omits live URL/Share registration. |
| Imported Silent Snip settings differ | Follow [settings recovery](workflow.md), including Retry Verification or Restore Saved Settings; don't infer settings retention from successful XML import. |

For discovery diagnostics after installation, run `Scripts/register-local.sh --check-only`. `auval -v aufx ctdn Ctdn` can additionally check the registered Audio Unit; it does not verify Final Cut timeline editing. Full offline test commands are in the [README](../README.md#tests).
