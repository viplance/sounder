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
    try check(mix[1000] == 0.25 && mix[13_000] == -0.5 && mix[40_000] == 0.25, "New fragments override overlaps; underlying audio returns after overlap")
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
    let layerEditor = Editor(store: store)
    layerEditor.project = Project(tracks: [track], nextOrder: 10)
    let oldID = track.clips[0].id
    layerEditor.moveFragmentLayer(oldID, up: true)
    let layerMix = try store.render(layerEditor.project)
    try check(layerMix[13_000] == 0.25 && layerMix[20_000] == 0, "Move up advances exactly one overlapping layer in both waveform order and rendered audio")
    layerEditor.moveFragmentLayer(oldID, up: true)
    let topMix = try store.render(layerEditor.project)
    try check(topMix[20_000] == 0.25 && layerEditor.fragmentLayerNeighbor(oldID, up: true) == nil, "A fragment reaches the top after one action per overlapping layer")
    layerEditor.moveFragmentLayer(oldID, up: false)
    let downMix = try store.render(layerEditor.project)
    try check(downMix == layerMix, "Move down restores the immediately lower audio priority")
    layerEditor.undo(); try check(try store.render(layerEditor.project) == topMix, "Layer changes support Undo")
    layerEditor.redo(); try check(try store.render(layerEditor.project) == layerMix, "Layer changes support Redo")
    let clipboardEditor = Editor(store: store)
    var copyA = track.clips[0]; copyA.start = 2; copyA.duration = 0.25; copyA.offset = 0.1
    var copyB = copyA; copyB.id = UUID(); copyB.start = 4; copyB.order += 1
    var copyC = copyA; copyC.id = UUID(); copyC.start = 6; copyC.order += 2
    let copyRoot = Track(name: "Copy source", clips: [copyA, copyC])
    let copyChild = Track(name: "Copy child", parent: copyRoot.id, clips: [copyB])
    clipboardEditor.project = Project(tracks: [copyRoot, copyChild], nextOrder: 20)
    clipboardEditor.selectAllFragments()
    try check(clipboardEditor.selection == [copyA.id, copyB.id, copyC.id], "Select All selects fragments across the full hierarchy")
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    clipboardEditor.copyFragments(to: pasteboard)
    clipboardEditor.cursor = 10; clipboardEditor.selectedTrack = copyChild.id
    clipboardEditor.pasteFragments(from: pasteboard)
    let pastedIDs = clipboardEditor.selection
    let pasted = clipboardEditor.project.tracks.flatMap(\.clips).filter { pastedIDs.contains($0.id) }
    try check(pasted.map(\.start).sorted() == [10, 12, 14] && pasted.allSatisfy { $0.offset == 0.1 && $0.duration == 0.25 }, "Paste anchors the earliest fragment at the cursor and preserves relative time and source bounds")
    try check(pastedIDs.count == 3 && pastedIDs.isDisjoint(with: [copyA.id, copyB.id, copyC.id]) && clipboardEditor.project.tracks.count == 3, "Paste creates fresh fragment IDs and any missing destination tracks")
    let copyRows = TrackHierarchy.orderedRows(clipboardEditor.project.tracks).map { $0.0 }
    try check(copyRows[1].clips.filter { pastedIDs.contains($0.id) }.count == 2 && copyRows[2].clips.first?.start == 12, "Paste preserves relative track rows from the active track")
    clipboardEditor.undo(); try check(clipboardEditor.project.tracks.count == 2 && clipboardEditor.project.tracks.flatMap(\.clips).count == 3, "One Undo removes the whole pasted group and created tracks")
    clipboardEditor.redo(); try check(clipboardEditor.project.tracks.flatMap(\.clips).count == 6, "Redo restores the pasted group")
    clipboardEditor.cursor = 20; clipboardEditor.pasteFragments(from: pasteboard)
    try check(clipboardEditor.project.tracks.flatMap(\.clips).filter { clipboardEditor.selection.contains($0.id) }.map(\.start).sorted() == [20, 22, 24], "Repeated paste uses the immutable clipboard rather than the previous paste positions")
    var child = Track(name: "Child", parent: track.id); child.clips = [Clip(name: "child", source: old.path, start: 0, duration: 1, order: 4)]
    project.tracks.append(child)
    let nested = try store.render(project); try check(nested[1000] == 0.5, "Nested tracks mix with parent")
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
    try check(abs(fxMix[1000] - 0.1875) < 0.000001, "Child effects run before parent bus effects, exactly once")
    fxChild.effects[0].bypassed = true; fxProject.tracks[1] = fxChild
    fxMix = try store.render(fxProject)
    try check(fxMix[1000] == 0.25, "Child bypass retains inherited parent effects")
    let sibling = Track(name: "Independent", clips: [track.clips[0]])
    fxProject.tracks.append(sibling); fxMix = try store.render(fxProject)
    try check(fxMix[1000] == 0.5, "Parent FX do not affect independent tracks")
    fxParent.effects.append(PluginEffect(name: "bias", path: "test", classID: "bias"))
    fxProject = Project(tracks: [fxParent]); let ordered = try store.render(fxProject)
    fxProject.tracks[0].effects.reverse(); let reversed = try store.render(fxProject)
    try check(abs(ordered[1000] - reversed[1000] - 0.05) < 0.000001, "FX chain order changes rendered audio")
    fxProject.tracks[0].effects = [PluginEffect(name: "tail", path: "test", classID: "tail")]
    fxMix = try store.render(fxProject); try check(fxMix.count == 48_002, "Effect tails survive bus summing and export")
    let dry = try store.render(fxProject, range: 0..<1, onlyTrack: fxParent.id)
    try check(dry.count == 48_000 && dry[1000] == 0.25, "Fragment joining stays dry to avoid double processing")
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
    try runRecordedMediaMoveTests()
    try runProjectStorageTests()
    try runTrackMeterTests()
    try runStreamingGraphTests()
    try runTransportPositionTests()
    try runTempoTests()
    try runTrackSoloTests()
    try runFragmentSettingsTests()
    try runFragmentFadeTests()
    try runFragmentMuteTests()
    try runNormalizationTests()
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
        editor.stop()
        guard editor.save() else { throw SounderError.message("Could not save live plug-in state") }
        let saved = try JSONDecoder().decode(Project.self, from: Data(contentsOf: projectURL))
        let savedHost = try SNPluginHost(path: path, classID: host.classID, state: saved.tracks[0].effects[0].state)
        guard abs(savedHost.parameterValue(id) - 0.62) < 0.001 else { throw SounderError.message("Save did not persist the open editor's current state") }
        editor.playPause()
        liveHost.setParameter(id, value: 0.47); panel.captureChanges()
        guard editor.dirty else { throw SounderError.message("Editing after Save did not mark the project dirty") }
        let unchanged = try Data(contentsOf: projectURL)
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
        print("PASS: audio engine streams with the native editor open; parameter edits and editor close do not restart playback; Save persists state while stopped; pause/resume/stop work")
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

func runNormalizationTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderNormalize-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let source = store.freshURL()
    let left = Array(repeating: Float(0.8), count: 24_000) + Array(repeating: Float(0.1), count: 24_000)
    let right = Array(repeating: Float(0.4), count: 24_000) + Array(repeating: Float(0.2), count: 24_000)
    try store.write(AudioSignal(channels: [left, right]), to: source, bitDepth: 32)
    let originalBytes = try Data(contentsOf: source)
    let a = Clip(name: "Quiet interval", source: source.path, start: 0, offset: 0.5, duration: 0.5, order: 1)
    let b = Clip(name: "Loud interval", source: source.path, start: 1, duration: 0.5, order: 2)
    let editor = Editor(store: store); editor.project = Project(tracks: [Track(name: "Normalize", clips: [a, b])], nextOrder: 3)
    editor.selection = [a.id, b.id]
    func process(_ level: Double) throws {
        editor.normalize(to: level)
        let limit = Date().addingTimeInterval(10)
        while editor.isNormalizing && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try check(!editor.isNormalizing, "Normalization finishes without blocking the main run loop")
    }
    try process(-3)
    let target = pow(10, -3.0 / 20)
    let normalized = try store.renderAudio(editor.project)
    try check(abs(Double(normalized.channels[1][1000]) - target) < 1e-6 && abs(Double(normalized.channels[0][49_000]) - target) < 1e-6, "Each fragment independently reaches its requested peak using only its trimmed source interval")
    try check(abs(normalized.channels[1][1000] / normalized.channels[0][1000] - 2) < 1e-6 && editor.project.tracks[0].clips[0].offset == 0.5, "Normalization links stereo gain and preserves source offset and timing")
    try check(try Data(contentsOf: source) == originalBytes && editor.undoStack.count == 1 && editor.project.normalizationLevel == -3, "Normalization leaves originals unchanged and stores the level with one Undo action")
    let graph = try StreamingGraph(project: editor.project, store: store) { _ in throw SounderError.message("Unexpected effect") }
    var peak: Float = 0
    while graph.position < graph.totalFrames { peak = max(peak, try graph.render(frames: 512).map { abs($0) }.max() ?? 0) }
    try check(abs(Double(peak) - target) < 1e-6, "Live playback and offline export use the same normalized gain")
    let gain = editor.project.tracks[0].clips[0].gain
    try process(-3)
    try check(editor.project.tracks[0].clips[0].gain == gain, "Repeated normalization does not accumulate gain or alter source data")
    editor.undo(); editor.undo()
    try check(editor.project.tracks[0].clips.allSatisfy { $0.gain == 1 } && editor.project.normalizationLevel == -1, "Undo restores original gain and the previous normalization level")
    editor.redo()
    editor.projectURL = directory.appendingPathComponent("Normalized.sounder")
    try check(editor.save(), "Normalized project saves successfully")
    let saved = try JSONDecoder().decode(Project.self, from: Data(contentsOf: editor.projectURL!))
    try check(saved.normalizationLevel == -3 && saved.tracks[0].clips[0].gain == gain, "Save/load preserves normalized gains and the last chosen level")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
    legacy.removeValue(forKey: "normalizationLevel")
    var tracks = legacy["tracks"] as! [[String: Any]]
    var clips = tracks[0]["clips"] as! [[String: Any]]
    for i in clips.indices { clips[i].removeValue(forKey: "gain") }
    tracks[0]["clips"] = clips; legacy["tracks"] = tracks
    let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacy))
    try check(decoded.normalizationLevel == -1 && decoded.tracks[0].clips.allSatisfy { $0.gain == 1 }, "Legacy projects default to unity gain and a -1 dBFS normalization target")
    let silence = AudioData(channels: [Array(repeating: Float(0), count: 48_000)])
    try check(FragmentNormalization.gain(for: b, data: silence, sampleRate: 48_000, level: -1) == 1, "Silent fragments remain finite and unchanged")
    var rejected = false
    do { try FragmentNormalization.validate(1) } catch { rejected = true }
    try check(rejected, "Normalization rejects a peak target above 0 dBFS")
}

func runFragmentMuteTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderFragmentMute-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let oldURL = store.freshURL(), newURL = store.freshURL()
    try store.write(Array(repeating: Float(0.25), count: 48_000), to: oldURL)
    try store.write(Array(repeating: Float(-0.5), count: 24_000), to: newURL)
    let old = Clip(name: "Old", source: oldURL.path, start: 0, duration: 1, order: 1)
    let newer = Clip(name: "New", source: newURL.path, start: 0.25, duration: 0.5, order: 2)
    let editor = Editor(store: store); editor.project = Project(tracks: [Track(name: "Mute", clips: [old, newer])], nextOrder: 3)
    editor.selection = [newer.id]
    let messages = editor.notifications.messages.count
    editor.toggleFragmentMute()
    let audible = try store.render(editor.project)
    try check(audible[13_000] == 0.25 && editor.project.tracks[0].clips[1].muted, "Muted fragments are skipped so underlying unmuted audio remains audible")
    let graph = try StreamingGraph(project: editor.project, store: store) { _ in throw SounderError.message("Unexpected effect") }
    var played: [Float] = []
    while graph.position < 14_000 { played += try graph.render(frames: 512) }
    try check(played[26_000] == 0.25, "Streaming playback honors per-fragment mute before track effects")
    editor.selection = [old.id, newer.id]; editor.toggleFragmentMute()
    try check(editor.fragmentsAreMuted(editor.selection) && (try store.render(editor.project)).allSatisfy { $0 == 0 }, "A mixed selection is muted together without changing the track's MUTE state")
    try check(!editor.project.tracks[0].muted && editor.notifications.messages.count == messages, "Fragment mute is independent from track mute and emits no notifications")
    editor.toggleFragmentMute()
    try check(editor.project.tracks[0].clips.allSatisfy { !$0.muted } && (try store.render(editor.project))[13_000] == -0.5, "Unmute restores all selected fragments and their original overlap priority")
    editor.undo(); try check(editor.project.tracks[0].clips.allSatisfy(\.muted), "One Undo restores the whole group's mute state")
    editor.redo(); editor.undo()
    editor.projectURL = directory.appendingPathComponent("Muted.sounder")
    try check(editor.save(), "Project with muted fragments saves successfully")
    let saved = try JSONDecoder().decode(Project.self, from: Data(contentsOf: editor.projectURL!))
    try check(saved.tracks[0].clips.allSatisfy(\.muted), "Save/load preserves fragment mute state")
    let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
    editor.copyFragments(to: pasteboard); editor.cursor = 2; editor.selectedTrack = editor.project.tracks[0].id
    editor.pasteFragments(from: pasteboard)
    try check(editor.project.tracks.flatMap(\.clips).filter { editor.selection.contains($0.id) }.allSatisfy(\.muted), "Clipboard copies retain fragment mute state")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
    legacy.removeValue(forKey: "muted")
    let restored = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: legacy))
    try check(!restored.muted, "Legacy fragments without a mute field remain audible")
}

func runFragmentFadeTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderFades-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    for rate in [44_100.0, 48_000, 96_000] {
        let format = ProjectAudioFormat(sampleRate: rate)
        store.configure(format)
        let aURL = store.freshURL(), bURL = store.freshURL()
        let frames = Int(rate * 0.4)
        try store.write(AudioSignal(channels: [Array(repeating: Float(0.4), count: frames), Array(repeating: Float(0.2), count: frames)]), to: aURL)
        try store.write(AudioSignal(channels: [Array(repeating: Float(-0.2), count: frames), Array(repeating: Float(-0.1), count: frames)]), to: bURL)
        let a = Clip(name: "Underlying", source: aURL.path, start: 0, duration: 0.4, order: 1)
        let b = Clip(name: "Overlay", source: bURL.path, start: 0.1, duration: 0.2, order: 2)
        let project = Project(tracks: [Track(name: "Fade", clips: [a, b])], nextOrder: 3, audioFormat: format)
        let mix = try store.renderAudio(project)
        let ramp = Int((rate * 0.01).rounded()), start = Int(rate * b.start), end = Int(rate * b.end)
        try check(mix.channels[0].first == 0 && mix.channels[0].last == 0 && abs(mix.channels[0][ramp] - 0.4) < 1e-6, "Fragment boundaries have a 10 ms fade at \(Int(rate)) Hz")
        try check(abs(mix.channels[0][start] - 0.4) < 1e-6 && abs(mix.channels[0][start + ramp] + 0.2) < 1e-6 && abs(mix.channels[0][end - 1] - 0.4) < 1e-6, "Overlapping starts and ends crossfade smoothly to and from the underlying fragment")
        let jump = zip(mix.channels[0], mix.channels[0].dropFirst()).map { abs($0 - $1) }.max()!
        try check(Double(jump) <= 0.6 / Double(ramp) + 1e-6 && zip(mix.channels[0], mix.channels[1]).allSatisfy { abs($0 - $1 * 2) < 1e-6 }, "Crossfades avoid hard discontinuities and preserve stereo balance")
        let region = 0.105..<0.115
        let selected = try store.renderAudio(project, range: region)
        try check(selected.channels == mix.channels.map { Array($0[Int(region.lowerBound * rate)..<Int(region.upperBound * rate)]) }, "Range rendering does not restart the fragment fades")
        let graph = try StreamingGraph(project: project, store: store) { _ in throw SounderError.message("Unexpected effect") }
        var streamed: [Float] = []
        while graph.position < graph.totalFrames { streamed += try graph.render(frames: 512) }
        var expected: [Float] = []
        for frame in 0..<mix.frameCount { expected += [mix.channels[0][frame], mix.channels[1][frame]] }
        try check(Array(streamed.prefix(expected.count)) == expected, "Streaming blocks and offline export share exactly the same fade samples")
        let editor = Editor(store: store); editor.project = project; editor.selectedTrack = project.tracks[0].id; editor.selection = [a.id, b.id]
        editor.join()
        let joined = try store.renderAudio(editor.project)
        try check(editor.project.tracks[0].clips.count == 1 && joined.channels == mix.channels, "Join bakes crossfades without applying outer fades twice")
        let joinedClip = editor.project.tracks[0].clips[0]
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(editor.project))
        try check(try store.renderAudio(restored).channels == joined.channels, "Project serialization retains baked fades without doubling them after reopening")
        var overlay = joinedClip.resized(leftEdge: false, by: -0.1, sourceDuration: 0.4)
        overlay.start = 0.05; overlay.order = 10
        let reused = try store.renderAudio(Project(tracks: [Track(name: "Joined overlay", clips: [a, overlay])], audioFormat: format))
        try check(abs(reused.channels[0][Int(0.05 * rate)] - 0.4) < 1e-6, "A reused joined fragment still crossfades with audio beneath its already-baked edge")
        let resized = joinedClip.resized(leftEdge: true, by: 0.02, sourceDuration: 0.4)
        try check(!resized.fadeInBaked && resized.fadeOutBaked, "Resizing a baked fragment edge restores its automatic fade")
        var short = a; short.duration = 0.01
        let shortMix = try store.renderAudio(Project(tracks: [Track(name: "Short", clips: [short])], audioFormat: format))
        try check(shortMix.frameCount == Int(rate * 0.01) && shortMix.channels[0].first == 0 && shortMix.channels[0].last == 0 && shortMix.channels[0].max()! > 0.39, "A 10 ms fragment uses shorter edge ramps without losing its peak or duration")
    }
}

func runFragmentSettingsTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderFragmentSettings-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory), source = directory.appendingPathComponent("source.wav")
    try store.write(AudioSignal(channels: [Array(repeating: Float(0.5), count: 48_000), Array(repeating: Float(0.25), count: 48_000)]), to: source)
    let original = Clip(name: "Settings", source: source.path, start: 0, duration: 1, order: 1)
    var settings = FragmentSettings(original)
    settings.volumeDB = 24; settings.fadeInMS = 20; settings.fadeOutMS = 40; settings.fadeInCurve = .exponential; settings.fadeOutCurve = .smooth
    let edited = try settings.applying(to: original, peak: 0.5)
    try check(abs(edited.volumeDB - 20 * log10(2)) < 1e-9 && edited.volumeDB <= 24, "Fragment volume is limited to the source's 0 dBFS peak ceiling")
    func render(_ clip: Clip, channels: Int = 2) throws -> AudioSignal { try store.renderAudio(Project(tracks: [Track(name: "Edit", clips: [clip])], audioFormat: ProjectAudioFormat(channels: channels))) }
    let audio = try render(edited)
    try check(audio.channels[0].max() == 1 && audio.channels[1].max() == 0.5, "Volume preserves stereo balance without exceeding 0 dBFS")
    try check(abs(audio.channels[0][480] - 0.25) < 1e-6 && abs(audio.channels[0][47_039] - 0.5) < 1e-6, "Independent fade lengths and curve types change the actual PCM envelope")
    var right = edited; right.pan = 90
    let rightAudio = try render(right)
    var left = edited; left.pan = -90
    let leftAudio = try render(left)
    try check(rightAudio.channels[0].allSatisfy { $0 == 0 } && rightAudio.channels[1].max() == 0.5 && leftAudio.channels[1].allSatisfy { $0 == 0 } && leftAudio.channels[0].max() == 1, "Pan -90 and +90 isolate left and right while center remains unchanged")
    let mono = try render(right, channels: 1)
    try check(mono.channels[0].max() == 0.75, "Mono project playback retains its full mix without pan-related loss")
    let graph = try StreamingGraph(project: Project(tracks: [Track(name: "Edit", clips: [right])]), store: store) { _ in throw SounderError.message("Unexpected effect") }
    var played: [Float] = []
    while graph.position < graph.totalFrames { played += try graph.render(frames: 512) }
    try check(played[20_000] == rightAudio.channels[0][10_000] && played[20_001] == rightAudio.channels[1][10_000], "Streaming playback applies fragment volume, pan and fades exactly like export")
    // Compare display buckets directly with independently rendered PCM, including
    // stereo-to-mono cancellation and mono-to-stereo pan routing.
    let sourceAudio = try store.load(source.path)
    for curve in FadeCurve.allCases {
        var visual = edited; visual.fadeInMS = 300; visual.fadeOutMS = 400
        visual.fadeInCurve = curve; visual.fadeOutCurve = curve; visual.pan = 35
        let pcm = try render(visual)
        let peaks = FragmentWaveform.peaks(sourceAudio, clip: visual, rate: 48_000, channels: 2)!
        try check(peaks == AudioData(channels: pcm.channels).channelPeaks, "Waveform matches rendered volume, pan and \(curve.title) fade curves sample for sample")
    }
    var trimmed = edited; trimmed.offset = 0.2; trimmed.duration = 0.6
    trimmed.fadeInBaked = true; trimmed.fadeOutBaked = true
    let trimmedPCM = try render(trimmed)
    try check(FragmentWaveform.peaks(sourceAudio, clip: trimmed, rate: 48_000, channels: 2)! == AudioData(channels: trimmedPCM.channels).channelPeaks, "Trimmed waveform uses the source offset and never reapplies baked fades")
    let monoSource = AudioData(Array(repeating: Float(0.5), count: 48_000))
    for channels in [1, 2] {
        let centered = FragmentWaveform.peaks(monoSource, clip: edited, rate: 48_000, channels: channels)!
        try check(centered.count == 1 && centered[0].max() == 1, "Centered mono uses one full-amplitude waveform in a \(channels)-channel project")
    }
    let monoPeaks = FragmentWaveform.peaks(monoSource, clip: right, rate: 48_000, channels: 2)!
    try check(monoPeaks.count == 2 && monoPeaks[0].allSatisfy { $0 == 0 } && monoPeaks[1].max() == 1, "Mono-source waveforms show both output channels and full-right pan")
    let opposite = AudioData(channels: [Array(repeating: Float(0.5), count: 48_000), Array(repeating: Float(-0.5), count: 48_000)])
    try check(FragmentWaveform.peaks(opposite, clip: right, rate: 48_000, channels: 1)![0].allSatisfy { $0 == 0 }, "Mono waveform reflects actual downmix cancellation instead of independent stereo peaks")
    try check(FragmentWaveform.peaks(sourceAudio, clip: edited, rate: 48_000, channels: 2, cancelled: { true }) == nil, "Obsolete waveform jobs cancel before scanning source audio")
    var baked = edited; baked.fadeInBaked = true; baked.fadeOutBaked = true
    let faded = baked.changingFade(left: true, durationMS: 100, curve: .logarithmic)
    let fadedPCM = try render(faded)
    try check(abs(fadedPCM.channels[0][2400] - Float(sqrt(0.5))) < 1e-6 && !faded.fadeInBaked && faded.fadeOutBaked, "Corner fade editing changes the actual curve envelope and only unbakes the edited edge")
    try check(baked.changingFade(left: false, durationMS: -10).fadeOutMS == 0 && baked.changingFade(left: true, durationMS: 2000).fadeInMS == 1000, "Fade duration editing stays within zero and the fragment length")
    let saved = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(edited))
    try check(FragmentSettings(saved) == FragmentSettings(edited), "Fragment settings survive project serialization")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
    for key in ["volumeDB", "pan", "fadeInMS", "fadeOutMS", "fadeInCurve", "fadeOutCurve"] { legacy.removeValue(forKey: key) }
    let decoded = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: legacy))
    try check(decoded.volumeDB == 0 && decoded.pan == 0 && decoded.fadeInMS == 10 && decoded.fadeOutMS == 10 && decoded.fadeInCurve == .linear && decoded.fadeOutCurve == .linear, "Older fragments retain unity volume, centered pan and 10 ms linear fades")
    let editor = Editor(store: store); editor.project = Project(tracks: [Track(name: "Edit", clips: [original])], nextOrder: 2)
    try editor.setFragmentSettings(original.id, settings: settings, peak: 0.5)
    try check(editor.undoStack.count == 1, "Editing all fragment settings creates one Undo step")
    editor.undo(); try check(editor.project.tracks[0].clips[0].volumeDB == 0, "Undo restores previous fragment settings")
    editor.redo(); try check(editor.project.tracks[0].clips[0].fadeInCurve == .exponential, "Redo restores fade settings")
    editor.selection = [original.id]
    let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
    editor.copyFragments(to: pasteboard); editor.cursor = 2; editor.pasteFragments(from: pasteboard)
    try check(editor.project.tracks.flatMap(\.clips).filter { editor.selection.contains($0.id) }.allSatisfy { FragmentSettings($0) == FragmentSettings(edited) }, "Copied fragments retain volume, pan, fade lengths and curves")
    settings.volumeDB = -100; settings.pan = 120; settings.fadeInMS = 0; settings.fadeOutMS = 0
    let bounded = try settings.applying(to: original, peak: 0.5)
    try check(bounded.volumeDB == -48 && bounded.pan == 90 && bounded.fadeInMS == 0, "Settings clamp volume and pan and allow disabling individual fades")
    for curve in FadeCurve.allCases {
        try check(curve.value(0) == 0 && curve.value(1) == 1 && curve.value(0.25) <= curve.value(0.75), "Fade curve \(curve.title) has valid monotonic endpoints")
    }
}

func runTrackSoloTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderSolo-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory), url = store.freshURL()
    try store.write(AudioSignal(channels: [Array(repeating: Float(0.2), count: 48_000), Array(repeating: Float(0.1), count: 48_000)]), to: url)
    let clip = Clip(name: "Solo", source: url.path, start: 0, duration: 1, order: 1)
    let effect = PluginEffect(name: "Gain", path: "test", classID: "gain")
    let parent = Track(name: "Parent", clips: [clip], effects: [effect])
    var child = Track(name: "Child", parent: parent.id, clips: [clip])
    var sibling = Track(name: "Sibling", clips: [clip])
    child.solo = true
    store.processEffects = { samples, effects in effects.isEmpty ? samples : samples.map { $0 * 0.5 } }
    func level(_ tracks: [Track]) throws -> Float { try store.renderAudio(Project(tracks: tracks)).channels[0][2000] }
    try check(abs(try level([parent, child, sibling]) - 0.1) < 1e-6, "Child Solo retains ancestor effects but excludes ancestor fragments and sibling tracks")
    sibling.solo = true
    try check(abs(try level([parent, child, sibling]) - 0.3) < 1e-6, "Multiple Solo tracks are mixed together in export")
    var soloParent = parent; soloParent.solo = true; child.solo = false; sibling.solo = false
    try check(abs(try level([soloParent, child, sibling]) - 0.2) < 1e-6, "Parent Solo includes its subtree while excluding other roots")
    var muted = soloParent; muted.muted = true
    try check(try level([muted, child, sibling]) == 0, "Mute overrides Solo and silences the muted parent subtree")
    let graph = try StreamingGraph(project: Project(tracks: [parent, child, sibling]), store: store) { _ in StreamingEffect(latency: 0, tail: 0) { $0.map { $0 * 0.5 } } }
    _ = try graph.render(frames: 512)
    graph.setSolo([child.id])
    try check(abs(try graph.render(frames: 128)[0] - 0.1) < 1e-6, "Live Solo switches the next block without rebuilding playback or resetting effects")
    graph.setSolo([child.id, sibling.id])
    try check(abs(try graph.render(frames: 128)[0] - 0.3) < 1e-6, "Live multiple Solo preserves both selected tracks")
    graph.setSolo([])
    try check(abs(try graph.render(frames: 128)[0] - 0.4) < 1e-6, "Clearing the last Solo restores all unmuted tracks")
    let initial = try StreamingGraph(project: Project(tracks: [soloParent, child, sibling]), store: store) { _ in StreamingEffect(latency: 0, tail: 0) { $0.map { $0 * 0.5 } } }
    try check(abs(try initial.render(frames: 512)[1000] - 0.2) < 1e-6, "Solo saved before Play is active in the initial streaming graph")
    let encoded = try JSONEncoder().encode(soloParent)
    try check(try JSONDecoder().decode(Track.self, from: encoded).solo, "Solo persists in project track data")
    var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]; legacy.removeValue(forKey: "solo")
    try check(try !JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: legacy)).solo, "Legacy projects default every track to Solo off")
    let editor = Editor(store: store); editor.project = Project(tracks: [parent, child, sibling])
    editor.toggleSolo(child.id); editor.toggleSolo(sibling.id)
    try check(editor.project.tracks.filter(\.solo).count == 2, "Solo toggles independently without clearing existing Solo tracks")
    editor.undo(); try check(editor.project.tracks.filter(\.solo).map(\.id) == [child.id], "Solo supports one-step Undo")
    editor.redo(); try check(editor.project.tracks.filter(\.solo).count == 2, "Solo supports Redo")
}

func runTrackMeterTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    var meter = TrackLevelMeter()
    try check(meter.fraction == 0 && meter.peakText == "−∞ dB", "Silent track meter has no fill and reports negative infinity")
    meter.update(0.9, at: 0); meter.update(0.1, at: 0.99)
    try check(meter.peak == 0.9, "Peak readout holds a maximum for the full one-second interval")
    meter.update(0.1, at: 1.01)
    try check(meter.peak == 0.1 && meter.fraction > 0, "Peak readout follows the current level after its one-second hold expires")
    meter.update(0.95, at: 1.02)
    try check(meter.peak == 0.95 && meter.level == 0.95, "A higher peak updates immediately during the hold interval")
    meter.update(0, at: 6)
    try check(meter.peak == 0 && meter.fraction == 0, "Meter release reaches silence and clears expired peak values")
    meter.update(1.2, at: 7)
    try check(meter.fraction == 1 && TrackLevelMeter.decibels(meter.peak) > 0, "Overload fills the header without hiding positive clipping peaks")
    var mid = TrackLevelMeter(); mid.update(pow(10, -30 / 20), at: 0)
    try check(abs(mid.fraction - 0.5) < 1e-9, "Header meter fills on a -60 to 0 dB scale")
    let id = UUID(), buffer = PlaybackMeterBuffer()
    buffer.append(frame: 512, peaks: [id: 0.9]); buffer.append(frame: 1024, peaks: [id: 0.2])
    try check(buffer.consume(through: 0).isEmpty && buffer.consume(through: 511).isEmpty, "Render-ahead meter snapshots are not displayed before their audio plays")
    try check(buffer.consume(through: 512)[id] == 0.9 && buffer.consume(through: 512).isEmpty && buffer.consume(through: 1024)[id] == 0.2, "Meter publication follows played frames and drains each peak once")
    buffer.append(frame: 1536, peaks: [id: 0.3]); buffer.append(frame: 2048, peaks: [id: 0.8])
    try check(buffer.consume(through: 2048)[id] == 0.8, "UI polling preserves brief peaks across all audio blocks since the previous update")
}

func runProjectStorageTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("SounderMedia-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let store = try AudioStore(directory: root.appendingPathComponent("working")), editor = Editor(store: store)
    var inputs: [URL] = []
    for (index, value) in [Float(0.1), Float(0.4)].enumerated() {
        let folder = root.appendingPathComponent("input\(index)"); try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("source.wav")
        try store.write(AudioSignal(channels: [Array(repeating: value, count: 4096), Array(repeating: value * 0.5, count: 4096)]), to: url)
        inputs.append(url)
    }
    let bytes = try inputs.map { try Data(contentsOf: $0) }
    let a = Clip(name: "Take", source: inputs[0].path, start: 0, duration: 0.05, order: 1)
    var split = a; split.id = UUID(); split.start = 0.06; split.offset = 0.01; split.duration = 0.02
    let b = Clip(name: "Imported", source: inputs[1].path, start: 0, duration: 0.05, order: 2)
    editor.project = Project(tracks: [Track(name: "Media", clips: [a, b, split])])
    let originalAudio = try store.renderAudio(editor.project)
    editor.checkpoint(); editor.project.tracks[0].clips[0].name = "Renamed"
    let url = root.appendingPathComponent("Session/Project.sounder"), media = url.deletingLastPathComponent().appendingPathComponent("media")
    try editor.save(to: url)
    var directory: ObjCBool = false
    try check(fm.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue && fm.fileExists(atPath: media.path), "New projects save as a file beside a media folder")
    let saved = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
    let paths = saved.tracks.flatMap(\.clips).map(\.source)
    try check(paths.allSatisfy { $0.hasPrefix("media/") } && Set(paths).count == 2 && paths[0] != paths[1] && paths[0] == paths[2], "Relative media paths deduplicate split sources and keep same-named input files distinct")
    try check(try inputs.enumerated().allSatisfy { try Data(contentsOf: $0.element) == bytes[$0.offset] }, "Saving copies media without modifying or deleting original inputs")
    try check(try store.renderAudio(editor.project).channels == originalAudio.channels && editor.project.tracks.flatMap(\.clips).allSatisfy { $0.source.hasPrefix(media.path + "/") }, "The live project switches to saved media paths without changing audio")
    try editor.save(to: url)
    try check(try fm.contentsOfDirectory(atPath: media.path).count == 2, "Repeated Save reuses existing media without extra copies")
    for file in inputs { try fm.removeItem(at: file) }
    editor.undo(); _ = try store.renderAudio(editor.project)
    try check(editor.project.tracks[0].clips[0].name == "Take" && editor.project.tracks[0].clips[0].source.hasPrefix(media.path + "/"), "Undo references saved media even after transient source files disappear")
    editor.redo(); _ = try store.renderAudio(editor.project)
    let newTake = store.freshURL(); try store.write(AudioSignal(channels: [Array(repeating: Float(0.05), count: 4096)]), to: newTake)
    editor.project.tracks[0].clips.append(Clip(name: "New take", source: newTake.path, start: 0.1, duration: 0.05, order: 4))
    try editor.save(to: url)
    try check(try fm.contentsOfDirectory(atPath: media.path).count == 3 && editor.project.tracks[0].clips.last!.source.hasPrefix(media.path + "/"), "Saving again adds newly recorded or imported sources to the same media folder")
    let originalJSON = try Data(contentsOf: url)
    let copy = root.appendingPathComponent("Copy/Clone.sounder")
    try editor.save(to: copy)
    try check(try Data(contentsOf: url) == originalJSON && fm.contentsOfDirectory(atPath: copy.deletingLastPathComponent().appendingPathComponent("media").path).count == 3, "Save As copies all referenced media beside the new project and preserves the original project")
    let moved = root.appendingPathComponent("Moved")
    try fm.moveItem(at: copy.deletingLastPathComponent(), to: moved)
    let movedProject = moved.appendingPathComponent("Clone.sounder"), reader = Editor(store: try AudioStore(directory: root.appendingPathComponent("reader")))
    try reader.open(from: movedProject)
    try check(reader.project.tracks.flatMap(\.clips).allSatisfy { $0.source.hasPrefix(moved.appendingPathComponent("media").path + "/") } && (try reader.audio.renderAudio(reader.project)).frameCount > 0, "Moving the project and media folder together preserves reopening and playback")
    let previous = try Data(contentsOf: movedProject)
    var broken = reader.project
    broken.tracks[0].clips.append(Clip(name: "Missing", source: root.appendingPathComponent("missing.wav").path, start: 0, duration: 1, order: 10))
    var rejected = false
    do { _ = try ProjectStorage.save(broken, to: movedProject) } catch { rejected = true }
    try check(rejected && (try Data(contentsOf: movedProject)) == previous, "A missing source cannot overwrite an already saved project")
    let folder = root.appendingPathComponent("Directory.sounder", isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    rejected = false; do { _ = try ProjectStorage.load(from: folder) } catch { rejected = true }
    try check(rejected, "Opening a project accepts files only")
    rejected = false; do { _ = try ProjectStorage.save(reader.project, to: folder) } catch { rejected = true }
    try check(rejected, "Saving cannot turn a directory into a project package")
    var escape = saved; escape.tracks[0].clips[0].source = "../outside.wav"
    let escapeURL = moved.appendingPathComponent("Escape.sounder")
    try JSONEncoder().encode(escape).write(to: escapeURL)
    rejected = false; do { _ = try ProjectStorage.load(from: escapeURL) } catch { rejected = true }
    try check(rejected, "Project media references cannot escape the containing project folder")
}

func runRecordedMediaMoveTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("SounderTakeMove-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let store = try AudioStore(directory: root.appendingPathComponent("temporary")), editor = Editor(store: store)
    let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    func record() throws -> URL {
        let recorder = try LiveRecorder(url: store.freshURL(), format: editor.project.audioFormat, inputFormat: input)
        try recorder.start(); editor.activateRecording(recorder)
        recorder.writer.append(captureTestBuffer(format: input, start: 0, frames: 24_000)); recorder.writer.waitForPendingWrites()
        editor.stop(); return recorder.url
    }
    let take = try record(), takeBytes = try Data(contentsOf: take), firstID = editor.project.tracks[0].clips[0].id
    let deletedTake = try record()
    editor.selection = [editor.project.tracks[0].clips.last!.id]; editor.deleteClips()
    let imported = root.appendingPathComponent("original-import.wav")
    try store.write(AudioSignal(channels: [Array(repeating: Float(0.1), count: 24_000)]), to: imported)
    let originalBytes = try Data(contentsOf: imported)
    editor.finishAudioImport([ImportedAudio(name: "Imported", url: imported, data: try store.load(imported.path))], track: editor.project.tracks[0].id, start: 1)
    let pasteboard = NSPasteboard.general
    let previousClipboard = (pasteboard.types ?? []).compactMap { type in pasteboard.data(forType: type).map { (type, $0) } }
    defer { pasteboard.clearContents(); for (type, data) in previousClipboard { pasteboard.setData(data, forType: type) } }
    editor.selection = [firstID]; editor.copyFragments()
    let destination = root.appendingPathComponent("Saved/Project.sounder")
    try editor.save(to: destination)
    let media = destination.deletingLastPathComponent().appendingPathComponent("media")
    let savedTake = editor.project.tracks[0].clips.first { $0.id == firstID }!
    try check(!fm.fileExists(atPath: take.path) && savedTake.source.hasPrefix(media.path + "/") && (try Data(contentsOf: URL(fileURLWithPath: savedTake.source))) == takeBytes, "A successful Save moves newly recorded takes into media without changing their bytes")
    try check(!fm.fileExists(atPath: deletedTake.path) && (try fm.contentsOfDirectory(atPath: media.path)).count == 3, "Save also moves recorded takes retained by Undo history")
    try check(try Data(contentsOf: imported) == originalBytes && editor.project.tracks[0].clips.last!.source != imported.path, "Imported audio is copied into media while its original remains unchanged")
    editor.undo(); editor.undo()
    try check(editor.project.tracks[0].clips.count == 2 && editor.project.tracks[0].clips.allSatisfy { fm.fileExists(atPath: $0.source) && $0.source.hasPrefix(media.path + "/") }, "Undo restores deleted takes using relocated media instead of missing temporary files")
    editor.redo(); editor.redo()
    editor.cursor = 2; editor.pasteFragments()
    try check(editor.project.tracks[0].clips.last!.source == savedTake.source && editor.project.tracks[0].clips.last!.start == 2, "The fragment clipboard still pastes a take after its temporary source moves")
    let originalProjectBytes = try Data(contentsOf: destination)
    let clone = root.appendingPathComponent("Clone/Copy.sounder")
    try editor.save(to: clone)
    try check(fm.fileExists(atPath: savedTake.source) && (try Data(contentsOf: destination)) == originalProjectBytes && editor.project.tracks[0].clips[0].source.hasPrefix(clone.deletingLastPathComponent().appendingPathComponent("media").path), "Save As copies already saved takes and leaves the original project media intact")
    let pending = try record()
    let invalid = root.appendingPathComponent("CannotOverwrite.sounder", isDirectory: true)
    try fm.createDirectory(at: invalid, withIntermediateDirectories: true)
    var failed = false; do { try editor.save(to: invalid) } catch { failed = true }
    try check(failed && fm.fileExists(atPath: pending.path), "A failed project Save cannot remove a newly recorded temporary take")
    try editor.save(to: clone)
    try check(!fm.fileExists(atPath: pending.path), "A later successful Save moves the retained take after an earlier failure")
}
