# Legacy Silent Snip Audio effect

The current app uses **Window → Extensions → Silent Snip** and does not require an audio effect. Use the [setup guide](../docs/setup.md) and [workflow guide](../docs/workflow.md) for that interface.

This directory retains the earlier sandboxed Audio Unit, its native Controls window, and review connection code shared with the Workflow frontend.

## Legacy interface

Older installations expose **Silent Snip Audio** in Final Cut's Effects browser. Its Controls window contains detection settings, output, Analyze, review, and Apply. **Update Cuts**, when available, recalculates from retained measurements; changed source media, volume, or processing requires a new Analyze.

The effect passes mono/stereo Float32 audio through unchanged, with zero latency and tail. Rendering, opening the window, and restoring state do not initiate analysis or timeline edits. The containing worker performs the Final Cut integration outside the Audio Unit sandbox.

| Setting | Parameter address | Default |
| --- | --- | --- |
| Silence Threshold | 1 | −40 dBFS |
| Minimum Silence | 2 | 0.5 s |
| Before Speech | 3 | 0.1 s |
| After Speech | 4 | 0.1 s |

The component identifiers are `aufx / ctdn / Ctdn`; the extension bundle ID is `local.silentsnip.app.audio`. Settings serialize through `fullState` and `fullStateForDocument`. Main-thread document-state notifications allow Final Cut to archive native parameter edits.

## Build the legacy extension

With [development prerequisites](../docs/development.md#prerequisites) installed and Final Cut closed:

```sh
Scripts/build-audio-plugin.sh
```

This builds `build/Candidate/AudioPlugin/SilentSnipAudio.appex` from the **SilentSnipAudio** scheme. It does not install or register the effect. The default app build packages the Workflow frontend and an AU-free worker; it does not embed this candidate.

## Existing projects and results

Updating the apps does not remove saved legacy effect instances. Remove an instance in Final Cut when it is no longer needed.

Older processed-audio results may reference `Processed Audio/<request UUID>/Processed-Audio.wav` under the worker's application-support directory. Keep that file while the project uses it. Those results contain rendered sound; return to the original project to change the processing effects.

Final Cut can omit effect settings from XML imports. Legacy detector recovery writes the four settings only to verified imported occurrences, then checks a fresh host export. Native numeric fields preserve precision better than sliders. Keep the original native project as the complete effect-state backup.

See [recovery](../docs/recovery.md), [storage](../docs/storage-cleanup.md), and [the review protocol](REVIEW_PROTOCOL.md) for related behavior.
