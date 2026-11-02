# Sounder project preferences

## Notifications and UX hints

- Do not add permanent status messages or instructional captions to the main interface (including the footer, timeline heading, and empty timeline).
- Present action feedback as rectangular notifications in the upper-right corner of the active application window.
- Successful edits and saves: green background, white text. Errors: red background, white text. UX hints: yellow background, dark readable text.
- Size each notification to its text plus horizontal padding, align right edges, and wrap long messages at the viewport-aware maximum width.
- Every message remains for 5 seconds independently. Append newer messages below older messages. Animate remaining messages upward when earlier messages expire.
- UX hints trigger at the relevant interaction and appear only once per running app session. Do not persist their seen-state across launches, and do not reset it on project open, save, or Undo/Redo.
- First actual drag of a track header: "Drag tracks to nest". First selection of an audio fragment: "Shift click to multi select".
- Opening or refreshing an editor or effects panel is not a successful edit and must not emit a success notification. Transport state belongs in transport controls, not success notifications.
- Use the shared ToastCenter and ToastOverlay for future features. Keep decision dialogs for actions requiring a choice; operational errors use notifications.

- Muting or unmuting a track must not emit notifications; the MUTE control shows its state. MUTE remains clickable with the standard arrow cursor during playback. Update the streaming graph on its worker without stopping audio, seeking, rebuilding the graph or resetting plug-ins. Parent mute silences its subtree; unmute also works for tracks muted before Play.
- Track and fragment deletion notifications use a red background with white text.
- Successful splitting or moving audio fragments must not emit success notifications or UX hints.
- Invalid FRAGMENTS actions (Split, Trim, Delete, Join) show a yellow selection/instruction notification on every attempt, including repeated clicks. Successful Split and fragment moves remain silent. Only first-drag and first-selection onboarding hints are limited to once per session.

## Button cursors

- Use PointerButton for app-owned clickable buttons, including all icon buttons. Buttons and icons use the standard arrow cursor. Provide subtle Apple-style hover feedback: a lighter circular background for icon buttons and a rounded highlight for text buttons, including MUTE/SOLO/FX. Disabled controls do not highlight. Keep I-beam cursors for editable text and dedicated resize/fade cursors.
- Track rename hit areas and I-beam regions cover only the rendered name text, not the rest of the header or the nesting arrow. Edit project and track names inline at the label position, without a popup, field background, border or automatic select-all. Activation must preserve text geometry and neighboring positions; grow the editor with the typed text, capped at its existing layout boundary. Limit project and track names to 100 Swift Characters (including spaces; do not split emoji). Scroll overflowing inline text horizontally to keep the insertion point and latest typed character visible after layout. Enter commits a nonempty trimmed name, Escape cancels, and leaving the field commits a valid name (an empty field retains the previous name). Keep transport shortcuts inactive while typing.
- Project and track rename targets use the I-beam text cursor. Track MUTE and FX controls use the standard arrow cursor. Refresh timeline cursor regions when tracks, layout, or editing availability change.

## Numeric fields

- Use the shared NumericInputFormatter for app-owned numeric inputs. Reject invalid edits and pasted strings before they enter the field: ASCII digits, at most one decimal dot/comma, and an optional leading minus/plus only for signed fields (Volume, Pan, Normalize). Fade durations and BPM are unsigned decimals. Metadata Year accepts digits; track/disc numbers also allow one slash for number/total. Keep clearing, selection replacement, caret editing and intermediate signs/decimal separators usable. Preserve range validation on Save and native text shortcuts. Display small programmatic numbers without exponent notation. Names and descriptive metadata remain unrestricted text.

## Project audio format

- Tracks inherit the project's sample rate, Mono/Stereo mode, and recording/export bit depth. Do not show per-track fragment counts or format captions.
- Preserve imported and recorded source files. Convert from each original source directly to the current project rate while preparing the mix; changing format must not accumulate resampling losses.
- Use AVAudioConverter's Mastering algorithm with maximum quality and proper priming. Verify passband fidelity, alias rejection, timing, and mixed-source formats when changing conversion code.
- Mix and run effects in Float32; apply the chosen PCM bit depth once to final playback/export and use it for new recordings.

## Waveforms

