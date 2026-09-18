# Native Final Cut fixtures

The `final-cut-12-3-*` fixtures came from Final Cut Pro 12.3 exports of generated local media inside the required `Cutdown Integration.fcpbundle` library. File URLs, library and media identifiers, timestamps, and bookmark data are sanitized. The paired `native-range-before.fcpxml` and `native-range-after.fcpxml` fixtures use the same neutral identifiers and placeholder bookmark data; their timeline edits are preserved.

`timeline-context.fcpxml` uses a trimmed, repeated audio-only recording with connected speech, music, titles, markers, and audio effects. It exercises project timing and preservation around an audio target. The historical `final-cut-12-3-basic.fcpxml` video export is retained only to verify that video remains readable timeline context and is rejected as a Cutdown target; video effects must remain part of the project fingerprint.

`final-cut-12-3-native-audio-after-cuts.fcpxml` records a computer-use integration test after a recovery snapshot was verified. Two analyzed ranges were deleted from latest to earliest using Final Cut's native range deletion. The result has three editable audio clips, preserves their Cutdown Audio effect instances, and lasts 7.3 seconds. The regression derives retained source intervals from the silence detector's proposed cuts and compares them with this exported result.

This proves the native editing behavior for the generated single-clip audio fixture. It is not a run of an implemented Cutdown application automation driver, and it does not establish connected-item preservation for more complex projects.
