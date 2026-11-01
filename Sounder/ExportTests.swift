import AppKit
import AVFoundation

func runExportTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("SounderExportTests-" + UUID().uuidString)
    defer { try? fm.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let samples = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.2 }
    let source = store.freshURL(); try store.write(AudioSignal(channels: [samples, samples.map { $0 * 0.5 }]), to: source)
    let project = Project(tracks: [Track(name: "Export", clips: [Clip(name: "Tone", source: source.path, start: 0, duration: 1, order: 1)])])
    var settings = ExportSettings(projectFormat: project.audioFormat)
    try check(settings.format == .mp3 && settings.sampleRate == 48_000 && settings.bitDepth == 24, "First export defaults to MP3 and the project's rate and bit depth")
    for depth in [16, 24, 32] {
        settings.format = .wav; settings.bitDepth = depth; settings.sampleRate = 96_000
        let path = directory.appendingPathComponent("out.wav")
        try AudioExporter.write(project: project, store: store, settings: settings, to: path)
        let file = try AVAudioFile(forReading: path)
        try check(file.fileFormat.sampleRate == 96_000 && file.fileFormat.channelCount == 2 && file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == depth && abs(file.length - 96_000) < 2, "WAV export writes the selected \(depth)-bit format and 96 kHz with the correct stereo duration")
    }
    var rangeSettings = ExportSettings(projectFormat: project.audioFormat)
    rangeSettings.format = .wav; rangeSettings.bitDepth = 32
    let selectedWAV = directory.appendingPathComponent("selected.wav")
    store.processEffects = { samples, _ in Array(repeating: Float(0), count: 4) + Array(samples.dropLast(4)) }
    let fullWithEffects = try store.renderAudio(project)
    try AudioExporter.write(project: project, store: store, settings: rangeSettings, to: selectedWAV, range: 0.2..<0.45)
    let selectedAudio = try AudioStore.decode(selectedWAV, sampleRate: 48_000)
    try check(selectedAudio.frameCount == 12_000 && selectedAudio.channels == fullWithEffects.channels.map { Array($0[9600..<21600]) }, "Selected-range WAV contains exactly the requested stereo frames with pre-range effect history")
    store.processEffects = nil
    try AudioExporter.write(project: project, store: store, settings: rangeSettings, to: selectedWAV, range: 0.8..<1.2)
    let padded = try AudioStore.decode(selectedWAV, sampleRate: 48_000)
    try check(padded.frameCount == 19_200 && padded.channels.allSatisfy { $0.suffix(9600).allSatisfy { $0 == 0 } }, "Selected empty timeline space is padded to the exact export range length")
    rangeSettings.sampleRate = 96_000
    try AudioExporter.write(project: project, store: store, settings: rangeSettings, to: selectedWAV, range: 0.2..<0.45)
    try check(abs((try AVAudioFile(forReading: selectedWAV)).length - 24_000) < 2, "Selected-range duration survives high-quality export resampling")
    rangeSettings.sampleRate = 44_100
    for format in [ExportFormat.mp3, .ogg] {
        rangeSettings.format = format
        let path = directory.appendingPathComponent("selected." + format.rawValue)
        try AudioExporter.write(project: project, store: store, settings: rangeSettings, to: path, range: 0.2..<0.7)
        if format == .mp3 {
            let result = try AudioStore.decode(path, sampleRate: 44_100)
            try check(abs(result.frameCount - 22_050) < 2304, "Selected-range MP3 exports only the chosen half-second within codec padding")
        } else {
            let result = try AudioExporter.runEncoder(["--inspect-ogg", path.path])
            let info = try JSONSerialization.jsonObject(with: result) as! [String: Any]
            try check(abs((info["frames"] as! Int) - 22_050) < 2, "Selected-range OGG exports the chosen half-second")
        }
    }
    settings.format = .mp3; settings.sampleRate = 44_100
    let mp3 = directory.appendingPathComponent("out.mp3")
    try AudioExporter.write(project: project, store: store, settings: settings, to: mp3)
    let decoded = try AudioStore.decode(mp3, sampleRate: 44_100)
    let energy = sqrt(decoded.channels[0].reduce(Double(0)) { $0 + Double($1 * $1) } / Double(decoded.frameCount))
    try check(decoded.channels.count == 2 && abs(decoded.frameCount - 44_100) < 2304 && energy > 0.12 && energy < 0.16, "MP3 export decodes to actual stereo audio at the chosen rate and duration")
    for rate in [44_100.0, 96_000.0] {
        settings.format = .ogg; settings.sampleRate = rate
        let path = directory.appendingPathComponent("out.ogg")
        try AudioExporter.write(project: project, store: store, settings: settings, to: path)
        let result = try AudioExporter.runEncoder(["--inspect-ogg", path.path])
        let info = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        try check((info["sampleRate"] as? Double) == rate && (info["channels"] as? Int) == 2 && abs((info["frames"] as! Int) - Int(rate)) < 2 && (info["rms"] as! Double) > 0.1, "OGG export decodes with the selected \(Int(rate)) Hz rate, stereo channels and full audio duration")
    }
    try check(store.sampleRate == project.audioFormat.sampleRate && project.audioFormat.bitDepth == 24, "Export conversion leaves the project and playback format unchanged")
    let before = try Data(contentsOf: mp3)
    settings.format = .mp3; settings.sampleRate = 96_000
    var rejected = false
    do { try AudioExporter.write(project: project, store: store, settings: settings, to: mp3) }
    catch { rejected = true }
    let after = try Data(contentsOf: mp3)
    try check(rejected && after == before, "A failed export preserves the existing destination file")
    settings.format = .ogg; settings.sampleRate = 96_000; settings.bitDepth = 16
    let editor = Editor(store: store); editor.project = project
    editor.project.audioFormat.sampleRate = 44_100
    store.configure(editor.project.audioFormat)
    var stale = ExportSettings(projectFormat: editor.project.audioFormat); stale.format = .wav; stale.sampleRate = 88_200
    editor.project.exportSettings = stale
    let initial = ExportOptionsController(settings: editor.project.defaultExportSettings)
    initial.formats.selectItem(at: 1); initial.changed()
    try check(initial.settings.sampleRate == 44_100 && initial.settings.format == .wav, "WAV initially uses 44.1 kHz from the project instead of an old unconfirmed 88.2 kHz choice")
    let priorUndo = editor.undoStack.count
    var invalid = settings; invalid.format = .mp3
    do { try editor.export(to: directory.appendingPathComponent("invalid.mp3"), settings: invalid) } catch {}
    try check(editor.project.defaultExportSettings.sampleRate == 44_100 && !editor.project.exportSettingsConfirmed && editor.undoStack.count == priorUndo, "An unsuccessful export cannot replace the project's default export choices")
    settings.format = .wav; settings.sampleRate = 88_200
    try editor.export(to: directory.appendingPathComponent("remembered.wav"), settings: settings)
    try check(editor.project.defaultExportSettings == settings && editor.project.exportSettingsConfirmed && editor.dirty, "A successful export becomes the next dialog's default and marks the project for Save")
    editor.projectURL = directory.appendingPathComponent("Saved.sounder")
    try check(editor.save(), "Project Save accepts the last selected export settings")
    let saved = try JSONDecoder().decode(Project.self, from: Data(contentsOf: editor.projectURL!))
    try check(saved.defaultExportSettings == settings && saved.exportSettingsConfirmed && saved.audioFormat == editor.project.audioFormat, "Saving and reopening preserves export choices independently of the project format")
    let legacy = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    try check(legacy.exportSettings == nil, "Older projects without export settings remain readable")
}