- Waveforms fill the fragment height. Draw fragment names over the waveform, with no reserved title row. Do not draw a RECORDING label or indicator icon inside the live recording fragment.
- Draw stereo fragments as separate waveforms: left channel above right, using actual per-channel PCM peaks for both imported audio and live recording. Mono sources use one waveform.

- Fragment waveforms use peaks of actual dry output samples after volume/normalization, output-channel pan and fade curves. Respect baked fades and project Mono/Stereo routing, including mono sources panned in stereo and phase cancellation in mono. A mono source with pan exactly zero displays one full-height waveform regardless of project format; panned mono sources in stereo display both output channels. Prepare peaks off the UI thread, cache per fragment settings/source bounds/format, cancel stale work, and do not apply gain or envelopes a second time while drawing cached peaks.

## Live recording

- Record remains available during ordinary playback (toolbar, Transport menu and R); disable it only during capture, shuttle, microphone permission/setup, import or normalization. Punch in on the active track without stopping/rebuilding the current playback engine or node. From stopped, prepare the backing mix before opening capture and start its prepared node once capture is ready, at the selected cursor. Continue the backing transport through silence beyond existing fragments until capture is stopped. Mix the metronome once on the backing output, never into the microphone file. Show other tracks' playback meters alongside the recording track's input meter. Space/Stop finalize capture and stop both transports; Enter discards the current take and seeks the same backing engine to the recording start before starting its replacement. Preserve backing playback after capture setup failure and restore normal end-of-project behavior.

- During recording, Space finalizes and retains the take and returns the cursor to its recording start. Enter (including keypad Enter) discards the current unsaved take and its file, then immediately starts a fresh take on the same track at the same recording start. Discarded takes must not consume take numbers or create Undo entries; keep earlier fragments intact.

- Draw the recording waveform incrementally from actual incoming PCM buffers before Stop. Do not substitute metering values or generated waveforms in production.
- Keep capture conversion and file I/O off the UI thread; publish incremental peaks rather than repeatedly copying all previous waveform data.
- Finalize the recorder before reading the finished WAV. Retain already captured audio on a recording error.

## Live plug-in editing

- Plug-in editors are nonmodal and have no Apply/Cancel controls. Parameter edits immediately affect the shared live processor; closing an editor retains changes in memory. Only project Save writes plug-in settings to disk.
- Replenish queued playback buffers on consumption, not device presentation completion. Use presentation completion only for the final buffer, and retain a short render-ahead margin to prevent underruns.
- Keep plug-in processing on the playback worker in short blocks, preserve child-to-parent routing and compensate parallel bus latency. Export uses current in-memory parameter state.
- Opening an editor must not mark the project dirty; actual parameter changes do. Saving with an editor open must capture its latest settings.

## Audio import

- After selecting multiple files, show an English placement dialog with Separate tracks first and selected by default, followed by One track, and Import/Cancel. Single-track placement is sequential; separate-track placement starts at the captured active track, follows visible hierarchy order below it, and gives all fragments the same captured cursor time. Create missing root tracks with the corresponding imported fragment names (respecting track name limits). Keep existing tracks/fragments intact; commit successful files and any new tracks together as one Undo action. Single-file import does not show this dialog. Within this modal window, Tab/Shift-Tab and Up/Down cycle the radio selection immediately, regardless of system keyboard-navigation preferences; Enter and Escape retain Import/Cancel behavior. Scope the key handler to this dialog and remove it when closed.

- Show a nonmodal import window immediately after file selection, with each file's own progress and outcome. Keep copy, decoding, resampling and waveform preparation on a worker queue.
- Publish prepared PCM and waveform data into the main-thread audio cache under the final copied source path before inserting fragments. Timeline drawing must not decode imported files again.
- Allow cancellation, remove incomplete copies, preserve source files and keep successful files when another file fails. Treat a completed batch as one Undo action.

## Playhead and seeking

- Single timeline clicks seek while preserving the selected time range. Only a double click clears the range, including on its handles, fragments and empty space.

