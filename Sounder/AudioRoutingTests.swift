import AppKit
import AVFoundation
import AudioToolbox

func runAudioRoutingTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderRouting-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let editor = Editor(store: store)
    let route = AudioEndpoint(deviceUID: "test-interface", channels: [2, 3])
    editor.setAudioInput(route)
    editor.setAudioInput(AudioEndpoint(deviceUID: "test-mic", channels: [0]), trackID: editor.project.tracks[0].id)
    editor.setAudioOutput(route)
    let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(editor.project))
    try check(restored.defaultInput == route && restored.defaultOutput == route && restored.tracks[0].input?.channels == [0], "Project persists device UIDs and individual capture/output channels")
    editor.undo(); try check(editor.project.defaultOutput == AudioEndpoint(), "Routing changes have one Undo step")
    editor.setAudioInput(nil, trackID: editor.project.tracks[0].id)
    try check(editor.project.tracks[0].input == nil && editor.project.defaultInput == route, "Track input can inherit the project default")
    let device = AudioHardwareDevice(id: 123, uid: "test-interface", name: "Interface", inputs: 4, outputs: 6)
    try check(try AudioDevices.resolve(route, direction: .input, devices: [device]) == device, "Physical channel selection resolves by stable device UID")
    for invalid in [AudioEndpoint(deviceUID: "missing"), AudioEndpoint(deviceUID: device.uid, channels: [4]), AudioEndpoint(deviceUID: device.uid, channels: [0, 0])] {
        var rejected = false
        do { _ = try AudioDevices.resolve(invalid, direction: .input, devices: [device]) } catch { rejected = true }
        try check(rejected, "Unavailable devices and invalid channels fail without silently recording another source")
    }
    try check(AudioDevices.outputMap(channels: [2, 3], hardwareChannels: 6) == [-1, -1, 0, 1, -1, -1], "Output mapping silences unselected physical outputs")
    let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!)
    let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    for channel in 0..<4 {
        for frame in 0..<48_000 { buffer.floatChannelData![channel][frame] = Float(channel + 1) * 0.1 * Float(sin(Double(frame) * 2 * .pi * 330 / 48_000)) }
    }
    for selection in [[2, 3], [3]] {
        for rate in [48_000.0, 44_100.0] {
            for depth in [16, 24, 32] {
                for loop in [false, true] {
                    let url = store.freshURL(), format = ProjectAudioFormat(sampleRate: rate, channels: 2, bitDepth: depth)
                    let session = try LiveRecorder(url: url, format: format, inputFormat: input, input: AudioEndpoint(channels: selection))
                    if loop { try session.configureLoop(0..<1, start: 0) }
                    try session.start(); session.writer.append(buffer); session.writer.waitForPendingWrites()
                    let preview = session.writer.consumeUpdate()
                    try check(session.format.channels == selection.count && preview.channelPeaks.count == selection.count, "Capture and live waveform preserve the selected mono/stereo input")
                    if loop { try check(!FileManager.default.fileExists(atPath: url.path), "Mono/stereo loop capture remains in RAM until Stop") }
                    if let failure = session.stop() { throw failure }
                    store.configure(format)
                    let signal = try store.load(url.path), file = try AVAudioFile(forReading: url)
                    try check(abs(signal.frameCount - Int(rate)) <= 1 && signal.channels.count == selection.count && Int(file.fileFormat.channelCount) == selection.count && file.fileFormat.streamDescription.pointee.mBitsPerChannel == depth,
                              "\(loop ? "Loop" : "Ordinary") capture saves true \(selection.count)-channel \(depth)-bit PCM at \(rate) Hz")
                    for channel in signal.channels.indices {
                        let physical = selection[channel]
                        let rms = sqrt(signal.channels[channel].dropFirst(512).dropLast(512).reduce(0.0) { $0 + Double($1 * $1) } / Double(signal.frameCount - 1024))
                        try check(abs(rms - Double(physical + 1) * 0.1 / sqrt(2)) < 0.001, "Capture routes physical input \(physical + 1) to file channel \(channel + 1) without adjacent input leakage")
                    }
                }
            }
        }
    }
    // Verify the real HAL property after selecting an available device, without
    // changing macOS defaults or requiring microphone permission.
    let devices = AudioDevices.available()
    if let device = devices.first(where: { $0.id == AudioDevices.defaultDevice(.output) && $0.outputs >= 2 }) {
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        try AudioDevices.configureOutput(AudioEndpoint(deviceUID: device.uid, channels: [0, 1]), engine: engine, projectChannels: 2)
        var id: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        try check(status == noErr && id == device.id, "Playback engine selects the requested physical output device")
        var map = [Int32](repeating: -2, count: device.outputs); size = UInt32(map.count * MemoryLayout<Int32>.size)
        let mapped = map.withUnsafeMutableBytes { AudioUnitGetProperty(engine.outputNode.audioUnit!, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 0, $0.baseAddress!, &size) }
        try check(mapped == noErr && map == AudioDevices.outputMap(channels: [0, 1], hardwareChannels: device.outputs), "HAL output channel map matches the selected stereo pair")
        engine.prepare(); try engine.start()
        try check(engine.isRunning, "Playback engine starts with explicit device/channel routing")
        engine.stop()
    } else { print("SKIP: no available stereo output for native routing smoke test") }
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
       let inputDevice = devices.first(where: { $0.id == AudioDevices.defaultDevice(.input) && $0.inputs > 0 }),
       let outputDevice = devices.first(where: { $0.id == AudioDevices.defaultDevice(.output) && $0.outputs > 0 }) {
        let playbackEngine = AVAudioEngine(), node = AVAudioPlayerNode()
        playbackEngine.attach(node); playbackEngine.connect(node, to: playbackEngine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        try AudioDevices.configureOutput(AudioEndpoint(deviceUID: outputDevice.uid), engine: playbackEngine, projectChannels: 2)
        playbackEngine.prepare(); try playbackEngine.start()
        defer { playbackEngine.stop() }
        let recorder = try LiveRecorder(url: store.freshURL(), format: ProjectAudioFormat(), input: AudioEndpoint(deviceUID: inputDevice.uid, channels: [0]))
        try recorder.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if let failure = recorder.stop() { throw failure }
        let file = try AVAudioFile(forReading: recorder.url)
        try check(file.length > 0 && file.fileFormat.channelCount == 1, "Native mono capture saves one channel with independent input/output devices")
    } else { print("SKIP: native routed capture requires existing microphone permission and input/output hardware") }
}

