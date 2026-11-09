import AppKit
import AVFoundation
import CoreMIDI

private func liveCheck(_ condition: Bool, _ message: String) throws {
    guard condition else { throw SounderError.message(message) }
    print("PASS: \(message)")
}

func runLiveEffectsTests() throws {
    let words: [UInt32] = [0x20903C64, 0x10F80000, 0x30FFFFFF, 0x2090447F, 0x20B0407F, 0x20803C00, 0x40000000]
    let messages = words.withUnsafeBufferPointer { LiveMIDIDecoder.decode($0, source: 7) }
    try liveCheck(messages == [LiveMIDIMessage(source: 7, status: 0x90, data1: 60, data2: 100),
                               LiveMIDIMessage(source: 7, status: 0xB0, data1: 64, data2: 127),
                               LiveMIDIMessage(source: 7, status: 0x80, data1: 60, data2: 0)],
                  "MIDI decoding preserves notes/pedal and skips system, SysEx and incomplete UMP messages")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderLiveFX-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory), url = store.freshURL()
    let format = ProjectAudioFormat(bitDepth: 32)
    try store.write(AudioSignal(channels: [Array(repeating: 0.1, count: 96_000), Array(repeating: 0.1, count: 96_000)]), to: url)
    let effect = PluginEffect(name: "Tail", path: "test", classID: "tail")
    let track = Track(name: "Tail", clips: [Clip(name: "Dry", source: url.path, start: 0, duration: 2, order: 1)], effects: [effect])
    let project = Project(tracks: [track], audioFormat: format)
    var state: Float = 0
    let graph = try StreamingGraph(project: project, store: store) { _ in
        StreamingEffect(latency: 0, tail: 48_000) { samples in
            var output = samples
            for i in stride(from: 0, to: output.count, by: 2) {
                state = state * 0.9999 + samples[i] * 0.001
                output[i] = state; output[i + 1] = state
            }
            return output
        }
    }
    let live = LivePlayback(graph: graph, format: format, start: 0)
    let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    try live.engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: 512)
    let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 512)!
    try live.startPlayback()
    defer { live.stop() }
    func block() throws -> Float {
        RunLoop.current.run(until: Date().addingTimeInterval(0.003)); live.queue.sync {}
        guard try live.engine.renderOffline(512, to: buffer) == .success else { throw SounderError.message("Cannot render live FX") }
        return (0..<512).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
    }
    for _ in 0..<8 { _ = try block() }
    live.auditionEffects(at: 0.25, hosts: [], tempo: 120); live.queue.sync {}
    let position = graph.position, cachedFrames = graph.outputCache.frames
    var tail: Float = 0
    for index in 0..<24 { let peak = try block(); if index > 8 { tail = max(tail, peak) } }
    try liveCheck(tail > 0.001 && live.engine.isRunning && live.node.isPlaying && !live.isPlaying,
                  "Stop retains the running engine/node and audible effect tails after queued source buffers finish")
    try liveCheck(live.currentTime == 0.25 && graph.position <= position + 480 && graph.outputCache.frames == cachedFrames,
                  "Effects keep processing silence without advancing the stopped timeline")
    live.setMuted(true, trackID: track.id)
    var muted: Float = 1
    for _ in 0..<12 { muted = try block() }
    try liveCheck(muted == 0, "Track MUTE silences live effects while stopped")
    // An idle graph must not decode even an unavailable source file.
    var missing = project; missing.tracks[0].clips[0].source = directory.appendingPathComponent("missing.wav").path
    let idle = try StreamingGraph(project: missing, store: store, includeAudioSources: false) { _ in StreamingEffect(latency: 0, tail: 0) { $0 } }
    try liveCheck(try idle.renderEffects(frames: 512).allSatisfy { $0 == 0 }, "Stopped FX preparation does not decode timeline sources")
}