- Dragging on the ruler selects a time range without seeking or stopping playback. Defer ruler click seeking until mouse-up without a drag. Highlight the range on the ruler and fragment area; its ruler edges are draggable with the horizontal resize cursor, without moving the playhead.
- Clicking the timeline ruler, a fragment, or empty timeline space seeks to that time. During ordinary playback, keep the same running engine, node, graph and effect instances; coalesce pending seeks on the worker, jump directly to the new dry PCM position, clear routing delays and pre-roll only declared effect latency. Keep ongoing effect tails rather than replaying project history. Crossfade the next source boundary over 10 ms without clearing queued audio. Use a short render-ahead margin (three 512-frame buffers at 48 kHz, scaled at higher sample rates); map the cursor to the audible output clock, switching position when the transition reaches output, without a visual jump ahead and back. Repeated arrow seeks accumulate from the pending target. Store processed cache regions at their absolute frame positions; skipped spans must never be treated as cached silence. If stopped, only reposition the cursor. Play starts from the selected playhead, independent of scrolling or the previous playback position.
- Pause via Play/Pause or Space plays a 10 ms fade-out at the next queued boundary, then pauses only the player node. Keep the engine, immutable PCM, graph and plug-in instances prepared while the project is unchanged; do not process effects while paused. Follow the audible position until the fade completes, then freeze the cursor. Resume from that visible cursor with a 10 ms fade-in and no engine restart or history warm-up. Coalesce rapid pause/resume toggles and ignore callbacks from obsolete node generations. A stopped timeline click changes the resume position without moving it back to the cached pause point. Discard the retained transport on project edits, open, recording, explicit Stop or shuttle; validate the project key again before reuse. The explicit Stop icon/menu/Escape stops and returns to the last playback start notch (zero before the first start), bringing it into view; when recording, return to the recording start. Keep gesture cancellation ahead of Stop. The next Play uses the visible cursor; a retained prepared transport must flush obsolete queued buffers before resuming, and must never override a newly selected stopped position. While playing, the cursor follows the render clock monotonically; missing timestamps must not reset it. Do not silently reset a selected position beyond the project end to zero.

- Natural playback completion (including effect tails) stops audio and returns the cursor to the last-start notch. Pause and playback errors retain their current position; stale completion callbacks must not move the cursor.

- Enter (Return or keypad Enter) always starts playback from the last successful user playback start, whether stopped or playing. During playback use the existing live seek/crossfade; from pause reuse the unchanged prepared transport with a fade-in. Show that position as an orange vertical notch on the ruler. Play/Space and live timeline seeks update the marker; Stop, stopped seeking, range selection, and internal effect-chain restarts do not. Before the first start, Enter starts at zero; opening a project clears the marker.

- Command-Left seeks to time zero; Command-Right seeks to the end of project audio, showing the destination in the viewport and preserving active playback when audio remains. Keep native Command-arrow text navigation in editors.

- Unmodified Left/Right restore the historical one-percent-of-visible-fragment-width seek step in both seconds and Tempo modes, preserving active playback and horizontal centering. Shift-Left/Right start shuttle immediately at the current source position, without a fixed seek step or hold timer. Start from zero velocity when paused. During Play keep the same audio engine, player node and queued output: Right smoothly accelerates from the existing forward velocity; Left brakes through zero then reverses, like tape. Direction changes preserve position and signed velocity at the next queued sample. Bound speed to 8x; OS key repeat must not restart motion. Use the same signed speed integral for resampling and cursor display, including turns inside an audio block. Preserve queued audio at transitions; do not stop/restart the live stream on arrow-down or add a fade-to-silence there. On arrow or Shift release preserve position, signed velocity, engine and queued samples. If Shift is released first, suppress repeats from that held arrow until key-up so they cannot interrupt the glide with ordinary seeks. Settle to zero or +1x over 0.5 seconds regardless of the current shuttle speed; keep held-key acceleration unchanged. If previously paused, ramp to zero and stop only after the last deceleration samples are audible, leaving the cursor at that final position. If previously playing, ramp to +1x (negative speed must brake through zero and turn forward); do not stop/restart the engine. Rebuild/warm the normal effect graph on a cancellable worker, sharing immutable dry PCM, then crossfade the source over 10 ms on the same node with unchanged fractional sample phase. Normal live Mute/Solo/FX and metronome must still work after return. Keep release in the transport's busy state until audible settling completes. New arrow presses cancel/re-target release; Stop/focus/seek cancel it immediately without a delayed restart. Stop, focus loss and new transport actions cancel shuttle; an older opposite-key release must not cancel the newer direction. Preserve native text/dialog/plugin arrows and Command-Left/Right boundaries. Transport menu Seek Backward/Forward retains the one-percent viewport step.
- Center ordinary playback and shuttle horizontally using the same viewport geometry as zoom, clamped to timeline bounds and preserving vertical scrolling. Keep existing recording edge-follow behavior.
- Cache rendered post-effect mix PCM temporarily on disk for shuttle audition; reuse valid rendered regions, with latency compensation, and render uncached small source windows dry without instantiating effects. Respect gain, pan, fades, Mute, Solo and parent routing. Smooth cached/dry transitions over 10 ms. Invalidate stale mix caches on audio/routing/plugin edits and project reconciliation; never persist cache PCM in projects. Keep normal live playback processing its graph so FX/routing edits remain responsive. Worker-owned source snapshots must not mutate the main audio cache; decode off the UI thread. Use integer frame windows to prevent rounding gaps. Unlink temporary mix files while open so forced exit cannot leave them behind.

