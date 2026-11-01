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

- Muting or unmuting a track must not emit notifications; the MUTE control shows its state. MUTE remains clickable with a pointing-hand cursor during playback. Update the streaming graph on its worker without stopping audio, seeking, rebuilding the graph or resetting plug-ins. Parent mute silences its subtree; unmute also works for tracks muted before Play.
- Track and fragment deletion notifications use a red background with white text.
- Successful splitting or moving audio fragments must not emit success notifications or UX hints.
- Invalid FRAGMENTS actions (Split, Trim, Delete, Join) show a yellow selection/instruction notification on every attempt, including repeated clicks. Successful Split and fragment moves remain silent. Only first-drag and first-selection onboarding hints are limited to once per session.

## Button cursors

- Use PointerButton for app-owned clickable buttons, including all icon buttons. Enabled buttons show the pointing-hand cursor; disabled buttons retain the standard cursor.
- Track rename hit areas and I-beam regions cover only the rendered name text, not the rest of the header or the nesting arrow. Edit project and track names inline at the label position, without a popup, field background, border or automatic select-all. Activation must preserve text geometry and neighboring positions; grow the editor with the typed text, capped at its existing layout boundary. Limit project and track names to 100 Swift Characters (including spaces; do not split emoji). Scroll overflowing inline text horizontally to keep the insertion point and latest typed character visible after layout. Enter commits a nonempty trimmed name, Escape cancels, and leaving the field commits a valid name (an empty field retains the previous name). Keep transport shortcuts inactive while typing.
- Project and track rename targets use the I-beam text cursor. Track MUTE and FX controls use the pointing-hand cursor. Refresh timeline cursor regions when tracks, layout, or editing availability change.

## Project audio format

- Tracks inherit the project's sample rate, Mono/Stereo mode, and recording/export bit depth. Do not show per-track fragment counts or format captions.
- Preserve imported and recorded source files. Convert from each original source directly to the current project rate while preparing the mix; changing format must not accumulate resampling losses.
- Use AVAudioConverter's Mastering algorithm with maximum quality and proper priming. Verify passband fidelity, alias rejection, timing, and mixed-source formats when changing conversion code.
- Mix and run effects in Float32; apply the chosen PCM bit depth once to final playback/export and use it for new recordings.

## Waveforms

- Waveforms fill the fragment height. Draw fragment names over the waveform, with no reserved title row. Do not draw a RECORDING label or indicator icon inside the live recording fragment.
- Draw stereo fragments as separate waveforms: left channel above right, using actual per-channel PCM peaks for both imported audio and live recording. Mono sources use one waveform.

## Live recording

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
- Clicking the timeline ruler, a fragment, or empty timeline space places the playhead at that time and discards any previous paused/playing stream. If playback is active, immediately continue playing from the selected time; if stopped, only reposition the cursor. Play starts from the selected playhead, independent of scrolling or the previous playback position.
- Pause via Play/Pause or Space captures the current render position, clears the stream and freezes the cursor. The explicit Stop icon/menu/Escape stops and returns to the last playback start notch (zero before the first start), bringing it into view; when recording, return to the recording start. Keep gesture cancellation ahead of Stop. The next Play always builds a new stream from that one cursor position. Never retain a separate paused position or resume old queued audio. While playing, the cursor follows the render clock monotonically; missing timestamps must not reset it. Do not silently reset a selected position beyond the project end to zero.

- Natural playback completion (including effect tails) stops audio and returns the cursor to the last-start notch. Pause and playback errors retain their current position; stale completion callbacks must not move the cursor.

- Enter (Return or keypad Enter) always starts playback from the last successful user playback start, whether stopped or playing. Show that position as an orange vertical notch on the ruler. Play/Space and live timeline seeks update the marker; Stop, stopped seeking, range selection, and internal effect-chain restarts do not. Before the first start, Enter starts at zero; opening a project clears the marker.

- Command-Left seeks to time zero; Command-Right seeks to the end of project audio, showing the destination in the viewport and preserving active playback when audio remains. Keep native Command-arrow text navigation in editors.

