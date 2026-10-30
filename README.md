# Sounder

A native audio recorder and editor for macOS 14+ (Apple Silicon), built with AppKit and AVFoundation. Author: Dzmitry Sharko. The Xcode project structure and npm commands follow FalconCleaner; Developer ID team: `W37L5728Y6`, bundle ID: `enotix.Sounder`.

## Running and building

- `npm start` — terminates existing processes with the exact name `Sounder`, waits for them to exit, builds and launches the app, and verifies that exactly one process is running.
- `npm run build:app` — creates a Release build at `build/Release/Sounder.app`. Uses Developer ID signing when the certificate is available; otherwise, explicitly reports that local ad-hoc signing is being used.
- `npm run build:icons` — regenerates all ten macOS AppIcon sizes from the original artwork. See [icon artwork and generation prompt](Design/AppIcon/README.md).
- `npm test` — builds the app and runs audio engine and editing tests.
- `npm run release:local` — creates a signed DMG without notarization.
- `npm run release` — creates a signed and notarized DMG; the Keychain profile is set through `NOTARY_PROFILE` (default: `falcon-notary`).
- `npm run clean` — removes build artifacts.

## Usage

1. Click Record or press R. Allow microphone access when recording for the first time. Stop / Escape finalizes a separate WAV fragment. During recording, Space saves the take and returns to its start; Enter discards the current take and immediately records a fresh take from the same position on the same track. Each new recording starts at the playhead on the selected track.
2. Import / ⌘I imports audio; multiple selected files are placed sequentially. A nonmodal window immediately lists the files and shows individual copy, decoding, and waveform progress. Import runs in the background and can be cancelled; incomplete copies are removed, and successful files are kept if another file fails. Prepared audio and waveforms are cached before fragments appear on the timeline. Formats supported by AVFoundation are accepted, including WAV, AIFF, MP3, and M4A.
3. Click the ruler to position the playhead; drag across the ruler to select a range without moving the playhead. The range is highlighted on both the ruler and fragment area; drag either ruler edge to resize it (horizontal resize cursor on hover). Up/Down arrows zoom in/out using the same limits as the View buttons. Zoom in and Zoom out center the view on the playhead, within the timeline bounds. Space starts or stops playback. Left/Right arrows move the playhead by 1% of the visible fragment area, accounting for zoom and horizontal scrolling; active playback continues from the new position. Enter restarts playback from the last start position, marked by an orange vertical notch on the ruler (zero before the first start). Natural playback completion returns the playhead to the last-start notch after effect tails finish. Manual stopping freezes the playhead at the current audio position; the next Play continues from that cursor. Clicking the ruler, a fragment, or empty timeline space selects a new start position; during playback, audio immediately continues from that position without requiring Play again. Each Play uses that one visible position, without retaining a separate paused stream.
4. Drag fragments along the timeline or onto another track. Shift-click to select multiple fragments. Delete removes the selected fragments.
5. Split / ⌘B splits selected fragments at the playhead. Trim keeps only the range selected on the ruler. Join / ⌘J combines selected fragments on one track into a new WAV, preserving silent gaps and overlap priority.
6. Add a track with + / ⌘T. The nested-track button creates a child track; dragging one track header onto another previews nesting immediately, together with its children and waveforms. Drag near the top or bottom edge of a row to reorder before or after it; drag into its middle to nest. Empty space below the rows moves a track to the root at the bottom. Mouse-up commits the preview with one Undo entry; Escape cancels. Use the context menu or Track → Move Track to Root to return it to the top level. Click a track name once to edit it inline; Enter saves, Escape cancels, and leaving the field saves a nonempty name. The project name in the titlebar edits the same way. Project and track names allow up to 100 characters, counting composed Unicode characters such as emoji as one. Overflowing editor text scrolls horizontally to keep the insertion point visible. Dragging the header, including the name itself, nests the track.
7. Muting a parent track also mutes its children. Deleting a parent removes its subtree after confirmation. All track and fragment changes support Undo / Redo.
8. Save / ⌘S creates a portable `.sounder` package containing JSON and copies of the source audio files. Export / ⌘E opens export options for MP3 (default), WAV or OGG/Vorbis. On first use, rate and bit depth come from the project; only choices used for a successful file export become the next dialog defaults and are stored in the project when saved. Cancelling either dialog or failing to export leaves the previous defaults intact. Projects from earlier builds with unconfirmed dialog choices start from the project audio format. Export conversion does not change the project audio settings.

