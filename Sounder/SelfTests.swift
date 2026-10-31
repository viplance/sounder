import Foundation
import AppKit
import AVFoundation
func runAudioTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderTests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    func check(_ condition: Bool, _ message: String) throws { if !condition { throw SounderError.message(message) }; print("PASS: \(message)") }
    let old = store.freshURL(), new = store.freshURL(), silent = store.freshURL()
    try store.write([Float](repeating: 0.25, count: 48_000), to: old)
    try store.write([Float](repeating: -0.5, count: 24_000), to: new)
    try store.write([Float](repeating: 0, count: 4_800), to: silent)
    var track = Track(name: "Test")
    track.clips = [Clip(name: "old", source: old.path, start: 0, duration: 1, order: 1), Clip(name: "new", source: new.path, start: 0.25, duration: 0.5, order: 2), Clip(name: "silent", source: silent.path, start: 0.4, duration: 0.1, order: 3)]
    var project = Project(tracks: [track])
    let mix = try store.render(project)
    try check(mix.count == 48_000, "Export duration is sample accurate")
    try check(mix[100] == 0.25 && mix[13_000] == -0.5 && mix[40_000] == 0.25, "New fragments override overlaps; underlying audio returns after overlap")
    try check(mix[20_000] == 0, "New silent fragment replaces old sound")
    let waveform = try store.load(new.path)
    try check(waveform.peaks[0] == 0.5, "Waveform peaks come from decoded PCM")
    let editable = Clip(name: "Trim edges", source: old.path, start: 2, offset: 0.2, duration: 0.5, order: 1)
    let shorterLeft = editable.resized(leftEdge: true, by: 0.1, sourceDuration: 1)
    try check(abs(shorterLeft.start - 2.1) < 1e-9 && abs(shorterLeft.offset - 0.3) < 1e-9 && shorterLeft.end == editable.end, "Left-edge trimming keeps the right edge and source audio aligned")
    let extendedLeft = editable.resized(leftEdge: true, by: -10, sourceDuration: 1)
    try check(extendedLeft.offset == 0 && extendedLeft.start == 1.8 && extendedLeft.end == editable.end, "Left extension stops at the beginning of the source recording")
    var nearZero = editable; nearZero.start = 0.05
    let zeroLimited = nearZero.resized(leftEdge: true, by: -10, sourceDuration: 1)
    try check(zeroLimited.start == 0 && abs(zeroLimited.offset - 0.15) < 1e-9, "Left extension cannot cross timeline zero")
    let extendedRight = editable.resized(leftEdge: false, by: 10, sourceDuration: 1)
    try check(extendedRight.start == editable.start && extendedRight.offset + extendedRight.duration == 1, "Right extension stops at the real source end without moving the start")
    for left in [true, false] {
        let shortest = editable.resized(leftEdge: left, by: left ? 10 : -10, sourceDuration: 1)
        try check(abs(shortest.duration - 0.010) < 1e-9, "Both fragment edges enforce a 10 ms minimum (left: \(left))")
    }
    var child = Track(name: "Child", parent: track.id); child.clips = [Clip(name: "child", source: old.path, start: 0, duration: 1, order: 4)]
    project.tracks.append(child)
    let nested = try store.render(project); try check(nested[100] == 0.5, "Nested tracks mix with parent")
    project.tracks[0].muted = true
    let muted = try store.render(project); try check(muted.allSatisfy { $0 == 0 }, "Parent mute silences nested tracks")
    let editor = Editor(store: store); editor.project = Project(tracks: [track]); editor.selectedTrack = track.id; editor.selection = [track.clips[0].id]; editor.cursor = 0.6
    editor.split(); try check(editor.project.tracks[0].clips.count == 4, "Split creates two source fragments")
    let splitMix = try store.render(editor.project); try check(splitMix == mix, "Split preserves exact rendered audio")
    editor.undo(); try check(editor.project.tracks[0].clips.count == 3, "Undo restores fragments")
    editor.redo(); editor.range = 0.2...0.8; editor.trim()
    let trimmed = editor.project.tracks[0].clips.filter { editor.selection.contains($0.id) }
    try check(trimmed.allSatisfy { $0.start >= 0.2 && $0.end <= 0.800001 }, "Trim keeps selected range with source offsets")
    editor.project = Project(tracks: [track]); editor.selectedTrack = track.id; editor.selection = Set(track.clips.map(\.id)); editor.join()
    let joined = try store.render(editor.project)
    try check(editor.project.tracks[0].clips.count == 1 && joined == mix, "Join preserves newest-fragment overlap semantics")
    editor.project = Project(tracks: [track, child]); editor.reparent(track.id, to: child.id)
    try check(editor.project.tracks[0].parent == nil, "Hierarchy cycles are rejected")
    let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(editor.project))
    try check(decoded.tracks[1].parent == track.id, "Project round-trip preserves nesting")
    let hierarchyEditor = Editor(store: store)
    hierarchyEditor.addTrack(nested: true)
    let levelOne = hierarchyEditor.selectedTrack!
    hierarchyEditor.addTrack(nested: true)
    let levelTwo = hierarchyEditor.selectedTrack!
    try check(hierarchyEditor.project.tracks.count == 3 && hierarchyEditor.project.tracks.last?.parent == levelOne, "Two nested levels can be created")
    let historyCount = hierarchyEditor.undoStack.count
    hierarchyEditor.addTrack(nested: true)
    try check(hierarchyEditor.project.tracks.count == 3 && hierarchyEditor.selectedTrack == levelTwo && hierarchyEditor.undoStack.count == historyCount, "Third-level creation is rejected without changing selection or Undo history")
    hierarchyEditor.addTrack()
    let independent = hierarchyEditor.selectedTrack!
    hierarchyEditor.reparent(independent, to: levelTwo)
    try check(hierarchyEditor.project.tracks.last?.parent == nil, "Reparenting cannot create a third nested level")
    hierarchyEditor.reparent(levelOne, to: independent)
    try check(hierarchyEditor.project.tracks[1].parent == independent && hierarchyEditor.project.tracks[2].parent == levelOne, "A subtree may move when its deepest child remains at depth two")
    hierarchyEditor.reparent(independent, to: hierarchyEditor.project.tracks[0].id)
    try check(hierarchyEditor.project.tracks.last?.parent == nil, "Subtree height prevents an otherwise valid parent from creating a third level")
    hierarchyEditor.reparent(levelTwo, to: nil)
    try check(hierarchyEditor.project.tracks[2].parent == nil, "Moving a deepest nested track back to the root remains available")
    var fxParent = Track(name: "Bus", clips: [track.clips[0]], effects: [PluginEffect(name: "half", path: "test", classID: "half")])
    var fxChild = Track(name: "Child", parent: fxParent.id, clips: [track.clips[0]], effects: [PluginEffect(name: "half", path: "test", classID: "half")])
    store.processEffects = { samples, effects in
        var output = samples
        for effect in effects where !effect.bypassed {
            if effect.classID == "half" { output = output.map { $0 * 0.5 } }
            if effect.classID == "bias" { output = output.map { $0 + 0.1 } }
            if effect.classID == "tail" { output.append(contentsOf: [0.1, 0.05]) }
        }
        return output
    }
    var fxProject = Project(tracks: [fxParent, fxChild])
    var fxMix = try store.render(fxProject)
    try check(abs(fxMix[100] - 0.1875) < 0.000001, "Child effects run before parent bus effects, exactly once")
    fxChild.effects[0].bypassed = true; fxProject.tracks[1] = fxChild
    fxMix = try store.render(fxProject)
    try check(fxMix[100] == 0.25, "Child bypass retains inherited parent effects")
    let sibling = Track(name: "Independent", clips: [track.clips[0]])
    fxProject.tracks.append(sibling); fxMix = try store.render(fxProject)
    try check(fxMix[100] == 0.5, "Parent FX do not affect independent tracks")
    fxParent.effects.append(PluginEffect(name: "bias", path: "test", classID: "bias"))
    fxProject = Project(tracks: [fxParent]); let ordered = try store.render(fxProject)
    fxProject.tracks[0].effects.reverse(); let reversed = try store.render(fxProject)
    try check(abs(ordered[100] - reversed[100] - 0.05) < 0.000001, "FX chain order changes rendered audio")
    fxProject.tracks[0].effects = [PluginEffect(name: "tail", path: "test", classID: "tail")]
    fxMix = try store.render(fxProject); try check(fxMix.count == 48_002, "Effect tails survive bus summing and export")
    let dry = try store.render(fxProject, range: 0..<1, onlyTrack: fxParent.id)
    try check(dry.count == 48_000 && dry[100] == 0.25, "Fragment joining stays dry to avoid double processing")
    let fxJSON = try JSONEncoder().encode(fxProject)
    let restoredFX = try JSONDecoder().decode(Project.self, from: fxJSON)
    try check(restoredFX.tracks[0].effects[0].classID == "tail", "Project round-trip preserves effect chains")
    var legacyJSON = try JSONSerialization.jsonObject(with: fxJSON) as! [String: Any]
    var legacyTracks = legacyJSON["tracks"] as! [[String: Any]]; legacyTracks[0].removeValue(forKey: "effects"); legacyJSON["tracks"] = legacyTracks
    let oldProject = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
    try check(oldProject.tracks[0].effects.isEmpty, "Projects from before FX support remain readable")
    editor.renameProject("  Voice Session  ")
    try check(editor.projectName == "Voice Session" && editor.dirty, "Project rename trims whitespace and marks changes")
    editor.renameProject("   ")
    try check(editor.projectName == "Voice Session", "Empty project names are ignored")
    editor.undo(); try check(editor.projectName == "MY PROJECT", "Project rename supports Undo")
    editor.redo()
    try editor.setAudioFormat(ProjectAudioFormat(sampleRate: 96_000, channels: 2))
    let metadata = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(editor.project))
    try check(metadata.name == "Voice Session" && metadata.audioFormat == ProjectAudioFormat(sampleRate: 96_000, channels: 2), "Name and audio settings survive project serialization")
    editor.undo(); try check(editor.project.audioFormat == ProjectAudioFormat() && store.sampleRate == 48_000, "Undo restores the audio decoding rate")
    let legacyProject = try JSONDecoder().decode(Project.self, from: Data("{\"tracks\":[],\"nextOrder\":1}".utf8))
    try check(legacyProject.name == nil && legacyProject.audioFormat == ProjectAudioFormat(channels: 1, bitDepth: 32), "Old projects default to 48 kHz mono")
    do {
        _ = try JSONDecoder().decode(Project.self, from: Data("{\"tracks\":[],\"audioFormat\":{\"sampleRate\":0,\"channels\":3}}".utf8))
        throw SounderError.message("Invalid project format was accepted")
    } catch DecodingError.dataCorrupted { throw SounderError.message("Unexpected metadata decoding error") }
      catch SounderError.message(let message) { try check(message == "Unsupported project audio format", "Invalid audio formats are rejected") }
    store.processEffects = nil
    store.configure(ProjectAudioFormat())
    let stereoURL = store.freshURL()
    let left = (0..<48_000).map { Float(sin(Double($0) / 48_000 * 2 * .pi * 440) * 0.2) }
    let right = left.map { -$0 }
    try store.write(AudioSignal(channels: [left, right]), to: stereoURL)
    let stereoTrack = Track(name: "Stereo", clips: [Clip(name: "Stereo source", source: stereoURL.path, start: 0.25, duration: 1, order: 1)])
    for rate in ProjectAudioFormat.supportedRates {
        let stereoProject = Project(tracks: [stereoTrack], audioFormat: ProjectAudioFormat(sampleRate: rate, channels: 2))
        let stereoMix = try store.renderAudio(stereoProject)
        try check(stereoMix.frameCount == Int(rate * 1.25) && stereoMix.channels.count == 2, "Stereo duration is preserved at \(Int(rate)) Hz")
        let frame = Int(rate * 0.26)
        try check(abs(stereoMix.channels[0][frame] + stereoMix.channels[1][frame]) < 0.00001 && stereoMix.channels[0].contains { abs($0) > 0.1 }, "Stereo channels stay distinct at \(Int(rate)) Hz")
        let decoded = try store.load(stereoURL.path)
        try check(abs(Double(decoded.frameCount) / rate - 1) < 0.001 && decoded.peaks.contains { $0 > 0.1 }, "Resampling preserves duration and out-of-phase waveform energy (frames: \(decoded.frameCount), rate: \(rate))")
        let exported = store.freshURL(); try store.write(stereoMix, to: exported)
        let file = try AVAudioFile(forReading: exported)
        try check(file.processingFormat.sampleRate == rate && file.processingFormat.channelCount == 2 && file.length == stereoMix.frameCount, "WAV export has selected sample rate and channels")
    }
    let monoProject = Project(tracks: [stereoTrack], audioFormat: ProjectAudioFormat(channels: 1))
    let monoMix = try store.renderAudio(monoProject)
    try check(monoMix.channels.count == 1 && monoMix.channels[0].allSatisfy { abs($0) < 0.00001 }, "Switching to Mono downmixes both source channels")
    let stereoAgain = try store.renderAudio(Project(tracks: [stereoTrack], audioFormat: ProjectAudioFormat(channels: 2)))
    try check(stereoAgain.channels[0].contains { abs($0) > 0.1 }, "Switching back to Stereo restores original channel separation")
    try check(Project().audioFormat.channels == 2 && Project().audioFormat.bitDepth == 24, "New projects default to 24-bit Stereo")
    let oldFormat = try JSONDecoder().decode(ProjectAudioFormat.self, from: Data("{\"sampleRate\":48000,\"channels\":1}".utf8))
    try check(oldFormat.channels == 1 && oldFormat.bitDepth == 32, "Old project formats preserve channels and Float32 depth")
    for depth in [16, 24, 32] {
        let format = ProjectAudioFormat(sampleRate: 48_000, channels: 2, bitDepth: depth)
        let restored = try JSONDecoder().decode(ProjectAudioFormat.self, from: JSONEncoder().encode(format))
        try check(restored == format, "Project preserves \(depth)-bit setting")
        let url = store.freshURL()
        try store.write(stereoAgain, to: url, bitDepth: depth)
        let file = try AVAudioFile(forReading: url)
        let pcm = file.fileFormat.streamDescription.pointee
        let isFloat = pcm.mFormatFlags & kAudioFormatFlagIsFloat != 0
        try check(pcm.mBitsPerChannel == UInt32(depth) && isFloat == (depth == 32) && pcm.mChannelsPerFrame == 2 && file.length == stereoAgain.frameCount, "WAV contains true \(depth)-bit \(depth == 32 ? "Float" : "integer") Stereo PCM")
        let recordingFile = try AVAudioFile(forWriting: store.freshURL(), settings: format.recordingSettings)
        let recordingPCM = recordingFile.fileFormat.streamDescription.pointee
        try check(recordingPCM.mBitsPerChannel == UInt32(depth) && recordingPCM.mChannelsPerFrame == 2, "Recording file format supports \(depth)-bit Stereo PCM")
        let decoded = try store.load(url.path)
        let error = zip(decoded.channels[0], stereoAgain.channels[0]).map { abs($0 - $1) }.max() ?? 0
        try check(error <= (depth == 16 ? 0.00004 : 0.000001), "\(depth)-bit export round-trip stays within quantization error")
    }
    try runStreamingGraphTests()
    try runTransportPositionTests()
    try runTempoTests()
    try runExportTests()
    try runLiveRecordingTests()
    try runResamplingTests()
    try runNotificationTests()
    try runAudioImportTests()
    print("All audio/editor tests passed")
}