## Timeline ruler

- Pin the track header column (names, nesting indicators, MUTE, FX and blank-space context menu) to the left while scrolling horizontally. It follows track rows vertically. Keep the TRACKS corner fixed on both axes and prevent hidden fragments or ruler controls from receiving sidebar clicks. Zoom centering and arrow seek distances use the viewport width minus the full pinned column.

- Pin the ruler (including TRACKS, time/tempo labels, range handles, playhead marker and last-start notch) to the top of the visible timeline during vertical scrolling. Horizontal scrolling stays synchronized with fragments. Ruler interactions must not trigger track controls underneath or vertically autoscroll during range selection.

## Timeline zoom

- Zoom in and Zoom out center the playhead horizontally in the visible fragment area after scaling, accounting for any visible track-header portion and clamping to the timeline bounds. Preserve vertical scrolling and playback position.

- Up arrow zooms in and Down arrow zooms out, using the same actions and limits as the View buttons. Preserve arrow navigation in text fields, dialogs and plug-in windows.

- Zoom out stops when the complete timeline width fits the scroll viewport, including the track header. Derive the minimum zoom from the viewport width and timeline duration rather than a fixed pixels-per-second floor. All fragments must fit, reset horizontal scrolling at the limit, and keep ruler labels readable for long projects.

## Window header

- Render the project name as plain text with an I-beam cursor, without button chrome. Allow up to 640 pt for the project name; use 13 pt semibold for both display and editing, and a smaller 10 pt audio-quality caption. Explicitly set the project NSToolbarItem.isBordered to false so macOS does not wrap the custom title view in a glass bezel. Keep the editable project name, clickable project audio quality immediately after it, and Open project, Save project, Export controls in the native compact titlebar toolbar. Hide the system window title. Omit the app icon and Sounder wordmark from the titlebar; retain the application icon for the Dock and Finder. Place the PLAYER/FRAGMENTS/TRACKS/VIEW panel directly below the titlebar, with no separate project header row or extra vertical gap.

## Export

- Put a Metadata disclosure button at the left of the Export audio footer. Expand editable track name, artist, album, album artist, composer, genre, date, track/disc number, copyright and comment in the same dialog; collapsing must retain edits. Write tags to MP3 (Unicode ID3v2), OGG (UTF-8 Vorbis comments) and WAV (RIFF INFO plus ID3). Keep audio samples/range unchanged. Commit metadata to project properties only after a successful file export, support Undo, persist on project Save and restore on reopening export. Cancel or failure must preserve previous metadata and existing destination files.

- Show an initially unchecked Selected range checkbox at the bottom of Export audio only for a nonempty timeline selection. When checked, export exactly that captured interval for WAV/MP3/OGG, preserving pre-range effect history and padding selected empty timeline space with silence. Crop at the project rate before final resampling. Keep the range choice transient; normal format settings retain their existing persistence.