## Audio model

New projects default to 48 kHz, Stereo, 24 bit. Click the format label to choose a sample rate of 44.1 / 48 / 88.2 / 96 / 192 kHz, Mono / Stereo, and a bit depth of 16 / 24 / 32 bit. Export options include 44.1 / 48 / 88.2 / 96 / 192 kHz and WAV depth of 16 / 24 / 32 bit. MP3 supports 44.1 / 48 kHz, with 128 / 192 / 256 / 320 kbps; OGG uses Vorbis quality 7. The dialog disables PCM bit depth for compressed formats and rejects unsupported MP3 rates. Bit depth applies to new recordings and WAV exports; effects processing and intermediate files remain Float32. Imported audio retains its original channels; conversion takes place during decoding and mixing. Waveforms use peaks from actual PCM samples, with the left channel above the right for stereo fragments; during recording, the waveform is drawn in real time from incoming PCM buffers, before Stop is pressed. When fragments overlap on the same track, only the more recently created fragment plays, even if it contains silence. The earlier fragment remains underneath and plays again outside the overlap. Separate tracks, including nested tracks, are summed; output is clamped to −1…1.

Editing preserves the original files: trimming and splitting store offsets into the source file. Recordings are saved separately in `~/Library/Application Support/Sounder/Recordings`. Saved projects contain their own audio copies. Recording, importing, and mixing are intended for small projects: decoded audio is kept in memory, and export processing is synchronous. This is a simple editor without stereo pan controls or streaming playback for large projects.

Save your project before running `npm start`: at the user's request, this command forcibly terminates existing instances. During normal shutdown, the app offers to save changes.

## Validation

`--self-test` checks overlaps (including silence), exact WAV length, PCM peaks, nesting, subtree muting, splitting, trimming, joining, Undo/Redo, cycle prevention, and project serialization. `--ui-test --snapshot /absolute/path.png` launches a test scene with synthesized audio, draws the waveform of its actual PCM signal, and saves an image of the window; test tracks are not added during normal launches.

## VST / VST3 effects (1.1)

Click **FX** in a track header or choose **Track → Track Effects… (⌘F)**. The panel shows the selected track's serial effects chain and its route through parent tracks.

- **Add** adds an installed effect; **Browse…** lets you select a `.vst` / `.vst3` manually. Adding an effect immediately opens its native editor, falling back to generic parameter controls if it has no native interface. **Rescan** refreshes the list from `/Library/Audio/Plug-Ins` and `~/Library/Audio/Plug-Ins`. Scanning lists bundles without executing their code; a module is loaded when added.
- **Open editor…** opens the plug-in's native interface. **Parameters…** provides generic controls and serves as a fallback for effects without their own window. Plug-in windows are nonmodal and have no Apply or Cancel buttons: parameter changes take effect immediately, including during playback. Closing the window keeps the changes in memory; project Save writes them to disk.
- **↑ / ↓** change the order; **Bypass** temporarily disables an effect; **Remove** removes it. Changes support Undo / Redo. Changes to the effects chain refresh active playback.
- The chain processes the sum of the track's own fragments and its already processed child tracks. The result then passes through the parent's chain and continues upward. Each parent's effects are applied exactly once. Root tracks are summed only at the master output.
- Plug-in state, order, and bypass settings are saved in `.sounder`. Plug-in binaries are not copied into the project. Moving a project to another Mac requires installing the same plug-ins; Play / Export reports an error if an active effect is missing. You can disable it with Bypass.
- Split / Trim remain nondestructive; Join combines **dry** fragments so that effects are not applied twice. Waveforms display the source audio.

**Processing mode:** playback processes audio in blocks of up to 512 frames on a dedicated worker, using the same plug-in instances as the open editors. Eight short buffers are queued for playback, so parameter changes become audible within the queue and device latency. The queue is replenished when each buffer is consumed, independently of device presentation latency; only the final buffer waits for audible completion. Export renders the current in-memory settings offline. Monitoring the microphone through effects is not yet supported. When starting in the middle of a project, processing begins at time zero to preserve compressor and delay history. Reported plug-in latency is compensated for, and effect tails are limited to 10 seconds per effect (legacy VST effects without tail information use 2 seconds). Source audio is decoded into memory before playback; seeking far into a project may take time to warm up effect history.