- Left/Right arrows seek by 1% of the currently visible fragment area width in timeline time, excluding the visible track-header portion. Respect zoom and horizontal scrolling, clamp at zero, and continue active playback. Do not intercept arrow keys in text fields, dialogs or plug-in windows.

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

- Show an initially unchecked Selected range checkbox at the bottom of Export audio only for a nonempty timeline selection. When checked, export exactly that captured interval for WAV/MP3/OGG, preserving pre-range effect history and padding selected empty timeline space with silence. Crop at the project rate before final resampling. Keep the range choice transient; normal format settings retain their existing persistence.

- Give the Export button comfortable horizontal padding. Disable both the titlebar button and File menu export action when the project has no audio fragments or editing is busy.
- Label the titlebar button and File menu action Export. Open export options before choosing a destination; offer MP3 (default), WAV and OGG. First use inherits project rate and depth; remember export choices only after a file is successfully written, and save those last successful choices inside the project, independently from project audio settings. Cancel must not export a file.
- PCM bit depth is editable for WAV only. MP3 offers supported rates up to 48 kHz and bitrate selection; explain codec constraints in the dialog. Use built-in encoders, preserve channels, process effects at the project rate and resample the finished mix only once using Mastering quality. Failed exports must not damage an existing destination.

## Tempo and metronome

- Tempo settings include a Tap button beside the BPM field. Compute BPM from monotonic tap intervals using a rolling recent window, update the field on every tap after the first, reset after a long pause and ignore accidental double taps. Keep values within 20–300 BPM and retain Save/Cancel semantics.

- Place Tempo, Metronome and the timer/BPM display in the pinned top-left timeline corner in place of the TRACKS caption. Use one vertically centered row: timer/BPM, metronome icon, flexible space, then Tempo pinned to the right edge beside the timeline. Use matching 18 pt light monospaced timer/BPM fonts and pin the controls on both scroll axes. The metronome uses an outline icon when off and a filled accent-colored icon when on.

- Show the metronome icon only in Tempo mode, to the right of Tempo. BPM uses exactly the timer font (18-point monospaced digits, light weight).
- Tempo toggles a 4/4 bar/beat ruler and replaces the timer with clickable BPM (20–300, initially 120). A Metronome icon button controls audible clicks during playback and recording, with a stronger first beat every four beats. Persist BPM, ruler mode and metronome choice in the project.
- Derive metronome timing from audio frames and absolute timeline position, not UI timers. Seeking and recording restarts must preserve beat alignment. Mix playback clicks only after track effects; route recording clicks to the output mixer separately from the microphone input tap. Never include the metronome in recorded files or exports. Tempo and metronome changes must not stop active capture or playback.

## Track dragging

- Limit nesting to two levels below a root (depths 0, 1, 2). Validate the whole moved subtree for both live previews and commits, and reject adding a third nested level without an Undo entry. Never silently change routing in an over-depth project loaded from disk.

- Preview track order and nesting live during header dragging, including the entire child subtree and all waveforms. The top/bottom quarter of a target row inserts before/after its subtree; the middle nests under it. Empty space below the rows moves to the root at the bottom. Resolve targets against a stable drag baseline to avoid oscillation. Commit once on mouse-up with one Undo entry; Escape/Stop cancels without a model change, and never permit nesting into the dragged subtree.

## Settings windows

- Audio settings, Track effects, Export audio and Tempo show their title and controls without an app icon or descriptive introductory text. Remove the space reserved for those descriptions and icon area; keep a compact top margin above the heading. Use CompactSettingsAlert for modal settings forms rather than the standard alert icon layout. Keep actionable export validation errors visible only when needed.

## Fragment marquee selection

- Drag on empty fragment-area space (including below all tracks) to select intersecting fragments with a live rectangular marquee. Shift adds to the selection captured at drag start. Preserve the playhead and active playback during marquee selection; only a background click without a drag seeks on mouse-up. Keep ruler range gestures and fragment dragging intact. Clip the marquee behind pinned headers, autoscroll at viewport edges, and restore the original selection/range on Escape. Selection changes do not create Undo entries.

## Fragment edge resizing

