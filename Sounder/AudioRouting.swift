import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio

/// Device UIDs survive reconnects; transient AudioDeviceIDs never enter projects.
struct AudioEndpoint: Codable, Equatable {
    var deviceUID: String? = nil
    var channels: [Int]? = nil
    func validate() throws {
        if let channels {
            guard (1...2).contains(channels.count), channels.allSatisfy({ (0..<4096).contains($0) }), Set(channels).count == channels.count else {
                throw SounderError.message("Invalid audio channel selection")
            }
        }
    }
}

enum AudioDirection { case input, output
    var scope: AudioObjectPropertyScope { self == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput }
    var title: String { self == .input ? "In" : "Out" }
}
struct AudioHardwareDevice: Equatable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var inputs: Int
    var outputs: Int
    func channelCount(_ direction: AudioDirection) -> Int { direction == .input ? inputs : outputs }
}

enum AudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector), value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    private static func integer(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var property = address(selector, scope: scope), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr ? value : nil
    }
    private static func channels(_ device: AudioDeviceID, _ direction: AudioDirection) -> Int {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: direction.scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, data) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func available() -> [AudioHardwareDevice] {
        var property = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            guard integer(id, kAudioDevicePropertyDeviceIsAlive) != 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            // A device exclusively owned by another process cannot be used by Sounder.
            let hog = integer(id, kAudioDevicePropertyHogMode).map { Int32(bitPattern: $0) } ?? -1
            guard hog == -1 || hog == getpid() else { return nil }
            let device = AudioHardwareDevice(id: id, uid: uid, name: name, inputs: channels(id, .input), outputs: channels(id, .output))
            return device.inputs + device.outputs > 0 ? device : nil
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func defaultDevice(_ direction: AudioDirection) -> AudioDeviceID? {
        integer(AudioObjectID(kAudioObjectSystemObject), direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
    }
    static func resolve(_ endpoint: AudioEndpoint, direction: AudioDirection, devices: [AudioHardwareDevice]? = nil) throws -> AudioHardwareDevice {
        try endpoint.validate()
        let devices = devices ?? available()
        let device = endpoint.deviceUID.flatMap { uid in devices.first { $0.uid == uid } } ?? (endpoint.deviceUID == nil ? devices.first { $0.id == defaultDevice(direction) } : nil)
        guard let device, device.channelCount(direction) > 0 else {
            throw SounderError.message("The selected audio \(direction == .input ? "input" : "output") is unavailable. Choose an available device in In | Out.")
        }
        if let selected = endpoint.channels, selected.contains(where: { $0 >= device.channelCount(direction) }) {
            throw SounderError.message("The selected audio channels are unavailable on \(device.name). Choose channels in In | Out.")
        }
        return device
    }
    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SounderError.message("\(operation) failed (audio error \(status)).") }
    }
    /// HAL input timestamps already account for IO buffering and the safety
    /// offset. Only the device/selected-stream hardware delay remains to remove.
    static func inputPresentationLatency(device: AudioDeviceID, channels: [Int]?, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        let deviceFrames = integer(device, kAudioDevicePropertyLatency, scope: kAudioDevicePropertyScopeInput) ?? 0
        var property = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0 else { return Double(deviceFrames) / sampleRate }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        let status = streams.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0.baseAddress!) }
        var streamFrames: UInt32 = 0
        if status == noErr {
            for stream in streams {
                if let channels, let first = integer(stream, kAudioStreamPropertyStartingChannel) {
                    var format = AudioStreamBasicDescription(), formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                    var formatProperty = address(kAudioStreamPropertyVirtualFormat)
                    if AudioObjectGetPropertyData(stream, &formatProperty, 0, nil, &formatSize, &format) == noErr,
                       !channels.contains(where: { $0 >= Int(first) - 1 && $0 < Int(first) - 1 + Int(format.mChannelsPerFrame) }) { continue }
                }
                streamFrames = max(streamFrames, integer(stream, kAudioStreamPropertyLatency) ?? 0)
            }
        }
        return (Double(deviceFrames) + Double(streamFrames)) / sampleRate
    }
    static func outputMap(channels: [Int], hardwareChannels: Int) -> [Int32] {
        var map = [Int32](repeating: -1, count: hardwareChannels)
        for (source, destination) in channels.enumerated() where map.indices.contains(destination) { map[destination] = Int32(source) }
        return map
    }
    static func configureOutput(_ endpoint: AudioEndpoint, engine: AVAudioEngine, projectChannels: Int) throws {
        guard !engine.isInManualRenderingMode, endpoint != AudioEndpoint() else { return }
        let device = try resolve(endpoint, direction: .output)
        let node = engine.outputNode
        guard let unit = node.audioUnit else { throw SounderError.message("Audio output is unavailable") }
        if endpoint.deviceUID != nil {
            var id = device.id
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)), "Selecting \(device.name)")
        }
        // Automatic uses the first stereo pair even for a mono project; the
        // mixer duplicates mono to both speakers. An explicit mono output
        // intentionally routes to just that physical channel.
        let selected = endpoint.channels ?? Array(0..<min(2, device.outputs))
        let hardware = node.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0,
              let client = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: AVAudioChannelCount(selected.count)) else { throw SounderError.message("The selected output has no usable audio format") }
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(engine.mainMixerNode, to: node, format: client)
        let map = outputMap(channels: selected, hardwareChannels: device.outputs)
        try map.withUnsafeBytes { bytes in
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 0, bytes.baseAddress!, UInt32(bytes.count)), "Selecting output channels")
        }
    }
}

