# Current identity (0.2)

At the user’s request, this release replaces the legacy containing-app identity instead of retaining compatibility: `local.silentsnip.app`, executable `SilentSnip`, extension `local.silentsnip.app.audio` / `SilentSnipAudio.appex`, and URL scheme `silentsnip`. New files use `Application Support/Silent Snip`; existing data and the workspace integration library are preserved. Permissions and the Final Cut Share action need to be selected for the new app.

# Single-app design and verification

## Agreed flow

Copy **Silent Snip.app** into Applications → open once → complete macOS permissions and Final Cut Share setup → use Silent Snip Audio in Final Cut.

No custom installer, repair app, package installer, or notarization work is included.

## Architecture

- One containing app runs the existing background helper executable and includes the sandboxed Audio Unit at `Contents/PlugIns/SilentSnipAudio.appex`.
- The containing app uses `local.silentsnip.app`; the extension keeps `local.silentsnip.app.audio`, its component identifiers, parameters, and saved-state format.
- The containing app keeps the helper's URL routes, Share scripting definitions, document handling, libraries, previews, analysis, verification, and recovery. Its process remains outside the extension sandbox. A scissors menu bar icon makes the running app visible and offers status, saved results, and Quit.
- Output: `build/App/Silent Snip.app`; downloadable archive: `dist/Silent Snip.zip`. Developer verification tools remain separate from the distributed app.
- Existing saved-data locations stay unchanged. Migrating users may need to grant control access again and reselect the combined app as the Share action.

## Implementation order

1. Remove the custom installer and confirmed unused code; retain developer build, registration, and uninstall tools. Run the remaining Swift and build-script suites before changing packaging.
2. Assemble and validate the combined app, then update the build and registration workflow. Remove the obsolete empty wrapper once the combined bundle works.
3. Check a copied app's signature, extension discovery, URL launch, Share exchange, settings, analysis, preview, Apply, verification, and recovery.

## Verification boundary

All live Final Cut tests must use the workspace-root `Cutdown Integration.fcpbundle`, created empty if absent, with disposable projects and referenced generated media. Never use another library. Preserve installed bundles, source media, evidence, and user data.

Packaging and offline checks do not establish successful automatic timeline editing. Record actual results here as each stage completes. If the platform blocks this architecture, document the restriction before changing architecture or removing features.

## Results — 2026-10-21

- Removed the custom setup sources, targets, installer tests, plist, icon generator, and installer packaging script. Removed the unused `FinalCutAXSession.setValue` method; preserved Cocoa Scripting entry points.
- Cleanup baseline: 331 Swift tests executed, one skipped, zero failures; 47 build-script tests passed before packaging changes.
- Single-app refactor verification (before the menu bar addition): 331 Swift tests executed, one skipped, zero failures; 53 build-script tests passed. Offline rendering passed 60 exact mono/stereo cases plus saved-state/persistence checks. The Controls harness passed its scenarios, including containing-app routing, invalid contracts, and inert candidates.
- Release `build/App/Silent Snip.app` and `dist/Silent Snip.zip` built successfully. The ZIP round trip verifies signatures, matching binaries, one containing app, one extension, stable identities, an unsandboxed containing app, and a sandboxed extension. The staged candidate disables URL/Share/document routes and its extension's containing-app launch contract; its signature and sandbox were checked.
- A copy at `~/Applications/Silent Snip.app` automatically registered its extension when opened, without running a registration script. `auval` passed against the combined app during the packaging probe.
- Created the required empty workspace-root `Cutdown Integration.fcpbundle`; imported one generated 10-second test project with `copy assets=0`. Final Cut loaded the copied extension's Controls, accepted detection settings, and retained them when Controls was closed and reopened. Existing detection defaults were backed up and confirmed byte-for-byte unchanged after testing.
- User authorized the copied app's control-access grant. After updating the menu bar build, added the exact `~/Applications/Silent Snip.app` through System Settings. macOS displays it under the cached name **CutdownAudio.app**, switched on. The running copied app reports `ready`. Replacing an ad hoc build can require refreshing this grant.
- The first live Analyze stopped before analysis or edits: the extension sandbox could not read the containing app's Info.plist. A debugger inspection confirmed that the extension could resolve its bundle URL but reading the parent plist returned nil. Fixed this by declaring the launch contract in the extension's own signed metadata. The extension now validates that contract and explicitly launches its containing app. Staged builds disable the contract and preserve the extension's sandbox when re-signing.
- The sandbox-safe fix passed offline regressions and was rebuilt and copied into Applications. The user offered to perform the remaining live testing. **Live Analyze, preview, Apply, post-import verification, and recovery remain unverified after this fix. No automatic cuts are claimed.**
- Added a new **Silent Snip** Share destination using **Audio Only / WAV**, with `~/Applications/Silent Snip.app` as the action. The existing **Cutdown** destination was left unchanged.

