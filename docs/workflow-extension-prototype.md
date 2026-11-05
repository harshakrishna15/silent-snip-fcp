# Workflow Extension prototype

November 4, 2026. Branch: `codex/workflow-extension-prototype`.

**Milestone 2 is implemented and automated-tested; native Analyze → review → Apply verification is pending.** Workflow frontend **6** and diagnostic worker **50** are installed; candidate worker **51** adds the tested foreground-handoff policy described below. The Audio Unit remains **29**, with the same executable hash as build 47. The new frontend reaches the worker, but has not yet completed native analysis or cuts. The three-second complete-flow target remains unmet.

**Milestone 1 passed native validation in build 5** for the hosted window, project/library/playhead observation, independent per-project settings, restart/reopen persistence, and reachable controls. Its recorded checks below remain historical evidence; they did not run audio analysis, Share, or timeline edits.

## Milestone 2 checkpoint

Frontend 6 adds explicit **Analyze Audio**, cut review/selection, **Apply**, **Cancel**, and existing-result **Retry Verification** controls. It delegates processing to the existing `local.silentsnip.app` worker using workflow protocol **1**; the extension itself still uses the SDK only for inspection. Analyze sends the observed library/project identity and current settings. Apply requires a fresh native button gesture and worker checks of the selected clip and fresh project XML. Settings edits discard an idle review, busy temporary-project callbacks defer rebinding, and retryable imported results retain recovery instead of enabling another Apply.

Automated checks passed **633 Swift tests** (14 Workflow, 551 Mac, 68 Core; **three existing opt-in skips**, zero failures), **120 Python tests**, **22 controller groups / 331 assertions**, and **9 review-client groups / 83 assertions**. Coverage includes original-source analysis without an AU, preservation of different serialized AU settings, foreground-handoff boundaries, and rejected stale gestures. The controller/client harnesses use fake dependencies rather than live Final Cut, helper launches, distributed notifications, or settings files. These checks do not establish native audio fidelity, timeline cuts, or performance for the new frontend.

Native frontend 6 opens inside Final Cut with Analyze, Apply, and Cancel visible, connects to the SDK, and loads project B's saved settings. Analyze launches the compatible installed worker. The user authenticated System Settings and its existing **Device Control and Data Access** grant was refreshed for each rebuilt worker. Worker 50 diagnostics verify exactly one matching native window, the correct focused window, the fresh Analyze identifier, and a disabled pending button; Final Cut's foreground-PID check alone fails. Direct native coordinate clicking reproduces it before Share. Candidate worker 51 permits Final Cut or this exact worker process to own the foreground during URL handoff while keeping the other native/project/selection checks mandatory. Every other foreground process is rejected. That candidate still needs native validation. No successful native analysis, review, Apply, or PCM comparison has been recorded for this milestone yet.

`build/WorkflowPrototype/Milestone2/Package-Frontend6-Worker49.json` verifies the frontend and worker packages, including deep signatures. `Install-Frontend6-Worker49.json` records installed hash equality and preservation of the containing app-directory inodes, keeping the existing worker/Share receiver path. Build 47's prior installed contents are preserved as `Retired-Installed47.package`. The frontend adds no shortcut or Share destination and retains the existing SDK sandbox capability set. Native completion evidence will be recorded separately.

`Package-Frontend6-Worker50.json`, `Install-Frontend6-Worker50.json`, and `Native-Frontend6-Worker50-ForegroundFailure.json` retain the diagnostic deployment and exact native failure. `Swift-Tests-Worker51.log` and `Python-Tests-Worker51.log` record the latest automated pass. Prior native failures remain evidence and are not treated as completed analysis or cuts.

## Scope and host support

The prototype has its own containing-app identity, `local.silentsnip.workflowprototype`, and one Workflow Extension, `local.silentsnip.workflowprototype.extension`. The UI provides explicit **Connect**, the four detection settings, output mode, **Save Settings**, and the Analyze/review/Apply controls described above. Settings live in the extension's own sandbox and are keyed by the library URL and project UID. Repeated host observations should preserve an unsaved draft for the same project; switching projects must invalidate old pending work before another project's settings can be loaded or saved.

