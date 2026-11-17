# Using Silent Snip

Silent Snip analyzes one selected clip, lets you review proposed cuts, and creates a cleaned copy of the project. The original project and source files stay unchanged.

Complete [setup](setup.md) first. Keep Final Cut in front while Silent Snip operates its Share panels and project controls.

## 1. Select a clip

Open a project, select a clip with audio in the primary storyline, and choose **Window → Extensions → Silent Snip**. Click **Connect to Final Cut Pro** if shown. The top bar shows the selected clip's name. No Silent Snip effect is required.

To analyze part of the clip, use Final Cut's Range Selection tool (**R**) to select a span within that one clip. Cut Review shows the analyzed span, and cuts stay inside it.

## 2. Set detection and output

| Setting | Default | What it does |
| --- | --- | --- |
| Silence Threshold | −40 dBFS | Audio below this level in every channel counts as quiet. Move toward zero to include louder pauses. |
| Minimum Silence | 0.5 s | Minimum removable pause after speech padding and frame alignment, before Target Pause shortening. |
| Before Speech | 0.1 s | Quiet audio to keep immediately before speech resumes. |
| After Speech | 0.1 s | Quiet audio to keep immediately after speech ends. |

Detection measures loudness in 0.01-second windows. It does not identify speech or breaths. Minimum Silence accepts 0.0001–10 seconds; very short values still depend on measurement and frame alignment.

Choose an output mode:

- **Remove Silence** closes each included removal. Set **Target Pause** above 0 to retain some original room tone: a 0.4-second target shortens a qualifying two-second pause to roughly 0.4 seconds. Shorter pauses stay intact. Use 0 for standard removal.
- **Replace with 1-Second Gaps** replaces each included range with an editable gap, rounded to the nearest project frame. This can lengthen a pause that was shorter than one second.

Cuts snap inward to boundaries shared by video frames and audio samples. Padding and alignment can leave more silence than the target. For example, 29.97 fps with 48 kHz audio uses a five-frame cut grid.

Use **Save Settings** to store detection and output values for this project. Settings are saved separately for each library/project identity.

## 3. Analyze audio

Click **Analyze Audio**. Silent Snip captures the project and checks the selected clip and media. It reads source audio for unprocessed clips and uses a checked Final Cut render when processing requires it.

Analysis proposes cuts; it does not apply them. If no usable silence is found, the review explains why and Apply stays disabled. **Cancel** stops an operation or discards a review.

Closing the extension or changing projects clears its active review. Reopen the extension and analyze again to edit.

## 4. Review the cuts

Check the proposed start, end, and duration of each cut. The timeline preview uses green start boundaries and orange end boundaries, with numbers matching the list. These are preview overlays; the timeline has not been edited yet.

| Action | Control |
| --- | --- |
| Keep or cut a pause | Toggle its checkbox, or press **Space** on the active row |
| Move between rows | **Up / Down** while the list has focus |
| Jump to a cut | **Go to Cut**, double-click its row, or press **Return** |
| Select a group | **Shift-click** or **Shift–Up / Shift–Down**, then **Keep Selected / Cut Selected** |
| Include or exclude all eligible cuts | **Select All / Deselect All** |
| Narrow a removal | Use its **Start / End** steppers; **Reset Cut** restores the proposal |
| Audition plain source audio | **Play Original / Play Proposed Cut** |

Audition includes a short amount of audio on each side of the cut and uses the same source level for both versions. It is available for plain source audio. Unavailable cuts explain their restriction and remain unchecked.

### Change settings during review

Valid detection or output edits refresh eligible ranges after a 250 ms pause, using the last analyzed audio. Apply and other cut actions wait for the latest update. Typing, pressing Return, and saving settings do not start another audio export.

Unchanged cuts keep their inclusion choices and boundary adjustments. When a kept pause splits or merges, the affected cuts stay unchecked and show **Review**.

Use **Analyze Again** after changing volume, effects, presets, bypass, source media, or timeline content. Also use it when the analyzed layout cannot refresh ranges from retained audio.

## 5. Apply cuts

Click **Apply Cuts** when you have at least one eligible cut selected. Silent Snip:

1. Rechecks the project, source media, settings, and reviewed cuts.
2. Saves recovery XML and the edit report.
3. Creates one uniquely named cleaned project in the original event and library.
4. Opens that project and checks its timeline, source references, and supported effect state.

The cleaned project contains the full supported edit, with retained source clips still trimmable. Linked camera audio and video receive the same cuts; compatible surrounding items follow the edit. Supported audio effects remain editable.

Listen around the joins and continue editing in the cleaned project. Delays, reverbs, and other effects with memory can react differently to the new boundaries even when their settings are preserved.

If Apply is interrupted, check for an existing result before trying again. Use [result recovery](recovery.md) to finish its checks without importing another project.

## Supported clips

The target must be one normal-speed direct media clip in the primary storyline, with enabled audio and available source media. Audio-only clips and linked camera audio/video are supported. Selecting a range limits cuts within that clip; it does not expand the supported layouts.

Retimed, compound, multicam, or connected targets; split audio/video edits; unsupported transitions; component trims; nested connections; and cuts crossing fades can prevent output. Simple connected music or B-roll can follow supported cuts, but connected dialogue and conflicting lanes can block the edit.

### Clips with audio effects

Final Cut XML can omit private effect settings. To retain those settings, Silent Snip uses native Copy and effects-only Paste Attributes on a narrower layout:

- One enabled audio-only clip fills the whole project, with no clip fades.
- Static effects are applied directly to that clip.
- The audio is eligible for the original project's Dialogue render.

Both removal and one-second-gap output use this route. Gaps are excluded from the effects transfer. Animated effects, component-level effects, and effects on broader project layouts can block Apply, even when analysis succeeds.

Keep the original native project and media. Recovery XML alone cannot restore effect settings that Final Cut leaves out of its exports.