/// Input-only HAL unit: capture must never share a device selector with the
/// playback output. In particular a microphone and headphones may be separate
/// Core Audio devices with no common duplex device.
final class HardwareAudioCapture {
    private var unit: AudioUnit?
    private(set) var format: AVAudioFormat!
    private var buffer: AVAudioPCMBuffer!
    private(set) var presentationLatency = 0.0
    var received: ((AVAudioPCMBuffer, UInt64?) -> Void)?
    var failed: ((OSStatus) -> Void)?
    private var running = false
    init(input: AudioEndpoint) throws {
        do { try configure(input) } catch { dispose(); throw error }
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SounderError.message("\(operation) failed (audio error \(status)).") }
    }
    private func configure(_ endpoint: AudioEndpoint) throws {
        let device = try AudioDevices.resolve(endpoint, direction: .input)
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw SounderError.message("Core Audio capture is unavailable") }
        try check(AudioComponentInstanceNew(component, &unit), "Creating audio input")
        guard let unit else { throw SounderError.message("Cannot create audio input") }
        var enabled: UInt32 = 1, disabled: UInt32 = 0, id = device.id
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, 4), "Enabling audio input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, 4), "Disabling capture output")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)), "Selecting " + device.name)
        var hardware = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "Reading input format")
        guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else { throw SounderError.message("The selected input has no usable audio format") }
        if hardware.mChannelsPerFrame > 2 {
            guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | hardware.mChannelsPerFrame) else { throw SounderError.message("Unsupported input channel layout") }
            format = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate, channelLayout: layout)
        } else { format = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame) }
        guard let format else { throw SounderError.message("Unsupported input format") }
        presentationLatency = AudioDevices.inputPresentationLatency(device: device.id, channels: endpoint.channels ?? Array(0..<min(2, Int(format.channelCount))), sampleRate: format.sampleRate)
        var client = format.streamDescription.pointee
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Configuring input PCM")
        var maximum: UInt32 = 4096
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, 4), "Configuring capture buffers")
        var callback = AURenderCallbackStruct(inputProc: { context, flags, timestamp, _, frames, _ in
            let capture = Unmanaged<HardwareAudioCapture>.fromOpaque(context).takeUnretainedValue()
            return capture.render(flags: flags, timestamp: timestamp, frames: frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Installing capture callback")
        try check(AudioUnitInitialize(unit), "Preparing audio capture")
        size = 4
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, &size), "Reading capture buffer size")
        guard maximum > 0, maximum <= 1_048_576, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximum) else { throw SounderError.message("Unsupported audio input buffer size") }
        self.buffer = buffer
    }
    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let unit, let buffer, frames <= buffer.frameCapacity else { failed?(kAudioUnitErr_TooManyFramesToProcess); return kAudioUnitErr_TooManyFramesToProcess }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timestamp, 1, frames, buffer.mutableAudioBufferList)
        if status == noErr {
            let host = timestamp.pointee.mFlags.contains(.hostTimeValid) ? timestamp.pointee.mHostTime : nil
            received?(buffer, host)
        } else { failed?(status) }
        return status
    }
    func start() throws { guard !running, let unit else { return }; try check(AudioOutputUnitStart(unit), "Starting audio input"); running = true }
    func stop() { if running, let unit { AudioOutputUnitStop(unit); running = false } }
    private func dispose() { stop(); if let unit { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit); self.unit = nil } }
    deinit { dispose() }
}