Apple's Workflow Extensions SDK **1.0.3 is installed** at `/Library/Developer/SDKs/WorkflowExtensionSDK.sdk`. The inspected Final Cut Pro 12.4, build 454072, includes Workflow Extension host metadata in `ProExtension.framework/Resources/Info.plist`. The SDK entry is `com.apple.FinalCut.WorkflowExtension`; its internal host declaration identifies `com.apple.proextension`, `ProExtensionHostContext`, and the view-service subsystem. This is installed-host metadata, not proof that this prototype loads or can obtain processed audio. Runtime access must use the public SDK interfaces.

The extension requests sandboxed `com.apple.FinalCut.library.inspection` access and the Automation entitlement needed to ask for macOS consent to connect to Final Cut. The scripting target remains exactly Final Cut's library-inspection group. **Connect** explicitly requests consent; only the user can approve a new Automation grant. The SDK entitlement permits inspection of project, library, and playhead; it adds no library-modification, accessibility, file, network, or additional app/group entitlement. The prototype bundle has no production Share, document, or URL receiver routes. Frontend 6 instead targets the existing compatible worker and its existing URL/Share integration for explicit processing requests.

The first native host connection returned Apple Event permission error `-1743` without an automatic consent prompt. The explicit, user-approved **Connect** action succeeded in build 3. Builds 4 and 5 retained the connection after rebuilding and reopening, without another Connect action or additional grant. These observations establish the tested connection; they do not assert particular macOS dialog handling. Any new Automation grant must still be approved by the user.

## Build and evidence

`Scripts/build-workflow-prototype.sh` builds the model with the shared `build/swift` cache and assembles `build/WorkflowPrototype/Products/Silent Snip Workflow Prototype.app`. It does not install or register that app. The worker at `build/App/Silent Snip.app` and `dist/Silent Snip.zip` remains a separate product. Frontend 6 requires the compatible worker 49; an inert staging bundle does not advertise the Workflow capability.

For a local developer build:

```sh
Scripts/build-workflow-prototype.sh
python3 Scripts/check-workflow-prototype.py \
  --app "build/WorkflowPrototype/Products/Silent Snip Workflow Prototype.app" \
  --output "build/WorkflowPrototype/Package-Verification-New.json"
```

Add `--worker "build/App/Silent Snip.app"` to check explicit worker metadata/signature compatibility too; this does not prove native sandbox access or processing. Choose a new report filename for each check; existing evidence is never overwritten. The checker accepts the installed prototype path too. It verifies exact identities, the SDK bootstrap entry point, inspection-only scripting targets with Automation consent, absence of Audio Unit/production routes and dynamic host-framework loads, and deep signatures. It does not launch, install, register, or test the host UI.

Quit Final Cut and the prototype before replacing a prototype copy. Move the **whole** generated app to `~/Applications/Silent Snip Workflow Prototype.app`, keeping its nested extension intact and one active prototype copy. Open that containing app once and choose **Done** in its instructions window. Open Final Cut and choose **Window → Extensions → Silent Snip Workflow Prototype**. Restart Final Cut if discovery has not refreshed; the build-4 installation required the containing-app launch and host restart before the extension appeared. Use **Connect to Final Cut Pro** when shown; the user handles any new consent request. The frontend remains a separate app. Install a verified compatible worker at the existing Silent Snip app path without changing the Share destination; current installation records are in the milestone-2 checkpoint above.

The historical milestone-1 read-only pre-install baseline is `build/WorkflowPrototype/Baseline.json`. It records matching build-47 helper and Audio Unit 29 executable hashes in the installed app, published app, and ZIP; deep signature verification for the installed and published apps; the installed Audio Unit registration path; host/SDK metadata; and anonymized fingerprints of accessible setup files. Production helper SHA-256 begins `2e04f539` and ends `648df`; the Audio Unit hash begins `cf42cb18` and ends `369cd`.

