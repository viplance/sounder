import AppKit
import AVFoundation

func runTempoTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    try check([0.0, 0.499, 0.5, 1.999, 2.0, 4.5].map { TempoGrid.positionLabel(time: $0, bpm: 120) } == ["1.1", "1.1", "1.2", "1.4", "2.1", "3.2"], "Transport bar/beat display follows beat boundaries and bar rollover")
    try check(TempoGrid.positionLabel(time: 4, bpm: 90) == "2.3" && TempoGrid.positionLabel(time: 60, bpm: 93.5) == "24.2", "Bar/beat display follows the current BPM including fractional tempos")
    var tap = TapTempo()
    try check(tap.tap(at: 0) == nil && tap.tap(at: 0.5) == 120 && tap.tap(at: 1) == 120, "Tap tempo derives BPM from successive monotonic click intervals")
    try check(tap.tap(at: 1.03) == nil && tap.tap(at: 1.5) == 120, "Tap tempo ignores accidental double clicks without disturbing the beat")
    try check(tap.tap(at: 10) == nil && tap.tap(at: 10.75) == 80, "A long pause resets tapping so a new tempo is measured immediately")
    for index in 2...12 { _ = tap.tap(at: 10 + Double(index) * 0.5) }
    try check(tap.tap(at: 16.5) == 120, "A rolling tap window adapts to a new tempo instead of averaging the whole session")
    var fast = TapTempo(); _ = fast.tap(at: 0)
    var slow = TapTempo(); _ = slow.tap(at: 0)
    try check(fast.tap(at: 0.15) == 300 && slow.tap(at: 3) == 20, "Tap tempo respects the project's 20–300 BPM limits")
    try check(TempoGrid.snappedMove(delta: 1.2, earliestStart: 0.5, bpm: 120) == 1 && TempoGrid.snappedMove(delta: -4, earliestStart: 0.5, bpm: 120) == -0.5, "Tempo moves use whole-beat deltas without taking the group before zero")
    try check(abs(TempoGrid.snappedMove(delta: 0.8, earliestStart: 0, bpm: 90) - 60 / 90) < 1e-9, "Movement beat snapping follows the current BPM")
    try check(TempoGrid.snappedEdge(time: 5.1, bounds: 0.51...7.9, bpm: 120) == 5 && TempoGrid.snappedEdge(time: 7.9, bounds: 0.51...7.9, bpm: 120) == 7.5 && TempoGrid.snappedEdge(time: 1, bounds: 0.1...0.49, bpm: 120) == nil, "Resize snapping uses only beat boundaries allowed by source and minimum-length bounds")
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
    let saved = try JSONDecoder().decode(Project.self, from: Data(contentsOf: editor.projectURL!))
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
        metronomeButton.performClick(nil)
        var modalFailure: String?
        let timer = Timer(timeInterval: 0.1, repeats: false) { [self] _ in
            func hasOrange(_ button: NSButton) -> Bool {
                guard let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return false }
                button.cacheDisplay(in: button.bounds, to: bitmap)
                for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5,
                       color.redComponent > 0.8, color.greenComponent > 0.25, color.greenComponent < 0.8, color.blueComponent < 0.35 { return true }
                } }
                return false
            }
            if let modal = NSApp.modalWindow {
                if abs(modal.contentView!.bounds.width - 340 / 1.5) > 1 { modalFailure = "Tempo dialog did not shrink to two thirds of its former width" }
                if window.isKeyWindow || !hasOrange(tempoButton) || !hasOrange(metronomeButton) { modalFailure = "Active Tempo/Metronome must remain orange while the dialog is key" }
            } else { modalFailure = "Tempo modal window was not shown" }
            func field(_ view: NSView) -> NSTextField? {
                if let text = view as? NSTextField, text.isEditable { return text }
                return view.subviews.lazy.compactMap { field($0) }.first
            }
            if let root = NSApp.modalWindow?.contentView { field(root)?.stringValue = "90" }
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        bpmButton.performClick(nil)
        if let modalFailure { throw SounderError.message(modalFailure) }
        print("PASS: Tempo popup is two thirds of its former width and active controls remain orange behind the modal window")
        guard editor.project.tempo == 90 && bpmButton.title == "90 BPM" else { throw SounderError.message("BPM could not be edited") }
        if !editor.project.metronomeEnabled { metronomeButton.performClick(nil) }
        guard editor.project.metronomeEnabled && metronomeButton.state == .on else { throw SounderError.message("Metronome checkbox did not change its setting") }
        window.setContentSize(NSSize(width: 1000, height: 700)); refresh(); window.contentView?.layoutSubtreeIfNeeded()
        for control in [tempoButton!, metronomeButton!, bpmButton!] {
            let rect = control.convert(control.bounds, to: window.contentView)
            guard rect.minX >= 0 && rect.maxX <= window.contentView!.bounds.maxX else { throw SounderError.message("Tempo controls do not fit the minimum window width") }
        }
        editor.seek(to: 2); editor.playPause()
        guard editor.isPlaying, bpmButton.title == "1.4" else { throw SounderError.message("Playback did not replace BPM with the current bar and beat") }
        editor.seek(to: 4)
        guard bpmButton.title == "2.3" else { throw SounderError.message("Bar/beat display did not follow live seeking") }
        editor.stop(); refresh()
        guard bpmButton.title == "90 BPM" else { throw SounderError.message("Stopped playback did not restore BPM") }
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let recorder = try LiveRecorder(url: editor.audio.freshURL(), format: editor.project.audioFormat, inputFormat: input)
        try recorder.start(); editor.cursor = 2.6; editor.activateRecording(recorder)
        guard editor.isRecording, bpmButton.title == "1.4" else { throw SounderError.message("Recording did not replace BPM with the current bar and beat") }
        recorder.writer.append(captureTestBuffer(format: input, start: 0, frames: 24_000))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2)); editor.updateTransportPosition()
        guard bpmButton.title == "2.1" else { throw SounderError.message("Recording bar/beat display did not advance with captured audio") }
        editor.stop(); refresh()
        guard bpmButton.title == "90 BPM" else { throw SounderError.message("Stopped recording did not restore BPM") }
        print("PASS: Playback and recording show current bar.beat, follow live seeking/capture, and restore BPM on stop")
        editor.dirty = false
        RunLoop.current.run(until: Date().addingTimeInterval(5.1))
        print("PASS: Tempo switches to editable BPM and a 4/4 ruler, Metronome toggles, and controls fit a 1000-point window")
    }
}