/// Real instrument test, optionally repeated with a legacy VST bundle.
func runLiveInstrumentTest(path: String, reverb: String? = nil) throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
    try runLiveEffectsTests()
    func loadOnWorker() throws -> SNPluginHost {
        let hostLock = NSLock()
        var loaded: Result<SNPluginHost, Error>?
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SNPluginHost(path: path, classID: "", state: nil) }
            hostLock.lock(); loaded = result; hostLock.unlock()
        }
        var result: Result<SNPluginHost, Error>?
        let deadline = Date().addingTimeInterval(15)
        while result == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            hostLock.lock(); result = loaded; hostLock.unlock()
        }
        guard let result else { throw SounderError.message("Background instrument loading timed out") }
        return try result.get()
    }
    let firstHost = try loadOnWorker()
    defer { withExtendedLifetime(firstHost) {} }
    let host = try loadOnWorker()
    try liveCheck(host.isInstrument && host.acceptsMIDI, "Host loads MIDI instruments, including instruments without audio inputs")
    try host.ensureStreaming(2); host.setTransportPlaying(false, position: 0, tempo: 120)
    let silence = [Float](repeating: 0, count: 1024).withUnsafeBytes { Data($0) }
    func energy(_ count: Int) throws -> Double {
        var sum = 0.0
        for _ in 0..<count {
            let block = try host.processBlock(silence, channels: 2)
            sum += block.withUnsafeBytes { $0.bindMemory(to: Float.self).reduce(0) { $0 + Double($1 * $1) } }
        }
        return sum
    }
    _ = try energy(8)
    host.sendMIDIStatus(0x90, data1: 60, data2: 100)
    let sounding = try energy(50)
    try liveCheck(sounding > 0.01, "Real synthesizer produces MIDI notes with transport stopped")
    try host.ensureStreaming(2)
    try liveCheck(try energy(16) > 0.01, "Reusing a live host does not reset held voices")
    host.allNotesOff(); _ = try energy(600)
    try liveCheck(try energy(30) < sounding * 0.001, "All Notes Off releases real instrument voices")

    // CoreMIDI virtual-source loopback exercises the same callback as a physical keyboard.
    var client: MIDIClientRef = 0, source: MIDIEndpointRef = 0
    guard MIDIClientCreateWithBlock("Sounder MIDI test" as CFString, &client, nil) == noErr else { throw SounderError.message("Cannot create test MIDI client") }
    defer { if source != 0 { MIDIEndpointDispose(source) }; MIDIClientDispose(client) }
    guard MIDISourceCreateWithProtocol(client, "Sounder temporary keyboard" as CFString, ._1_0, &source) == noErr else { throw SounderError.message("Cannot create temporary MIDI keyboard") }
    let lock = NSLock(); var received = [LiveMIDIMessage]()
    let input = try LiveMIDIInput(received: { batch in lock.lock(); received += batch; lock.unlock() }, disconnected: { _ in })
    defer { withExtendedLifetime(input) {} }
    var list = MIDIEventList()
    withUnsafeMutablePointer(to: &list) { pointer in
        let packet = MIDIEventListInit(pointer, ._1_0)
        var word: UInt32 = 0x2090407F
        _ = MIDIEventListAdd(pointer, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        MIDIReceivedEventList(source, pointer)
    }
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        lock.lock(); let ready = !received.isEmpty; lock.unlock(); if ready { break }
    }
    lock.lock(); let batch = received; lock.unlock()
    try liveCheck(batch.contains { $0.status == 0x90 && $0.data1 == 64 && $0.data2 == 127 }, "CoreMIDI receives notes from an external-source endpoint")
    for message in batch { host.sendMIDIStatus(message.status, data1: message.data1, data2: message.data2) }
    try liveCheck(try energy(30) > 0.01, "CoreMIDI input reaches the real stopped synthesizer")
    host.allNotesOff()

    if let snapshotIndex = CommandLine.arguments.firstIndex(of: "--snapshot"), snapshotIndex + 1 < CommandLine.arguments.count {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentView!.bounds); window.contentView!.addSubview(container)
        guard host.attachEditor(container) else { throw SounderError.message("No native instrument editor") }
        window.setContentSize(container.frame.size); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<30 { host.editorIdle(); RunLoop.current.run(until: Date().addingTimeInterval(0.01)); _ = try energy(1) }
        if let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
            container.cacheDisplay(in: container.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[snapshotIndex + 1]))
        }
        if let click = CommandLine.arguments.firstIndex(of: "--keyboard-test"), click + 2 < CommandLine.arguments.count,
           let x = Double(CommandLine.arguments[click + 1]), let y = Double(CommandLine.arguments[click + 2]) {
            host.allNotesOff(); _ = try energy(600)
            let point = NSPoint(x: x, y: y)
            guard container.hitTest(point) != nil else { throw SounderError.message("No keyboard hit target") }
            let location = container.convert(point, to: nil)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(down)
            RunLoop.current.run(until: Date().addingTimeInterval(0.04)); host.editorIdle()
            let keyboardEnergy = try energy(50)
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            window.sendEvent(up)
            try liveCheck(keyboardEnergy > 0.01, "Native plug-in on-screen keyboard produces sound with stopped transport")
        }
        host.detachEditor(); window.orderOut(nil)
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderInstrument-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let effect = PluginEffect(name: host.pluginName, path: path, classID: host.classID)
    let url = store.freshURL()
    try store.write([Float](repeating: 0, count: 96_000), to: url)
    let track = Track(name: "Instrument", clips: [Clip(name: "Silence", source: url.path, start: 0, duration: 2, order: 1)], effects: [effect])
    let editor = Editor(store: store, makePlayback: { graph, format, start in
        let live = LivePlayback(graph: graph, format: format, start: start)
        try live.engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!, maximumFrameCount: 512)
        return live
    })
    editor.project = Project(tracks: [track], audioFormat: ProjectAudioFormat(bitDepth: 32))
    editor.selectedTrack = track.id; editor.pluginHosts[effect.id] = host
    editor.keepsPluginsRunning = true
    defer { editor.shutdownLivePlugins(); editor.stop() }
    func wait(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try liveCheck(condition(), "Live instrument monitor becomes ready")
    }
    try wait { editor.liveEffectsPlayer?.isProcessingLiveEffects == true }
    editor.receiveMIDI([LiveMIDIMessage(source: 99, status: 0x90, data1: 67, data2: 100)])
    guard let monitor = editor.liveEffectsPlayer else { throw SounderError.message("Missing effects monitor") }
    let pcm = monitor.engine.manualRenderingFormat, buffer = AVAudioPCMBuffer(pcmFormat: monitor.engine.manualRenderingFormat, frameCapacity: 512)!
    var peak: Float = 0
    for _ in 0..<24 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.003)); monitor.queue.sync {}
        if try monitor.engine.renderOffline(512, to: buffer) == .success { peak = max(peak, (0..<512).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0) }
    }
    try liveCheck(peak > 0.001 && editor.pluginHosts[effect.id] === host && editor.cursor == 0 && pcm.channelCount == 2,
                  "Editor routes MIDI to the active unarmed track using its authoritative live host and a stationary cursor")
    editor.playPause()
    try wait { editor.isPlaying }
    guard let playing = editor.player else { throw SounderError.message("Missing playing engine") }
    let playingBuffer = AVAudioPCMBuffer(pcmFormat: playing.engine.manualRenderingFormat, frameCapacity: 512)!
    func render(_ playback: LivePlayback, _ buffer: AVAudioPCMBuffer, blocks: Int) throws -> Float {
        var peak: Float = 0
        for _ in 0..<blocks {
            RunLoop.current.run(until: Date().addingTimeInterval(0.003)); playback.queue.sync {}
            if try playback.engine.renderOffline(512, to: buffer) == .success {
                peak = max(peak, (0..<512).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0)
            }
        }
        return peak
    }
    _ = try render(playing, playingBuffer, blocks: 8)
    editor.stopAndReturnToStart()
    try liveCheck(editor.liveEffectsPlayer === playing && !editor.isPlaying && editor.cursor == 0,
                  "Editor Stop returns its marker and preserves the same live engine and plug-in")
    try liveCheck(try render(playing, playingBuffer, blocks: 24) > 0.001,
                  "A held real synthesizer note survives editor Play and Stop")
    editor.playPause(); try wait { editor.isPlaying }
    guard let resumed = editor.player else { throw SounderError.message("Missing resumed engine") }
    let resumedBuffer = AVAudioPCMBuffer(pcmFormat: resumed.engine.manualRenderingFormat, frameCapacity: 512)!
    _ = try render(resumed, resumedBuffer, blocks: 8)
    editor.playPause()
    for _ in 0..<16 { _ = try render(resumed, resumedBuffer, blocks: 1); if resumed.pauseComplete { break } }
    try liveCheck(resumed.pauseComplete && resumed.isProcessingLiveEffects && !editor.isPlaying,
                  "Pause freezes the timeline while its live instrument keeps processing")
    try liveCheck(try render(resumed, resumedBuffer, blocks: 16) > 0.001, "Real instrument remains audible during pause")
    editor.seek(to: 0.6)
    editor.playPause(); try wait { editor.isPlaying }
    var previousPosition = 0.6
    for _ in 0..<8 {
        _ = try render(resumed, resumedBuffer, blocks: 1)
        let position = resumed.currentTime
        try liveCheck(position >= previousPosition - 1e-9 && position < 0.8, "Resuming live FX keeps the new paused seek position monotonic")
        previousPosition = position
    }
    try liveCheck(editor.pluginHosts[effect.id] === host && editor.player === resumed, "Play after paused FX reuses the same engine and authoritative processor")
    editor.stopAndReturnToStart()
    editor.receiveMIDI([LiveMIDIMessage(source: 99, status: 0x80, data1: 67, data2: 0)])
    let lastIdle = editor.liveEffectsPlayer
    editor.toggleAllEffects(for: track.id)
    try wait { editor.liveEffectsPlayer == nil }
    try liveCheck(lastIdle?.engine.isRunning == false, "Bypassing the last active FX stops the idle engine")
    editor.shutdownLivePlugins()
    let secondHost = try SNPluginHost(path: path, classID: host.classID, state: nil)
    try secondHost.ensureStreaming(2); secondHost.setTransportPlaying(false, position: 0, tempo: 120)
    let secondEffect = PluginEffect(name: secondHost.pluginName, path: path, classID: secondHost.classID)
    var secondTrack = Track(name: "Second instrument", effects: [secondEffect]); secondTrack.recordArmed = true
    editor.project.tracks[0].effectsBypassed = false; editor.project.tracks[0].recordArmed = true
    editor.project.tracks.append(secondTrack); editor.pluginHosts[secondEffect.id] = secondHost
    host.allNotesOff(); _ = try energy(600)
    editor.receiveMIDI([LiveMIDIMessage(source: 101, status: 0x90, data1: 60, data2: 100)])
    let firstEnergy = try energy(32)
    var secondEnergy = 0.0
    for _ in 0..<32 { secondEnergy += try secondHost.processBlock(silence, channels: 2).withUnsafeBytes { $0.bindMemory(to: Float.self).reduce(0) { $0 + Double($1 * $1) } } }
    try liveCheck(firstEnergy > 0.01 && secondEnergy > 0.01, "MIDI notes reach all REC-armed instrument tracks simultaneously")
    editor.selectedTrack = secondTrack.id
    editor.project.tracks[0].recordArmed = false; editor.project.tracks[1].recordArmed = false
    editor.receiveMIDI([LiveMIDIMessage(source: 101, status: 0x80, data1: 60, data2: 0)])
    _ = try energy(600)
    try liveCheck(try energy(32) < firstEnergy * 0.001, "Note Off still reaches earlier recipients after REC/active-track changes")
    secondHost.allNotesOff()

    if let reverb {
        let fx = try SNPluginHost(path: reverb, classID: "", state: nil)
        try fx.ensureStreaming(2); fx.setTransportPlaying(true, position: 0, tempo: 120)
        for index in 0..<32 {
            let tone = (0..<512).flatMap { frame -> [Float] in
                let sample = Float(sin(Double(index * 512 + frame) * 440 * 2 * .pi / 48_000) * 0.3)
                return [sample, sample]
            }
            _ = try fx.processBlock(tone.withUnsafeBytes { Data($0) }, channels: 2)
        }
        fx.setTransportPlaying(false, position: 0, tempo: 120)
        var tail = 0.0
        for _ in 0..<64 { tail += try fx.processBlock(silence, channels: 2).withUnsafeBytes { $0.bindMemory(to: Float.self).reduce(0) { $0 + Double($1 * $1) } } }
        try liveCheck(tail > 0.001, "Real reverb continues its existing tail with transport stopped")
    }
}