**Compatibility:** native Apple Silicon / Universal VST 2.4 and VST3 audio effects with Float32 processing. Plug-ins receive the selected project sample rate. Stereo projects retain separate channels; for mono projects, stereo output is downmixed to mono. Effects with a fixed mono input receive the sum of the stereo channels. Instruments, MIDI, external sidechain inputs, automation, and Intel-only plug-ins are not supported. Tempo-synchronized effects use 120 BPM. The first compatible audio-effect class in a bundle is used, and its ID is saved in the project. Plug-ins run within the app's process.

The `com.apple.security.cs.disable-library-validation` entitlement is enabled to load third-party plug-ins; Hardened Runtime and Developer ID signing remain enabled. VST3 uses the official [Steinberg SDK](https://github.com/steinbergmedia/vst3sdk); the required source subset and MIT license are in `Vendor/VST3`, and the notice is included in the app bundle. VST2 uses a minimal ABI bridge without including the legacy VST2 SDK.

### Effects validation

- `npm test` also checks chain order, inherited effects, isolation between sibling tracks, bypass, tails, dry joining, and loading older projects.
- `npm run test:plugins -- --editor-test` tests installed IVGI2 and TDR Nova VST/VST3 plug-ins: signal processing, parameter persistence, and opening the native editor. Paths to other plug-ins can be passed as arguments. Each test runs in a separate process.
- `Sounder --ui-test --fx-ui-test /path/Plugin.vst3 --snapshot /tmp/sounder.png` captures the test timeline and effects panel.

## Project name and format

Click the name in the top bar to rename the project. Click the sample rate/channel/bit-depth label in the titlebar immediately after the project name to open audio settings. These actions are also available in the File menu. The new name is used for the initial save and export; an existing project file is not automatically renamed. The name, sample rate, and channels are saved in the project and support Undo/Redo. Settings are unavailable during playback and recording.

When the sample rate changes, source files retain their original format; decoded audio is resampled through AVAudioConverter using the Mastering algorithm at maximum quality, preserving fragment timing. Switching from Mono to Stereo restores the original stereo image of imported files. Sources recorded in mono are duplicated across both channels. Increasing the sample rate does not add detail to previously recorded audio.

Existing projects retain their Mono/Stereo mode. Projects without a bit-depth setting use the previous 32-bit Float format. 16- and 24-bit WAV files use integer PCM; the selection is saved in the project and displayed in the top bar.

## Notifications

Persistent hints and the status bar have been removed. Messages appear as rectangles in the upper-right corner: successful actions use green with white text, errors use red with white text, and UX hints use yellow with dark text. Track and fragment deletion notifications also use red with white text. Each message remains visible for 5 seconds independently; new messages are appended below older ones, and remaining messages move smoothly upward when earlier messages disappear. Notifications do not intercept clicks or dragging.

“Drag tracks to nest” appears on the first attempt to drag a track header; “Shift click to multi select” appears on the first fragment selection. These onboarding hints appear once per app session. Opening a project and Undo/Redo do not reset them. Invalid actions in the FRAGMENTS group show a yellow instruction on every attempt when the required selection is missing. Operational errors appear without a blocking window; dialogs that require a choice remain dialogs.

Rules for future development are saved in `AGENTS.md`. `--ui-test --notifications-ui-test --snapshot /tmp/sounder.png` checks actual interactions, card ordering, independent five-second timers, and the upward movement of remaining messages.

## Shared track format and SRC quality

All tracks record and play using the project's shared settings. Track headers have no fragment counts or local mono/stereo/nested labels. When preparing a mix, each source file is decoded and, if necessary, resampled directly to the current project sample rate; Stereo/Mono is adapted to the selected channel count. Processing and summing use Float32; the selected bit depth is applied once to the final WAV for playback or export. Recording uses the project's sample rate, channels, and bit depth from the start.

Conversion uses [AVAudioConverter Mastering](https://developer.apple.com/documentation/avfaudio/avsamplerateconverteralgorithm_mastering) with `AVAudioQuality.max` and normal priming to preserve timing. The cache is rebuilt when the sample rate changes; conversion always starts from the saved sources, avoiding accumulated losses from repeatedly converting already resampled files.

`npm test` checks mixing 44.1 kHz Mono 16-bit, 96 kHz Stereo 24-bit, and 48 kHz Stereo Float32 audio, followed by a project format change. It verifies duration, channel separation, timing alignment, and preservation of source files. Additional spectral checks for 96 → 44.1 kHz require less than 0.05 dB level deviation and 0.002 rad phase deviation for 1/19 kHz tones, plus more than 90 dB alias rejection for a 30 kHz tone.

## Live recording waveform

Microphone capture uses AVAudioEngine. Incoming buffers are copied to a recording queue, converted to the project format through a streaming Mastering converter, and saved to a separate WAV. Separate peaks for each channel are calculated from the same PCM samples in groups of 128 frames; the UI consumes only new peaks approximately 25 times per second. Level meters and artificial waveforms are not used for the live display.

The fragment being recorded and its waveform appear in red over earlier fragments; the timeline scrolls when the playhead leaves the visible area. Stop flushes the converter, writes remaining buffers, and closes the WAV before adding the completed fragment. If recording fails, captured audio is retained when the file contains data, and a red notification appears.

`npm test` checks that peaks appear before Stop, that the live waveform matches the completed WAV, bit depth/channels/sample rate, streaming SRC continuity, and handling of late buffers. `--ui-test --live-recording-ui-test --snapshot /tmp/live.png` captures two stages of the growing waveform before Stop. `--microphone-test` checks the actual microphone when permission has already been granted (otherwise it reports SKIP). To check the app's own permission, launch it with `open -W -n Sounder.app --args --microphone-test`.

`--import-ui-test /path/to/audio.wav --snapshot /tmp/import.png` checks background import against a real stereo file, captures the progress window, and measures main-thread responsiveness.

`--playback-test /path/to/stereo.wav --reference /path/to/reference.wav` compares imported PCM with an independent conversion and checks rendered playback frame by frame for gaps, duplicates, and timing drift.

Transport regression tests render distinct PCM values for every source frame and verify that the sound and cursor stay aligned through repeated stop/continue cycles and backward/forward seeks. `--ui-test --restart-ui-test` checks Return and keypad Enter, the last-start marker, and playback restarts. `--ui-test --mute-ui-test` checks live MUTE controls without restarting playback, plus Undo/Redo. Streaming tests verify live parent/child mute routing and unmuting tracks that were muted before Play. `--ui-test --zoom-ui-test` checks fitting short, multi-minute, multi-hour and empty projects to the viewport. Zoom out uses the current window width and project duration, with adaptive ruler spacing. `--ui-test --range-ui-test` checks selection, both resize handles, reverse dragging, and uninterrupted playback. `--ui-test --playhead-ui-test` also checks the same workflow after the playhead leaves the visible timeline.

Audio export codecs are built into the application: [LAME](https://lame.sourceforge.io/) for MP3 and [Xiph Ogg/Vorbis](https://xiph.org/downloads/) for OGG. No external encoder installation is needed. `npm run build:app` verifies the vendored source archive checksums, builds a cached static helper via `scripts/build-codecs.mjs`, and signs/copies it to `Sounder.app/Contents/Helpers`. The build requires Apple command-line build tools; codec source archives and licenses are included in `Vendor/AudioCodecs` and `ThirdPartyNotices.txt`. `--self-test` covers encoding, decoded rate/channels/duration, non-destructive export failure, backward-compatible project loading and saved export choices. `--ui-test --export-ui-test --snapshot /tmp/sounder.png` checks and captures the export dialog.

Click Tempo beside the time display to switch between seconds and a 4/4 bar/beat ruler. In Tempo mode, click the BPM display to set 20–300 BPM (default 120). Metronome enables beat clicks during playback and recording, with an accented first beat every four beats. Its timing follows absolute audio frames and remains aligned after seeks. Clicks are output monitoring only: they bypass track effects and are absent from recorded WAVs and exports. Tempo, ruler mode and metronome state are saved with the project. `--self-test` checks real rendered beat timing at 44.1/48 kHz, accents, seeking, disabling clicks, capture/export separation and project compatibility; `--ui-test --tempo-ui-test --snapshot /tmp/tempo.png` checks the controls and minimum window layout.

The track names and controls stay pinned to the left during horizontal scrolling and follow their rows vertically. The time/tempo ruler stays pinned above the tracks while scrolling vertically. Horizontal scrolling keeps its labels aligned with the fragments; seeking and range selection/resizing remain available on the pinned ruler. `--ui-test --pinned-ruler-ui-test` verifies scrolling, ruler interactions, covered track controls and tempo labels.
