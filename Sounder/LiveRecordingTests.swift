import AppKit
import AVFoundation

/// Compare saved PCM against an independently assembled physical input timeline.
/// Gaps, duplicate deliveries and pre-roll must not shift later input samples.
func runRecordingPacketTimelineTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderPacketClock-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    for rate in [44_100.0, 48_000, 96_000] {
        for channels in [1, 2] {
            for looping in [false, true] {
                let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels))!
                let format = ProjectAudioFormat(sampleRate: rate, bitDepth: 32)
                let actualURL = store.freshURL(), expectedURL = store.freshURL()
                let actual = try RecordingWriter(url: actualURL, format: format, inputFormat: input)
                let expected = try RecordingWriter(url: expectedURL, format: format, inputFormat: input)
                if looping {
                    try actual.configureLoop(0.02..<0.08, start: 0)
                    try expected.configureLoop(0.02..<0.08, start: 0)
                }
                let clock = RecordingHostClock(), reference = 100.0, latency = 0.023
                clock.set(hostTime: AVAudioTime.hostTime(forSeconds: reference))
                actual.configureSynchronization(clock: clock, inputLatency: latency)
                // A gap during pre-roll, an overlap, a missing input packet,
                // a repeated packet and a pulse after all these transitions.
                let packets = [(-600, 200), (-400, 200), (-200, 457), (200, 312), (512, 512),
                               (1536, 512), (1536, 512), (2048, 4096)]
                let total = 6144
                var referencePCM = [[Float]](repeating: Array(repeating: 0, count: total), count: channels)
                var written = 0
                for (first, count) in packets {
                    let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(count))!
                    buffer.frameLength = AVAudioFrameCount(count)
                    for channel in 0..<channels { for i in 0..<count {
                        let frame = first + i
                        let sample: Float = frame == 4000 ? 0.8 : Float(sin(Double(frame) * 0.017) * 0.2)
                        let value = channel == 0 ? sample : -sample * 0.3
                        buffer.floatChannelData![channel][i] = value
                        if frame >= written && frame >= 0 { referencePCM[channel][frame] = value }
                    } }
                    written = max(written, first + count)
                    let stamp = AVAudioTime.hostTime(forSeconds: reference + latency + Double(first) / 48_000)
                    actual.append(buffer, hostTime: [-400, 512, 2048].contains(first) ? nil : stamp)
                }
                // The reference writer sees one continuous, already aligned stream.
                let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(total))!
                buffer.frameLength = AVAudioFrameCount(total)
                for channel in 0..<channels { referencePCM[channel].withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: total) } }
                expected.append(buffer)
                if let failure = actual.finish() { throw failure }
                if let failure = expected.finish() { throw failure }
                let result = try AudioStore.decode(actualURL, sampleRate: rate)
                let target = try AudioStore.decode(expectedURL, sampleRate: rate)
                guard result.frameCount == target.frameCount, zip(result.channels, target.channels).allSatisfy({ a, b in
                    zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }
                }) else {
                    throw SounderError.message("Input packet loss/overlap shifts recorded PCM (\(Int(rate)) Hz, \(channels) channels, Loop \(looping), frames \(result.frameCount)/\(target.frameCount))")
                }
                print("PASS: Timestamped gaps/overlaps preserve saved PCM and loop seams at \(Int(rate)) Hz, \(channels) channel(s), Loop \(looping)")
            }
        }
    }
}

func runAtomicStopPositionTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderAtomicStop-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    for space in [false, true] {
        let editor = Editor(store: store)
        editor.cursor = 1.25
        let recorder = try LiveRecorder(url: store.freshURL(), format: ProjectAudioFormat(), inputFormat: input)
        try recorder.start(); editor.activateRecording(recorder)
        recorder.writer.append(captureTestBuffer(format: input, start: 0, frames: 24_000))
        recorder.writer.waitForPendingWrites(); editor.updateRecordingWaveform()
        var presented: [Double] = []
        editor.changed = { presented.append(editor.cursor) }
        if space { editor.playPause() } else { editor.stopAndReturnToStart() }
        guard !presented.isEmpty, presented.allSatisfy({ $0 == 1.25 }), editor.cursor == 1.25 else {
            throw SounderError.message("\(space ? "Space" : "Stop") publishes intermediate recording-end cursor positions: \(presented)")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        guard editor.cursor == 1.25, editor.project.tracks[0].clips.count == 1 else {
            throw SounderError.message("Late capture completion moves the stopped cursor or loses the take")
        }
        print("PASS: \(space ? "Space" : "Stop") commits recording and presents only the final return position")
    }
}

func runRecordingOutputAnchorTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderOutputAnchor-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    for capacity in [96, 1000, 1024, 4096, 32768] {
        let format = ProjectAudioFormat(bitDepth: 32)
        let project = Project(tracks: [Track(name: "Selected empty loop")], audioFormat: format)
        let live = LivePlayback(graph: try StreamingGraph(project: project, store: store) { _ in fatalError() }, format: format, start: 100.0 / 48_000)
        try live.configureBufferSize(capacity)
        live.setLoop((100.0 / 48_000)..<(137.0 / 48_000))
        try live.prepareForRecording()
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        try live.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
        try live.startPlayback(playImmediately: false)
        defer { live.stop() }
        for frame in [0, 36, 37, 38, capacity - 1] {
            let renderSeconds = 100 + Double(frame) / 48_000
            let renderTime = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: renderSeconds))
            let playerTime = AVAudioTime(sampleTime: AVAudioFramePosition(frame), atRate: 48_000)
            let latency = 0.037
            guard let anchor = live.recordingAnchor(renderTime: renderTime, playerTime: playerTime, outputLatency: latency) else {
                throw SounderError.message("Missing recording DAC snapshot")
            }
            let expectedFrame = 100 + frame % 37
            let error = abs(AVAudioTime.seconds(forHostTime: anchor.hostTime) - renderSeconds - latency)
            guard abs(anchor.sourceTime * 48_000 - Double(expectedFrame)) < 1e-6, error < 1e-7 else {
                throw SounderError.message("Recording anchor crosses a loop cycle or adds render-ahead latency (capacity \(capacity), frame \(frame))")
            }
            // A physical pulse 50 ms after the DAC anchor must be placed at
            // 50 ms in the new take, independently of ready-queue capacity.
            let clock = RecordingHostClock(); clock.set(hostTime: anchor.hostTime)
            let inputStamp = AVAudioTime.hostTime(forSeconds: AVAudioTime.seconds(forHostTime: anchor.hostTime) + 0.023 + 0.05)
            guard clock.inputFrameOffset(hostTime: inputStamp, latency: 0.023, sampleRate: 48_000) == 2400 else {
                throw SounderError.message("Recording adds queue capacity or device latency twice")
            }
        }
        // Reproduce a DSP worker that stopped replenishing output while the
        // device clock advanced by the 1.98 s gap found in the reported take.
        let blocked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        live.queue.async { blocked.signal(); release.wait() }
        blocked.wait()
        let lateFrame = capacity + 95_056
        let lateStamp = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100 + Double(lateFrame) / 48_000))
        let latePlayer = AVAudioTime(sampleTime: AVAudioFramePosition(lateFrame), atRate: 48_000)
        let unsafeAnchor = live.recordingAnchor(renderTime: lateStamp, playerTime: latePlayer, outputLatency: 0.037)
        release.signal()
        guard unsafeAnchor == nil else {
            throw SounderError.message("Starved playback fabricated a recording anchor in the past instead of rejecting an untrustworthy clock")
        }
        print("PASS: DSP starvation cannot fabricate a late recording anchor with a \(capacity)-sample queue")
        // Enter's replacement take starts when the queued seek reaches output,
        // even when the old source has the same time on a different loop pass.
        live.seek(to: 0.5); live.queue.sync {}
        let stamp = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100))
        let played = AVAudioTime(sampleTime: 0, atRate: 48_000)
        guard let anchor = live.recordingAnchor(at: 0.5, renderTime: stamp, playerTime: played, outputLatency: 0.037),
              abs(AVAudioTime.seconds(forHostTime: anchor.hostTime) - 100 - 0.037 - Double(capacity) / 48_000) < 1e-7 else {
            throw SounderError.message("Enter anchors the replacement recording before its seek is audible")
        }
        print("PASS: One DAC snapshot aligns punch-in, short Loop and queued Enter with a \(capacity)-sample queue")
    }
}

/// Record a timestamped pulse, finalize its WAV, then play it with the backing
/// pulse through AVAudioEngine. A correct preview alone cannot pass this test.
func runRecordedTrackAlignmentTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderRecordedAlignment-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    for rate in [44_100.0, 48_000, 96_000] {
        for capacity in [96, 1000, 32768] {
            let format = ProjectAudioFormat(sampleRate: rate, bitDepth: 32)
            let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let reference = 100.037, inputLatency = 0.023
            let editor = Editor(store: store, makeRecorder: { url, format in
                let capture = try LiveRecorder(url: url, format: format, inputFormat: input)
                let clock = RecordingHostClock(); clock.set(hostTime: AVAudioTime.hostTime(forSeconds: reference))
                capture.writer.configureSynchronization(clock: clock, inputLatency: inputLatency)
                return capture
            }, makePlayback: { graph, format, start in
                let live = LivePlayback(graph: graph, format: format, start: start)
                try live.engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!, maximumFrameCount: 512)
                return live
            })
            store.configure(format)
            var bedPCM = [Float](repeating: 0, count: Int(rate))
            let pulseFrame = Int((0.35 * rate).rounded())
            bedPCM[pulseFrame] = 0.4
            let bedURL = store.freshURL(); try store.write(AudioSignal(channels: [bedPCM]), to: bedURL, bitDepth: 32)
            let bed = Track(name: "Backing pulse", clips: [Clip(name: "Reference", source: bedURL.path, start: 0, duration: 1, order: 1)])
            let mic = Track(name: "Recorded pulse")
            editor.project = Project(tracks: [bed, mic], audioFormat: format)
            editor.project.playbackBufferFrames = capacity
            editor.selectedTrack = mic.id; editor.cursor = 0.25
            defer { editor.stop() }
            try editor.startRecording()
            let writer = editor.recorder!.writer
            let pre = 1776
            for first in stride(from: -pre, to: 19_200, by: 257) {
                let count = min(257, 19_200 - first)
                let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                buffer.floatChannelData![0].initialize(repeating: 0, count: count)
                if first <= 4800 && first + count > 4800 { buffer.floatChannelData![0][4800 - first] = 0.4 }
                writer.append(buffer, hostTime: AVAudioTime.hostTime(forSeconds: reference + inputLatency + Double(first) / 48_000))
            }
            writer.waitForPendingWrites(); editor.stopAndReturnToStart()
            guard let take = editor.project.tracks[1].clips.first, take.start == 0.25 else { throw SounderError.message("Recorded take lost its trigger position") }
            let recorded = try store.renderAudio(editor.project, onlyTrack: mic.id)
            let peak = recorded.channels[0].indices.max { abs(recorded.channels[0][$0]) < abs(recorded.channels[0][$1]) }!
            guard abs(peak - pulseFrame) <= 3 else { throw SounderError.message("Saved take lags backing pulse at \(Int(rate)) Hz, buffer \(capacity): \(peak - pulseFrame) frames") }
            editor.seek(to: 0); editor.playPause()
            guard let live = editor.player else { throw SounderError.message("Cannot replay recorded take") }
            let quantum = min(512, capacity / 3)
            let output = AVAudioPCMBuffer(pcmFormat: live.engine.manualRenderingFormat, frameCapacity: 512)!
            var audible: [Float] = []
            while audible.count < pulseFrame + 1024 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.001)); live.queue.sync {}
                guard try live.engine.renderOffline(AVAudioFrameCount(quantum), to: output) == .success else { throw SounderError.message("Cannot render recorded take replay") }
                audible.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: quantum))
            }
            let maximum = audible.indices.max { abs(audible[$0]) < abs(audible[$1]) }!
            guard abs(maximum - pulseFrame) <= 3, abs(audible[maximum]) > 0.6 else {
                throw SounderError.message("Replayed take does not coincide with backing audio at \(Int(rate)) Hz, buffer \(capacity)")
            }
            print("PASS: Recorded WAV and actual replay align with the backing pulse at \(Int(rate)) Hz, buffer \(capacity)")
        }
    }
}