/// A paused node still owns its live processor while its queued fade is audible.
/// Hold the offline device clock still to expose preparation races deterministically.
func runLiveEffectsOwnershipTest(path: String) throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SounderFXOwnership-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AudioStore(directory: root), url = store.freshURL()
    try store.write([Float](repeating: 0.1, count: 96_000), to: url)
    let host = try SNPluginHost(path: path, classID: "", state: nil)
    let effect = PluginEffect(name: host.pluginName, path: path, classID: host.classID)
    let track = Track(name: "FX", clips: [Clip(name: "Tone", source: url.path, start: 0, duration: 2, order: 1)], effects: [effect])
    let lock = NSLock(); var players: [LivePlayback] = []
    let editor = Editor(store: store, makePlayback: { graph, format, start in
        let playback = LivePlayback(graph: graph, format: format, start: start)
        try playback.engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels))!, maximumFrameCount: 512)
        lock.lock(); players.append(playback); lock.unlock()
        return playback
    })
    editor.project = Project(tracks: [track], audioFormat: ProjectAudioFormat(bitDepth: 32))
    editor.selectedTrack = track.id; editor.pluginHosts[effect.id] = host
    editor.keepsPluginsRunning = true
    defer {
        editor.shutdownLivePlugins(); editor.stop()
        lock.lock(); let all = players; lock.unlock(); all.forEach { $0.stop() }
    }
    func wait(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        guard condition() else { throw SounderError.message("FX ownership test timed out") }
    }
    try wait { editor.liveEffectsPlayer != nil }
    editor.playPause(); try wait { editor.isPlaying }
    guard let active = editor.player else { throw SounderError.message("Missing active transport") }
    lock.lock(); let before = players.count; lock.unlock()
    editor.playPause()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    lock.lock(); let after = players.count; let running = players.filter { $0.engine.isRunning }.count; lock.unlock()
    print("FX OWNERSHIP \(host.pluginName): engines before pause=\(before), after=\(after), running=\(running), latency=\(host.latency)")
    try liveCheck(after == before && editor.liveEffectsPlayer == nil,
                  "Pause fade never creates a second engine processing the same live FX host")
    let buffer = AVAudioPCMBuffer(pcmFormat: active.engine.manualRenderingFormat, frameCapacity: 512)!
    for _ in 0..<32 {
        _ = try active.engine.renderOffline(512, to: buffer)
        RunLoop.current.run(until: Date().addingTimeInterval(0.003)); active.queue.sync {}
        if active.pauseComplete { break }
    }
    try liveCheck(active.pauseComplete && active.isProcessingLiveEffects && editor.liveEffectsPlayer == nil,
                  "Paused FX remain owned by the original transport after its audible fade")
    editor.playPause()
    try liveCheck(editor.player === active && editor.pluginHosts[effect.id] === host,
                  "Resume retains one engine and one authoritative effect processor")
    for _ in 0..<8 {
        editor.stopAndReturnToStart()
        editor.toggleAllEffects(for: track.id); editor.toggleAllEffects(for: track.id)
        // Play as soon as ownership is published; the idle engine can still be
        // starting on its worker, before the completion callback is delivered.
        try wait { editor.liveEffectsPlayer != nil }
        editor.playPause(); try wait { editor.isPlaying }
        lock.lock(); let all = players; lock.unlock()
        try liveCheck(all.filter { $0.engine.isRunning && $0.node.isPlaying }.count == 1,
                      "Play during idle-FX startup leaves exactly one running audio producer")
    }
}