- Give the Export button comfortable horizontal padding. Disable both the titlebar button and File menu export action when the project has no audio fragments or editing is busy.
- Label the titlebar button and File menu action Export. Open export options before choosing a destination; offer MP3 (default), WAV and OGG. First use inherits project rate and depth; remember export choices only after a file is successfully written, and save those last successful choices inside the project, independently from project audio settings. Cancel must not export a file.
- PCM bit depth is editable for WAV only. MP3 offers supported rates up to 48 kHz and bitrate selection; explain codec constraints in the dialog. Use built-in encoders, preserve channels, process effects at the project rate and resample the finished mix only once using Mastering quality. Failed exports must not damage an existing destination.

## Tempo and metronome

- Tempo settings include a Tap button beside the BPM field. Compute BPM from monotonic tap intervals using a rolling recent window, update the field on every tap after the first, reset after a long pause and ignore accidental double taps. Keep values within 20–300 BPM and retain Save/Cancel semantics.

- Place Tempo, Metronome and the timer/BPM display in the pinned top-left timeline corner in place of the TRACKS caption. Use one vertically centered row: timer/BPM, flexible space, then metronome icon immediately before Tempo pinned to the right edge beside the timeline. Use matching 18 pt light monospaced timer/BPM fonts and pin the controls on both scroll axes. The metronome uses an outline icon when off and a filled orange icon when on.

- Show the metronome icon only in Tempo mode, immediately to the left of Tempo. BPM uses exactly the timer font (18-point monospaced digits, light weight).
- Active Tempo uses an orange button background and an orange BPM value. Selected Tempo and Metronome controls retain their orange active appearance even while a modal dialog makes the main window inactive. While playing or recording in Tempo mode, replace the BPM text with the current 1-based bar.beat at the transport cursor, using current BPM and four beats per bar; restore editable BPM when stopped. Keep its font and orange color, follow seeks and capture progress, and retain click-to-edit-tempo. Tempo toggles a 4/4 bar/beat ruler and replaces the timer with clickable BPM (20–300, initially 120). A Metronome icon button controls audible clicks during playback and recording, with a stronger first beat every four beats. Persist BPM, ruler mode and metronome choice in the project.
- Derive metronome timing from audio frames and absolute timeline position, not UI timers. Seeking and recording restarts must preserve beat alignment. Mix playback clicks only after track effects; route recording clicks to the output mixer separately from the microphone input tap. Never include the metronome in recorded files or exports. Tempo and metronome changes must not stop active capture or playback.

## Track dragging

- Limit nesting to two levels below a root (depths 0, 1, 2). Validate the whole moved subtree for both live previews and commits, and reject adding a third nested level without an Undo entry. Never silently change routing in an over-depth project loaded from disk.

- Preview track order and nesting live during header dragging, including the entire child subtree and all waveforms. The top/bottom quarter of a target row inserts before/after its subtree; the middle nests under it. Empty space below the rows moves to the root at the bottom. Resolve targets against a stable drag baseline to avoid oscillation. Commit once on mouse-up with one Undo entry; Escape/Stop cancels without a model change, and never permit nesting into the dragged subtree.

## Settings windows

- Tempo uses a compact dialog approximately 227 pt wide (two thirds of the former 340 pt), with BPM, Tap, Save and Cancel fitting within it.

- Audio settings, Track effects, Export audio and Tempo show their title and controls without an app icon or descriptive introductory text. Remove the space reserved for those descriptions and icon area; keep a compact top margin above the heading. Use CompactSettingsAlert for modal settings forms rather than the standard alert icon layout. Keep actionable export validation errors visible only when needed.

## Fragment marquee selection

- Drag on empty fragment-area space (including below all tracks) to select intersecting fragments with a live rectangular marquee. Shift adds to the selection captured at drag start. Preserve the playhead and active playback during marquee selection; only a background click without a drag seeks on mouse-up. Keep ruler range gestures and fragment dragging intact. Clip the marquee behind pinned headers, autoscroll at viewport edges, and restore the original selection/range on Escape. Selection changes do not create Undo entries.

## Fragment edge resizing

- Drag a fragment's left or right edge to trim or restore source audio non-destructively. Keep the opposite edge fixed, enforce a 10 ms minimum and source-file bounds, and never extend left of timeline zero. Show a horizontal resize cursor only on exposed edges. Preview live without seeking or changing tracks; commit once with one Undo entry and allow Escape/Stop to cancel. Keep body dragging and overlapping-fragment hit order intact.