The protected Final Cut preferences file could not be read: macOS returned **Operation not permitted** for both ordinary and approved unsandboxed read attempts. No protection was changed and no raw preference values, project lists, or library lists were copied. Consequently, a complete semantic preference baseline is **unavailable**. The accessible custom-command-set file is fingerprinted, but that does not establish which command set is active or which Share destination is the default. Those selected values require minimal native before/after observations.

The Swift bridge writes only `Project-Settings.json` under the extension's own `Application Support/Silent Snip Workflow Prototype` directory. The model has no default file location and does not use `UserDefaults` or a Final Cut preference domain. Controller instances share one actor for this file within the extension process. Cross-process/external writers are outside this store's supported scope. The settings bridge does not write the library, production settings/results, keyboard command sets, Share destinations, or default-destination preferences. Frontend 6 can explicitly ask the existing worker to analyze or create a cleaned result using its established verification flow; it adds no Final Cut preference-writing path.

The milestone-1 `After-Preservation.json` confirms that production installed/published/ZIP executables, the ZIP archive, signatures, and Audio Unit registration path match the baseline. Accessible command-set/export-preset files retain identical byte and semantic fingerprints. Native v3 observations retained **Export File** as the default, the existing **Silent Snip** and **Save Current Frame** commands, and production Audio Unit **Ready / -50 / 0.1 / 0.05 / 0.05 / Remove Silence** settings. No shortcut or Share destination was added for the prototype. The active command-set selection was not exposed by Accessibility; selection equality is not established. Protected preferences were not retried, and full preference equality remains unproven.

## Recorded milestone-1 functional checks

All live checks used the existing workspace-root **Cutdown Integration.fcpbundle** and disposable projects with generated media referenced in place. Build 3 displayed the active project/library through the SDK and saved these distinct project settings:

| Disposable project | Threshold | Minimum silence | Before | After | Output |
| --- | ---: | ---: | ---: | ---: | --- |
| A | -47 dBFS | 0.35 s | 0.12 s | 0.18 s | Remove Silence |
| B | -32 dBFS | 0.8 s | 0.2 s | 0.25 s | Replace with 1-Second Gaps |

After restarting Final Cut, project A restored its values; switching to B restored B's values. On B's 30 fps timeline, moving from `01:00:00:00` to `01:00:00:01` changed the project-relative display from **0.000** to **0.033 seconds**. Submitting threshold **-81** on **project A** was rejected; a cold restart restored A's saved **-47** threshold. Build 4 restored B after rebuilding/reopening, including its **0.033-second** playhead display, without another Connect action.

Builds 3–4 failed native visual acceptance: the **840 × 477-point** host window clipped the header, which scrolling upward did not reveal. Build 5 removed the root `preferredContentSize` constraint and lowered the declared minimum height to 300 points. In the same native window size, the title, project, library, and playhead became visible. Public Accessibility **Scroll Down** reached Save Settings, status, and the bottom scope message; **Scroll Up** restored the top. Injected wheel input did not move the scroll, and manual window drag-resizing was not tested. The controller harness separately covers constrained and frame-driven host resizing.

In final build-5 testing, B restored **-32 / 0.8 / 0.2 / 0.25 / Gaps** and **0.033 seconds**, and Save Settings succeeded. Switching through Final Cut's native project browser to A showed native timecode `01:00:00:00`, prototype **0.000 seconds**, and **-47 / 0.35 / 0.12 / 0.18 / Remove Silence**; Save Settings succeeded. **Command–W** closed the extension and returned to Final Cut's main window. Reopening through **Window → Extensions** restored A with the complete header visible. No audio analysis, Share export, or timeline mutation ran during this milestone.

Recorded automated checks passed **614 Swift tests** with **three existing opt-in skips and zero failures**, **117 Python tests**, and the final **11 controller groups / 181 assertions**. The controller harness uses no Final Cut instance, windows, events, or settings files. Its late-callback, permission, layout, and persistence guards are separate from the native observations above. Library-identity isolation and pending-operation races have offline coverage; they were not tested in another live library or represented as native timing-race tests.