func captureTestBuffer(format: AVAudioFormat, start: Int, frames: Int) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
        let t = Double(start + i) / format.sampleRate
        let amplitude = t < 0.1 ? 0 : (0.05 + 0.6 * abs(sin(t * 7)))
        let sample = Float(sin(t * 2 * .pi * 330) * amplitude)
        for channel in 0..<Int(format.channelCount) { buffer.floatChannelData![channel][i] = channel == 1 ? -sample * 0.25 : sample }
    }
    return buffer
}

func runLiveRecordingTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }
        print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderLiveRecording-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let formats = [ProjectAudioFormat(sampleRate: 44_100, channels: 2, bitDepth: 16), ProjectAudioFormat(), ProjectAudioFormat(sampleRate: 96_000, channels: 2, bitDepth: 32)]
    for format in formats {
        let url = store.freshURL()
        let writer = try RecordingWriter(url: url, format: format, inputFormat: inputFormat)
        var peaks: [Float] = [], offset = 0, beforeStop = false
        var channelPeaks = [[Float]](repeating: [], count: format.channels)
        for size in [1, 127, 777, 2048, 511, 4096, 20_000, 20_440] {
            writer.append(captureTestBuffer(format: inputFormat, start: offset, frames: size)); offset += size
            writer.waitForPendingWrites()
            let update = writer.consumeUpdate(); if let failure = update.failure { throw failure }
            peaks.append(contentsOf: update.peaks)
            for channel in channelPeaks.indices { channelPeaks[channel].append(contentsOf: update.channelPeaks[channel]) }
            if offset > 12_000 && update.frames > 0 && peaks.contains(where: { $0 > 0.1 }) { beforeStop = true }
        }
        try check(offset == 48_000 && beforeStop, "Real PCM peaks are published before Stop (\(format.label))")
        try check(writer.consumeUpdate().peaks.isEmpty, "UI drains new peaks without duplicating waveform history")
        if let failure = writer.finish() { throw failure }
        let final = writer.consumeUpdate(); peaks.append(contentsOf: final.peaks)
        if let partial = final.partialPeak { peaks.append(partial) }
        for channel in channelPeaks.indices {
            channelPeaks[channel].append(contentsOf: final.channelPeaks[channel])
            if let partial = final.partialChannelPeaks[channel] { channelPeaks[channel].append(partial) }
        }
        store.configure(format)
        let saved = try store.load(url.path)
        let file = try AVAudioFile(forReading: url)
        try check(saved.frameCount == Int(format.sampleRate) && file.fileFormat.channelCount == format.channels && file.fileFormat.streamDescription.pointee.mBitsPerChannel == format.bitDepth, "Streaming capture flushes all frames and preserves the selected WAV format")
        let peakError = zip(peaks, saved.peaks).map { abs($0 - $1) }.max() ?? 0
        try check(peaks.count == saved.peaks.count && peakError < (format.bitDepth == 16 ? 0.00004 : 0.000001), "Live waveform matches the finalized recording, including stereo with opposite phase")
        for channel in channelPeaks.indices {
            let difference = zip(channelPeaks[channel], saved.channelPeaks[channel]).map { abs($0 - $1) }.max() ?? 0
            try check(channelPeaks[channel].count == saved.channelPeaks[channel].count && difference < (format.bitDepth == 16 ? 0.00004 : 0.000001), "Live channel \(channel) matches its own finalized PCM waveform")
        }
        try check((channelPeaks[0].max() ?? 0) > (channelPeaks[1].max() ?? 0) * 3.9, "Left and right waveform peaks retain their independent amplitudes")
        writer.append(captureTestBuffer(format: inputFormat, start: 0, frames: 1024)); writer.waitForPendingWrites()
        try check(writer.consumeUpdate().frames == final.frames && writer.finish() == nil, "Stop rejects late tap buffers and is safe to repeat")
    }
    let mono = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let session = try LiveRecorder(url: store.freshURL(), format: ProjectAudioFormat(), inputFormat: mono)
    let editor = Editor(store: store); editor.cursor = 1.25
    try session.start(); editor.activateRecording(session)
    session.writer.append(captureTestBuffer(format: mono, start: 0, frames: 22_050)); session.writer.waitForPendingWrites()
    editor.updateRecordingWaveform()
    try check(editor.isRecording && editor.recordingChannelPeaks.count == 1 && !editor.recordingPeaks.isEmpty && editor.cursor > 1.25 && editor.project.tracks[0].clips.isEmpty, "Editor displays live waveform and sample-accurate playhead while take is still recording")
    editor.stop()
    let clips = editor.project.tracks[0].clips
    try check(!editor.isRecording && editor.recordingPeaks.isEmpty && clips.count == 1 && abs(clips[0].start - 1.25) < 0.000001 && abs(clips[0].duration - 0.5) < 0.000001, "Stop replaces the live preview with one independent saved fragment")
    let recorded = try store.load(clips[0].source)
    try check(recorded.channels.count == 1 && session.format.channels == 1 && editor.project.audioFormat.channels == 2, "Mono input saves a mono take while the project remains Stereo")
    try check(clips[0].name == "Audio 01 1", "First take uses the track name and its own take number")
    func recordTake() throws {
        let session = try LiveRecorder(url: store.freshURL(), format: editor.project.audioFormat, inputFormat: mono)
        try session.start(); editor.activateRecording(session)
        session.writer.append(captureTestBuffer(format: mono, start: 0, frames: 4410))
        editor.stop()
    }
    // Removing clips or changing the track name must not reset the saved counter.
    editor.project.tracks[0].clips = []
    editor.project.tracks[0].name = "Vocals"
    editor.project.nextOrder = 100
    editor.project = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(editor.project))
    try recordTake()
    try check(editor.project.tracks[0].clips.last?.name == "Vocals 2" && editor.project.tracks[0].clips.last?.order == 100, "Take numbering survives deletion, rename and project round-trip independently of overlap order")
    editor.addTrack()
    try recordTake()
    try check(editor.project.tracks[1].clips.last?.name == "Audio 02 1", "Each track starts its own take numbering")

    let retryEditor = Editor(store: store, makeRecorder: { url, format in
        try LiveRecorder(url: url, format: format, inputFormat: mono)
    })
    retryEditor.project = editor.project; retryEditor.selectedTrack = editor.project.tracks[1].id
    retryEditor.cursor = 2.5
    let retry = try LiveRecorder(url: store.freshURL(), format: retryEditor.project.audioFormat, inputFormat: mono)
    try retry.start(); retryEditor.activateRecording(retry)
    let originalProject = retryEditor.project
    let originalClips = originalProject.tracks.flatMap(\.clips).map(\.id)
    let undoCount = retryEditor.undoStack.count
    for _ in 0..<3 {
        let active = retryEditor.recorder!
        active.writer.append(captureTestBuffer(format: mono, start: 0, frames: 8820))
        active.writer.waitForPendingWrites(); retryEditor.updateRecordingWaveform()
        retryEditor.restartFromLastStart()
        try check(retryEditor.isRecording && retryEditor.recorder !== active && retryEditor.recordingStart == 2.5 && retryEditor.cursor == 2.5, "Enter restarts capture on the same track at its original recording start")
        try check(!FileManager.default.fileExists(atPath: active.url.path) && retryEditor.project.tracks.flatMap(\.clips).map(\.id) == originalClips, "Enter deletes only the discarded capture file and preserves previous fragments")
        try check(retryEditor.undoStack.count == undoCount && retryEditor.project.tracks[1].nextTakeNumber == originalProject.tracks[1].nextTakeNumber, "Discarded takes consume neither Undo entries nor take numbers")
    }
    let final = retryEditor.recorder!
    final.writer.append(captureTestBuffer(format: mono, start: 0, frames: 22050))
    final.writer.waitForPendingWrites(); retryEditor.updateRecordingWaveform()
    retryEditor.playPause()
    let saved = retryEditor.project.tracks[1].clips.last!
    try check(!retryEditor.isRecording && retryEditor.cursor == 2.5 && saved.start == 2.5 && abs(saved.duration - 0.5) < 0.000001, "Space saves the completed take and returns the cursor to its recording start")
    try check(FileManager.default.fileExists(atPath: saved.source) && retryEditor.project.tracks[1].clips.count == originalProject.tracks[1].clips.count + 1 && retryEditor.undoStack.count == undoCount + 1, "Space retains the final capture as exactly one undoable fragment")
}

