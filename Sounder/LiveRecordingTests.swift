import AppKit
import AVFoundation

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
    try check(editor.isRecording && !editor.recordingPeaks.isEmpty && editor.cursor > 1.25 && editor.project.tracks[0].clips.isEmpty, "Editor displays live waveform and sample-accurate playhead while take is still recording")
    editor.stop()
    let clips = editor.project.tracks[0].clips
    try check(!editor.isRecording && editor.recordingPeaks.isEmpty && clips.count == 1 && abs(clips[0].start - 1.25) < 0.000001 && abs(clips[0].duration - 0.5) < 0.000001, "Stop replaces the live preview with one independent saved fragment")
    let recorded = try store.load(clips[0].source)
    try check(recorded.channels.count == 2 && recorded.channels[0] == recorded.channels[1], "Mono input records to the project's Stereo format without losing either channel")
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
