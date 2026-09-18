# Historical integration record (through September 16, 2026)

> Historical development record. Build paths, installed/staged app state, and test totals below describe the original run. Generated logs and Final Cut libraries are not included in Git. Use the [README](../README.md) for verification of this repository copy and [setup](setup.md) for a fresh installation.

This is an archived snapshot. Statements labeled “current” below describe their original revision, not the latest source. Use [workflow.md](workflow.md) and [overhaul-progress.md](overhaul-progress.md) for current behavior and verification status. All shell commands assume the workspace root.

# Cutdown

A free, local **audio-only** silence-removal tool for Final Cut Pro, currently at the integration milestone.

## Reduced analysis work — September 16

Processed-clip Analyze now uses **three Share exchanges instead of four**. The XML delivered with the isolated audio render is checked directly against the generated isolation before any PCM is used, including rendering effects, media, timing, project name, and a nonempty host-assigned UUID. This replaces the separate pre-render XML-only Share. Original-project checks after rendering, fresh baseline/media checks before Apply, and host-import verification remain in place. Analyze also reuses immutable captured XML bytes. The missing-callback fallback parses unchanged XML once, while still requiring three seconds of stable reads and rejecting invalid or replaced data.

**86 focused tests passed** with access to macOS media services (`build/reduced-analysis-work-tests-access.log`); the initial sandboxed run could not open AVFoundation audio readers. The helper rebuild is recorded in `build/reduced-analysis-work-build.log`. No live Final Cut run or elapsed-time improvement has been verified for this revision. The current user workflow remains Controls → Analyze → review → Apply Cuts.

## Imported project opening repair — September 16

The reported analysis project was imported into the browser but never opened in the timeline. Project navigation now scopes lookup to the browser, rejects duplicate names, selects the exact item (Accessibility first, guarded single-click fallback), verifies sole selection and browser focus, and invokes Clip → Open Clip. Menu completion permits only the requested destination in the same Final Cut process/window; the timeline and subsequent XML checks remain required.

**Validation:** 39 focused tests passed and the helper was rebuilt. A disposable six-second project referencing generated media in place inside `Cutdown Integration.fcpbundle` imported and opened through the native Open Clip command. The rebuilt helper's live Analyze test stopped at macOS Accessibility permission, before navigation; automatic analysis, Apply, and cuts are not established by this repair. Evidence: `build/ProjectNavigationVerification/Notes.md`, `build/project-navigation-tests.log`, and `build/project-navigation-build.log`.

## Menu and keyboard cleanup — September 16

XML capture now exclusively uses the existing programmatic Share exchange. The unused Export XML/save-panel route and its Go to Folder/Return keystrokes were removed; this does not change the exchange already used by interactive Analyze and Apply. Empty range selections no longer trigger Clear Selected Ranges. Export tabs already selected are not pressed again. Visible imported projects open without first navigating to Libraries or changing browser view. The timeline-focus menu fallback now verifies focus instead of relying on a fixed delay.

Share initiation/confirmation, conditional range clearing, and project navigation still require bounded host UI actions. Cuts and result delivery remain programmatic. **67 focused tests pass; no fresh live Final Cut run was performed for this cleanup.** Test evidence: `build/programmatic-actions-tests.log`. See `docs/workflow.md` for the current source workflow; older sections below include superseded implementation details.

## Audio plugin compatibility — September 16