func runMicrophoneSmokeTest() throws {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        print("SKIP: microphone smoke test requires the user's existing microphone permission")
        return
    }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SounderMicTest-" + UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = try LiveRecorder(url: url, format: ProjectAudioFormat())
    try recorder.start()
    RunLoop.current.run(until: Date().addingTimeInterval(1.3))
    let live = recorder.writer.consumeUpdate()
    if let failure = recorder.stop() { throw failure }
    let file = try AVAudioFile(forReading: url)
    guard live.frames > 0, !live.peaks.isEmpty, file.length >= live.frames else { throw SounderError.message("Microphone capture produced no live PCM waveform") }
    print("PASS: actual microphone tap published \(live.peaks.count) live peaks before Stop; saved \(file.length) frames")
}

func runOverdubTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SounderOverdub-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try AudioStore(directory: dir)
    let format = ProjectAudioFormat(bitDepth: 32)
    let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let bedURL = store.freshURL()
    try store.write(AudioSignal(channels: [Array(repeating: 0.2, count: 12_000), Array(repeating: -0.05, count: 12_000)]), to: bedURL)
    let bed = Track(name: "Backing", clips: [Clip(name: "Backing", source: bedURL.path, start: 0, duration: 0.25, order: 1)])
    let target = Track(name: "Voice")
    func makeEditor() -> Editor {
        let editor = Editor(store: store, makeRecorder: { url, format in
            try LiveRecorder(url: url, format: format, inputFormat: pcm)
        }, makePlayback: { graph, format, start in
            let playback = LivePlayback(graph: graph, format: format, start: start)
            try playback.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
            return playback
        })
        editor.project = Project(tracks: [bed, target], audioFormat: format, tempoMode: true, metronomeEnabled: true)
        editor.selectedTrack = target.id
        return editor
    }
    let editor = makeEditor()
    let reference = try store.renderAudio(editor.project, onlyTrack: bed.id)
    editor.playPause()
    guard let live = editor.player else { throw SounderError.message("Backing playback failed") }
    let engine = live.engine, node = live.node
    let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 512)!
    var frame = 0
    func render() throws {
        RunLoop.current.run(until: Date().addingTimeInterval(0.002)); live.queue.sync {}
        guard try engine.renderOffline(512, to: output) == .success else { throw SounderError.message("Cannot render overdub playback") }
    }
    for _ in 0..<21 { try render(); frame += 512 }
    try check(editor.canRecord, "Record remains available during ordinary playback")
    try editor.startRecording()
    let startedAt = editor.recordingStart
    try check(editor.isRecording && editor.isPlaying && editor.player === live && live.engine === engine && live.node === node,
              "Punch-in retains the same running playback engine and node")
    try check(abs(startedAt - Double(frame) / 48_000) <= 512 / 48_000, "Punch-in records from the current playback position")
    let mic = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 512)!
    mic.frameLength = 512
    for ch in 0..<2 { for i in 0..<512 { mic.floatChannelData![ch][i] = 0 } }
    var error = 0.0, sawBackingMeter = false
    for _ in 0..<40 {
        editor.recorder!.writer.append(mic); editor.recorder!.writer.waitForPendingWrites()
        try render()
        for i in 0..<512 { for ch in 0..<2 {
            let index = frame + i
            let bedSample = index < reference.frameCount ? reference.channels[ch][index] : 0
            let click = MetronomeClick.sample(frame: Int64(index), sampleRate: 48_000, bpm: 120)
            error = max(error, abs(Double(output.floatChannelData![ch][i] - min(1, max(-1, bedSample + click)))))
        } }
        frame += 512
        editor.updateTransportPosition()
        sawBackingMeter = sawBackingMeter || (editor.trackMeters[bed.id]?.left.peak ?? 0) > 0.1
    }
    try check(error < 1e-6 && sawBackingMeter, "Overdub preserves both backing channels, meters and exactly one frame-aligned metronome (error: \(error))")
    try check(editor.isRecording && editor.isPlaying && live.currentTime > 0.5 && editor.cursor > 0.5,
              "Recording and its transport continue beyond the end of existing fragments")
    let captureURL = editor.recordingURL!
    editor.playPause()
    let captured = try store.load(captureURL.path)
    try check(!editor.isRecording && !editor.isPlaying && editor.cursor == startedAt && captured.frameCount == 40 * 512,
              "Space finalizes an overdub and returns to the punch-in position")
    try check(captured.channels.allSatisfy { $0.allSatisfy { $0 == 0 } }, "Backing tracks and metronome never enter the recorded microphone file")
    try check(editor.project.tracks[0].clips.count == 1 && editor.project.tracks[1].clips.count == 1 && editor.project.tracks[1].clips[0].start == startedAt,
              "Overdub preserves backing fragments and commits a separate take on the active track")
    let stopped = makeEditor()
    try stopped.startRecording()
    guard let restartedBacking = stopped.player else { throw SounderError.message("Record from stopped did not start backing playback") }
    try check(stopped.isRecording && stopped.isPlaying && stopped.recordingStart == 0, "Record from stopped starts the existing backing mix at the selected cursor")
    let oldCapture = stopped.recordingURL!
    stopped.recorder!.writer.append(mic); stopped.recorder!.writer.waitForPendingWrites()
    stopped.restartFromLastStart()
    try check(stopped.isRecording && stopped.player === restartedBacking && !FileManager.default.fileExists(atPath: oldCapture.path),
              "Enter restarts the take and backing position without rebuilding the playback engine")
    stopped.recorder!.writer.append(mic); stopped.recorder!.writer.waitForPendingWrites(); stopped.stop()
    // There may be no backing material at all, or recording may start beyond it.
    let empty = makeEditor(); empty.project.tracks[0].clips = []; empty.cursor = 3
    try empty.startRecording()
    try check(empty.isRecording && empty.isPlaying && empty.recordingStart == 3, "Empty projects and positions beyond the mix end still support recording")
    empty.recorder!.writer.append(mic); empty.recorder!.writer.waitForPendingWrites(); empty.stop()
}

func runLoopRecordingTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("SounderLoopRecording-" + UUID().uuidString)
    defer { try? fm.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    for format in [ProjectAudioFormat(bitDepth: 32), ProjectAudioFormat(sampleRate: 44_100, channels: 1, bitDepth: 16)] {
        store.configure(format)
        let url = store.freshURL(), referenceURL = store.freshURL()
        let loop = try RecordingWriter(url: url, format: format, inputFormat: input)
        try loop.configureLoop(0.25..<1.25, start: 0)
        let reference = try RecordingWriter(url: referenceURL, format: format, inputFormat: input)
        var preview: [[Float]] = Array(repeating: [], count: format.channels)
        func merge(_ update: RecordingUpdate) {
            guard let state = update.loop else { return }
            let count = (state.frameCount + 127) / 128
            if state.resetWaveform { preview = Array(repeating: Array(repeating: 0, count: count), count: format.channels) }
            for channel in preview.indices where preview[channel].count < count {
                preview[channel].append(contentsOf: repeatElement(0, count: count - preview[channel].count))
            }
            for (index, peaks) in state.peakPatches where index < count { for channel in peaks.indices { preview[channel][index] = peaks[channel] } }
        }
        try check(!fm.fileExists(atPath: url.path), "Loop capture does not create a WAV when configured")
        var frame = 0
        while frame < 144_000 {
            let size = min(777, 144_000 - frame)
            let buffer = captureTestBuffer(format: input, start: frame, frames: size)
            loop.append(buffer); reference.append(buffer); frame += size
            loop.waitForPendingWrites(); reference.waitForPendingWrites()
            let update = loop.consumeUpdate(); if let failure = update.failure { throw failure }; merge(update)
        }
        try check(!fm.fileExists(atPath: url.path) && loop.isLoopRecording, "All loop passes remain in memory until Stop")
        try check(loop.retainedLoopFrames <= Int(format.sampleRate * 1.25) + 8192, "Loop memory retains the lead-in and one period, without accumulating passes")
        if let failure = reference.finish() { throw failure }
        if let failure = loop.finish() { throw failure }
        merge(loop.consumeUpdate())
        let linear = try AudioStore.decode(referenceURL, sampleRate: format.sampleRate)
        let saved = try AudioStore.decode(url, sampleRate: format.sampleRate)
        let lower = Int((format.sampleRate * 0.25).rounded()), upper = Int((format.sampleRate * 1.25).rounded())
        var expected = Array(repeating: Array(repeating: Float(0), count: upper), count: format.channels), position = 0
        var previousPass = expected, wrapped = false
        let fade = Int((format.sampleRate * 0.01).rounded())
        for i in 0..<linear.frameCount {
            let gain: Float = wrapped ? Float(min(1, Double(position - lower) / Double(fade - 1))) : 1
            for channel in expected.indices {
                expected[channel][position] = expected[channel][position] * (1 - gain) + linear.channels[channel][i] * gain
            }
            position += 1
            if position == upper { position = lower; wrapped = true; previousPass = expected }
        }
        if wrapped, position > lower {
            let first = max(lower, position - fade)
            for frame in first..<position {
                let gain = Float(position - 1 - frame) / Float(max(1, position - first - 1))
                for channel in expected.indices { expected[channel][frame] = expected[channel][frame] * gain + previousPass[channel][frame] * (1 - gain) }
            }
        }
        let error = zip(saved.channels, expected).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
        try check(saved.frameCount == upper && error < (format.bitDepth == 16 ? 0.00006 : 0.000001), "Stop preserves the original lead-in and merges the latest loop with 10 ms crossfades at both seams (\(format.label))")
        try check(zip(saved.channels, linear.channels).allSatisfy { zip($0.prefix(lower), $1.prefix(lower)).allSatisfy { abs($0 - $1) < 0.000001 } }, "Repeated loops leave every sample before the loop unchanged")
        let file = try AVAudioFile(forReading: url)
        try check(file.fileFormat.streamDescription.pointee.mBitsPerChannel == format.bitDepth && Int(file.fileFormat.channelCount) == format.channels, "Final loop WAV uses the project's channel count and bit depth")
        let peaks = AudioData(channels: expected).channelPeaks
        let peakError = zip(peaks, preview).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
        try check(zip(peaks, preview).allSatisfy { $0.count == $1.count } && peakError < 0.00004, "Incremental overwritten waveforms match the final stereo/mono PCM")
        let bytes = try Data(contentsOf: url)
        _ = loop.finish(); loop.append(captureTestBuffer(format: input, start: 0, frames: 128)); loop.waitForPendingWrites()
        try check(try Data(contentsOf: url) == bytes, "Repeated Stop and late input cannot append another pass to the final WAV")
    }
    let format = ProjectAudioFormat(bitDepth: 32)
    store.configure(format)
    for (origin, count) in [(0.05, 2400), (0.4, 960)] {
        let url = store.freshURL()
        let writer = try RecordingWriter(url: url, format: format, inputFormat: input)
        try writer.configureLoop(0.1..<0.3, start: origin)
        writer.append(captureTestBuffer(format: input, start: 10_000, frames: count)); writer.waitForPendingWrites()
        let state = writer.consumeUpdate().loop!
        try check(!fm.fileExists(atPath: url.path) && state.startFrame == Int((origin * 48_000).rounded()) && state.frameCount == count,
                  "Loop capture at \(origin) retains its actual first-pass interval in RAM without relocating")
        if let failure = writer.finish() { throw failure }
        try check(try AVAudioFile(forReading: url).length == AVAudioFramePosition(count), "Stopping before a first wrap writes only the captured interval")
    }
    let bedURL = store.freshURL()
    try store.write(AudioSignal(channels: [Array(repeating: 0.2, count: 96_000), Array(repeating: 0.1, count: 96_000)]), to: bedURL, bitDepth: 32)
    let bed = Track(name: "Backing", clips: [Clip(name: "Bed", source: bedURL.path, start: 0, duration: 2, order: 1)])
    let mic = Track(name: "Mic")
    func editor() -> Editor {
        let result = Editor(store: store, makeRecorder: { url, format in try LiveRecorder(url: url, format: format, inputFormat: input) }, makePlayback: { graph, format, start in
            let live = LivePlayback(graph: graph, format: format, start: start)
            try live.engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!, maximumFrameCount: 512)
            return live
        })
        result.project = Project(tracks: [bed, mic], audioFormat: format, loopEnabled: true)
        result.selectedTrack = mic.id; result.range = 0.1...0.3; return result
    }
    let session = editor()
    try session.startRecording()
    let capture = session.recorder!, backing = session.player!, engine = backing.engine, node = backing.node
    let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let rendered = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 512)!
    var bedPeak: Float = 0
    for n in 0..<94 {
        capture.writer.append(captureTestBuffer(format: input, start: n * 512, frames: 512))
        capture.writer.waitForPendingWrites()
        RunLoop.current.run(until: Date().addingTimeInterval(0.001)); backing.queue.sync {}
        guard try backing.engine.renderOffline(512, to: rendered) == .success else { throw SounderError.message("Cannot render cyclic backing") }
        for i in 0..<512 { bedPeak = max(bedPeak, abs(rendered.floatChannelData![0][i])) }
        session.updateRecordingWaveform()
    }
    try check(session.isRecording && session.player === backing && backing.engine === engine && backing.node === node && bedPeak > 0.19 && (0.1..<0.3).contains(backing.currentTime), "Loop recording keeps the same backing engine playing and cycling")
    try check(session.recordingStart == 0 && session.recordingEnd == 0.3 && (0.1..<0.3).contains(session.cursor) && !session.recordingPeaks.isEmpty, "Live recording cursor wraps while the original lead-in and retained period stay visible")
    try check(!fm.fileExists(atPath: capture.url.path) && session.project.tracks[1].clips.isEmpty && session.project.tracks[1].nextTakeNumber == 1 && session.undoStack.isEmpty, "Repeated recording passes create no files, fragments, Undo entries or take numbers")
    session.playPause()
    let clip = session.project.tracks[1].clips[0]
    try check(!session.isRecording && session.cursor == 0 && clip.start == 0 && abs(clip.duration - 0.3) < 1e-9 && clip.name == "Mic 1" && session.undoStack.count == 1, "Space commits one final loop fragment including its lead-in and returns to the original recording start")
    try check(fm.fileExists(atPath: clip.source), "Only stopping loop capture creates its final audio file")
    session.cursor = 0
    try session.startRecording()
    let discarded = session.recorder!, playback = session.player!, history = session.undoStack.count
    discarded.writer.append(captureTestBuffer(format: input, start: 0, frames: 24_000)); discarded.writer.waitForPendingWrites()
    session.updateRecordingWaveform(); session.restartFromLastStart()
    try check(session.isRecording && session.player === playback && session.recorder !== discarded && !fm.fileExists(atPath: discarded.url.path) && session.undoStack.count == history, "Enter discards loop memory and restarts from the original position without writing a take")
    session.recorder!.writer.append(captureTestBuffer(format: input, start: 0, frames: 24_000)); session.recorder!.writer.waitForPendingWrites()
    session.stopAndReturnToStart()
    try check(session.project.tracks[1].clips.count == 2 && session.project.tracks[1].nextTakeNumber == 3, "Only finalized loop recordings consume take numbers")
    let empty = editor(); empty.project.tracks[0].clips = []
    try empty.startRecording()
    try check(empty.recorder!.writer.isLoopRecording, "An empty project can record a selected Loop period")
    empty.recorder!.writer.append(captureTestBuffer(format: input, start: 0, frames: 24_000)); empty.recorder!.writer.waitForPendingWrites()
    empty.stop()
    try check(empty.project.tracks[1].clips.count == 1, "Selected-period loop capture commits correctly without pre-existing music")
}

