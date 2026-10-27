# Silent Snip Audio: settings and actions in the effect window

Add **Silent Snip Audio** from the Effects browser and open its **Controls** window in Final Cut. The window contains four detection settings and **Analyze**, followed by a separate review section and **Apply Cuts** button. Configure the required Share destination once using [first-time setup](../docs/setup.md). Normal Analyze/Apply use does not require manually sharing or choosing an export method.

Controls is now the only Silent Snip window. The background helper retains analysis state but creates no review window. If Final Cut recreates Controls during rendering, the new view reconnects through a helper check of its unique native control, original project, and selected clip. Cancel appears in Controls when available; **More… → Verify Existing Result…** handles saved results. Both matching builds are required. Offline checks cover the protocol and layout; live host reconnection and visible preview remain for the user to verify.

**Current source:** see [the workflow](../docs/workflow.md). Analyze supports source decoding and verified isolated rendering. Apply replaces the current project through XML in its original event, saves recovery XML first, and verifies the host re-export. See [replacement validation](../docs/xml-replacement.md). The Controls window supports per-cut selection, safe retries of the same Apply request, timeout recovery, and restoration from `Analysis-Settings.json`. The current build still needs live verification; historical button tests are not proof of this revision.

The [current cleanup update](../docs/cleanup-fixes.md) also fixes dropped Retry Verification and preview commands, separates connection state from this view, and validates behavior with independent test scenarios. That update recorded staged helper and plug-in candidates; current-build live testing remains outstanding.

## Window and sidebar

The extension uses `com.apple.AudioUnit-UI` and `SilentSnipAudioUnitFactory`, an `AUViewController` implementing `AUAudioUnitFactory`. Final Cut hosts it in the effect's Controls window. The current request supersedes the earlier sidebar-only requirement.

The native AppKit inspector starts with Detection: all four settings, Output, Save Settings, and More remain visible. The large product heading and introductory block are removed; status is a small footer item. Review and its table appear only when analysis returns ranges, and stay available when every range is deselected. At 580 points wide, the preferred height is 220 points before analysis and about 400 points for a two-range review; hosts that keep a fixed window size can scroll the inspector. Output remains a standard pop-up menu. Before/after duration stays beside the Review heading, and each row combines the start and end timecodes with its duration. Restricted ranges retain an explanation below their timecodes.

**Analyze Again** stays beside the separate **Apply** button during review. Cancel and Retry Verification appear when relevant. Successful analysis has a short status; **More… → Analysis Details…** retains the complete explanation. Errors open a native alert sheet; the inspector retains a short status and **More… → Error Details…** reopens the complete message. Repeated status packets do not repeat the same alert. Long messages scroll inside the alert. **More…** also provides cut navigation, bulk selection, Restore Saved Settings, and Verify Existing Result. Common decimals display as `0.1` without changing stored Float32 values. Automatic settings recovery continues to use the original visible fields and Save button.

The factory harness and staged plug-in build pass, including long-notice layout, menu availability, settings precision, and existing analysis/review behavior. The combined app's Controls opened inside Final Cut and retained saved values across closing/reopening the window. The complete Analyze → Apply workflow remains unverified after the sandbox-safe containing-app launch fix; offline checks do not establish automatic timeline cuts. The staged extension is at `build/Candidate/AudioPlugin/SilentSnipAudio.appex`; `Scripts/build-app.sh` embeds it into the containing app.

- The host-facing `parameterTree` is empty. The four settings live in Silent Snip's private `analysisParameterTree` and are edited only in the window.
- Controls requests that its window center each time the view appears. Placement in Final Cut's hosted window still needs live verification.
- Final Cut may retain an empty **Parameters** heading; it supplies that heading itself.
- Final Cut caches the old parameter layout on existing effect instances. A newly added instance has no setting fields in the sidebar. Reapplying an old instance is a one-time migration; note its window settings first, because the new instance inherits last-used settings rather than the removed instance's individual settings.
- Stable parameter IDs and Apple's AU state serialization are retained through an internal, non-rendering state codec. The codec is not a second installed effect. Legacy native Final Cut state restores in tests with identical data bytes.
- Settings edits immediately disable Apply. Analyze validates all four values and sends an immutable request. Analyze never sends Apply automatically.
- Preview guidelines stay visible during review. Closing the Controls window leaves the preview active. Apply or cancellation clears the preview. Removing Silent Snip from the selected clip’s Audio Inspector also clears its preview; Analyze again after restoring or re-adding it. Lines remain tied to the verified clip and the visible Final Cut project window. Switching app focus keeps uncovered lines visible; macOS composites windows above the project naturally; Silent Snip no longer treats their rectangles as opaque masks. The overlay also clips to the timeline scroll area, excluding the docked Effects and Transitions browsers.
- Preview lines and labels reuse vector layers. Repeated Final Cut geometry reads run on a serial background worker, with notification wakeups, fallback polling, and stale-result rejection. Normal operation generates no preview diagnostic images or logs.
- Apply is a distinct button below the review area. It requires an included eligible cut, a `review` result with `canApply`, unchanged settings, and a fresh unconsumed plan. Duplicate or older responses cannot apply a plan twice or end a pending Apply.