extension AppDelegate {
    func verifyTapTempoUI() throws {
        var clock = 0.0
        let dialog = TempoDialog(bpm: 93, now: { clock })
        var failure: String?
        let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
            dialog.tapButton.performClick(nil)
            if dialog.field.stringValue != "93" { failure = "First tap should leave BPM unchanged" }
            clock = 0.5; dialog.tapButton.performClick(nil)
            if dialog.field.stringValue != "120" { failure = "Second tap should immediately show 120 BPM" }
            clock = 1.25; dialog.tapButton.performClick(nil)
            if dialog.field.stringValue != "96" { failure = "Every following tap should update the BPM field" }
            dialog.alert.buttons[0].performClick(nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        let result = dialog.runModal()
        if let failure { throw SounderError.message(failure) }
        guard result == 96 else { throw SounderError.message("Save did not return the tapped BPM") }
        let cancelled = TempoDialog(bpm: editor.project.tempo, now: { clock })
        let original = editor.project.tempo
        let cancel = Timer(timeInterval: 0.1, repeats: false) { _ in
            cancelled.tapButton.performClick(nil); clock += 0.5; cancelled.tapButton.performClick(nil)
            cancelled.alert.buttons[1].performClick(nil)
        }
        RunLoop.main.add(cancel, forMode: .common)
        guard cancelled.runModal() == nil, editor.project.tempo == original else { throw SounderError.message("Cancel changed the project tempo") }
        print("PASS: Tap updates the BPM field in real time, Save accepts it, and Cancel retains the project tempo")
    }
}