## Fragment alignment

- While moving a fragment to another track, snap its start or end to other fragments' boundaries, and preserve its original time on near-vertical moves. Use the nearest match strictly within 1% of the visible fragment area's time span, excluding the pinned sidebar; derive the threshold again after zoom or viewport changes. Show a vertical dashed guide across all visible track rows while matched, clear it outside the threshold and on drop, and preserve source offsets/duration and single-step Undo.

## Group fragment dragging

- A plain click on a selected group member selects only that fragment on mouse-up. Preserve the group on mouse-down so an actual drag still moves it together. Shift-click toggles selection; selection-only clicks do not create Undo entries. Apply the same plain-click behavior to fragment edges when no resizing occurs.

- Dragging the body of any selected fragment moves all selected fragments with one common time delta and preserves their time spacing, source offsets and durations. Clamp the whole group at timeline zero, never individual fragments. On cross-track moves, preserve relative visible row offsets and clamp the group to existing track bounds; preview every selected waveform on its destination. Snap the whole group rigidly, exclude its members from snap targets, retain selection after drop, and use one Undo step for all time/track changes. Shift-click toggles membership on mouse-up; Shift-drag keeps the group together and bypasses Tempo snapping. Edge resizing still affects only the grabbed edge's fragment.

## Fragment context menu

- Right-clicking a selected fragment preserves the entire selection; right-clicking an unselected fragment selects it alone. Open Move up, Move down, Delete without seeking. Apply each action to the selection captured when opening the menu, across all tracks, in a single Undo step. Layer moves skip selected neighbors and process the leading edge first so stacked selected fragments do not swap or cancel each other. Enable a direction if any selected fragment can move past an unselected overlapping neighbor. Move up/down advances one overlapping layer on the same track, preserving all other fragments' relative order, timing and source bounds. Disable a direction when no overlapping neighbor exists there. Use the same order for waveform layering and audio overlap priority, support Undo/Redo, and keep layer changes silent. Delete removes the whole context selection and uses the existing red notification. Track menus belong to the sidebar, not empty fragment space.

## Fragment clipboard and duplication

- Command-A selects all fragments. Command-C writes an immutable group snapshot to the system pasteboard; Command-V creates fresh fragment IDs at the cursor, anchoring the earliest selected fragment there and preserving time spacing, relative visible track rows, source offsets, durations and overlap ordering. Use the active track as the first destination row and create missing root tracks as needed. Keep native text Select All/Copy/Paste in inline editors and other text fields. Paste is a single Undo action. Command held when a fragment drag begins creates live preview copies and leaves originals untouched; retain group spacing and snapping, select the copies after drop and undo duplication in one step.

## Keyboard layout independence

- Split uses the unmodified physical S key (including Russian ы), shown as S in the menu and toolbar tooltip. Resolve app-owned letter shortcuts by physical key codes in the main editor window while respecting their exact modifier masks, validation, dialogs and plugin windows. Keep normal typing and native text shortcuts in text editors; Command-S remains Save. Arrow and transport key codes remain layout-independent.

## Fragment normalization

- Normalize is available from FRAGMENTS, the Fragments system menu and the fragment context menu, applying to the captured selection. Use unmodified physical N (including Russian т). Show a compact Normalize dialog with Maximum level in dBFS, Process and Cancel; accept -120…0 dBFS, initially -1 dBFS. Remember the last successfully processed level in the project and use it on reopening the dialog. Analyze the actual selected source interval off the UI thread, independently per fragment with linked stereo-channel gain; leave silence unchanged. Apply non-destructive gain before track effects, reflect it in waveforms, preserve originals and source bounds, and support one-step Undo/Redo. Gain and the level must survive save/load; legacy clips use unity gain. Splits, trims, clipboard copies, playback, export and joining must honor gain without applying it twice.

## Fragment muting