The later menu bar addition passed a Release build and bundle/archive signature checks. The copied app launched and reported control access granted. Native automation cannot inspect this accessory-only app's menu bar, so its icon and menu interactions remain a manual UI check; no Final Cut editing test was run for this addition.

Local evidence is recorded in `build/SingleAppEvidence/Verification.json` and the `build/single-app-*.log` files. These generated files are preserved locally and excluded from Git.

## Preview responsiveness and matching cut numbers — 2026-10-22

Build 8 keeps Controls inside Final Cut, as requested. It adds matching, stable cut numbers to review rows and timeline markers, requests a larger review view, and reduces preview tracking overhead. See [tracking changes and verification](preview-responsiveness.md). After the user confirmed both apps were closed, build 8 replaced the copy in `~/Applications`. The installed bundle matches the published app and ZIP, its extension is registered, Apple’s Audio Unit validation passes, and the copied app reports `ready` after refreshing its existing control-access grant. Build 7 is preserved in a backup ZIP. Live scroll latency and the larger view inside Final Cut remain unverified; timer targets are not measured frame rates.

## Counted Apply confirmation fix — 2026-10-22

Build 9 removes the literal `Apply Cuts` title requirement that rejected the redesigned counted button. Exact fresh gesture, disabled-button, view, clip, project, and revision checks remain. See [confirmation contract and regression checks](apply-confirmation.md). On October 23, after the user confirmed both apps were closed, build 9 replaced the installed copy. The app matches the published bundle and ZIP, the extension is registered, Apple’s Audio Unit validation passes, and the copied app reports `ready` after refreshing its existing control-access grant. Build 8 is preserved in a backup ZIP. No live Apply success is claimed.

## Live handoff checklist

### Compact Controls startup fix — 2026-10-22

Build 6 crashed when Final Cut created the Audio Unit on its XPC queue after loading Controls: `updatePrimaryAction` reached AppKit's `setPreferredContentSize:` off the main thread. Build 7 creates the processor on the calling thread and asynchronously connects it to the controller on the main thread, without making the audio host wait for UI work. The factory regression suite now covers both view-first and processor-first background startup orders, including a blocked main thread during creation.

Build 7 passed 22 factory scenarios, 60 exact mono/stereo audio cases, and Apple's `auval`. The copied app and ZIP signatures and file contents were verified, the installed extension was registered, and the copied app reported `ready` after refreshing its existing control-access permission. Final Cut was closed during replacement. This verifies the startup fix and Audio Unit validation; reopening Controls in Final Cut and the full Analyze → Apply editing pass remain live checks.

1. Open the updated copied app and look for the scissors icon in the menu bar. Its menu should show the access status and offer **Open Results Folder** and **Quit Silent Snip**. The current control-access entry is **Silent Snip.app**; enable it for the copied app. In Final Cut, use only `Cutdown Integration.fcpbundle` at the workspace root. The generated **Silent Snip Audio Only Basic** project is disposable; it references `build/SingleAppEvidence/Fixtures/Recording.wav` in place.
2. Select its single 10-second audio clip and open **Silent Snip Audio → Controls**. Use **−40 dBFS**, **0.5 s** minimum silence, **0.1 s** before speech, **0.1 s** after speech, and **Remove Silence**. Save settings, close/reopen Controls, and confirm the values persist.
3. Click **Analyze**. Expect two cut ranges, **2.1–3.4 s** and **5.1–6.9 s**, with no timeline edits before Apply. Confirm preview visibility, cut selection, and Controls reconnection on this same clip.
4. Click **Apply Cuts** only in this disposable project. Expect three editable retained segments, **6.9 seconds** total duration, the same original media and effect settings, and recovery XML saved before replacement. Export the result XML into `build/SingleAppEvidence` to verify segment timing, source references, settings, and the user marker.
5. Test recovery and **Verify Existing Result** using the saved job's `Silent Snip.fcpxml` and `Before-Silent Snip.fcpxml`; preserve that evidence. Test **Replace with 1-Second Gaps** only on a fresh disposable project; expected duration is **8.9 seconds** for this fixture. No other libraries or projects should be used.

If anything fails, capture the exact Controls message and the job's reports before retrying. Do not treat an effect loading or Analyze succeeding as evidence that automatic Apply works.
