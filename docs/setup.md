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

Quit Final Cut Pro and any running Cutdown helper, then run:

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

## Grant macOS access

Launch the installed helper once:

```sh
open "$PWD/build/Cutdown.app"
```

The helper runs in the background; its lack of a separate window is expected. Its launch code requests access to control Final Cut. Enable **Cutdown** in System Settings → Privacy & Security → Accessibility, or the control-access pane named in Cutdown's error on your macOS version. The current code names that pane **Device Control and Data Access** on macOS 27.

Use the installed helper, not `build/Candidate/Cutdown.app`. If a rebuild leaves a previously granted helper reporting missing access, quit and relaunch it first. If necessary, remove its stale permission entry and add the current `build/Cutdown.app`. Ad hoc rebuilds can change the app's signing identity.

## Create the Cutdown Share destination

Reopen Final Cut after registering the apps. A destination must be configured once on each Mac; it is not included in a Git checkout.

1. Choose **Final Cut Pro → Settings → Destinations → Add Destination** and add an **Export File** destination. Rename it **Cutdown**. Apple documents adding and renaming destinations in [Create share destinations](https://support.apple.com/guide/final-cut-pro/ver9fd008a21/mac).
2. Set **Format** to **Audio Only** and **Audio Format** to **WAV**. Under **Action**, choose **Other…**, select this checkout's `build/Cutdown.app`, and confirm. See Apple's [Export File destination settings](https://support.apple.com/guide/final-cut-pro/ver13664388c/mac).
3. Confirm **Cutdown…** appears under **File → Share**. The exact name matters: the helper looks up that menu item and the matching confirmation panel.

This combines Apple's documented destination controls with Cutdown's source requirements. A fresh-machine setup using these steps still needs live verification. The registered helper declares Apple's [Media Asset Protocol](https://developer.apple.com/documentation/professional-video-applications/receiving-media-and-data-through-a-custom-share-destination) so Final Cut can deliver XML and requested media. During an analysis, Cutdown requests XML alone or configures the isolated audio render automatically. Normal use starts from **Analyze** in the effect's Controls window; there is no manual export step for each analysis.

## Integration-test library

Every live test must run only in **Cutdown Integration.fcpbundle** at the repository root. Reuse it if it already exists. On a fresh checkout, create a new empty Final Cut library with that exact name and location before testing. Do not use another library or a real editing project. Libraries are deliberately ignored by Git.

Install FFmpeg and Python 3 if you want to generate the test media, then run:

```sh
ffmpeg -version
python3 --version
Scripts/make-fixtures.sh
```

The script writes generated WAV files, FCPXML bundles, and expected-results JSON under `build/Fixtures`. Its XML validation currently expects Final Cut at `/Applications/Final Cut Pro.app` with the FCPXML 1.14 DTD. A missing DTD is an environment/setup issue to resolve before relying on that validation.

With the integration library open, import `build/Fixtures/Cutdown Audio Only Basic.fcpxmld` into that library. Keep source files in place; disable copied, optimized, and proxy media. Use a fresh disposable test project for each run. The sanitized files under `Tests/CutdownCoreTests/Fixtures` use placeholder media URLs for offline regression tests; use the generated `build/Fixtures` files for live imports.

Follow [the workflow](workflow.md) to add Cutdown Audio, open Controls, Analyze, review, and Apply. Check the resulting project's editable segments, source references, effects/settings, and total duration, as well as whether preview and recovery work. Merely seeing the effect or passing analysis is not evidence that automatic cuts work. Preserve exported evidence separately from build caches.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Build cannot inspect processes | Run from a Terminal with process-list access. The scripts intentionally stop when they cannot check whether an app is running. |
| Xcode fails while creating debug symbols | Check the build environment's filesystem/process permissions; record any sandbox failure separately from a normal Terminal retry. |
| Cutdown Audio is missing or unresponsive | Quit Final Cut, rebuild both apps, rerun registration, then reopen it. Xcode may have registered a staged audio candidate. |
| Analyze cannot open Share | Confirm the destination is named exactly `Cutdown`, targets the installed helper, and Final Cut is using English labels. Close other dialogs. |
| The helper reports missing access | Follow the macOS access steps above, including restarting the helper after a rebuild. |
| Effect appears but Analyze cannot connect | Confirm both matching components are installed. A staged helper has a different identity and omits live URL/Share registration. |
| Imported Cutdown settings differ | Follow [settings recovery](workflow.md), including Retry Verification or Restore Saved Settings; don't infer settings retention from successful XML import. |

For discovery diagnostics after installation, run `Scripts/register-local.sh --check-only`. `auval -v aufx ctdn Ctdn` can additionally check the registered Audio Unit; it does not verify Final Cut timeline editing. Full offline test commands are in the [README](../README.md#tests).
