# Cutdown Audio: settings and actions in the effect window

Add **Cutdown Audio** from the Effects browser and open its **Controls** window in Final Cut. The window contains four detection settings and **Analyze**, followed by a separate review section and **Apply Cuts** button. Configure the required Share destination once using [first-time setup](../docs/setup.md). Normal Analyze/Apply use does not require manually sharing or choosing an export method.

Controls is now the only Cutdown window. The background helper retains analysis state but creates no review window. If Final Cut recreates Controls during rendering, the new view reconnects through a helper check of its unique native control, original project, and selected clip. Cancel appears in Controls when available; **More… → Verify Existing Result…** handles saved results. Both matching builds are required. Offline checks cover the protocol and layout; live host reconnection and visible preview remain for the user to verify.

**Current source:** see [the workflow](../docs/workflow.md). Analyze supports source decoding and verified isolated rendering. Apply replaces the current project through XML in its original event, saves recovery XML first, and verifies the host re-export. See [replacement validation](../docs/xml-replacement.md). The Controls window supports per-cut selection, safe retries of the same Apply request, timeout recovery, and restoration from `Analysis-Settings.json`. The current build still needs live verification; historical button tests are not proof of this revision.

The [current cleanup update](../docs/cleanup-fixes.md) also fixes dropped Retry Verification and preview commands, separates connection state from this view, and validates behavior with independent test scenarios. That update recorded staged helper and plug-in candidates; current-build live testing remains outstanding.

## Window and sidebar

The extension uses `com.apple.AudioUnit-UI` and `CutdownAudioUnitFactory`, an `AUViewController` implementing `AUAudioUnitFactory`. Final Cut hosts it in the effect's Controls window. The current request supersedes the earlier sidebar-only requirement.

The compact window requests 520 × 560 points. All settings, progress, review, and Apply controls stay in this one hosted window. Detection fields and Output share an aligned label column; Save Settings sits beside the Detection heading, with Analyze aligned to the right below the settings. **More…** contains Restore Saved Settings and Verify Existing Result. Review uses the remaining space, with one compact Include / Show Preview / Go to Cut toolbar that appears when cuts exist. Apply stays at the bottom right; Cancel and Retry Verification appear only when relevant. Common decimals display as `0.1` without changing the stored Float32 value.

The factory harness and staged plug-in build pass, including long-notice layout, menu availability, settings precision, and existing analysis/review behavior. This layout has not been verified live inside Final Cut; these checks do not establish automatic timeline cuts. The staged candidate is at `build/Candidate/AudioPlugin/CutdownAudio.app`; use the documented build/registration steps with Final Cut closed to install it.

- The host-facing `parameterTree` is empty. The four settings live in Cutdown's private `analysisParameterTree` and are edited only in the window.
- Controls requests that its window center each time the view appears. Placement in Final Cut's hosted window still needs live verification.
- Final Cut may retain an empty **Parameters** heading; it supplies that heading itself.
- Final Cut caches the old parameter layout on existing effect instances. A newly added instance has no setting fields in the sidebar. Reapplying an old instance is a one-time migration; note its window settings first, because the new instance inherits last-used settings rather than the removed instance's individual settings.
- Stable parameter IDs and Apple's AU state serialization are retained through an internal, non-rendering state codec. The codec is not a second installed effect. Legacy native Final Cut state restores in tests with identical data bytes.
- Settings edits immediately disable Apply. Analyze validates all four values and sends an immutable request. Analyze never sends Apply automatically.
- **Show Preview** hides or restores the timeline lines without discarding analysis. Analyze turns it on. Closing the Controls window leaves the preview active; uncheck it to dismiss the lines. Apply or cancellation clears the preview. Removing Cutdown from the selected clip’s Audio Inspector also clears its preview; Analyze again after restoring or re-adding it. Lines remain tied to the verified clip and the visible Final Cut project window. Switching app focus keeps uncovered lines visible; macOS composites windows above the project naturally; Cutdown no longer treats their rectangles as opaque masks. The overlay also clips to the timeline scroll area, excluding the docked Effects and Transitions browsers.
- Preview lines and labels reuse vector layers. Repeated Final Cut geometry reads run on a serial background worker, with notification wakeups, fallback polling, and stale-result rejection. Normal operation generates no preview diagnostic images or logs.
- Apply is a distinct button below the review area. It requires an included eligible cut, a `review` result with `canApply`, unchanged settings, and a fresh unconsumed plan. Duplicate or older responses cannot apply a plan twice or end a pending Apply.