- Drag a fragment's left or right edge to trim or restore source audio non-destructively. Keep the opposite edge fixed, enforce a 10 ms minimum and source-file bounds, and never extend left of timeline zero. Show a horizontal resize cursor only on exposed edges. Preview live without seeking or changing tracks; commit once with one Undo entry and allow Escape/Stop to cancel. Keep body dragging and overlapping-fragment hit order intact.

## Fragment alignment

- While moving a fragment to another track, snap its start or end to other fragments' boundaries, and preserve its original time on near-vertical moves. Use the nearest match strictly within 1% of the visible fragment area's time span, excluding the pinned sidebar; derive the threshold again after zoom or viewport changes. Show a vertical dashed guide across all visible track rows while matched, clear it outside the threshold and on drop, and preserve source offsets/duration and single-step Undo.

## Group fragment dragging

- A plain click on a selected group member selects only that fragment on mouse-up. Preserve the group on mouse-down so an actual drag still moves it together. Shift-click toggles selection; selection-only clicks do not create Undo entries. Apply the same plain-click behavior to fragment edges when no resizing occurs.

- Dragging the body of any selected fragment moves all selected fragments with one common time delta and preserves their time spacing, source offsets and durations. Clamp the whole group at timeline zero, never individual fragments. On cross-track moves, preserve relative visible row offsets and clamp the group to existing track bounds; preview every selected waveform on its destination. Snap the whole group rigidly, exclude its members from snap targets, retain selection after drop, and use one Undo step for all time/track changes. Shift-deselecting a fragment must not start a group move. Edge resizing still affects only the grabbed edge's fragment.

## Fragment context menu

- Right-clicking a selected fragment preserves the entire selection; right-clicking an unselected fragment selects it alone. Open Move up, Move down, Delete without seeking. Apply each action to the selection captured when opening the menu, across all tracks, in a single Undo step. Layer moves skip selected neighbors and process the leading edge first so stacked selected fragments do not swap or cancel each other. Enable a direction if any selected fragment can move past an unselected overlapping neighbor. Move up/down advances one overlapping layer on the same track, preserving all other fragments' relative order, timing and source bounds. Disable a direction when no overlapping neighbor exists there. Use the same order for waveform layering and audio overlap priority, support Undo/Redo, and keep layer changes silent. Delete removes the whole context selection and uses the existing red notification. Track menus belong to the sidebar, not empty fragment space.

## Fragment clipboard and duplication

- Command-A selects all fragments. Command-C writes an immutable group snapshot to the system pasteboard; Command-V creates fresh fragment IDs at the cursor, anchoring the earliest selected fragment there and preserving time spacing, relative visible track rows, source offsets, durations and overlap ordering. Use the active track as the first destination row and create missing root tracks as needed. Keep native text Select All/Copy/Paste in inline editors and other text fields. Paste is a single Undo action. Command held when a fragment drag begins creates live preview copies and leaves originals untouched; retain group spacing and snapping, select the copies after drop and undo duplication in one step.

## Keyboard layout independence

- Split uses the unmodified physical S key (including Russian ы), shown as S in the menu and toolbar tooltip. Resolve app-owned letter shortcuts by physical key codes in the main editor window while respecting their exact modifier masks, validation, dialogs and plugin windows. Keep normal typing and native text shortcuts in text editors; Command-S remains Save. Arrow and transport key codes remain layout-independent.

## Fragment normalization

- Normalize is available from FRAGMENTS, the Edit menu and the fragment context menu, applying to the captured selection. Use unmodified physical N (including Russian т). Show a compact Normalize dialog with Maximum level in dBFS, Process and Cancel; accept -120…0 dBFS, initially -1 dBFS. Remember the last successfully processed level in the project and use it on reopening the dialog. Analyze the actual selected source interval off the UI thread, independently per fragment with linked stereo-channel gain; leave silence unchanged. Apply non-destructive gain before track effects, reflect it in waveforms, preserve originals and source bounds, and support one-step Undo/Redo. Gain and the level must survive save/load; legacy clips use unity gain. Splits, trims, clipboard copies, playback, export and joining must honor gain without applying it twice.
