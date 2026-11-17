# Install and setup

## Install the apps

1. Quit Final Cut Pro and both Silent Snip apps before installing or updating.
2. Open **Silent Snip.pkg** and follow the Installer prompts. It installs **Silent Snip.app** and **Silent Snip Workflow Prototype.app** in `~/Applications`.
3. Open both apps once. In the Workflow app's instructions window, choose **Done**.

To open `~/Applications` in Finder, press **Command–Shift–G** and enter that path.

If your existing apps are in `/Applications` or another folder, extract **Silent Snip.zip** and replace both apps at their existing paths. Keep one active copy of each, in the same folder. This keeps Final Cut's Share action pointed at the right worker.

The local installer is unsigned, and the apps use ad hoc signing by default. macOS may block downloaded copies.

**Silent Snip.app** runs in the background without a Dock or menu bar icon. The other app provides the interface under **Window → Extensions → Silent Snip** in Final Cut. Its filename still includes “Workflow Prototype.” Opening the extension starts the worker when needed; the worker quits after Final Cut closes and cleanup finishes.

## Grant access

- **Worker control access:** in **System Settings → Privacy & Security → Device Control and Data Access**, enable the installed **Silent Snip.app**. Earlier macOS versions call this setting **Accessibility**.
- **Frontend Automation access:** open **Window → Extensions → Silent Snip** in Final Cut, click **Connect to Final Cut Pro** if shown, and approve its Automation request.

Grant access to the installed worker, or to `build/App/Silent Snip.app` for an in-place developer build. A staged candidate cannot handle the live workflow. Rebuilding an ad hoc signed worker can leave its existing access entry stale; quit and reopen it, then refresh that entry if access still fails.

## Add the Share destination

Configure this once per Mac:

1. Open **Final Cut Pro → Settings → Destinations**.
2. Add an **Export File** destination and name it **Silent Snip**.
3. Set **Format → Audio Only** and **Audio Format → WAV**.
4. Set **Action → Other…** to the same installed **Silent Snip.app** that has control access. For an in-place developer build, use `build/App/Silent Snip.app`.
5. Confirm **Silent Snip…** appears under **File → Share**.

Use the exact destination name. The Share action must point to the worker, **Silent Snip.app**.

Start normal work with **Analyze Audio** in the extension. Silent Snip handles Share automatically; you do not need to export XML yourself. Keep Final Cut in front while its Share panels, navigation, and import are being automated.

## First edit

Select a supported clip, open **Window → Extensions → Silent Snip**, and click **Analyze Audio**. Review the proposed cuts, then choose **Apply Cuts** to create a cleaned copy. Follow the [workflow guide](workflow.md) for settings and review controls.

## Upgrade from the audio-effect version

Replace both apps with Final Cut closed, then open both once. Keep the Share destination pointing at the same worker path and refresh its control-access entry if needed.

The current worker does not embed or require **Silent Snip Audio**. Installation leaves existing projects and saved effect instances alone. Remove an old Silent Snip effect in Final Cut when you no longer need it.

Enter detection settings in the Workflow extension; old Audio Unit settings are not copied into it. Use **Save Settings** to store values for the current project. Keep original media, saved results, recovery files, and any legacy processed audio. See [storage](storage-cleanup.md).

## Build from source

See [development](development.md) for Xcode and SDK requirements, build commands, and local registration.

## Integration-test library

Run every live Final Cut test in **Cutdown Integration.fcpbundle** at the repository root. Reuse an existing library at that exact path without replacing it.

On a fresh checkout:

1. In Final Cut, choose **File → New → Library**.
2. Save an empty library as **Cutdown Integration.fcpbundle** at the repository root.
3. Create a small disposable event/project inside it and reference generated source media in place.

Disable copied, optimized, and proxy media for these fixtures. Do not substitute another library or test in a real editing project. See [development](development.md#live-final-cut-tests) for the test procedure.

## Uninstall

1. Remove the **Silent Snip** destination in **Final Cut Pro → Settings → Destinations**.
2. Quit Final Cut and both apps, then move **Silent Snip.app** and **Silent Snip Workflow Prototype.app** to Trash.
3. Remove their control-access and Automation entries in System Settings if listed. Remove older app copies separately.

Uninstalling keeps settings, saved results, recovery XML, and media. It does not undo cuts. If you still use the legacy audio effect, remove its project instances before removing the old app that supplies it.

For repository builds, preview removal with:

```sh
Scripts/uninstall-local.sh --dry-run
```

`Scripts/uninstall-local.sh` removes known app bundles inside the checkout. Adding `--remove-data` also erases known settings, saved result reports, and recovery XML, while preserving durable **Processed Audio**. It leaves app copies outside the checkout, libraries, source media, build caches, and exported evidence in place. Protected container data may need manual removal in Finder.

Keep **Processed Audio** while any Final Cut project references it. See [storage locations and cleanup](storage-cleanup.md) and [troubleshooting](recovery.md#troubleshooting).