/// Device/default changes are rare; no polling or audio work runs on the UI thread.
final class AudioDeviceMonitor {
    private let listener: AudioObjectPropertyListenerBlock
    private var properties: [AudioObjectPropertyAddress]
    init(changed: @escaping () -> Void) {
        listener = { _, _ in changed() }
        properties = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map {
            AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
        for index in properties.indices { AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &properties[index], .main, listener) }
    }
    deinit { for index in properties.indices { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &properties[index], .main, listener) } }
}

/// The same device/channel picker is used for Default In, Out and every track.
final class AudioRoutePicker: NSPopUpButton {
    struct Choice { var title: String; var endpoint: AudioEndpoint? }
    private(set) var choices: [Choice] = []
    var onChange: ((AudioEndpoint?) -> Void)?
    var selectedEndpoint: AudioEndpoint? {
        guard let item = selectedItem, choices.indices.contains(item.tag) else { return nil }
        return choices[item.tag].endpoint
    }
    init(label: String) {
        super.init(frame: .zero, pullsDown: false)
        target = self; action = #selector(changed); setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(devices: [AudioHardwareDevice], direction: AudioDirection, selected: AudioEndpoint?, inherit: Bool) {
        removeAllItems(); choices = []; menu?.autoenablesItems = false
        func append(_ title: String, _ endpoint: AudioEndpoint?, enabled: Bool = true) {
            choices.append(Choice(title: title, endpoint: endpoint))
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.tag = choices.count - 1; item.isEnabled = enabled
            menu?.addItem(item)
            if endpoint == selected { select(item) }
        }
        if inherit { append("Default input", nil) }
        append("System default", AudioEndpoint())
        for device in devices where device.channelCount(direction) > 0 {
            menu?.addItem(.separator())
            append(device.name + " · Automatic", AudioEndpoint(deviceUID: device.uid))
            let count = device.channelCount(direction)
            for channel in 0..<count { append(device.name + " · \(direction.title) \(channel + 1)", AudioEndpoint(deviceUID: device.uid, channels: [channel])) }
            if count >= 2 {
                for channel in stride(from: 0, to: count - 1, by: 2) {
                    append(device.name + " · \(direction.title) \(channel + 1)–\(channel + 2)", AudioEndpoint(deviceUID: device.uid, channels: [channel, channel + 1]))
                }
            }
        }
        if let selected, !choices.contains(where: { $0.endpoint == selected }) {
            append("Unavailable · " + (selected.deviceUID ?? "channels"), selected, enabled: false)
        }
        if let index = choices.firstIndex(where: { $0.endpoint == selected }), let item = menu?.items.first(where: { $0.tag == index && !$0.isSeparatorItem }) { select(item) }
        toolTip = titleOfSelectedItem
    }
    @objc private func changed() { toolTip = titleOfSelectedItem; onChange?(selectedEndpoint) }
}