extension AppDelegate {
    func verifyExportUI() throws {
        let ranged = ExportOptionsController(settings: editor.project.defaultExportSettings, range: 1...3)
        guard !ranged.selectedRangeCheckbox.isHidden, ranged.selectedRange == nil else { throw SounderError.message("Selected range must be visible and initially unchecked for a timeline range") }
        ranged.selectedRangeCheckbox.performClick(nil)
        guard ranged.selectedRange == 1..<3 else { throw SounderError.message("Selected range checkbox did not enable interval export") }
        ranged.rates.selectItem(at: 3); ranged.changed()
        guard !ranged.note.isHidden, ranged.selectedRangeCheckbox.frame.maxY <= ranged.note.frame.minY, ranged.selectedRange == 1..<3 else { throw SounderError.message("Export validation overlaps or resets the range checkbox") }
        ranged.formats.selectItem(at: 1); ranged.changed()
        guard ranged.note.isHidden, ranged.selectedRangeCheckbox.frame.maxY < ranged.bitrates.frame.minY else { throw SounderError.message("Selected range must remain the last export form row") }
        let empty = ExportOptionsController(settings: editor.project.defaultExportSettings, range: 2...2)
        guard empty.selectedRangeCheckbox.isHidden else { throw SounderError.message("An empty time range must not show the checkbox") }
        let options = ExportOptionsController(settings: editor.project.defaultExportSettings)
        guard options.settings.sampleRate == editor.project.audioFormat.sampleRate && options.settings.bitDepth == editor.project.audioFormat.bitDepth && options.settings.format == .mp3 else { throw SounderError.message("Export dialog defaults do not match the project") }
        guard options.selectedRangeCheckbox.isHidden && options.selectedRange == nil else { throw SounderError.message("No selected timeline range must hide the export checkbox") }
        guard !options.depths.isEnabled && options.bitrates.isEnabled else { throw SounderError.message("Compressed export presents misleading PCM bit depth") }
        options.formats.selectItem(at: 1); options.changed()
        guard options.depths.isEnabled && !options.bitrates.isEnabled else { throw SounderError.message("WAV depth is not editable") }
        options.formats.selectItem(at: 0); options.changed()
        let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
            if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count, let view = options.alert.window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                let url = URL(fileURLWithPath: CommandLine.arguments[index+1]).deletingPathExtension().appendingPathExtension("export.png")
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
            NSApp.stopModal(withCode: .alertSecondButtonReturn)
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        guard options.runModal() == nil else { throw SounderError.message("Export Cancel was ignored") }
        print("PASS: export range checkbox is conditional, initially off, survives format validation and stays at the form bottom; defaults and Cancel work")
    }
}
