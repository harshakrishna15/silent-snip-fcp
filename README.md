# Silent Snip

Remove quiet pauses from clips in Final Cut Pro. Review each proposed cut, choose what to keep, and create a cleaned copy of your project. The original project and source media stay unchanged.

Open Silent Snip from **Window → Extensions → Silent Snip**. No Silent Snip audio effect is needed on the clip.

## Requirements

- Apple Silicon Mac.
- macOS 14 or later. Your versions of Xcode and Final Cut may require a newer system.
- Final Cut Pro with its interface set to English.

## Get started

1. Install **Silent Snip.pkg** to put both apps in `~/Applications`. If you keep an existing copy elsewhere, use **Silent Snip.zip** to replace both apps in that folder.
2. Follow [first-time setup](docs/setup.md) to open the apps, grant access, and add the **Silent Snip** Share destination.
3. In Final Cut, select one supported clip with audio and choose **Window → Extensions → Silent Snip**.
4. Set detection and output, then click **Analyze Audio**.
5. Review the cuts and click **Apply Cuts**. Silent Snip creates a separate cleaned project in the original event.

Keep Final Cut in front during analysis and Apply. Silent Snip uses its visible Share panels and project controls.

## What you can do

- Remove selected pauses or replace them with one-second gaps.
- Set **Target Pause** to shorten long pauses while keeping some original room tone.
- Review cuts in a list and on the timeline, adjust individual boundaries, and keep or cut groups of pauses.
- Audition the original and proposed cut on plain source audio.
- Analyze a selected range within one clip.
- Change detection settings after analysis to refresh eligible cut ranges without another audio export.

Changes to volume, audio effects, media, or timeline content require **Analyze Again**. Applying cuts is always a separate action. See the [workflow guide](docs/workflow.md) for settings and controls.

## Supported clips and effects

Select one normal-speed clip in the primary storyline with enabled audio and available source media. Audio-only clips and linked camera audio/video are supported within the [editing limits](docs/workflow.md#supported-clips). Split audio/video edits, retimed clips, compounds, and multicam targets are outside this scope.

Clips with audio effects need a narrower layout: one audio-only clip filling the project, with static effects applied directly to it. Silent Snip transfers those effects in Final Cut so their controls remain editable. Unsupported effect layouts stop the operation.

Detection uses loudness, so quiet breaths can be marked as silence. Listen around the joins before finishing your edit. Delays and other effects with memory can sound different at new cut boundaries.

## Build from source

Install full Xcode and Apple's Workflow Extensions SDK, then quit Final Cut and both Silent Snip apps. From the repository root, run:

```sh
Scripts/build-app.sh
Scripts/build-installer.sh
```

The apps are packaged in `dist/Silent Snip.zip` and `dist/Silent Snip.pkg`. Local apps use ad hoc signing, and the installer is unsigned. See [development](docs/development.md) for prerequisites, build options, and source layout.

## Documentation

| Guide | Contents |
| --- | --- |
| [Setup](docs/setup.md) | Install, permissions, Share destination, upgrades, and uninstall |
| [Workflow](docs/workflow.md) | Clip selection, detection settings, review, and Apply |
| [Recovery](docs/recovery.md) | Interrupted operations, saved results, and troubleshooting |
| [Storage](docs/storage-cleanup.md) | Automatic cleanup and files to keep |
| [Development](docs/development.md) | Builds, local registration, and Final Cut test fixtures |
| [Architecture](docs/architecture.md) | App components, audio capture, caching, and output |

The [legacy Audio Unit notes](AudioPlugin/README.md) cover the earlier effect interface. They are separate from the current Workflow extension.