The current source analyzes the complete audio effect chain through an isolated Final Cut render: Noise Gate, Compressor, EQ, Limiter, and third-party Audio Units use the same generic path. Only unprocessed clips use direct source audio. Effect order, bypass states, presets, parameter values, and opaque saved state are retained when generating cut segments and checked during host re-export verification. Set processing first, then Analyze; changes to processing invalidate the review. See [Using other audio plugins](workflow.md#using-other-audio-plugins).

New regression coverage exercises stacked plugins, component-level processing, controller placement, isolation, cut and gap outputs, and rejection of changed effect state. A synthetic gated-audio test checks that rendered silence is used even when the original source has no silence. These tests do not run vendor DSP or establish live Final Cut plugin round trips. Audio-only scope remains unchanged; timed automation and fades still prevent automatic Apply. Older integration entries below describe historical implementations and evidence.

The render is temporary analysis media. Output segments reference the original audio and keep editable effects; no baked replacement asset is introduced. **53 focused tests passed** with macOS media-service access (`build/audio-plugin-compatibility-tests-unsandboxed.log`); the sandboxed run could not decode rendered WAV fixtures through AVFoundation. This update adds tests and documentation, without changing runtime behavior or rebuilding the installed helper. No new live Final Cut integration test was performed.

## Missing cut-boundary preview — September 16

The reported Analyze failure rejected Final Cut's newly assigned imported project UUID even though the semantic timeline fingerprints matched. The installed helper predated the existing host-assigned-identity correction. After rebuilding and refreshing its existing macOS access, live Analyze completed on the six-second generated-audio project **Cutdown Preview Return 0916** in the workspace **Cutdown Integration.fcpbundle**. Isolation and rendered-audio project verification passed; the review proposed one 1.933-second removal and enabled **Show Cut Preview**. No cuts were applied.

A live overlay capture remained blank. Diagnostics showed masks covering the full clip; the owning-window check and final on-screen verification remain incomplete. Separately, a regression test reproduced lost boundary pixels when the view's backing layer was replaced. The renderer now reattaches its retained drawing even when geometry is unchanged. All 43 focused capture, preview, review, and isolated-project tests passed. Optional preview diagnostics now include drawing attachment and window-surface metadata to distinguish rendering faults from intentional occlusion.

The updated helper is built and installed. **The user stopped live testing before the final build's permission refresh and pixel verification completed. Do not treat this as a verified fix for the missing on-screen lines.** Evidence and limitations: `build/PreviewReturnVerification/Notes.md`; test logs: `build/preview-layer-before.log` and `build/preview-layer-tests.log`.

**Required workflow:** add Cutdown Audio from Final Cut's Effects browser, open its Controls window, adjust the four detection settings, click **Analyze**, review, then click the separate **Apply Cuts** button. Settings belong in the window, not in the sidebar. After the one-time [Share destination setup](setup.md#create-the-cutdown-share-destination), the intended Analyze/Apply workflow does not require a manual Share or export-method choice.

**Current status:** Analyze reads an unprocessed clip directly from its source. Clips with volume adjustments, fades, channel changes, enhancements, or effects use a Final Cut WAV render so detection includes their processing. The rendered path currently requires Dialogue-only audio and no other enabled audio overlapping the target; ambiguous context stops explicitly. The new automatic render path still needs live button verification after restoring the helper’s existing macOS access. Apply now checks the project and source media again, generates all selected cuts in FCPXML, saves a separate `Before-Cuts.fcpxml` snapshot, and sends one new project to Final Cut Pro. The original timeline and media remain unchanged. The result is named separately in **Cutdown Results**. Remove Silence and one-second-gap output use the XML writer; no per-cut menu or keyboard commands are sent. The completion message confirms document delivery, not an automatically verified host import. Final Cut can drop Cutdown settings during XML import; the exact analysis settings are also saved in `Analysis-Settings.json`.

The background analysis and editable FCPXML writer can be exercised together through `AudioProjectProcessor` and the developer-only verifier below. Successful processing of exported artifacts does not establish an effect-triggered operation, live result import, or edits in Final Cut's current timeline.

## Effect-aware analysis (September 15)

**Export-format label correction:** a user capture exposed the separate label `Format:` where the earlier layout exposed `Export File Format:`. Both exact labels now resolve the container-format popup; `Audio Format:` remains a separate codec control. The 12 export tests pass, including acceptance of both layouts and rejection of ambiguous labels. The helper was rebuilt. This fixes the reported lookup failure; a new automatic export round trip has not been verified. Logs: `build/export-format-label-tests.log`, `build/export-format-label-build.log`.

Analyze now uses Final Cut’s output for processed clips, including volume, Limiter, Noise Gate, other audio effects, and opaque third-party AU state. No per-effect DSP recreation is attempted. A clip with only Cutdown and neutral metadata keeps the fast source path. Effect changes after Analyze invalidate the review; changing only detection settings recalculates the cached measurements.

The current renderer exports the full Dialogue mix and measures the selected target’s interval. It requires a Dialogue-only project with no enabled overlapping audio and rejects unresolved compound/multicam/transition/retimed context. Mixed roles and overlapping tracks still need isolated-clip export support. This is **not universal project support**. Detection uses 10 ms RMS, which differs from peak meters even after rendering. XML-import effect-state retention remains a separate limitation.

**Validation:** 43 focused tests pass, including source/processed routing, no mixing of overlapping audio, rendered-versus-source threshold behavior, stale effect changes, export completion/cancellation, and XML generation. The initial sandboxed run could not start AVFoundation readers; the same tests passed with access to the media service. The helper was rebuilt and restarted.

**Manual Final Cut verification passed:** a disposable six-second `Cutdown Effects Processed` project in `Cutdown Integration.fcpbundle` references generated stereo PCM in place and has +12 dB gain plus Limiter. Export File was verified as Audio Only / WAV / All Dialogue / one file and one track. The source’s quiet tone measures about −53.9 dBFS; the host render measures about −42.4 dBFS. At −50 dBFS the source path would remove 1.033–4.967 s, while rendered analysis correctly removes only 3.033–4.967 s. XML generation from the rendered measurements produces a 4.067 s result; that result was not imported. Evidence: `build/EffectAwareVerification/Verification.json`, the manual WAV/XML, and `build/effect-aware-analysis-tests.log`.

**Automatic button verification remains blocked:** Analyze on that test fixture reported missing macOS Device Control and Data Access after the local rebuild. The user’s earlier choice to test manually was honored; no permission was granted. Manual export and backend success do not establish automatic Analyze, automatic Apply, or host effect-state retention for this build.

## Preset-related Apply failure fixed (September 15)

A captured failure from project `test` stopped **before XML generation**: Final Cut added `presetID` to the Cutdown effect between Analyze and Apply, while its settings, timeline, volume, and other effects remained unchanged. The source-project check reused the native-edit verifier and misleadingly reported “the timeline does not exactly match the expected native edits.”

The comparison now excludes the preset reference only for the exact Cutdown audio controller when its settings are validated separately. Full output validation still includes that preset and its effect state. Other effects' presets, enabled states, media references, clip timing, and volume remain checked. XML Apply has a dedicated baseline check whose error identifies real changes and states that generation has not started. This applies to supported audio-only targets in any source project/library, without a fixture-name or library-name exception. Linked video, retimed targets, compound clips, and connections crossing cuts retain their existing explicit restrictions.

A regression test failed before the fix. **82 targeted tests passed** afterward. Replaying the failed job's exact Analyze/Apply exports now passes both baseline and controller-settings checks and generates **120 removals**: 268.6 s becomes 197.333 s. The same ranges generate one-second-gap output totaling 317.333 s. Both generated files preserve the complete source effect payloads; they were **not imported into Final Cut**, and no fresh effect-button round trip is claimed. The helper was rebuilt and restarted. Evidence: `build/PresetBaselineVerification/Verified/Verification.json`, `build/preset-baseline-before.log`, `build/preset-baseline-tests.log`, and `build/preset-baseline-build.log`.

## XML Apply verification (September 15)

The new `XMLProjectApply` prepares and validates all edits in one project, preserves a recovery copy and analysis settings, and refuses delivery if the XML changes or the destination library disappears. Cancellation before delivery sends nothing; an uncertain import is not retried. Existing result folders are never overwritten.

**Live manual round trip passed for cut structure:** a fresh `Cutdown XML Apply Verification` project in the workspace's `Cutdown Integration.fcpbundle` contained the existing generated ten-second `Recording.wav`, referenced in place. Source decoding at −32 dBFS, 0.5 s minimum silence, and 0.1 s padding produced two removals totaling 3.1 s. The same XML preparation code used by Apply generated the result in approximately 0.009 s (generation/validation and artifact writes only; not source analysis or Final Cut import). Finder import created `Cutdown XML Verified Result` with three editable segments totaling **6.9 s**. A manual Final Cut re-export confirmed exact timeline offsets, source starts, durations, original media references, and the Cutdown effect reference on each segment.

**Effect state still fails round trip:** the generated XML preserved the original effect archive, but Final Cut re-exported three bare filter references. The verifier correctly reports `cutStructureVerified: true` and `effectPayloadUnchanged: false` and exits nonzero. This does not establish preserved settings. Check settings before analyzing an imported segment again.

**Button workflow remains unverified for this build:** the rebuilt helper lacks Device Control and Data Access permission. The user chose manual XML testing instead of granting access. No permission was added, and no effect-triggered Apply or automatic final verification is claimed. The helper was built and restarted; 38 targeted tests cover artifact preparation, cancellation, delivery, the XML writer, gap output, and coordinator behavior. Evidence: `build/XMLApplyVerification/`, `build/xml-apply-tests.log`, and `build/xml-apply-build.log`.

## Programmatic XML exchange

**Historical range shortcut optimization (superseded by XML Apply):** the native driver attempts the assigned keyboard shortcuts for Clear Selected Ranges, Set Range Start, and Set Range End, reading the retained Mark menu's Accessibility metadata without opening it. Unavailable, disabled, or incomplete assignments use the existing menu driver before any shortcut is sent. Preparation checks the cleared range, the new start, and the complete removal range; it stops on an unconfirmed shortcut instead of retrying through a menu. Delete, recovery snapshots, and final XML verification retain their existing checks. The 21 capture tests pass, including three new shortcut metadata tests (`build/range-shortcut-tests.log`). Live shortcut execution and timing remain unverified because Final Cut computer access was not approved; this is not evidence of automatic timeline cuts or a measured speedup. That native driver is no longer called by interactive Apply. XML capture still uses the Share confirmation; cuts and gaps are generated in code.

Interactive Analyze and Apply use the configured **Cutdown** Share destination and Apple's Media Asset Protocol. The helper supplies a unique output folder and filename and requests XML only (`hasMedia=false`, no library archive). XML capture needs no Export XML Save panel or filename entry. Processed clips additionally use the Export File audio-only WAV flow, including its save panel, and a second XML capture to verify the project did not change during rendering. Final Cut still requires initiating the Share command and confirming its panel; Cutdown performs those bounded Accessibility actions. Timeline focus uses an Accessibility property first, with the menu command as a compatibility fallback.

The current cycle captures XML for Analyze and for the changed-project check before generating the edited copy. It then sends the completed result through an Open Document request. A final host re-export is currently a developer verification step. Completion arrives through a dedicated Open Document scripting handler. If the host omits that callback, only a complete, parseable XML at the exact assigned job path is accepted after three seconds of stable reads. Late identical completion messages are harmless; replaced files and unrelated jobs fail validation. Cancellation never sends an old XML-only delivery to the legacy audio workflow.

**Historical separate-project verification:** both buttons passed in `Cutdown Button Verification` inside `Cutdown Integration.fcpbundle`. Two XML-only deliveries produced no Save dialogs or rendered audio. Final Cut imported a separate result with three editable clips totaling 7.3 seconds. 33 exchange/capture tests passed. Evidence: `build/ProgrammaticVerification/`. The prior source-interval roundtrip evidence remains in `build/SourceVerification/`.

The machine must have a Share destination named **Cutdown** targeting the installed helper; the historical test Mac already had it configured. New checkouts must complete [first-time setup](setup.md). A missing destination produces an explanation rather than silently switching to manual Save dialogs. The legacy Export XML save-panel driver was removed in the September 16 cleanup.

## XML export repair (September 15)

The live Analyze button now opens Export XML, selects the job folder, saves the FCPXML bundle, and parses the selected ten-second `Recording` in `Cutdown Button Verification`. Fixed retained closed-menu detection with hit testing, selected menu activation, and stale toolbar-object checks when native panels open. The effect is not explicitly closed. Evidence: `build/xml-save-fixed.fcpxml`, `build/xml-save-fix-build.log`, and `build/xml-save-fix-tests.log`.

The earlier controller-settings blocker was caused when Final Cut exported `<filter-audio ref="r4" name="Cutdown Audio"/>` without scalar parameters or `effectState` for this instance. The interactive path now accepts the explicit window request only for a verified, enabled, single Cutdown effect whose exported entry is completely empty. Partial or malformed saved settings still fail. The source-analysis workflow replaces the subsequent rendered-audio export path.

## Scope

- One normal-speed, primary-storyline audio-only clip, including source trims and repeated source instances.
- Only the selected clip's source audio supplies measurements. Timeline volume, effects, role assignments, and overlapping clips are not part of the analyzed sound. Proposed cuts stay inside the selected clip.
- Clips containing video are rejected. An audio-only timeline insertion may reference a source file that also has an unused video stream.
- Other timeline items remain part of project validation and synchronization checks. Their presence does not expand the target's editing scope.
- Retimed, nested, ambiguous, missing-media, disabled-audio, and entirely silent targets cannot be applied automatically.

The only effect is the **Cutdown Audio AUv3** audio effect. The video plug-in, its Xcode project, Motion templates, build script, and video-fixture generation have been removed. Existing integration projects, source media, recovery snapshots, and exported evidence are preserved.

## Current interface and status

The current build adds an animated progress bar during Final Cut operations, measured PCM-read progress, and elapsed seconds. Export ETA is unavailable. Analyze and Apply no longer call the review-window closing routine, and the project is no longer explicitly raised over the review. Continued visibility throughout a successful export/import remains a live integration check. The existing macOS access can require refreshing after a locally signed helper rebuild.

The four settings and **Analyze** are in **Audio Inspector → Cutdown Audio → Controls**. A separate review section below contains **Apply Cuts**. This supersedes the earlier sidebar-only UI. Final Cut supplies the window and may keep an empty Parameters heading in the sidebar. Cutdown's host parameter tree is empty; private settings retain stable IDs and Apple's existing saved-state format. See [Audio Unit details](../AudioPlugin/README.md).

| Setting | Default |
|---|---|
| Silence Threshold | −40 dBFS |
| Minimum Silence | 0.5 seconds |
| Before Speech | 0.1 seconds |
| After Speech | 0.1 seconds |

Existing verification on this Apple Silicon Mac with Final Cut Pro 12.3 and Xcode 27:

- The helper and Audio Unit build and sign locally. Apple's Audio Unit validation passed for `aufx / ctdn / Ctdn`.
- **Current window build:** build 4 restores an Audio Unit custom view with four private settings, Analyze, and a separate gated Apply Cuts button. Factory tests, legacy native-state compatibility, 60 audio render cases, and `auval` pass. A fresh instance in `Cutdown Backend Verification` has no sidebar setting fields. A window setting survived a full Final Cut restart; Analyze received the helper’s current unavailable response and Apply stayed disabled. Existing instances retain Final Cut's cached controls until reapplied. Evidence: `build/audio-window-*.log` and `build/audio-window-verification.json`.
- Final Cut loads Cutdown Audio on an audio-only clip. Its four scalar settings and instance-state restoration passed live checks.
- The audio render tests passed 60 passthrough cases plus persistence checks. The legacy custom-view harness also passed; its result does not establish the requested native Inspector interaction.
- The September 15 background-processing regression run passed **213 tests** (138 Mac, 75 Core), including ten PCM-to-project tests and four decoded breath-like-noise tests. Evidence: `build/background-processing-tests.log`.
- **Current backend/live-import evidence:** the processor decoded the existing ten-second Final Cut Dialogue WAV, measured 1,000 windows, and generated two cuts removing 2.7 seconds. The result was imported into **Cutdown Backend Verification** inside `Cutdown Integration.fcpbundle`. Final Cut displayed three editable audio segments totaling 7.3 seconds; its re-export confirmed their exact source starts, durations, timeline offsets, and original media references. No media copies were requested. Artifacts: `build/BackendVerification/`.
- **Live-import failure:** Final Cut discarded the imported Cutdown parameter/state payload. The first segment's Inspector showed threshold −26 dB instead of the output's −32 dB. Effect references survived, but settings retention did not. `Scripts/verify-backend-roundtrip.py` deliberately reports a failed effect-payload check; this result must not be presented as a complete integration pass.
- **Historical analysis evidence:** the shared pipeline processed an actual ten-second Final Cut Dialogue WAV and XML export, finding two frame-aligned cuts totaling 2.7 seconds with the effect's saved settings.
- **Historical manual-edit evidence:** two manually performed native partial-range deletions left three editable audio segments totaling 7.3 seconds. A recovery snapshot and final XML confirmed the retained source intervals and effect on each segment. This establishes Final Cut's native behavior, not automatic editing by the helper.

**Source-analysis integration:** capture, direct source decoding, review restoration, explicit Apply, and result import passed on the simple fixture. The imported result was opened manually for final verification. The source-interval roundtrip passed; imported effect settings retention remains unverified. Timeline markers and in-place native deletion remain unavailable. Apply produces a separate cut-up project. The rendered analysis path rejects mixed-role projects and overlapping audio; direct source analysis does not export or mix roles. The effect-aware change and its verification limits are documented above.

The separate Share-to-Cutdown review window remains developer-only. Interactive Analyze now selects direct source decoding or the verified-role WAV export path according to the clip’s processing. Users continue using Analyze and Apply; the helper drives Share and, when needed, audio export.

## Detection and review

`ClipAudioAnalysisRoute` chooses direct source decoding only when the target contains no processing beyond the known passthrough Cutdown controller and neutral metadata. All other children conservatively require Final Cut rendering, including unknown third-party effects. The source path seeks to the selected trim and rejects multiple audio tracks, unavailable media, and incomplete trims. The rendered path verifies Dialogue-only export, target isolation, completed PCM duration, unchanged XML, and source media hashes. Temporary renders are deleted after measurements are loaded; recalculation uses cached measurements. Render failures never fall back to unprocessed audio.

The detector measures RMS loudness in 10 ms windows, separately for each channel, and uses the loudest channel. It intersects quiet intervals with the target, checks minimum duration, retains the before/after speech padding, and rounds removal boundaries inward to project frames. Rational project timing remains necessary for an audio-only Final Cut timeline.

Source analysis ignores role assignments and measures the selected source channels. This is loudness-based pause detection; it does not classify breaths or separate speech from music mixed into the same recording. A quiet breath-containing pause may be removed when it stays below the threshold long enough. Louder breaths and quiet events shorter than Minimum Silence remain. Increasing the threshold can also remove quiet speech; there is no speech classifier protecting it.

`BreathLevelProcessingTests` decodes deterministic, nonzero filtered-noise WAVs through AVFoundation and verifies measured RMS and exact resulting ranges. Its long quiet event, louder event, short quiet event, and stereo checks establish level-based behavior. Synthetic noise does not validate recognition of real human breaths.

The interactive pipeline verifies the project fingerprint, target occurrence, source trim and audio hash. The rendered path additionally verifies the asserted roles and full-project duration. It rejects stale, incomplete, or misaligned input. Cached measurements support recalculation when settings change.

Controller-bound analysis requires the known Cutdown Audio effect on the exact target. In the interactive path only, an entirely empty verified effect entry uses the immutable settings submitted by its window. Explicit exported parameter values take precedence over the effect's bounded, validated native saved state. Missing or mismatched settings never fall back to guessed defaults. The developer verifier can also analyze fixtures without an effect; any present Cutdown controller is validated.

The review model records cut ranges, eligibility explanations, inclusion choices, time removed, and remaining target duration. The effect window displays the coordinator’s analyzed ranges and summary when capture succeeds. Rendering never starts analysis or timeline edits.

## Build and register locally

Install Xcode, accept its license, and complete first-launch setup. Build using the native macOS SDK; no additional plug-in SDK or Motion installation is required.

Quit Final Cut before rebuilding or registering the audio plug-in. Re-registering an active extension terminates its process and makes Final Cut disable it; the scripts now reject that operation while Final Cut is running.

```sh
./Scripts/build-helper.sh
./Scripts/build-audio-plugin.sh
./Scripts/register-local.sh --check-only
./Scripts/register-local.sh
```

Products:

- `build/Cutdown.app` — background helper with the `cutdown` application URL scheme.
- `build/AudioPlugin/Build/Products/Debug/CutdownAudio.app` — audio wrapper containing `CutdownAudioExtension.appex`.

The audio Xcode project is **CutdownAudio.xcodeproj**; the helper and shared libraries use **Package.swift**. Signing is local and ad hoc. No paid developer account, distribution service, or license server is configured.

Registration verifies both apps and the embedded audio extension before registering their existing build paths. It does not grant Accessibility access. Keep these bundles in place. Register or replace the Audio Unit while Final Cut is closed, then reopen Final Cut so it loads the updated extension. See [Audio Unit details](../AudioPlugin/README.md).

## Verification

Use the shared Swift scratch directory:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/module-cache" \
swift test --disable-sandbox --scratch-path build/swift --cache-path build/swift-cache

./AudioPlugin/test-audio.sh
./AudioPlugin/test-factory.sh
auval -v aufx ctdn Ctdn
```

AVFoundation tests require access to macOS media services. A restricted outer sandbox can produce decoding error −11800 for valid WAV files; SwiftPM's `--disable-sandbox` does not disable that outer sandbox.

The core and Mac tests cover pause detection, channel handling, padding, exact timing, audio-only target validation, project state, roles, marker ownership, saved AU settings, transport, job lifecycle, and export cleanup. The factory test checks the custom-window metadata, private settings, saved-state compatibility, validation, and separate Analyze/Apply actions. It does not establish automatic timeline analysis or application. Video-containing XML is retained only where needed to test rejection or surrounding project context.

### Read-only native export verification

```sh
CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/module-cache" \
swift run --disable-sandbox --scratch-path build/swift --cache-path build/swift-cache \
  CutdownVerify \
  --xml "build/Fixtures/Cutdown Audio Native - Before Cuts.fcpxmld" \
  --audio "build/Fixtures/Cutdown Audio Native.wav" \
  --target-start 0s --target-end 10s --role dialogue \
  --controller-uid 'AudioUnit: 0x617566786374646e4374646e' \
  --threshold -32 --minimum 0.75 --before 0.125 --after 0.25
```

Repeat `--role` for each included Dialogue role/subrole. Role metadata is an explicit caller assertion; a file hash cannot prove which mix was exported. This command reads exported artifacts and does not control Final Cut or edit timelines.

The preserved **Before Cuts** XML and WAV describe the ten-second fixture. `Cutdown Audio Native Analysis.json` records cuts `34/15s–101/30s` and `79/15s–103/15s`, totaling `27/10s`. The unqualified native XML and later **Export Probe** XML contain a separate 74.6-second recording (title omitted for privacy).

### Background processing to an editable project

This is **developer verification**, using existing XML and full-project Dialogue PCM artifacts. It is not a required manual export workflow for the finished app. `AudioProjectProcessor` runs actual PCM decoding, silence detection, eligibility review, and XML creation without a window. The verifier exposes it with `--output-directory NEWDIR`:

```sh
build/swift/debug/CutdownVerify \
  --xml "build/Fixtures/Cutdown Audio Native - Before Cuts.fcpxmld" \
  --audio "build/Fixtures/Cutdown Audio Native.wav" \
  --target-start 0s --target-end 10s --role dialogue \
  --controller-uid 'AudioUnit: 0x617566786374646e4374646e' \
  --threshold -32 --minimum 0.75 --before 0.125 --after 0.25 \
  --output-directory "build/Background Verification" \
  --output-name "Cutdown Background Verification" \
  --destination-library "$PWD/Cutdown Integration.fcpbundle"
```

The output directory must be new and its parent must exist. Optional `--output-name NAME` and `--destination-library PATH` require `--output-directory`. The destination library must already exist; the option records an import destination in the XML and does not import or open it.

When eligible cuts exist, the processor writes:

- `Cutdown.fcpxml`: a new project containing editable retained audio segments, with source media referenced in place.
- `Before-Cutdown.fcpxml`: the input XML before transformation.
- `Edit-Report.json`: decoded audio identity, measured-window count, settings, candidate eligibility, removed duration, and retained source intervals. It explicitly records that the detector does not classify breaths.

No qualifying or eligible cuts produces no output project. The processor checks input consistency before publishing a completed result and never overwrites an existing result directory. It does not modify source audio, the input XML, or any open Final Cut timeline. Live import and effect-triggered processing are separate verification steps.

The recorded live test imported the generated project through Finder and then exported it from Final Cut for comparison. This was a development test, not the required finished-app interaction. `Final Cut Roundtrip.fcpxmld` and `Live-Verification.json` preserve the evidence. The cut-structure check passed; the effect-payload check failed as described above.

The writer currently rejects unsupported topology, including target connections, connections crossing a cut, relevant transitions, and timed audio automation/component trims. Those cases require additional integration work before automatic output can be supported.

## Disposable integration fixtures

**Every Final Cut test must use the existing `Cutdown Integration.fcpbundle` library in this workspace.** Use small disposable projects and reference source files in place, without copied, optimized, or proxy media.

```sh
./Scripts/make-fixtures.sh
# For an isolated generator check without replacing existing fixture media:
./Scripts/make-fixtures.sh --output-dir /tmp/cutdown-audio-fixtures
```

The generator creates only original PCM audio and these three projects:

| Project | Content |
|---|---|
| Cutdown Audio Only Basic | Ten-second recording, two pauses, user marker |
| Cutdown Audio Only Trimmed Repeated | Source 1–9s used twice; distinct timeline occurrences |
| Cutdown Audio Only Dialogue Context | Overlapping Dialogue plus separate Music |

FFmpeg is a development fixture dependency, not an application dependency. The script checks PCM samples, expected frame-aligned removals, and the installed FCPXML DTD. Do not regenerate media currently used in a live test. DTD validation does not establish successful Final Cut import.

## Remaining integration work

1. Establish an explicit native Audio Inspector Process action and connect it to a background job, without a separate window or a manual export-method choice.
2. Obtain the exact selected audio occurrence and correctly aligned project Dialogue context reliably from that action.
3. Automate background output delivery and fix Cutdown settings retention on XML import. The simple three-segment audio result has passed a live source-interval check; its effect state has not.
4. Complete project-change checks, cancellation, recovery, and any native timeline preview/application retained in the final interface.
5. Verify mixed roles, connected items, transitions, and recovery in disposable audio-only projects before expanding supported output topology.

## Source layout

- `AudioPlugin`, `CutdownAudio.xcodeproj`: audio passthrough, native scalar parameters, factory without a custom editor.
- `Sources/CutdownApp`: background helper entry point.
- `Sources/CutdownCore`: rational time, detector, timeline validation, review and markers.
- `Sources/CutdownMac`: audio decoding, background processing, edited XML writer, AU settings, and experimental capture/Share integrations.
- `Sources/CutdownVerify`: read-only analysis or explicit edited-project output from existing artifacts.
- `Tests`: regression tests and XML fixtures.

The latest integration report is at `~/Library/Application Support/Cutdown/Integration/latest.json`.

The retired video source, app bundles, and installed templates were moved to Trash for recovery. `build/audio-only-retirement.json` records the exact locations. Their unused build cache and the redundant `.build` cache were removed; the shared `build/swift` cache remains in use.

### Dotted timeline preview (September 15)

Analyze now drives a transparent, click-through helper overlay with green dotted
START lines and orange longer-dashed END lines at each included removal.
Numbered labels distinguish each pair; END is the end-exclusive boundary. This is
an on-screen annotation, not a native Final Cut marker or an edit. Apply remains
separate. **Show Cut Preview** in the effect window hides or restores the lines without discarding the reviewed cuts. Analyze enables it, and closing the window leaves it active. Review changes update the boundaries; leaving review clears them.
The visible portion of the analyzed clip is sufficient. The overlay follows its name and exact
clip edges independently of selection, so deselecting the clip does not clear it.
Overlapping review windows mask only the covered portion. The overlay follows the visible Final Cut project window even when another app has focus. Windows in front of the project mask only their covered portions. It hides when the project is minimized/offscreen/on another Space, a modal is open, the analyzed occurrence changes or is ambiguous, or its geometry cannot be verified. No XML export or timeline mutation is needed to draw the lines.

The original preview helper build and 10 coordinator tests passed. The subsequent
labeled/persistent preview build passed and live Analyze reported both boundary
types while the review window remained open. In `Cutdown Button Verification`
inside `Cutdown Integration.fcpbundle`, live analysis produced two cuts and four
normalized boundaries (0.226667, 0.336667, 0.526667, 0.686667); the reported overlay
width followed timeline zoom from 1215 to 608 screen points. The helper's status
was recorded in `~/Library/Application Support/Cutdown/Integration/TimelinePreview.txt` (now written only during explicitly enabled diagnostics).
Final Cut's window-only screenshot excludes the separate helper surface, so
visual appearance/compositing has not been independently confirmed. Partial
visibility, multiple displays, and rapid scrolling require further integration
validation; this is not evidence of native in-place cutting.

## Native Apply validation and limits

- The first live native run applied two ranges to the original ten-second fixture,
  leaving three editable clips totaling 7.3 seconds. Before/after exports are
  regression fixtures (`native-range-before.fcpxml`, `native-range-after.fcpxml`).
- Full sequence fingerprints match after normalizing an omitted asset-clip
  `start` and an explicit zero start; nonzero starts remain significant.
- 75 core tests and 15 native/coordinator tests passed.
- The recovery XML imported into `Cutdown Integration.fcpbundle` and restored a
  ten-second `Recording` clip in a separately named before-cuts project. Final Cut
  quit during recovery-import UI inspection; the imported project survived reopening.
- Native Apply currently requires non-drop-frame display and a normal-speed
  primary-storyline audio-only target. Existing writer topology restrictions still
  apply; connected items and transitions requiring unsupported edits are rejected.
  Intermediate Accessibility validation may conservatively reject other layouts.
- On interruption, the report distinguishes verified cuts from deletion commands
  sent and gives the recovery path. Do not retry a consumed plan; analyze afresh.
- Recovery snapshots reference existing media and do not copy audio.

Final installed-build retest completed successfully: request `319D8702-0A76-4FC5-B728-9A7E64693359` reported **Applied and verified 2 cuts in the current timeline**. Evidence: `build/NativeApplyVerification/`.

Preview stability update: partial viewport visibility no longer hides the entire preview. Boundaries are mapped using the full clip width, then clipped to the visible portion; offscreen boundaries are not pinned to screen edges. The timer uses common run-loop modes, and one retained drawing view is explicitly redrawn instead of recreated on every tick.

The preview also reacquires the live timeline Accessibility object within the pinned project window after layout changes. Final build compiled and signed; its Accessibility refresh may require local macOS authentication.

Final preview stability build: existing Accessibility permission refreshed, Analyze returned review, and the helper reported a visible overlay on the fitted integration clip. Evidence: `build/PreviewStabilityVerification/`.

Preview visibility control: **Show Cut Preview** is installed. Fifteen coordinator/transport tests and the custom-view harness passed, including JSON-boolean command validation. Live testing in `Cutdown Audio Native` confirmed seven cuts, hide/show, continued Apply availability, and the checked state surviving window close/reopen. No cuts were applied. The helper confirmed hiding on request; after restoring and closing the window it reported foreground/geometry unavailable, so persistent visible compositing remains unverified. Evidence: `build/PreviewToggleVerification/`.

Effect-removal preview cleanup: the helper checks the analyzed occurrence when it is the sole selected timeline item and its Audio Inspector is readable. If Cutdown is absent for at least 0.5 seconds, it clears the overlay and stops its refresh timer. That analysis cannot restore the overlay after Undo/re-adding the effect; Analyze creates a fresh preview. Hidden Inspectors, other selections, and collapsed Effects groups do not establish removal. This uses Inspector observation, not a plugin deletion callback; removal through other workflows is detected once the target is selected with its Audio Inspector visible. Sixteen focused capture tests passed. Live testing in `Cutdown Audio Native` confirmed effect removal clears the preview, Undo restores the effect and all four settings, and the previous preview stays dismissed. No cuts were applied. Evidence: `build/EffectRemovalVerification/`.

Preview refresh consistency: timer callbacks now run directly on the main run loop instead of queuing asynchronous refresh tasks. Each verified frame restores the nonactivating overlay above Final Cut, even if AppKit still reports the obscured panel as visible. The panel follows Spaces, and coordinate conversion uses the fixed main-display origin. Hidden status now records specific causes (foreground app, modal dialog, clip match, or viewport geometry). Twenty-eight capture/coordinator tests passed, including foreground-independent window matching and occlusion masking. Diagnostics identified foreground-app changes as the recurring hide reason; preview visibility now uses the visible project window instead. Live verification passed in `Cutdown Audio Native`: the helper reported visibility after closing the effect window and switching focus to Codex; Zoom In updated the clip rectangle from width 1292 to 2584 with a negative offscreen origin. No cuts were applied. Evidence: `build/PreviewConsistencyVerification/`. Window-only captures still do not independently verify composed overlay appearance.

Preview drawing regression correction: the previous “visible” status only established that the panel was ordered in, not that boundary pixels existed. Live drawing capture reproduced a blank image. Masking now excludes non-application utility/system surfaces and surfaces at menu-bar level or higher, which had supplied a full-screen obstruction. The overlay renders a bitmap explicitly and assigns its CGImage to a backing layer, avoiding the blank live view-cache path. Eighteen capture/rendering tests passed, including an assertion that real colored pixels reach the layer. Live analysis produced seven visible boundary pairs in the actual rendering image after closing Controls; no timeline cuts were applied. Before/after drawing evidence: `build/PreviewMaskVerification/`. The user subsequently confirmed the green START and orange END lines are visible on the actual Final Cut timeline.

Docked-browser clipping: preview geometry now intersects the analyzed clip with every enclosing timeline scroll viewport. This excludes the Effects/Transitions browser inside the same Final Cut window while preserving the full clip rectangle for time mapping. Nineteen focused capture/rendering tests passed. Live testing in `Cutdown Audio Native` confirmed the overlay width is 1439 points with either browser open and expands to 1840 when closed, while the full zoomed clip stays 5168 points wide. Visible boundary pixels were inspected; no cuts were applied. Evidence: `build/BrowserPreviewVerification/`.

### Preview performance update (September 15)

The preview now uses retained `CAShapeLayer` lines and `CATextLayer` labels instead of rebuilding a bitmap. Geometry and mask equality checks skip unchanged layer updates. Start/end styling, viewport clipping, and overlapping-window masks remain in place.

A serial background worker reads cached Accessibility handles and window geometry. Accessibility notifications wake the sampler; fallback polling runs up to 30 times per second while active and about 7 times per second when idle. Identity/effect checks refresh every 0.5 seconds. Only one read may be in flight, and generation tokens discard late results after dismissal or a new analysis. An unresponsive host hides stale geometry. Final Cut read latency still limits how quickly lines can follow movement; this is not a guaranteed 30 FPS overlay.

Normal preview operation writes no diagnostic PNGs or status logs. For explicit profiling, create `~/Library/Application Support/Cutdown/Integration/EnablePreviewDiagnostics`, then Analyze. The first 120 samples produce one timing report and one drawing PNG; diagnostic failure/removal status remains available for that session. Remove the flag and Analyze again to return to normal operation. These files describe helper rendering and do not independently prove desktop compositing.

Validation: 32 focused coordinator/capture/rendering tests passed, including layer reuse, real boundary pixels, overlapping masks, and rejection of late callbacks. The installed helper was tested only in `Cutdown Audio Native` in `Cutdown Integration.fcpbundle`. Analyze returned seven ranges; Show Cut Preview remained usable; effect removal logged dismissal, and Undo restored the effect and settings. Final analysis completed with profiling disabled. No cuts were applied in this preview test.

A 120-sample live capture measured mean background read time of 7.34 ms (maximum 93.93 ms) and mean main-thread presentation/update time of 0.125 ms (maximum 10.97 ms). Presentation samples include unchanged frames and initial layer construction, and exclude compositor work. Forty AX notification registrations succeeded. There is no comparable pre-change timing capture, so these are current measurements, not a speedup ratio. Evidence: `build/PreviewPerformanceVerification/`.

### Maintenance pass (September 15)

- PCM readers now throttle progress notifications to at most ten intermediate updates per second, plus immediate first/final reports. Every measurement window is still decoded and analyzed; completion is emitted once. This reduces main-thread tasks and review transport writes on long recordings.
- Analysis callbacks arriving after completion, failure, cancellation, or transition to Apply can no longer overwrite the current review status.
- Preview publication follows successful review serialization/transport. A failed review clears its preview, and unrelated rejected jobs cannot dismiss the active preview.
- Vector redraws compare the boundary list once per update instead of once per boundary, avoiding quadratic list-comparison work when scrolling or zooming many cuts.
- The helper's startup status correctly describes native timeline cuts and the recovery snapshot.

Two review-state regressions were reproduced before the fixes. The complete Swift suite then passed: 164 Mac tests and 75 core tests (239 total), including new throttling and real PCM source-trim/render checks. The helper compiled and was installed. Existing macOS access was refreshed, and live Analyze passed in `Cutdown Audio Native` inside the workspace `Cutdown Integration.fcpbundle`: seven proposed cuts, stable completion, preview enabled, and separate Apply available. The temporary test effect was removed afterward, leaving the original audio clip and duration intact. No cuts were applied; no native Apply test is claimed for this maintenance pass. Logs: `build/maintenance-regression-before.log`, `build/maintenance-tests.log`, and `build/maintenance-build.log`.

### Apply failure on compact retained segments (September 15)

The seven-cut recording stopped after two verified removals because Final Cut omitted Title/Leading Edge/Trailing Edge children for a four-frame retained segment. The live item still exposed `Audio-Clip:<name>`, exact duration, and its Item start time. The previous verifier misreported this compact representation as a changed project.

Native verification now snapshots each item's attributes once and accepts this compact representation only for supported primary-storyline audio clips with exact name, start, and duration. Any conflicting exposed title/edge, missing/duplicate Item position, or ambiguous match still fails. The selected deletion range retains its complete boundary/focus checks, and final source/effect/project verification still compares the full XML fingerprint. Errors now identify the unmatched interval or clip-count discrepancy.

Validation: 38 focused tests passed. A separate `Cutdown Apply Compact Regression` project in the existing workspace `Cutdown Integration.fcpbundle` reproduced the same source/settings. All seven native cuts completed and the final XML fingerprint matched: 74.6 seconds became 58.7 seconds, with eight editable audio segments and Cutdown retained on each segment, including four-frame ends. The original partially edited project and its original recovery snapshot were preserved. No source media was copied. Final Cut crashed in AppKit text-control recursion after the test XML import; the imported project survived reopening, and the subsequent Apply completed without that interruption. Evidence: `build/ApplyCompactVerification/`; test/build logs: `build/apply-compact-tests.log` and `build/apply-compact-build.log`.

### One-second gap output

The audio effect window offers **Output → Remove Silence** (existing ripple cuts) or **Replace with 1-Second Gaps**. Choose the mode before Analyze. Changing it invalidates Apply until a fresh analysis; it is locked during application. The output choice is bound to the analysis request. The review summary includes all inserted gap time. Each selected quiet range becomes one editable gap, even when the quiet range was shorter than one second, so this mode can lengthen short pauses. At fractional frame rates, the gap uses the closest whole-frame duration (for example 1.001 seconds at 29.97 fps).

Gap Apply uses Final Cut's native **Edit → Replace with Gap**, verifies the intermediate timeline, selects the exact new gap, then changes its duration to one second and verifies again. It proceeds latest first, keeps the existing before-cuts snapshot and final XML fingerprint checks, and preserves the same supported topology restrictions as ripple mode. Cancellation/failure can leave a same-length gap if interrupted before resizing; recovery reporting identifies the completed ranges and attempted range edits. Do not assume an interrupted gap has already reached one second.

Validation: the full Swift suite passed 246 tests, the output-selector harness passed, and the native menu correction passed 43 focused tests. A manual native gap probe confirmed Final Cut's `start="3600s"` gap source clock and one-second duration. Gap evidence is in `build/GapVerification/`. The full live test passed in `Cutdown Gap Regression` inside the existing `Cutdown Integration.fcpbundle`: seven one-second gaps, eight retained audio segments with their effects, 74.6 → 65.7 seconds, and an exact final XML fingerprint match. The retained source intervals also match the previously verified ripple result. No source media was copied.
