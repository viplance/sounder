import AppKit
import AVFoundation
import AudioToolbox

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
    for format in [ExportFormat.wav, .mp3, .ogg] {
        var formatSettings = ExportSettings(projectFormat: project.audioFormat); formatSettings.format = format
        let path = directory.appendingPathComponent("progress." + format.rawValue)
        var values: [Double] = [], encoding: [Double] = []
        try AudioExporter.write(project: project, store: store, settings: formatSettings, to: path, progress: { value, phase in
            values.append(value)
            if phase.hasPrefix("Encoding") { encoding.append(value) }
        })
        try check(values.count > 10 && values.last == 1 && zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "\(format.title) reports monotonic progress from actual audio work")
        if format != .wav { try check(encoding.count > 2, "\(format.title) reports incremental encoder progress") }
        let original = try Data(contentsOf: path)
        var cancel = false, cancelled = false
        do {
            try AudioExporter.write(project: project, store: store, settings: formatSettings, to: path, progress: { _, phase in
                if phase == "Writing WAV" || phase.hasPrefix("Encoding") { cancel = true }
            }, cancelled: { cancel })
        } catch is CancellationError { cancelled = true }
        try check(cancelled && (try Data(contentsOf: path)) == original, "Cancelling \(format.title) during writing preserves the existing destination")
        try check(!(try fm.contentsOfDirectory(atPath: directory.path)).contains { $0.hasPrefix(".sounder-") }, "Cancelled export removes its partial output")
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
    var tagged = project
    tagged.metadata = AudioMetadata(trackName: "Ночной свет 🎵", artist: "Björk / Исполнитель", album: "Альбом", albumArtist: "Various — Артисты", composer: "Автор", genre: "Ambient", year: "2026", trackNumber: "3/12", discNumber: "1/2", copyright: "© 2026 Автор", comment: "Line one\nQuoted \"value=two\" \\")
    let expectedFrames = ["TIT2", "TPE1", "TALB", "TPE2", "TCOM", "TCON", "TYER", "TRCK", "TPOS", "TCOP", "COMM"]
    func readID3(_ tag: Data) throws -> [String: String] {
        try check(tag.prefix(3) == Data("ID3".utf8) && tag[3] == 3, "Metadata contains a standard ID3v2.3 tag")
        let tagEnd = 10 + tag[6..<10].reduce(0) { ($0 << 7) | Int($1) }
        var offset = 10, values: [String: String] = [:]
        while offset + 10 <= min(tagEnd, tag.count), tag[offset] != 0 {
            let id = String(data: tag[offset..<offset+4], encoding: .ascii)!
            let size = tag[offset+4..<offset+8].reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, offset + 10 + size <= tag.count else { throw SounderError.message("Malformed ID3 frame") }
            let payload = Data(tag[offset+10..<offset+10+size])
            if expectedFrames.contains(id) {
                guard payload.first == 0 || payload.first == 1 else { throw SounderError.message("Unknown ID3 text encoding") }
                var start = 1
                if id == "COMM" {
                    start = 4 // encoding + language, followed by a UTF-16 description
                    while start + 1 < payload.count {
                        if payload[start] == 0 && payload[start + 1] == 0 { start += 2; break }
                        start += 2
                    }
                }
                values[id] = String(data: payload[start...], encoding: payload.first == 1 ? .utf16 : .isoLatin1)?.trimmingCharacters(in: .init(charactersIn: "\0"))
            }
            offset += 10 + size
        }
        return values
    }
    for format in ExportFormat.allCases {
        var taggedSettings = ExportSettings(projectFormat: tagged.audioFormat); taggedSettings.format = format
        let path = directory.appendingPathComponent("metadata." + format.rawValue)
        try AudioExporter.write(project: tagged, store: store, settings: taggedSettings, to: path, range: 0.2..<0.7)
        if format == .ogg {
            let info = try JSONSerialization.jsonObject(with: AudioExporter.runEncoder(["--inspect-ogg", path.path])) as! [String: Any]
            let tags = info["metadata"] as! [String: String]
            try check(AudioMetadata.fields.allSatisfy { tags[$0.tag] == tagged.metadata[keyPath: $0.key] } && info["frames"] as! Int == 24_000, "OGG stores every Unicode tag and preserves the selected audio duration")
        } else {
            let bytes = try Data(contentsOf: path)
            var tag = bytes
            if format == .wav {
                let size = bytes[4..<8].enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                try check(size + 8 == bytes.count, "WAV RIFF length includes padded metadata chunks")
                var cursor = 12; var found = false
                while cursor + 8 <= bytes.count {
                    let size = bytes[cursor+4..<cursor+8].enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                    if bytes[cursor..<cursor+4] == Data("id3 ".utf8) { tag = Data(bytes[cursor+8..<cursor+8+size]); found = true; break }
                    cursor += 8 + size + size % 2
                }
                try check(found, "WAV contains the complete ID3 metadata chunk")
            }
            let tags = try readID3(tag)
            try check(zip(AudioMetadata.fields, expectedFrames).allSatisfy { tags[$1] == tagged.metadata[keyPath: $0.key] }, "\(format.title) round-trips all metadata fields including Unicode and comments")
            var file: AudioFileID?
            let status = AudioFileOpenURL(path as CFURL, .readPermission, 0, &file)
            guard status == noErr, let file else { throw SounderError.message("Native decoder rejected tagged file") }
            defer { AudioFileClose(file) }
            var info: Unmanaged<CFDictionary>?, size = UInt32(MemoryLayout<CFDictionary?>.size)
            let result = withUnsafeMutablePointer(to: &info) { AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, UnsafeMutableRawPointer($0)) }
            let native = info?.takeRetainedValue() as? [String: Any] ?? [:]
            try check(result == noErr && native[kAFInfoDictionary_Title as String] as? String == tagged.metadata.trackName, "macOS reads the exported \(format.title) Unicode title")
            let decoded = try AudioStore.decode(path, sampleRate: 48_000)
            try check(abs(decoded.frameCount - 24_000) < (format == .mp3 ? 2304 : 2), "Tagged \(format.title) audio still decodes with the selected duration")
        }
    }
    let beforeMetadata = editor.project.metadata
    do { try editor.export(to: directory.appendingPathComponent("bad-metadata.mp3"), settings: invalid, metadata: tagged.metadata) } catch {}
    try check(editor.project.metadata == beforeMetadata, "Failed exports do not commit metadata to the project")
    try editor.export(to: directory.appendingPathComponent("committed.wav"), settings: settings, metadata: tagged.metadata)
    try check(editor.project.metadata == tagged.metadata && editor.dirty, "Successful export commits metadata and marks the project dirty")
    try check(editor.save(), "Project with metadata saves successfully")
    let savedMetadata = try JSONDecoder().decode(Project.self, from: Data(contentsOf: editor.projectURL!))
    try check(savedMetadata.metadata == tagged.metadata, "Project Save and reopen preserve all metadata")
    let reopened = ExportOptionsController(settings: savedMetadata.defaultExportSettings, metadata: savedMetadata.metadata)
    try check(reopened.metadata == tagged.metadata, "Reopened export dialog restores the project's metadata")
    var oversized = tagged.metadata; oversized.comment = String(repeating: "x", count: 8193)
    var oversizedRejected = false
    do { try editor.export(to: mp3, settings: rangeSettings, metadata: oversized) } catch { oversizedRejected = true }
    try check(oversizedRejected && editor.project.metadata == tagged.metadata && (try Data(contentsOf: mp3)) == before, "Invalid metadata preserves both the destination and project")
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
        let collapsed = options.alert.accessoryView!.frame.size
        options.metadataButton.performClick(nil)
        guard options.alert.accessoryView!.frame.height > collapsed.height, options.metadataFields.allSatisfy({ !$0.isHidden && $0.superview?.isHidden == false }) else { throw SounderError.message("Metadata button did not reveal fields") }
        options.metadataFields[0].stringValue = "Ночной свет 🎵"
        options.metadataFields[1].stringValue = "Björk"
        options.metadataButton.performClick(nil)
        guard options.alert.accessoryView!.frame.size == collapsed, options.metadata.trackName == "Ночной свет 🎵" else { throw SounderError.message("Collapsing metadata discarded edits or changed layout") }
        options.metadataButton.performClick(nil)
        guard let leading = options.alert.leadingButton, let cancel = options.alert.buttons.last, leading.frame.maxX < cancel.frame.minX else { throw SounderError.message("Metadata overlaps export actions") }
        print("PASS: Metadata expands inline, collapses without losing edits and keeps action buttons separate")
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
        let typing = ExportOptionsController(settings: editor.project.defaultExportSettings)
        typing.toggleMetadata()
        let commitTimer = Timer(timeInterval: 0.1, repeats: false) { _ in
            let field = typing.metadataFields[0]
            typing.alert.window.makeFirstResponder(field)
            field.currentEditor()?.string = "Last typed character 🎵"
            typing.alert.buttons[0].performClick(nil)
        }
        RunLoop.main.add(commitTimer, forMode: .modalPanel)
        guard typing.runModal() != nil, typing.metadata.trackName == "Last typed character 🎵" else { throw SounderError.message("Export did not commit the active metadata text editor") }
        print("PASS: Export captures the active metadata field's latest typed text")
        print("PASS: export range checkbox is conditional, initially off, survives format validation and stays at the form bottom; defaults and Cancel work")
    }
}