- Provide a Mute/Unmute toggle in FRAGMENTS, the Fragments system menu and the fragment context menu. Apply to the whole selection across tracks with one Undo step: mute a mixed/unmuted selection, unmute when all selected fragments are muted. Dim muted fragments without hiding their waveform or selection. Persist per-fragment mute in the project and clipboard; legacy clips default to unmuted. Exclude muted clips from playback/export/joins, allowing underlying unmuted overlaps to sound. Keep fragment mute edits silent and subject to normal fragment-edit availability. Track MUTE remains independent.

## Automatic fragment fades

- Apply 10 ms linear fade-in/out in the shared dry fragment renderer before track effects. At overlaps, crossfade the incoming/outgoing fragment against the already composed underlying audio, retaining newest-fragment priority outside the ramps and linked stereo weights. Short fragments cap ramps at half their length; use absolute fragment bounds so seeking, range export and streaming block boundaries do not restart fades. Preserve source files and duration. Join bakes the existing fades/crossfades and marks its two edges as baked to avoid applying them twice; split, trim and resize restore automatic fading on newly created/changed edges. Persist baked-edge metadata with legacy defaults false.

## Fragment settings

- Double-clicking a fragment (including its edge) or its context Edit opens a compact Edit fragment dialog for that fragment only. Single clicks retain selection behavior. Provide volume -48…+24 dB limited by the source interval's peak and normalization gain to keep individual peaks at or below 0 dBFS; pan -90…+90 degrees; independent fade-in/out times in ms and Linear, S-curve, Exponential, Logarithmic curves. Analyze peaks off the main thread. Stereo balance keeps center unchanged and attenuates the opposite channel toward either endpoint; mono output ignores pan. Save settings in the project, preserve them in split/trim/copies, honor them in waveform/playback/export/joins, and support one Undo step. Cancel changes nothing. Defaults for older clips are 0 dB, centered pan, 10 ms linear fades.

## Tempo edit snapping

- In Tempo mode, fragment body drags (including groups and Command copies) move by whole beat durations (60/BPM, one quarter of a 4/4 bar) relative to their original positions; do not let overlap snapping override those deltas. Resize either edge to absolute beat boundaries that satisfy source bounds, timeline zero and the 10 ms minimum; if none exist, retain the original edge. A click without a drag must not snap or resize. Shift bypasses beat movement and beat-edge snapping, including when pressed/released mid-drag, retaining normal source limits and group spacing. Outside Tempo, keep ordinary editing behavior.

## Track Solo

- Add SOLO immediately right of MUTE and before FX, with equal button widths, centered labels, the standard arrow cursor and a clear blue active state. Multiple Solo selections remain enabled independently. Dim excluded tracks and their fragments the same way as muted tracks; respect audible nested branches. No Solo means all unmuted tracks play; Solo parent includes its subtree, while Solo child passes through ancestor effects without ancestor dry fragments or unrelated branches. Mute remains authoritative. Use the same routing for playback and export; dry fragment processing/joining stays independent. Apply live changes on the playback worker without seeking, rebuilding the graph or resetting effects. Persist Solo with legacy default false, support Undo/Redo, and keep toggles silent.

## Track mixer controls

- Place a native horizontal volume slider below MUTE/SOLO/FX and a full-height vertical Pan slider on the right of each track header, with small equal top/bottom insets. Reserve its column in track name and peak-readout layout. Pan up routes left, Pan down routes right, matching the upper L/lower R waveform and meters; invert only the UI mapping, retaining negative-left/positive-right project values. Double-click either slider to reset to 0 dB/center, with normal live smoothing and Undo, and no history entry when already at default. Keep the existing row height, clear name/meter/button hit areas, standard arrow cursor, native keyboard/accessibility support, and tooltips with the current values. Pin them with the sidebar horizontally and clip them below the ruler on vertical scroll. Volume defaults to 0 dB, ranges from silence at -60 dB to +12 dB; Pan defaults to center and ranges -90…+90 degrees. Pan balances stereo and leaves mono unchanged. Apply each fader after that track's effects, including routed children, before ancestor effects; use the same ordering in export and live playback. Allow adjustment while playing/recording without restarting the engine or plug-ins, smooth live channel gain changes over 10 ms, and invalidate stale processed cache regions. Dry shuttle respects the faders of the source track and ancestors. Keep source/fragment rendering and capture files independent of track mix. Persist settings in projects, use one Undo entry per drag, and emit no notifications for slider movements.

