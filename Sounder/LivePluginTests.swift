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
