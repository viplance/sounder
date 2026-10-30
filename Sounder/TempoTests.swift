import AppKit
import AVFoundation

func runTempoTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("SounderTempo-" + UUID().uuidString)
    defer { try? fm.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    for rate in [44_100.0, 48_000.0] {
        let format = ProjectAudioFormat(sampleRate: rate)
        store.configure(format)
        let url = store.freshURL()
        try store.write(AudioSignal(channels: Array(repeating: [Float](repeating: 0, count: Int(rate * 3)), count: 2)), to: url)
        var project = Project(tracks: [Track(name: "Silent recording", clips: [Clip(name: "Silence", source: url.path, start: 0, duration: 3, order: 1)])], audioFormat: format)
        project.metronomeEnabled = true; project.tempoMode = true; project.tempo = 120
        func playback(start: Double) throws -> LivePlayback {
            let graph = try StreamingGraph(project: project, store: store) { _ in fatalError("No effects") }
            let session = LivePlayback(graph: graph, format: format, start: start)
            try session.engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!, maximumFrameCount: 512)
            session.setMetronome(tempo: project.tempo, enabled: true); try session.startPlayback()
            return session
        }
        func render(_ session: LivePlayback, seconds: Double) throws -> [Float] {
            let buffer = AVAudioPCMBuffer(pcmFormat: session.engine.manualRenderingFormat, frameCapacity: 512)!
            var samples = [Float]()
            for _ in 0..<Int(ceil(seconds * rate / 512)) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.001)); session.queue.sync {}
                guard try session.engine.renderOffline(512, to: buffer) == .success else { throw SounderError.message("Metronome audio render failed") }
                for i in 0..<Int(buffer.frameLength) {
                    guard buffer.floatChannelData![0][i] == buffer.floatChannelData![1][i] else { throw SounderError.message("Metronome is missing from one output channel") }
                    samples.append(buffer.floatChannelData![0][i])
                }
            }
            return samples
        }
        func energy(_ samples: [Float], at time: Double, length: Double = 0.03) -> Double {
            let first = max(0, Int((time * rate).rounded())), last = min(samples.count, Int(((time + length) * rate).rounded()))
            guard last > first else { return 0 }
            return samples[first..<last].reduce(0) { $0 + Double($1 * $1) } / Double(last - first)
        }
        let session = try playback(start: 0)
        let output = try render(session, seconds: 2.1)
        let beats = (0..<5).map { energy(output, at: Double($0) * 0.5) }
        try check(beats.allSatisfy { $0 > 0.001 } && energy(output, at: 0.1, length: 0.3) == 0, "Real \(Int(rate)) Hz playback produces four evenly spaced beats per bar with silence between clicks")
        try check(beats[0] > beats[1] * 2 && abs(beats[0] - beats[4]) < 0.00001, "Every fourth beat receives the same stronger first-beat accent")
        session.setMetronome(tempo: 120, enabled: false)
        let disabled = try render(session, seconds: 0.6)
        try check(disabled.suffix(Int(rate * 0.3)).allSatisfy { $0 == 0 }, "Disabling the metronome silences subsequent beats without restarting playback")
        session.stop()
        let sought = try playback(start: 0.25)
        let afterSeek = try render(sought, seconds: 0.4)
        try check(energy(afterSeek, at: 0, length: 0.2) == 0 && energy(afterSeek, at: 0.25) > 0.001, "Seeking halfway through a beat keeps the click aligned to the absolute timeline grid")
        sought.stop()
        let path = directory.appendingPathComponent("NoClick-\(Int(rate)).wav")
        var settings = ExportSettings(projectFormat: format); settings.format = .wav
        try AudioExporter.write(project: project, store: store, settings: settings, to: path)
        try check(try AudioStore.decode(path, sampleRate: rate).channels.allSatisfy { $0.allSatisfy { $0 == 0 } }, "Enabled metronome is excluded from exported audio")
    }
    let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let outputVoice = MetronomeVoice(sampleRate: 48_000)
    outputVoice.configure(bpm: 120, enabled: true, start: 0)
    let outputEngine = AVAudioEngine(), sourceNode = outputVoice.source(format: input)
    outputEngine.attach(sourceNode); outputEngine.connect(sourceNode, to: outputEngine.mainMixerNode, format: input)
    try outputEngine.enableManualRenderingMode(.offline, format: input, maximumFrameCount: 512)
    try outputEngine.start()
    let audible = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 512)!
    let status = try outputEngine.renderOffline(512, to: audible)
    try check(status == .success && (0..<512).contains { abs(audible.floatChannelData![0][$0]) > 0.1 }, "Recording monitor source reaches the actual audio engine output mixer")
    outputEngine.stop()
    let recorder = try LiveRecorder(url: store.freshURL(), format: ProjectAudioFormat(), inputFormat: input)
    recorder.metronome.configure(bpm: 120, enabled: true, start: 0)
    let monitor = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 512)!; monitor.frameLength = 512
    recorder.metronome.render(frames: 512, buffers: monitor.mutableAudioBufferList)
    try check((0..<512).contains { abs(monitor.floatChannelData![0][$0]) > 0.1 }, "Recording output monitor renders the audible metronome click")
    let silence = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4096)!; silence.frameLength = 4096
    for channel in 0..<2 { for frame in 0..<4096 { silence.floatChannelData![channel][frame] = 0 } }
    try recorder.start(); recorder.writer.append(silence)
    if let failure = recorder.stop() { throw failure }
    try check(try AudioStore.decode(recorder.url, sampleRate: 48_000).channels.allSatisfy { $0.allSatisfy { $0 == 0 } }, "Recording capture stays separate from the metronome output")
    let ticks = TempoGrid.ticks(from: 0, to: 4, zoom: 140, bpm: 120)
    try check(ticks.prefix(5).map(\.time) == [0, 0.5, 1, 1.5, 2] && ticks.prefix(5).map(\.label) == ["1.1", "1.2", "1.3", "1.4", "2.1"], "Tempo ruler shows 4/4 bars and beats on the same time grid as the audio")
    let editor = Editor(store: store)
    editor.toggleTempoMode(); editor.setTempo(93.5); editor.toggleMetronome()
    editor.projectURL = directory.appendingPathComponent("Tempo.sounder")
    try check(editor.save(), "Tempo project saves successfully")
    let saved = try JSONDecoder().decode(Project.self, from: Data(contentsOf: editor.projectURL!.appendingPathComponent("project.json")))
    try check(saved.tempoMode && saved.metronomeEnabled && saved.tempo == 93.5, "Project Save preserves BPM, tempo ruler mode and metronome choice")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
    for key in ["tempo", "tempoMode", "metronomeEnabled"] { legacy.removeValue(forKey: key) }
    let loaded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacy))
    try check(loaded.tempo == 120 && !loaded.tempoMode && !loaded.metronomeEnabled, "Older projects retain the time ruler and silent metronome by default")
}