Apple documents [custom Audio Unit views](https://developer.apple.com/documentation/audiotoolbox/auaudiounitfactory) and [opening audio-effect windows in Final Cut](https://support.apple.com/guide/final-cut-pro/adjust-audio-effects-verb71ca9ce/mac).

## Build and verify

Install both matching components. Quit Final Cut Pro and the helper before running the build/registration commands; see [setup and prerequisites](../docs/setup.md). The test harnesses run offline.

```sh
Scripts/build-helper.sh --release
Scripts/build-audio-plugin.sh
AudioPlugin/test-audio.sh
AudioPlugin/test-factory.sh
Scripts/register-local.sh --check-only
# With Final Cut closed:
Scripts/register-local.sh
auval -v aufx ctdn Ctdn
```

Project: `CutdownAudio.xcodeproj`, scheme **CutdownAudio**. Product: `build/AudioPlugin/Build/Products/Debug/CutdownAudio.app`, containing `Contents/PlugIns/CutdownAudioExtension.appex`. The project uses the native macOS SDK, targets Apple Silicon and macOS 14 or later, and defaults to local ad hoc signing. The audio build script selects the Debug configuration. The copied source was built with Xcode 27.0; the deployment target is not a compatibility claim for every toolchain or Final Cut version. Registration checks the UI extension point and current factory.

The render harness checks 60 passthrough cases and persistence. The custom-view harness checks private controls, legacy state compatibility, invalid input rejection, distinct button actions, and stale-result/replay protection. The test launcher and command sender are overridden, and the settings file is temporary; it does not launch the real helper or edit timelines.

Earlier window-only verification confirmed that a window threshold edit survived a full Final Cut restart. The helper returned its current unavailable status, and Apply remained disabled. The test value was restored afterward.

Live verification uses small disposable projects inside the workspace `Cutdown Integration.fcpbundle`; a fresh checkout must first follow [test-library setup](../docs/setup.md#integration-test-library). Historical evidence paths such as `build/audio-window-*.log` and `build/audio-window-verification.json` refer to local artifacts, which are not included in Git. Offline or interface tests do not establish automatic timeline cuts.

## Settings and processing

| Setting | Private address | Default |
|---|---|---|
| Silence Threshold | 1 | −40 dBFS |
| Minimum Silence | 2 | 0.5 seconds |
| Before Speech | 3 | 0.1 seconds |
| After Speech | 4 | 0.1 seconds |

- Wrapper ID: `local.cutdown.audio`; extension ID: `local.cutdown.audio.extension`.
- Component type/subtype/manufacturer: `aufx / ctdn / Ctdn`.
- The AU passes mono/stereo Float32 audio through unchanged, with zero latency and tail.
- Rendering, window creation, and state restoration never initiate processing or timeline edits.
- Private settings serialize in `fullState` and `fullStateForDocument`. New instances use last-used settings saved after submitting Analyze; existing state restoration does not change those defaults.

`InteractiveAudioSession` connects this window to capture, analysis, review, and verified XML Apply. `AudioProjectProcessor` provides the separate offline artifact-processing API. Detection is level-based; no speech/breath classifier is implemented.

## Known import limitation

The earlier September 15 FCPXML import test produced the correct three audio segments, but Final Cut discarded copied effect parameter/state payloads. Generated results now embed the submitted settings and report host retention separately. If the host discards state, the helper now restores affected imported segments through their exact Controls windows and verifies another host export. **Save Settings** commits values without Analyze. **More… → Restore Saved Settings…** remains a manual fallback. This recovery path is implemented and tested with injected host captures; live native persistence still needs validation. Native document-state persistence is not proof of XML-import settings retention. See the root README for backend and import evidence.

Historical XML-only Media Asset Protocol checks reported live Analyze and Apply success; see [integration history](../docs/integration-history.md). The referenced `build/ProgrammaticVerification/` artifacts are not included in Git, and those results do not verify the current build. The configured Cutdown Share destination is initiated and confirmed automatically. File paths, XML delivery, audio decoding, output creation, and result import are programmatic.

### Output mode

Choose **Remove Silence** or **Replace with 1-Second Gaps** in the effect window before Analyze. Gap mode replaces each included quiet range with an editable one-second gap; the resulting duration is shown in review. Changing the mode requires Analyze again. Apply remains a separate button. One second is rounded to the nearest project frame at fractional frame rates.

## Verification recovery and cut navigation

**Go to Cut** moves to the selected review row’s start after checking the original timeline. Inclusion choices remain unchanged.

**Retry Verification** appears after a recoverable post-import failure. It never resends XML. **More… → Verify Existing Result…** in Controls can resume after restart or adopt an older result with matching saved artifacts. Both operations use the existing result; settings recovery is restricted to that separately named imported project. Matching staged helper and plugin builds are required for these additions; no live validation is claimed.