Apple documents [custom Audio Unit views](https://developer.apple.com/documentation/audiotoolbox/auaudiounitfactory) and [opening audio-effect windows in Final Cut](https://support.apple.com/guide/final-cut-pro/adjust-audio-effects-verb71ca9ce/mac).

Final Cut may add its own plug-in name and surrounding controls outside the custom view. Silent Snip does not draw a second product-name footer. The documented Audio Unit view-configuration API describes host-provided control surfaces; no Final Cut footer-hide option was found. See [Apple’s view configuration reference](https://developer.apple.com/documentation/coreaudiokit/auaudiounitviewconfiguration).

## Build and verify

Install both matching components. Quit Final Cut Pro and the helper before running the build/registration commands; see [setup and prerequisites](../docs/setup.md). The test harnesses run offline.

```sh
Scripts/build.sh --release
AudioPlugin/test-audio.sh
AudioPlugin/test-factory.sh
Scripts/register-local.sh --check-only
auval -v aufx ctdn Ctdn
```

Project: `SilentSnipAudio.xcodeproj`, scheme **SilentSnipAudio**, now builds only **SilentSnipAudio**. `Scripts/build-app.sh` combines the Release extension with the existing background executable and Share definitions into `build/App/Silent Snip.app`; the ZIP is `dist/Silent Snip.zip`. The former empty wrapper target has been removed. The extension remains sandboxed; the containing app performs the existing Final Cut integration outside that sandbox. Both target Apple Silicon and macOS 14 or later. Build-script defaults use local ad hoc signing; a deployment target alone is not a toolchain or host compatibility claim.

For a developer-only native UI preview, run `AudioPlugin/preview-ui.sh --build-only`, then open `build/NativePreview/Silent Snip UI Preview.app`. Its app menu provides review, restricted-range, long-list, failure, and progress fixtures, plus light/dark appearance. The preview uses the actual AppKit controller with an inert transport and a private temporary settings store; it cannot send timeline commands. It is excluded from the distributed app.

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

- Containing app ID: `local.silentsnip.app`; extension ID: `local.silentsnip.app.audio`.
- Component type/subtype/manufacturer: `aufx / ctdn / Ctdn`.
- The AU passes mono/stereo Float32 audio through unchanged, with zero latency and tail.
- Rendering, window creation, and state restoration never initiate processing or timeline edits.
- Private settings serialize in `fullState` and `fullStateForDocument`. New instances use last-used settings saved after submitting Analyze; existing state restoration does not change those defaults.

`InteractiveAudioSession` connects this window to capture, analysis, review, and verified XML Apply. `AudioProjectProcessor` provides the separate offline artifact-processing API. Detection is level-based; no speech/breath classifier is implemented.

## Known import limitation

The earlier September 15 FCPXML import test produced the correct three audio segments, but Final Cut discarded copied effect parameter/state payloads. Generated results now embed the submitted settings and report host retention separately. If the host discards state, the helper now restores affected imported segments through their exact Controls windows and verifies another host export. **Save Settings** commits values without Analyze. **More… → Restore Saved Settings…** remains a manual fallback. This recovery path is implemented and tested with injected host captures; live native persistence still needs validation. Native document-state persistence is not proof of XML-import settings retention. See the root README for backend and import evidence.

Historical XML-only Media Asset Protocol checks reported live Analyze and Apply success; see [integration history](../docs/integration-history.md). The referenced `build/ProgrammaticVerification/` artifacts are not included in Git, and those results do not verify the current build. The configured Silent Snip Share destination is initiated and confirmed automatically. File paths, XML delivery, audio decoding, output creation, and result import are programmatic.

### Output mode

Choose **Remove Silence** or **Replace with 1-Second Gaps** in the effect window before Analyze. Gap mode replaces each included quiet range with an editable one-second gap; the resulting duration is shown in review. Changing the mode requires Analyze again. Apply remains a separate button. One second is rounded to the nearest project frame at fractional frame rates.

## Verification recovery and cut navigation

**Go to Cut** moves to the selected review row’s start after checking the original timeline. Inclusion choices remain unchanged.

**Retry Verification** appears after a recoverable post-import failure. It never resends XML. **More… → Verify Existing Result…** in Controls can resume after restart or adopt an older result with matching saved artifacts. Both operations use the existing result; settings recovery is restricted to that separately named imported project. Matching staged helper and plugin builds are required for these additions; no live validation is claimed.