func runPluginPersistenceTest(path: String) throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SounderPluginState-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AudioStore(directory: root)
    let host = try SNPluginHost(path: path, classID: "", state: nil)
    let baseline = try host.saveState()
    let dictionary = try PropertyListSerialization.propertyList(from: baseline, format: nil) as! [String: Any]
    let key = dictionary["component"] != nil ? "component" : "chunk"
    guard let original = dictionary[key] as? Data, let xmlMagic = original.range(of: Data("VC2!".utf8)) else {
        throw SounderError.message("This persistence fixture requires Convology XT's JUCE state")
    }
    let xmlStart = xmlMagic.lowerBound + 8
    func littleInt(_ data: Data, _ at: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(data[at + $1]) << ($1 * 8) }
    }
    func writeInt(_ value: Int, into data: inout Data, at offset: Int, big: Bool) {
        for byte in 0..<4 { data[offset + byte] = UInt8((value >> ((big ? 3 - byte : byte) * 8)) & 255) }
    }
    let xmlLength = littleInt(original, xmlStart - 4)
    guard let xml = String(data: original[xmlStart..<(xmlStart + xmlLength)], encoding: .utf8), xml.contains("<file></file>") else {
        throw SounderError.message("Unexpected Convology XT fixture state")
    }
    func state(selecting url: URL) throws -> Data {
        let escaped = url.path.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let changed = Data(xml.replacingOccurrences(of: "<file></file>", with: "<file>" + escaped + "</file>").utf8)
        var component = original
        component.replaceSubrange(xmlStart..<(xmlStart + xmlLength), with: changed)
        let difference = changed.count - xmlLength
        writeInt(changed.count, into: &component, at: xmlStart - 4, big: false)
        // VST3 wraps the same legacy chunk in a VstW/FBCh header.
        if key == "component" {
            writeInt(component.count - 24, into: &component, at: 20, big: true)
            let chunkSize = (0..<4).reduce(0) { $0 << 8 | Int(original[xmlMagic.lowerBound - 4 + $1]) }
            writeInt(chunkSize + difference, into: &component, at: xmlMagic.lowerBound - 4, big: true)
        }
        var result = dictionary; result[key] = component
        return try PropertyListSerialization.data(fromPropertyList: result, format: .binary, options: 0)
    }
    func containsFile(_ state: Data?, _ url: URL) throws -> Bool {
        guard let state, let saved = try PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any],
              let component = saved[key] as? Data else { return false }
        return component.range(of: Data(url.path.utf8)) != nil
    }
    let effect = PluginEffect(name: host.pluginName, path: path, classID: host.classID, state: baseline)
    let masterEffect = PluginEffect(name: host.pluginName, path: path, classID: host.classID, state: baseline)
    let editor = Editor(store: store)
    editor.project = Project(tracks: [Track(name: "IR", effects: [effect])], masterEffects: [masterEffect])
    editor.range = 1.25...8.75
    let projectURL = root.appendingPathComponent("Saved.sounder")
    for name in ["First IR.wav", "Second IR.wav"] {
        let ir = root.appendingPathComponent(name)
        var impulse = [Float](repeating: 0, count: 4800); impulse[0] = 0.8; impulse[1000] = 0.2
        try store.write(impulse, to: ir)
        let loaded = try SNPluginHost(path: path, classID: host.classID, state: state(selecting: ir))
        let master = try SNPluginHost(path: path, classID: host.classID, state: state(selecting: ir))
        try liveCheck(try containsFile(loaded.saveState(), ir), "Real Convology XT accepts the impulse file in its opaque state")
        let parameters = loaded.parameters().compactMap { $0["value"] as? NSNumber }
        let polled = loaded.editorSnapshot(revision: loaded.editRevision, values: parameters)
        try liveCheck(polled?["state"] == nil, "Unchanged parameter polling does not capture Convology XT's opaque impulse selection")
        editor.pluginHosts[effect.id] = loaded; editor.pluginHosts[masterEffect.id] = master
        let board = NSPasteboard.withUniqueName()
        let sourceRack = EffectsWindow(editor: editor, trackID: editor.project.tracks[0].id)
        let targetRack = EffectsWindow(editor: editor, trackID: Project.masterID)
        sourceRack.pasteboard = board; targetRack.pasteboard = board
        sourceRack.run(); targetRack.run()
        sourceRack.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try liveCheck(sourceRack.copySelection() && targetRack.pasteSelection(), "Copy/Paste transfers Convology XT between FX windows")
        try liveCheck(try containsFile(targetRack.effects.last?.state, ir), "FX clipboard captures the current opaque impulse-file selection")
        sourceRack.done(); targetRack.done(); board.releaseGlobally()
        try editor.save(to: projectURL)
        let reopened = Editor(store: try AudioStore(directory: root.appendingPathComponent("Opened")))
        try reopened.open(from: projectURL)
        let restoredEffect = reopened.project.tracks[0].effects[0]
        let restored = try SNPluginHost(path: path, classID: host.classID, state: restoredEffect.state)
        try restored.ensureStreaming(2)
        try liveCheck(try containsFile(restored.saveState(), ir), "Save/Open restores Convology XT's selected impulse with its editor closed")
        try liveCheck(try containsFile(reopened.project.masterEffects[0].state, ir), "Save includes the authoritative MASTER impulse state")
        try liveCheck(reopened.range == editor.range, "Project restores the selected timeline period together with the impulse")
    }
}