extension AppDelegate {
    func verifyAudioRoutingUI() throws {
        try runAudioRoutingTests()
        let original = editor.project
        defer { if let panel = audioRoutingWindow { _ = panel.windowShouldClose(panel.window) }; editor.project = original; refresh() }
        showAudioRouting()
        guard let panel = audioRoutingWindow, panel.window.isVisible,
              panel.trackInputs.count == editor.project.tracks.count,
              panel.input.selectedEndpoint == AudioEndpoint(), panel.output.selectedEndpoint == AudioEndpoint() else { throw SounderError.message("Routing window did not show project and track inputs") }
        let fixture = AudioHardwareDevice(id: 123, uid: "test-interface", name: "Four channel interface", inputs: 4, outputs: 6)
        let picker = AudioRoutePicker(label: "Test input")
        let route = AudioEndpoint(deviceUID: fixture.uid, channels: [2, 3])
        picker.configure(devices: [fixture], direction: .input, selected: route, inherit: true)
        guard picker.selectedEndpoint == route, picker.choices.contains(where: { $0.endpoint?.channels == [3] }), picker.choices.first?.endpoint == nil else { throw SounderError.message("Shared route picker lost a mono, stereo or inherited selection") }
        editor.setAudioInput(route, trackID: editor.project.tracks[0].id); panel.refresh()
        guard panel.trackInputs[editor.project.tracks[0].id]?.selectedEndpoint == route else { throw SounderError.message("Disconnected input selection was lost") }
        editor.requestingMic = true; panel.refresh()
        guard !panel.input.isEnabled, !panel.output.isEnabled, panel.trackInputs.values.allSatisfy({ !$0.isEnabled }) else { throw SounderError.message("Routing controls are editable during capture setup") }
        editor.requestingMic = false; panel.refresh()
        guard panel.input.isEnabled else { throw SounderError.message("Routing did not re-enable after transport") }
        print("PASS: In/Out window reuses device/channel pickers, preserves unavailable selections and guards live transport")
        if let bitmap = panel.window.contentView?.bitmapImageRepForCachingDisplay(in: panel.window.contentView!.bounds) {
            panel.window.contentView!.cacheDisplay(in: panel.window.contentView!.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/sounder-routing-popup.png"))
        }
    }
}