extension AppDelegate {
    func verifyTempoUI() throws {
        tempoButton.performClick(nil)
        guard editor.project.tempoMode && timeLabel.isHidden && !bpmButton.isHidden else { throw SounderError.message("Tempo button did not replace the timer with BPM") }
        let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
            func field(_ view: NSView) -> NSTextField? {
                if let text = view as? NSTextField, text.isEditable { return text }
                return view.subviews.lazy.compactMap { field($0) }.first
            }
            if let root = NSApp.modalWindow?.contentView { field(root)?.stringValue = "90" }
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        bpmButton.performClick(nil)
        guard editor.project.tempo == 90 && bpmButton.title == "90 BPM" else { throw SounderError.message("BPM could not be edited") }
        metronomeButton.performClick(nil)
        guard editor.project.metronomeEnabled && metronomeButton.state == .on else { throw SounderError.message("Metronome checkbox did not change its setting") }
        window.setContentSize(NSSize(width: 1000, height: 700)); refresh(); window.contentView?.layoutSubtreeIfNeeded()
        for control in [tempoButton!, metronomeButton!, bpmButton!] {
            let rect = control.convert(control.bounds, to: window.contentView)
            guard rect.minX >= 0 && rect.maxX <= window.contentView!.bounds.maxX else { throw SounderError.message("Tempo controls do not fit the minimum window width") }
        }
        editor.dirty = false
        RunLoop.current.run(until: Date().addingTimeInterval(5.1))
        print("PASS: Tempo switches to editable BPM and a 4/4 ruler, Metronome toggles, and controls fit a 1000-point window")
    }
}