func runPluginTest(path: String, editorTest: Bool = false) throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let host = try SNPluginHost(path: path, classID: "", state: nil)
    print("Loaded \(host.pluginName) [\(host.classID)]")
    let parameters = host.parameters()
    guard !parameters.isEmpty else { throw SounderError.message("No plug-in parameters") }
    let parameter = parameters.first { ($0["name"] as? String ?? "").lowercased().contains("output") } ?? parameters[0]
    let id = (parameter["index"] as! NSNumber).intValue
    host.setParameter(id, value: 0.37)
    let state = try host.saveState()
    let restored = try SNPluginHost(path: path, classID: host.classID, state: state)
    guard abs(restored.parameterValue(id) - host.parameterValue(id)) < 0.001 else { throw SounderError.message("Plug-in parameter state did not round-trip") }
    print("PASS: parameter state round-trip (\(parameter["name"] ?? ""))")
    let samples = (0..<48_000).map { Float(sin(Double($0) / sampleRate * 2 * .pi * 440) * 0.2) }
    let output = try restored.processMono(samples.withUnsafeBytes { Data($0) })
    let result = output.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    guard result.count >= samples.count, result.allSatisfy({ $0.isFinite }), result.contains(where: { abs($0) > 0.00001 }) else { throw SounderError.message("Invalid or silent plug-in output") }
    let difference = zip(samples, result).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) }
    guard difference > 0.01 else { throw SounderError.message("Plug-in output is unchanged after changing output gain") }
    print("PASS: effect changes the audio signal")
    print("PASS: audio processing, \(result.count) samples, latency \(restored.latency), tail \(restored.tail)")
    for rate in [44_100.0, 96_000.0] {
        let frames = Int(rate / 4)
        let left = (0..<frames).map { Float(sin(Double($0) / rate * 2 * .pi * 440) * 0.2) }
        let right = (0..<frames).map { Float(sin(Double($0) / rate * 2 * .pi * 880) * 0.1) }
        let effect = PluginEffect(name: host.pluginName, path: path, classID: host.classID, state: state)
        let result = try PluginProcessing.apply(AudioSignal(channels: [left, right]), effects: [effect], format: ProjectAudioFormat(sampleRate: rate, channels: 2))
        guard result.channels.count == 2, result.frameCount >= frames, result.channels.flatMap({ $0 }).allSatisfy({ $0.isFinite }) else { throw SounderError.message("Invalid stereo plug-in output") }
        let channelDifference = zip(result.channels[0], result.channels[1]).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) }
        guard channelDifference > 0.1 else { throw SounderError.message("Stereo plug-in processing collapsed the channels") }
        print("PASS: real plug-in preserves stereo at \(Int(rate)) Hz")
    }
    // Reuse the same processor across blocks and change a parameter while it runs.
    let stream = try SNPluginHost(path: path, classID: host.classID, state: state)
    try stream.beginStreaming(2)
    let tone = (0..<512).flatMap { frame -> [Float] in
        let value = Float(sin(Double(frame) * 2 * .pi * 440 / sampleRate) * 0.05)
        return [value, value * 0.5]
    }
    func streamedLevel(_ value: Double) throws -> Double {
        stream.setParameter(id, value: value)
        var energy = 0.0
        for block in 0..<100 {
            let data = try stream.processBlock(tone.withUnsafeBytes { Data($0) }, channels: 2)
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard samples.count == 1024 && samples.allSatisfy({ $0.isFinite }) else { throw SounderError.message("Invalid live plug-in block") }
            if block >= 80 { energy += samples.reduce(0) { $0 + Double($1 * $1) } }
        }
        return energy
    }
    let quiet = try streamedLevel(0.15), loud = try streamedLevel(0.85)
    guard abs(quiet - loud) > 0.001 else { throw SounderError.message("Live parameter changes did not affect the streaming processor") }
    print("PASS: live VST parameter changes affect subsequent streaming blocks")
    if editorTest {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderLiveFX-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = Editor(store: try AudioStore(directory: directory))
        let effect = PluginEffect(name: host.pluginName, path: path, classID: host.classID, state: state)
        editor.project.tracks[0].effects = [effect]
        let liveHost = try editor.pluginHost(effect)
        let panel = PluginEditorWindow(host: liveHost, editor: editor, effectID: effect.id)
        panel.show(native: true)
        let sourceURL = editor.audio.freshURL()
        try editor.audio.write([Float](repeating: 0.005, count: 96_000), to: sourceURL)
        editor.project.tracks[0].clips = [Clip(name: "Live test", source: sourceURL.path, start: 0, duration: 2, order: 1)]
        editor.playPause()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard !editor.dirty else { throw SounderError.message("Opening an editor or playing audio marked the project dirty") }
        guard editor.isPlaying, let playback = editor.player, playback.renderedFrames > 2048 else { throw SounderError.message("Live playback did not replenish its queued buffers") }
        func hasConfirmationButtons(_ view: NSView) -> Bool {
            if let button = view as? NSButton, ["Apply", "Cancel"].contains(button.title) { return true }
            return view.subviews.contains(where: hasConfirmationButtons)
        }
        guard NSApp.modalWindow == nil, !hasConfirmationButtons(panel.window.contentView!) else { throw SounderError.message("Plug-in editor is modal or still has confirmation buttons") }
        liveHost.setParameter(id, value: 0.62)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard editor.isPlaying, editor.player === playback, editor.dirty, editor.project.tracks[0].effects[0].state != state else { throw SounderError.message("Live editor changes did not update the project in memory") }
        let projectURL = directory.appendingPathComponent("Test.sounder")
        guard !FileManager.default.fileExists(atPath: projectURL.path) else { throw SounderError.message("Plug-in edit unexpectedly wrote a project") }
        editor.projectURL = projectURL
        guard editor.save() else { throw SounderError.message("Could not save live plug-in state") }
        let saved = try JSONDecoder().decode(Project.self, from: Data(contentsOf: projectURL.appendingPathComponent("project.json")))
        let savedHost = try SNPluginHost(path: path, classID: host.classID, state: saved.tracks[0].effects[0].state)
        guard abs(savedHost.parameterValue(id) - 0.62) < 0.001 else { throw SounderError.message("Save did not persist the open editor's current state") }
        liveHost.setParameter(id, value: 0.47); panel.captureChanges()
        guard editor.dirty else { throw SounderError.message("Editing after Save did not mark the project dirty") }
        let unchanged = try Data(contentsOf: projectURL.appendingPathComponent("project.json"))
        guard try JSONDecoder().decode(Project.self, from: unchanged).tracks[0].effects[0].state == saved.tracks[0].effects[0].state else { throw SounderError.message("Editing a plug-in wrote to disk without project Save") }
        editor.playPause()
        let stoppedAt = editor.cursor
        guard !editor.isPlaying && editor.player == nil else { throw SounderError.message("Live playback did not stop and release its stream") }
        editor.playPause()
        guard editor.isPlaying, editor.player?.start == stoppedAt else { throw SounderError.message("Live playback did not continue at the visible stopped cursor") }
        panel.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard editor.isPlaying else { throw SounderError.message("Closing the plug-in editor stopped playback") }
        editor.stop()
        guard editor.player == nil else { throw SounderError.message("Live playback did not stop") }
        editor.cursor = 0; editor.project.tracks[0].clips[0].duration = 0.08
        editor.playPause()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4 + Double(liveHost.tail) / sampleRate))
        guard editor.player == nil, editor.cursor == 0, editor.lastPlaybackStart == 0 else { throw SounderError.message("Live playback did not return to its last start after the project and effect tail finished") }
        print("PASS: audio engine streams with the native editor open; parameter edits, Save and editor close do not restart playback; pause/resume/stop work")
        guard abs((try editor.pluginHost(editor.project.tracks[0].effects[0])).parameterValue(id) - 0.47) < 0.001 else { throw SounderError.message("Closing the editor discarded live changes") }
        print("PASS: nonmodal plug-in editor applies changes immediately, retains edits on close, and writes state only on project Save")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = host.pluginName
        let container = NSView(frame: window.contentView!.bounds); window.contentView!.addSubview(container)
        guard host.attachEditor(container) else { throw SounderError.message("No native editor attached") }
        window.setContentSize(container.frame.size); window.makeKeyAndOrderFront(nil)
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { host.editorIdle(); RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count, let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
            container.cacheDisplay(in: container.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        host.detachEditor(); window.orderOut(nil)
        print("PASS: native plug-in editor attached, rendered and detached")
    }
}