extension AppDelegate {
    func verifyExportProgressUI() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderExportUI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = ExportSettings(projectFormat: editor.project.audioFormat); settings.format = .mp3
        let destination = directory.appendingPathComponent("export.mp3")
        let previous = editor.project.defaultExportSettings
        try editor.startAudioExport(to: destination, settings: settings)
        guard let cancelledJob = editor.exporter, cancelledJob.isRunning, cancelledJob.window.isVisible,
              editor.busy, !editor.canRecord, !editor.canExport else {
            throw SounderError.message("Export window must appear immediately and lock conflicting controls")
        }
        cancelledJob.cancel()
        func wait(_ job: AudioExportController) throws {
            let deadline = Date().addingTimeInterval(30)
            while job.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            guard !job.isRunning else { job.cancel(); throw SounderError.message("Background export timed out") }
        }
        try wait(cancelledJob)
        guard cancelledJob.failure is CancellationError, !FileManager.default.fileExists(atPath: destination.path), editor.project.defaultExportSettings == previous else {
            throw SounderError.message("Cancelled background export changed the file or saved choices")
        }
        try editor.startAudioExport(to: destination, settings: settings)
        guard let job = editor.exporter else { throw SounderError.message("Missing export job") }
        var mainThreadResponded = false
        DispatchQueue.main.async { mainThreadResponded = job.isRunning }
        try wait(job)
        guard mainThreadResponded, job.failure == nil, job.fraction == 1,
              FileManager.default.fileExists(atPath: destination.path), editor.project.defaultExportSettings == settings,
              !job.window.isVisible, !editor.isExporting else { throw SounderError.message("Background export did not complete responsively") }
        print("PASS: Export shows shared progress UI immediately, keeps the main run loop responsive, cancels safely and commits choices only on success")
    }
}