## Track header meters

- Use the track settings header background as two independent live post-effect channel meters (L above R), each filling left to right on a -60…0 dB scale. Measure and publish per-channel peaks without collapsing them to mono; keep independent release and one-second peak holds, and show separate L/R numeric peaks in the top-right. Duplicate the single output level into both displays for mono projects. During recording use per-channel peaks from the converted project-format capture PCM. Playback fill always uses the turquoise timer accent; the actively recording track uses red fill at every input level. Both stereo fills remain proportional to their channel levels. Only the numeric peak readout changes color: turquoise below -6 dB, yellow from -6 dB, red from -1 dB, identically during playback and recording. Respect Solo, Mute and ancestor mute, include routed child audio, exclude the output-only metronome, and align snapshots with played frames and compensated effect latency. Measure on the playback worker, publish through a short lock, and keep audio processing off the UI thread. Reserve a top-right peak readout with a one-second maximum hold; retain space for track names and controls. On Stop clear fill immediately and expire held peaks. During recording the red fill width follows the captured input level on the same scale; silence has no fill. Show peaks from real captured PCM. Meter state is transient and never dirties the project.

## Fragment fade controls

- Selected fragments show fade-in/out curves with exact duration-to-timeline scaling (no minimum visual width), matching the processed waveform. Do not draw corner squares or permanent handle icons. Keep usable invisible hit areas at the current upper curve endpoints (fade-in end and fade-out start), extending 5 pt above the fragment and 7 pt horizontally on either side of the endpoint. Use the same exterior tolerance for hover cursors, starting drags and curve menus; clip interactions behind the pinned sidebar/ruler and newer fragments, with compact 20-point rising/upper-left and falling/upper-right curve cursors taking priority over horizontal edge-resize cursors. Drag the fade-in endpoint right to lengthen fade-in, or the fade-out endpoint left to lengthen fade-out; clamp duration to 0…fragment duration. Preserve clip timing, source bounds, other edge and group selection, preview curves and processed waveform live, and commit one silent Undo action on mouse-up. A click alone changes nothing; Escape/Stop cancels. Only exposed curve endpoint targets of selected fragments take priority over normal edge resizing and body dragging. Right-click a selected fade area to choose among graphical Linear/S-curve/Exponential/Logarithmic previews, with no visible text titles or selection checkmarks, applying only to that edge. Keep accessible curve names for assistive technology. Retain ordinary fragment context menus elsewhere, existing settings persistence, and baked-fade handling.

## System Fragments menu

- Place fragment-specific Split, Trim, Join, Normalize, Mute/Unmute and Delete in a dedicated Fragments menu immediately right of Edit. Keep standard Undo/Redo and text-compatible Select All/Copy/Paste in Edit. Disable every Fragments item when no existing fragment is selected, while busy, in modal/plugin windows or while editing text. Preserve existing shortcuts and keyboard-layout independence. Toolbar invalid-action hints retain their existing behavior.

## Project file actions

- Disable titlebar Open/Save controls, their NSToolbarItems, File menu Open/Save/Save As, and corresponding keyboard actions while the editor is busy (including playback and recording). Disable native toolbar autovalidation for these custom views so it cannot override state. Re-enable after Stop; enforce the same busy guard in Editor save entry points before showing panels or writing files.

## Project media storage

- Save new projects as plain .sounder JSON files with a sibling lowercase media folder. Move newly captured temporary takes there on successful Save (including takes reachable through Undo/Redo), while copying imported/joined sources and previously saved media on Save As; store relative media/... paths, deduplicate shared sources and never reuse another file solely because its basename matches. Preserve imported originals and media belonging to previously saved projects. Copy all required media and commit JSON before deleting temporary recorded takes; a failed Save must keep temporary recordings intact. After successful atomic JSON save, switch live clips, matching Undo/Redo references and the fragment clipboard to the saved absolute paths and reuse prepared audio caches. Repeated saves reuse managed media; Save As copies to the new location. Project plus media folder must reopen after moving together. Support only plain .sounder files and sibling media/... references; do not add project-package compatibility or migration code. The Open dialog accepts files only. A copy failure must leave the prior project document intact, and loaded relative paths must stay inside the project folder.