func runEffectsClipboardTest(path: String) throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SounderFXClipboard-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let editor = Editor(store: try AudioStore(directory: root))
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    var source: [PluginEffect] = [], values: [Double] = [], parameter: Int = 0
    for i in 0..<3 {
        let host = try SNPluginHost(path: path, classID: "", state: nil)
        let parameters = host.parameters()
        let chosen = parameters.first { ($0["name"] as? String ?? "").lowercased().contains("output") } ?? parameters[0]
        parameter = (chosen["index"] as! NSNumber).intValue
        let state = try host.saveState()
        let value = 0.25 + Double(i) * 0.2
        host.setParameter(parameter, value: value)
        values.append(host.parameterValue(parameter))
        let effect = PluginEffect(name: "Effect \(i)", path: path, classID: host.classID, state: state, bypassed: i == 2)
        source.append(effect); editor.pluginHosts[effect.id] = host
    }
    let track = Track(name: "Source", effects: source)
    editor.project = Project(tracks: [track], masterEffects: [PluginEffect(name: "Existing", path: path, classID: source[0].classID)], masterEffectsBypassed: true)
    let rack = EffectsWindow(editor: editor, trackID: track.id); rack.pasteboard = board; rack.run()
    let master = EffectsWindow(editor: editor, trackID: Project.masterID); master.pasteboard = board; master.run()
    defer { rack.done(); master.done(); editor.closePluginWindows(capture: false) }
    func command(_ window: NSWindow, code: UInt16, character: String) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                    characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        return window.performKeyEquivalent(with: event)
    }
    rack.window.makeFirstResponder(rack.table)
    try liveCheck(command(rack.window, code: 0, character: "a") && rack.table.selectedRowIndexes == IndexSet(integersIn: 0..<3),
                  "Command-A selects every effect in the focused FX window")
    func click(_ row: Int, shift: Bool) {
        rack.table.layoutSubtreeIfNeeded()
        let rect = rack.table.rect(ofRow: row)
        let point = rack.table.convert(NSPoint(x: 15, y: rect.midY), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: rack.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: rack.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: true); rack.window.sendEvent(down)
        while let event = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { rack.window.sendEvent(event) }
    }
    click(0, shift: false); click(2, shift: true)
    try liveCheck(rack.table.selectedRowIndexes == IndexSet(integersIn: 0..<3), "Shift-click selects a contiguous range of native FX rows")
    rack.table.deselectRow(1)
    let undoCount = editor.undoStack.count
    try liveCheck(command(rack.window, code: 8, character: "c") && editor.undoStack.count == undoCount && !editor.dirty,
                  "Command-C copies selected effects without editing the project")
    let copyPoint = rack.table.convert(NSPoint(x: 10, y: rack.table.rect(ofRow: 0).midY), to: nil)
    let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: copyPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: rack.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    let copyMenu = rack.contextMenu(for: rightClick), copyItem = copyMenu.item(withTitle: "Copy")!
    try liveCheck(rack.table.selectedRowIndexes == IndexSet([0, 2]) && copyItem.isEnabled && NSApp.sendAction(copyItem.action!, to: copyItem.target, from: copyItem),
                  "Context-menu Copy preserves the multi-selection when right-clicking a selected row")
    let payload = try JSONDecoder().decode([PluginEffect].self, from: board.data(forType: EffectsWindow.clipboardType)!)
    try liveCheck(payload.map(\.name) == ["Effect 0", "Effect 2"] && payload[1].bypassed,
                  "Clipboard preserves selected chain order and individual bypass flags")
    try liveCheck(command(rack.window, code: 9, character: "v") && rack.effects.count == 5 && rack.table.selectedRowIndexes == IndexSet(integersIn: 3..<5),
                  "Command-V appends copies and selects them at the end of the same chain")
    try liveCheck(editor.undoStack.count == undoCount + 1 && Set(rack.effects.map(\.id)).count == 5,
                  "A multi-effect paste creates fresh identities and one Undo action")
    for (offset, expected) in [values[0], values[2]].enumerated() {
        let effect = rack.effects[3 + offset]
        let copied = try editor.pluginHost(effect)
        try liveCheck(abs(copied.parameterValue(parameter) - expected) < 0.001 && copied !== editor.pluginHosts[source[offset == 0 ? 0 : 2].id],
                      "Pasted effect has the current live settings and an independent processor")
    }
    editor.undo()
    try liveCheck(rack.effects.count == 3 && abs(try editor.pluginHost(rack.effects[0]).parameterValue(parameter) - values[0]) < 0.001,
                  "Undo removes the entire batch and preserves original live settings")
    editor.redo(); try liveCheck(rack.effects.count == 5, "Redo restores the complete FX batch")
    rack.done()
    let location = master.table.convert(NSPoint(x: 10, y: master.table.bounds.maxY - 1), to: nil)
    let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: master.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    let menu = master.contextMenu(for: event), paste = menu.item(withTitle: "Paste")!
    try liveCheck(paste.isEnabled && NSApp.sendAction(paste.action!, to: paste.target, from: paste) && master.effects.count == 3,
                  "Context-menu Paste appends to another FX window after the source window closes")
    try liveCheck(editor.project.masterEffectsBypassed && master.effects.suffix(2).map(\.name) == ["Effect 0", "Effect 2"],
                  "Cross-window paste preserves destination bulk bypass and copied order")
    let count = master.effects.count, history = editor.undoStack.count
    var broken = payload; broken[1].path = root.appendingPathComponent("Missing.vst3").path
    board.clearContents(); board.setData(try JSONEncoder().encode(broken), forType: EffectsWindow.clipboardType)
    try liveCheck(!master.pasteSelection() && master.effects.count == count && editor.undoStack.count == history,
                  "A missing plug-in fails atomically without inserting a partial batch")
    board.clearContents(); board.setString("Unrelated text", forType: .string)
    try liveCheck(!master.canPasteEffects && !master.pasteSelection(), "FX Paste ignores unrelated clipboard formats")
}
