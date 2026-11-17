# Development

Run commands from the repository root on an Apple Silicon Mac.

## Prerequisites

- Full Xcode, with first-launch components and license setup complete. Command Line Tools alone are insufficient.
- Xcode selected under **Xcode → Settings → Locations → Command Line Tools**.
- Apple's Workflow Extensions SDK at `/Library/Developer/SDKs/WorkflowExtensionSDK.sdk`, or another installed path set with `SILENT_SNIP_WORKFLOW_SDK`.
- Python 3 for the package checker.
- Final Cut Pro in English for live integration work.

The deployment target is macOS 14. Xcode and Final Cut may require a newer system. The Swift package has no external dependencies.

Check the selected toolchain with:

```sh
xcode-select -p
xcodebuild -version
```

## Build the app pair

Quit Final Cut and both Silent Snip apps before publishing or registering a build.

```sh
Scripts/build-app.sh
Scripts/build-installer.sh
```

| Output | Contents |
| --- | --- |
| `build/App/Silent Snip.app` | Background worker and Share receiver |
| `build/WorkflowPrototype/Products/Silent Snip Workflow Prototype.app` | Frontend app with its nested Workflow extension |
| `dist/Silent Snip.zip` | Both complete apps in a `Silent Snip` folder |
| `dist/Silent Snip.pkg` | Installer for the app pair from the ZIP, targeting `~/Applications` |

The scripts check package compatibility and signatures and refuse to replace running apps. Local app signing defaults to ad hoc; the installer is unsigned. `SILENT_SNIP_SIGNING_IDENTITY` and `SILENT_SNIP_DEVELOPMENT_TEAM` select existing developer signing settings.

Follow [setup](setup.md) to install the apps and configure permissions and Share. Keep registered bundles in place, including the frontend's nested extension.

## In-place builds

| Command | Action |
| --- | --- |
| `Scripts/build.sh` | Build a Debug worker and Release frontend, package them, and register the pair |
| `Scripts/build.sh --release` | Use Release for both components and register them |
| `Scripts/build.sh --stage` | Build only an inert worker at `build/Candidate/App/Silent Snip.app` |
| `Scripts/register-local.sh --check-only` | Check the default app pair without changing registrations |

A staged candidate has no live Share, URL, document, or Workflow routes. It does not replace the published apps, ZIP, or registrations and is not distributable.

To check copied apps:

```sh
Scripts/register-local.sh --check-only \
  --app "/absolute/path/Silent Snip.app" \
  --frontend "/absolute/path/Silent Snip Workflow Prototype.app"
```

Omit `--check-only` to register that exact pair while Final Cut is closed. Registration retires known old local Audio Unit registrations without deleting their bundles or modifying libraries.

Reuse `build/swift` for sequential Swift builds. Remove redundant generated caches only when no process is using them. Preserve source media, exported integration evidence, and registered app bundles.

## Live Final Cut tests

Use only the workspace-root **Cutdown Integration.fcpbundle**. Reuse it without replacement, or create an empty library at that exact path using [test-library setup](setup.md#integration-test-library). Never use the user's other libraries or projects.

Create small disposable projects and reference generated media in place. Disable copied, optimized, and proxy media. Exercise the [normal workflow](workflow.md), including:

- Analyze, review, and Apply for removal and gap output.
- Range-limited analysis, settings updates, selection, navigation, boundary edits, and cancellation.
- Supported effects, stale-review rejection, and saved-result recovery after restart without reimport.
- The actual saved timeline: retained source intervals, duration, linked video, supported connections, effects, and unchanged originals.

An extension opening or analysis completing does not establish that automatic cuts work. Check the generated project in Final Cut; compare exported audio separately when assessing sound at cut boundaries. Keep generated media and exported evidence when cleaning build caches.

## Source layout

| Path | Purpose |
| --- | --- |
| `Sources/SilentSnipCore/` | Time arithmetic, timeline parsing, detection, and review rules |
| `Sources/SilentSnipMac/` | Final Cut integration, audio capture, XML output, preview, and recovery |
| `Sources/SilentSnipWorkflowModel/` | Workflow settings and model |
| `Sources/SilentSnipApp/` | Background worker executable |
| `Sources/SilentSnipVerify/` | Offline artifact verifier; does not import projects |
| `WorkflowPrototype/` | Current frontend, project settings, and review clients |
| `AudioPlugin/` | Legacy Audio Unit and shared review connection code |
| `Scripts/` | Build, packaging, registration, uninstall, and icon tools |
| `Config/` | App metadata, Share definitions, signing, and installer resources |

See [architecture](architecture.md) for the data flow, [the review protocol](../AudioPlugin/REVIEW_PROTOCOL.md) for transport details, and [icon resources](../WorkflowPrototype/Resources/README.md) for artwork generation.