Evidence is retained under `build/WorkflowPrototype`: final `Native-M1.json`, `Install-5.json`, `Package-Verification-5.json`, `Baseline.json`, `After-Preservation.json`, `UI-Baseline.json`, `Swift-Tests.log`, `Python-Tests.log`, `Controller-Tests-Final.log`, and the earlier installation/package/native-connection records. Build 5's verified container hash begins `a09caa0c` and ends `61440`; its extension hash begins `1df54a55` and ends `1f5500`. The installed build-5 extension matched its verified package. `Install-5.json` records the earlier installation stage; `Native-M1.json` supplies the later final native result. These build-5 preservation checks precede the separate worker-49 installation recorded above.

## Regression protocol

For future reruns, use small disposable projects in the existing workspace-root **Cutdown Integration.fcpbundle**, with generated media referenced in place and no copied, optimized, or proxy media. Do not substitute another library. The milestone-1 checks below are rerun guidance; native milestone-2 processing and fidelity verification remain pending as stated above.

- Open the prototype from Final Cut's Extensions UI and verify its project/library labels against the actual disposable project. Opening the standalone instructions app is not host-load evidence.
- Move the playhead to known positions in a project with a nonzero timecode origin and verify the displayed project-relative seconds. Read-only observation must not move the playhead or edit the timeline itself.
- Save nondefault values and output mode explicitly; reopen the extension and verify the same project restores them. Switch to a second disposable project and back to prove isolation by project UID. Offline model tests cover library-identity isolation without testing in another live library.
- Run the offline controller/model checks for project switches during pending loads or saves, late completions, repeated observations, and unsaved drafts. Those tests supplement native A/B switching; they do not claim a live timing-race stress test.
- Verify that typing, switching output, reopening, and Save Settings do not start analysis or Share. Frontend 6 starts work only through explicit Analyze and Apply actions; separately record native review, result verification, PCM fidelity, and timing before claiming milestone-2 completion.
- Compare installed frontend/worker hashes and signatures against their current verified package/install records; compare unchanged Audio Unit 29 against the historical baseline. Preserve accessible setup-file fingerprints and native default-destination observations. Keep the active command-set selection, global import preferences, and complete protected preference equality unverified unless direct evidence becomes available. Frontend 6 delegates imports to the existing worker without adding a preference-writing route.

If protected preference access later becomes available, compare parsed values semantically and retain only necessary hashes or selected non-sensitive values. Any tolerated Workflow Extension discovery bookkeeping change must identify the exact key and reason; do not blanket-ignore other preference changes.

## Verification record

| Check | Status |
| --- | --- |
| Apple Workflow Extensions SDK 1.0.3 installed | Verified metadata |
| Production build-47 preservation baseline | Recorded before prototype installation |
| Prototype packaging/build validation | Frontend 6 / workers 49–50 passed; installed hashes match their records; candidate 51 native validation pending |
| Native Final Cut extension load and project/playhead observation | Build 5 passed; earlier functional checks retained |
| Native per-project settings persistence and isolation | Build 5 passed A/B save/switch/reopen; build 3 passed host restart |
| Native layout and complete control reachability | Build 5 passed at 840 × 477 points using public AX scrolling; earlier failures retained |
| Automated model, packaging, controller, and client checks | Milestone 2 passed 633 Swift / 120 Python / 22 controller groups / 9 client groups as scoped above |
| Native setup/preference comparison | Production/setup-file checks passed; protected preferences and active command-set selection remain limited |
| Native Workflow Analyze → review → Apply and audio fidelity | Implemented; worker 50 isolated a foreground-handoff mismatch; candidate 51 native completion pending |
| Three-second complete-flow target and universal effect compatibility | Not established |

Milestone 1 remains complete only for the hosted window, project/playhead observation, and per-project settings described here. Milestone 2 has implementation and automated evidence; native cuts, audio fidelity, and throughput still require separate successful runs.