extension AppDelegate {
    func verifyLoopRecordingUI() throws {
        let original = editor.project, originalRange = editor.range, originalSelection = editor.selectedTrack
        let format = AVAudioFormat(standardFormatWithSampleRate: editor.audio.sampleRate, channels: 2)!
        let recorder = try LiveRecorder(url: editor.audio.freshURL(), format: editor.project.audioFormat, inputFormat: format)
        defer {
            editor.stop(); editor.project = original; editor.range = originalRange; editor.selectedTrack = originalSelection
            editor.cursor = 0; editor.undoStack = []; editor.redoStack = []; editor.dirty = false
            try? FileManager.default.removeItem(at: recorder.url); refresh()
        }
        editor.project.loopEnabled = true; editor.range = 0.5...0.7; editor.cursor = 0
        try recorder.configureLoop(0.5..<0.7, start: 0); try recorder.start(); editor.activateRecording(recorder)
        func signal(frames: Int, amplitude: Float) -> AVAudioPCMBuffer {
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            input.frameLength = AVAudioFrameCount(frames)
            for frame in 0..<frames {
                let sample = Float(sin(Double(frame) * 2 * .pi * 330 / format.sampleRate)) * amplitude
                input.floatChannelData![0][frame] = sample; input.floatChannelData![1][frame] = -sample * 0.5
            }
            return input
        }
        recorder.writer.append(signal(frames: Int(format.sampleRate * 0.7), amplitude: 0.6))
        recorder.writer.waitForPendingWrites(); editor.updateRecordingWaveform()
        recorder.writer.append(signal(frames: Int(format.sampleRate * 0.06), amplitude: 0.08))
        recorder.writer.waitForPendingWrites(); editor.updateRecordingWaveform(); refresh()
        guard editor.isRecording, abs(editor.recordingStart) < 1e-8, abs(editor.recordingEnd - 0.7) < 1e-8,
              abs(editor.cursor - 0.56) < 0.002, !FileManager.default.fileExists(atPath: recorder.url.path) else { throw SounderError.message("Loop recording preview or memory-only capture is incorrect") }
        let middle = Int(0.52 * format.sampleRate / 128)..<Int(0.54 * format.sampleRate / 128)
        guard editor.recordingChannelPeaks[0][middle].max() ?? 0 < 0.081,
              editor.recordingChannelPeaks[0].prefix(10).max() ?? 0 > 0.59,
              editor.recordingChannelPeaks[0].suffix(10).max() ?? 0 > 0.59 else { throw SounderError.message("Loop preview did not replace its prefix while preserving the old tail") }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count, let view = window.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            let url = URL(fileURLWithPath: CommandLine.arguments[i + 1]).deletingPathExtension().appendingPathExtension("loop-recording.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        let count = editor.project.tracks.flatMap(\.clips).count
        editor.playPause()
        guard !editor.isRecording, editor.project.tracks.flatMap(\.clips).count == count + 1,
              editor.cursor == 0, FileManager.default.fileExists(atPath: recorder.url.path) else { throw SounderError.message("Space did not commit exactly one loop fragment") }
        print("PASS: Loop recording displays the full period with its overwritten prefix and retained tail, creates no file while active, and Space commits one fragment")
    }
}

func runMultitrackRecordingTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderMultiCapture-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    var created = 0
    let editor = Editor(store: store, makeRecorder: { url, format in
        let input = created.isMultiple(of: 2) ? mono : stereo; created += 1
        return try LiveRecorder(url: url, format: format, inputFormat: input)
    }, makePlayback: { graph, format, start in
        let playback = LivePlayback(graph: graph, format: format, start: start)
        try playback.engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 512)
        return playback
    })
    let a = Track(name: "Microphone"), b = Track(name: "Instrument"), c = Track(name: "Active")
    editor.project = Project(tracks: [a, c, b]); editor.selectedTrack = c.id; editor.cursor = 2.5
    try check(editor.recordingTargets == [c.id], "Without REC selections recording targets only the active track")
    editor.toggleRecordArm(a.id); editor.toggleRecordArm(b.id)
    let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(editor.project))
    try check(decoded.tracks.filter(\.recordArmed).map(\.id) == [a.id, b.id] && editor.selectedTrack == c.id,
              "Independent REC choices persist without changing the active track")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
    legacy.removeValue(forKey: "recordArmed")
    try check(try !JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: legacy)).recordArmed,
              "Projects saved before REC default to unarmed tracks")
    let undoCount = editor.undoStack.count
    try editor.startRecording()
    let transport = editor.player!
    try check(editor.recordings.compactMap(\.track) == [a.id, b.id] && editor.recordings.count == 2 && !editor.canArmTracks,
              "Record starts all armed inputs and freezes REC choices during capture")
    func feed(_ frames: Int) {
        for (index, take) in editor.recordings.enumerated() {
            let input = take.recorder.format.channels == 1 ? mono : stereo
            let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<Int(input.channelCount) {
                for frame in 0..<frames { buffer.floatChannelData![channel][frame] = index == 0 ? 0.2 : -0.5 }
            }
            take.recorder.writer.append(buffer); take.recorder.writer.waitForPendingWrites()
        }
        editor.updateRecordingWaveform()
    }
    feed(4800)
    try check(editor.recordings.allSatisfy { !$0.peaks.isEmpty && abs($0.start - 2.5) < 1e-8 } &&
              editor.recordings[0].channelPeaks.count == 1 && editor.recordings[1].channelPeaks.count == 2,
              "Every armed track has an independent live PCM waveform in its actual channel format")
    try check((editor.displayedTrackMeter(editor.project.tracks[0]).left.peak) > 0.19 &&
              (editor.displayedTrackMeter(editor.project.tracks[2]).left.peak) > 0.49,
              "All recording tracks display their own microphone meters")
    editor.restartFromLastStart()
    try check(editor.recordings.count == 2 && editor.player === transport && editor.cursor == 2.5 && editor.undoStack.count == undoCount,
              "Enter replaces all unsaved takes together on the same backing transport without Undo entries")
    feed(4800)
    let discarded = editor.recordings.map { $0.recorder.url }
    editor.restartFromLastStart()
    try check(discarded.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } && editor.project.tracks.allSatisfy { $0.nextTakeNumber == 1 },
              "Enter removes every discarded take file without consuming track take numbers")
    feed(4800); editor.playPause()
    let clips = editor.project.tracks.flatMap(\.clips)
    try check(!editor.isRecording && !editor.isPlaying && editor.cursor == 2.5 && clips.count == 2 && editor.project.tracks[1].clips.isEmpty && editor.undoStack.count == undoCount + 1,
              "Space saves every armed track together as one Undo step and returns to the recording start")
    let first = try store.load(clips[0].source), second = try store.load(clips[1].source)
    try check(first.channels.count == 1 && second.channels.count == 2 && abs(first.channels[0][0] - 0.2) < 0.0001 && abs(second.channels[0][0] + 0.5) < 0.0001,
              "Multitrack takes retain distinct microphone PCM and true mono/stereo formats")
    editor.undo()
    try check(editor.project.tracks.allSatisfy { $0.clips.isEmpty && $0.nextTakeNumber == 1 }, "Undo removes the whole multitrack take and restores all counters")
    editor.redo()
    try check(editor.project.tracks.flatMap(\.clips).count == 2, "Redo restores all tracks in the take")
    editor.toggleRecordArm(a.id); editor.toggleRecordArm(b.id)
    editor.cursor = 1
    try editor.startRecording()
    try check(editor.recordings.count == 1 && editor.recordingTrack == c.id,
              "Clearing every REC selection restores recording to the active track")
    feed(480); editor.stop()

    editor.toggleRecordArm(a.id); editor.toggleRecordArm(b.id)
    editor.project.loopEnabled = true; editor.range = 0.1...0.3; editor.cursor = 0
    try editor.startRecording(); feed(33_600)
    try check(editor.recordings.count == 2 && editor.recordings.allSatisfy { abs($0.start) < 1e-8 && abs($0.end - 0.3) < 1e-8 } &&
              editor.recordings.allSatisfy { !FileManager.default.fileExists(atPath: $0.recorder.url.path) },
              "Loop capture keeps a separate bounded RAM period and live preview for every armed track")
    let beforeLoop = editor.undoStack.count
    editor.playPause()
    try check(editor.undoStack.count == beforeLoop + 1 && editor.project.tracks.filter(\.recordArmed).allSatisfy { abs(($0.clips.last?.duration ?? 0) - 0.3) < 1e-8 },
              "Stopping loop capture writes all armed tracks as one take and one Undo action")
}

func runRecordingSynchronizationTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderCaptureClock-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let outputDelay = 0.037, inputDelay = 0.023 // A simulated 60 ms round trip.
    let reference = 100 + outputDelay
    for rate in [44_100.0, 48_000, 96_000] {
        for inputRate in [44_100.0, 48_000] {
            for channels in [1, 2] {
                let input = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: AVAudioChannelCount(channels))!
                let format = ProjectAudioFormat(sampleRate: rate, bitDepth: 32)
                let url = store.freshURL()
                let writer = try RecordingWriter(url: url, format: format, inputFormat: input)
                let clock = RecordingHostClock(); clock.set(hostTime: AVAudioTime.hostTime(forSeconds: reference))
                writer.configureSynchronization(clock: clock, inputLatency: inputDelay)
                let pre = Int((outputDelay * inputRate).rounded())
                let pulse = pre + Int((0.12 * inputRate).rounded())
                let total = pre + Int(0.4 * inputRate)
                let firstPhysical = reference - Double(pre) / inputRate
                for first in stride(from: 0, to: total, by: 257) {
                    let count = min(257, total - first)
                    let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(count))!
                    buffer.frameLength = AVAudioFrameCount(count)
                    for channel in 0..<channels { for frame in 0..<count {
                        buffer.floatChannelData![channel][frame] = first + frame == pulse ? (channel == 0 ? 0.8 : -0.3) : 0
                    } }
                    // Deliberately unrelated to callback delivery/wall time.
                    let stamp = firstPhysical + Double(first) / inputRate + inputDelay
                    writer.append(buffer, hostTime: AVAudioTime.hostTime(forSeconds: stamp))
                }
                writer.waitForPendingWrites()
                let preview = writer.consumeUpdate()
                if let failure = writer.finish() { throw failure }
                let data = try AudioStore.decode(url, sampleRate: rate)
                let maximum = data.channels[0].indices.max { abs(data.channels[0][$0]) < abs(data.channels[0][$1]) }!
                let expected = Int((Double(pulse - pre) * rate / inputRate).rounded())
                try check(abs(maximum - expected) <= 3 && data.channels.count == channels,
                          "60 ms interface delay aligns the pulse within resampling precision at \(Int(inputRate))→\(Int(rate)) Hz, \(channels) channel(s)")
                let peakBucket = preview.channelPeaks[0].indices.max { preview.channelPeaks[0][$0] < preview.channelPeaks[0][$1] }!
                try check(abs(peakBucket - maximum / 128) <= 1,
                          "Live waveform and finalized compensated PCM use the same sample timeline")
            }
        }
    }
    let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let delayedURL = store.freshURL()
    let delayed = try RecordingWriter(url: delayedURL, format: ProjectAudioFormat(bitDepth: 32), inputFormat: input)
    let clock = RecordingHostClock(); clock.set(hostTime: AVAudioTime.hostTime(forSeconds: reference))
    delayed.configureSynchronization(clock: clock, inputLatency: inputDelay)
    let impulse = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4800)!
    impulse.frameLength = 4800; impulse.floatChannelData![0].initialize(repeating: 0, count: 4800); impulse.floatChannelData![0][0] = 0.75
    delayed.append(impulse, hostTime: AVAudioTime.hostTime(forSeconds: reference + inputDelay + 0.025))
    if let failure = delayed.finish() { throw failure }
    let padded = try AudioStore.decode(delayedURL, sampleRate: 48_000).channels[0]
    try check(padded.prefix(1200).allSatisfy { $0 == 0 } && abs(padded[1200] - 0.75) < 1e-6,
              "Late capture startup preserves the real gap instead of shifting recorded sound early")

    let alignedURL = store.freshURL(), expectedURL = store.freshURL()
    let aligned = try RecordingWriter(url: alignedURL, format: ProjectAudioFormat(bitDepth: 32), inputFormat: input)
    let expected = try RecordingWriter(url: expectedURL, format: ProjectAudioFormat(bitDepth: 32), inputFormat: input)
    try aligned.configureLoop(0.1..<0.3, start: 0); try expected.configureLoop(0.1..<0.3, start: 0)
    aligned.configureSynchronization(clock: clock, inputLatency: inputDelay)
    let pre = 1776, frames = 22_560
    for first in stride(from: 0, to: pre + frames, by: 512) {
        let count = min(512, pre + frames - first)
        let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for frame in 0..<count {
            let source = first + frame - pre
            buffer.floatChannelData![0][frame] = source < 0 ? 0.99 : Float(sin(Double(source) * 0.031) * 0.4)
        }
        aligned.append(buffer, hostTime: AVAudioTime.hostTime(forSeconds: reference - Double(pre) / 48_000 + Double(first) / 48_000 + inputDelay))
    }
    for first in stride(from: 0, to: frames, by: 512) {
        let count = min(512, frames - first)
        let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for frame in 0..<count { buffer.floatChannelData![0][frame] = Float(sin(Double(first + frame) * 0.031) * 0.4) }
        expected.append(buffer)
    }
    if let failure = aligned.finish() { throw failure }; if let failure = expected.finish() { throw failure }
    let actual = try AudioStore.decode(alignedURL, sampleRate: 48_000)
    let target = try AudioStore.decode(expectedURL, sampleRate: 48_000)
    try check(actual.channels == target.channels && actual.frameCount == 14_400,
              "Latency compensation precedes loop overwrites/crossfades and preserves the first-pass lead-in exactly")
}