private final class RoutingContent: NSView { override var isFlipped: Bool { true } }
final class AudioRoutingWindow: NSObject, NSWindowDelegate {
    unowned let editor: Editor
    let window: NSWindow
    let input = AudioRoutePicker(label: "Default audio input")
    let output = AudioRoutePicker(label: "Default audio output")
    private(set) var trackInputs: [UUID: AudioRoutePicker] = [:]
    private var devices: [AudioHardwareDevice] = []
    private var monitor: AudioDeviceMonitor?
    private let tracksView = RoutingContent()
    private var trackKeys: [String] = []
    var closed: (() -> Void)?
    init(editor: Editor) {
        self.editor = editor
        let height = min(540, 168 + max(1, editor.project.tracks.count) * 44)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "In | Out"; window.isReleasedWhenClosed = false; window.delegate = self
        window.level = .floating; window.hidesOnDeactivate = false
        let root = RoutingContent(); root.wantsLayer = true; root.layer?.backgroundColor = panelColor.cgColor; window.contentView = root
        func caption(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, heading: Bool = false) {
            let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: heading ? 13 : 11, weight: heading ? .semibold : .regular)
            field.textColor = heading ? .labelColor : .secondaryLabelColor; field.frame = NSRect(x: x, y: y, width: width, height: 20); root.addSubview(field)
        }
        caption("Default", x: 20, y: 14, width: 620, heading: true)
        caption("In", x: 20, y: 40, width: 302); caption("Out", x: 338, y: 40, width: 302)
        input.frame = NSRect(x: 20, y: 62, width: 302, height: 26); output.frame = NSRect(x: 338, y: 62, width: 302, height: 26)
        root.addSubview(input); root.addSubview(output)
        caption("Tracks", x: 20, y: 110, width: 220, heading: true); caption("In", x: 244, y: 110, width: 396)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 138, width: 620, height: CGFloat(height) - 154)); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        tracksView.frame = NSRect(x: 0, y: 0, width: 604, height: 44); scroll.documentView = tracksView; root.addSubview(scroll)
        input.onChange = { [weak editor] route in editor?.setAudioInput(route ?? AudioEndpoint()) }
        output.onChange = { [weak editor] route in editor?.setAudioOutput(route ?? AudioEndpoint()) }
        reloadDevices()
        monitor = AudioDeviceMonitor { [weak self] in self?.reloadDevices() }
    }
    func show() { window.center(); window.makeKeyAndOrderFront(nil) }
    private func reloadDevices() { devices = AudioDevices.available(); refresh(force: true) }
    func refresh(force: Bool = false) {
        let rows = TrackHierarchy.orderedRows(editor.project.tracks)
        let keys = rows.map { $0.0.id.uuidString + $0.0.name }
        if keys != trackKeys {
            trackKeys = keys; tracksView.subviews.forEach { $0.removeFromSuperview() }; trackInputs = [:]
            tracksView.setFrameSize(NSSize(width: 604, height: max(44, rows.count * 44)))
            for (index, row) in rows.enumerated() {
                let (track, depth) = row
                let name = NSTextField(labelWithString: String(repeating: "  ", count: depth) + track.name)
                name.font = .systemFont(ofSize: 12); name.lineBreakMode = .byTruncatingTail
                name.frame = NSRect(x: 0, y: CGFloat(index * 44 + 9), width: 208, height: 22); tracksView.addSubview(name)
                let picker = AudioRoutePicker(label: track.name + " input")
                picker.frame = NSRect(x: 224, y: CGFloat(index * 44 + 6), width: 380, height: 26)
                picker.onChange = { [weak editor] route in editor?.setAudioInput(route, trackID: track.id) }
                picker.configure(devices: devices, direction: .input, selected: track.input, inherit: true)
                tracksView.addSubview(picker); trackInputs[track.id] = picker
            }
        }
        if force || input.selectedEndpoint != editor.project.defaultInput { input.configure(devices: devices, direction: .input, selected: editor.project.defaultInput, inherit: false) }
        if force || output.selectedEndpoint != editor.project.defaultOutput { output.configure(devices: devices, direction: .output, selected: editor.project.defaultOutput, inherit: false) }
        input.isEnabled = !editor.busy; output.isEnabled = !editor.busy
        for track in editor.project.tracks {
            guard let picker = trackInputs[track.id] else { continue }
            if force || picker.selectedEndpoint != track.input { picker.configure(devices: devices, direction: .input, selected: track.input, inherit: true) }
            picker.isEnabled = !editor.busy
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { monitor = nil; window.orderOut(nil); closed?(); return false }
}
