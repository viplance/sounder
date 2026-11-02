import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Project-level tags shared by the export dialog and all file encoders.
struct AudioMetadata: Codable, Equatable {
    var trackName = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var composer = ""
    var genre = ""
    var year = ""
    var trackNumber = ""
    var discNumber = ""
    var copyright = ""
    var comment = ""
    static let fields: [(label: String, key: WritableKeyPath<AudioMetadata, String>, tag: String, riff: String?)] = [
        ("Track name", \.trackName, "TITLE", "INAM"), ("Artist", \.artist, "ARTIST", "IART"),
        ("Album", \.album, "ALBUM", "IPRD"), ("Album artist", \.albumArtist, "ALBUMARTIST", nil),
        ("Composer", \.composer, "COMPOSER", nil), ("Genre", \.genre, "GENRE", "IGNR"),
        ("Year", \.year, "DATE", "ICRD"), ("Track number", \.trackNumber, "TRACKNUMBER", "ITRK"),
        ("Disc number", \.discNumber, "DISCNUMBER", nil), ("Copyright", \.copyright, "COPYRIGHT", "ICOP"),
        ("Comment", \.comment, "COMMENT", "ICMT")
    ]
    var encoderArguments: [String] {
        Self.fields.flatMap { field in self[keyPath: field.key].isEmpty ? [] : [field.tag, self[keyPath: field.key]] }
    }
    func validate() throws {
        for field in Self.fields {
            let value = self[keyPath: field.key]
            guard !value.utf8.contains(0), value.utf8.count <= 8192 else {
                throw SounderError.message("\(field.label) must be at most 8192 UTF-8 bytes and contain no null characters")
            }
        }
    }
}

enum ExportFormat: String, Codable, CaseIterable {
    case mp3, wav, ogg
    var title: String { rawValue.uppercased() }
}
struct ExportSettings: Codable, Equatable {
    var format: ExportFormat = .mp3
    var sampleRate: Double
    var bitDepth: Int
    var mp3Bitrate = 320
    init(projectFormat: ProjectAudioFormat) {
        sampleRate = projectFormat.sampleRate; bitDepth = projectFormat.bitDepth
    }
    func validate() throws {
        guard ProjectAudioFormat.supportedRates.contains(sampleRate), [16, 24, 32].contains(bitDepth), [128, 192, 256, 320].contains(mp3Bitrate) else {
            throw SounderError.message("Unsupported export settings")
        }
        if format == .mp3 && sampleRate > 48_000 { throw SounderError.message("MP3 supports up to 48 kHz. Choose 44.1 or 48 kHz, or select WAV/OGG.") }
    }
}
final class ExportOptionsController: NSObject {
    let alert = CompactSettingsAlert()
    let formats = NSPopUpButton(), rates = NSPopUpButton(), depths = NSPopUpButton(), bitrates = NSPopUpButton()
    let note = NSTextField(wrappingLabelWithString: "")
    let selectedRangeCheckbox = PointerButton(title: "Selected range", target: nil, action: nil)
    private let availableRange: ClosedRange<Double>?
    private var showsRateError = false
    let metadataButton = PointerButton(title: "Metadata", target: nil, action: nil)
    private(set) var metadataFields: [NSTextField] = []
    private var metadataExpanded = false
    private var metadataPanel = NSView()
    init(settings: ExportSettings, range: ClosedRange<Double>? = nil, metadata: AudioMetadata = AudioMetadata()) {
        availableRange = range.flatMap { $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.lowerBound >= 0 && $0.upperBound > $0.lowerBound ? $0 : nil }
        super.init()
        alert.messageText = "Export audio"
        alert.icon = NSImage(size: .zero)
        alert.addButton(withTitle: "Export…"); alert.addButton(withTitle: "Cancel")
        let rangeHeight: CGFloat = availableRange == nil ? 0 : 32
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 154 + rangeHeight))
        let rows: [(String, NSPopUpButton)] = [("Format", formats), ("Sample rate", rates), ("Bit depth", depths), ("MP3 bitrate", bitrates)]
        for (index, row) in rows.enumerated() {
            let y = CGFloat(120 - index * 36) + rangeHeight
            let label = NSTextField(labelWithString: row.0); label.frame = NSRect(x: 0, y: y + 3, width: 115, height: 22); form.addSubview(label)
            row.1.frame = NSRect(x: 124, y: y, width: 260, height: 28)
            row.1.setAccessibilityLabel(row.0); row.1.target = self; row.1.action = #selector(changed)
            form.addSubview(row.1)
        }
        formats.addItems(withTitles: ExportFormat.allCases.map(\.title)); formats.selectItem(at: ExportFormat.allCases.firstIndex(of: settings.format)!)
        rates.addItems(withTitles: ProjectAudioFormat.supportedRates.map { ProjectAudioFormat(sampleRate: $0).rateLabel })
        rates.selectItem(at: ProjectAudioFormat.supportedRates.firstIndex(of: settings.sampleRate) ?? 1)
        depths.addItems(withTitles: ["16 bit", "24 bit", "32 bit (Float)"]); depths.selectItem(at: [16,24,32].firstIndex(of: settings.bitDepth) ?? 1)
        bitrates.addItems(withTitles: ["128 kbps", "192 kbps", "256 kbps", "320 kbps"]); bitrates.selectItem(at: [128,192,256,320].firstIndex(of: settings.mp3Bitrate) ?? 3)
        note.frame = NSRect(x: 0, y: rangeHeight, width: 390, height: 54); note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; form.addSubview(note)
        selectedRangeCheckbox.setButtonType(.switch); selectedRangeCheckbox.state = .off
        selectedRangeCheckbox.frame = NSRect(x: 0, y: 0, width: 390, height: 24)
        selectedRangeCheckbox.isHidden = availableRange == nil; form.addSubview(selectedRangeCheckbox)
        alert.accessoryView = form
        metadataButton.bezelStyle = .rounded
        metadataButton.imagePosition = .imageLeft
        metadataButton.target = self; metadataButton.action = #selector(toggleMetadata)
        metadataButton.setAccessibilityLabel("Show or hide metadata")
        alert.leadingButton = metadataButton
        for (index, field) in AudioMetadata.fields.enumerated() {
            let x = CGFloat(index % 2) * 300, y = CGFloat(5 - index / 2) * 52
            let label = NSTextField(labelWithString: field.label)
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: x, y: y + 28, width: 280, height: 16)
            let input = NSTextField(string: metadata[keyPath: field.key])
            if field.tag == "DATE" { input.formatter = NumericInputFormatter(.integer) }
            if field.tag == "TRACKNUMBER" || field.tag == "DISCNUMBER" { input.formatter = NumericInputFormatter(.trackNumber) }
            input.frame = NSRect(x: x, y: y, width: 280, height: 24)
            input.setAccessibilityLabel(field.label)
            metadataPanel.addSubview(label); metadataPanel.addSubview(input); metadataFields.append(input)
        }
        metadataPanel.frame = NSRect(x: 0, y: rangeHeight, width: 580, height: 312)
        metadataPanel.isHidden = true; form.addSubview(metadataPanel)
        updateMetadataButton(); changed()
    }
    var selectedRange: Range<Double>? {
        guard selectedRangeCheckbox.state == .on, let availableRange else { return nil }
        return availableRange.lowerBound..<availableRange.upperBound
    }
    var settings: ExportSettings {
        var value = ExportSettings(projectFormat: ProjectAudioFormat(sampleRate: ProjectAudioFormat.supportedRates[rates.indexOfSelectedItem], bitDepth: [16,24,32][depths.indexOfSelectedItem]))
        value.format = ExportFormat.allCases[formats.indexOfSelectedItem]; value.mp3Bitrate = [128,192,256,320][bitrates.indexOfSelectedItem]
        return value
    }
    @objc func changed() {
        depths.isEnabled = settings.format == .wav; bitrates.isEnabled = settings.format == .mp3
        let invalidMP3Rate = settings.format == .mp3 && settings.sampleRate > 48_000
        alert.buttons[0].isEnabled = !invalidMP3Rate
        note.stringValue = invalidMP3Rate ? "MP3 supports up to 48 kHz. Choose 44.1 or 48 kHz, or select WAV/OGG." : ""
        note.isHidden = !invalidMP3Rate
        if invalidMP3Rate != showsRateError, let form = alert.accessoryView {
            let shift: CGFloat = invalidMP3Rate ? 54 : -54
            for view in form.subviews where view !== note && view !== selectedRangeCheckbox && view !== metadataPanel { view.frame.origin.y += shift }
            form.frame.size.height += shift
            showsRateError = invalidMP3Rate
            alert.layout()
        }
    }
    var metadata: AudioMetadata {
        var result = AudioMetadata()
        for (index, field) in AudioMetadata.fields.enumerated() {
            result[keyPath: field.key] = metadataFields[index].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
    private func updateMetadataButton() {
        metadataButton.image = NSImage(systemSymbolName: metadataExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    }
    @objc func toggleMetadata() {
        guard let form = alert.accessoryView else { return }
        // End field editing before reparenting the alert's views.
        alert.window.makeFirstResponder(nil)
        let shift: CGFloat = metadataExpanded ? -324 : 324
        for view in form.subviews where view !== selectedRangeCheckbox && view !== metadataPanel { view.frame.origin.y += shift }
        form.frame.size.height += shift
        form.frame.size.width = metadataExpanded ? 390 : 580
        metadataExpanded.toggle(); metadataPanel.isHidden = !metadataExpanded
        updateMetadataButton(); alert.layout()
    }
    func runModal() -> ExportSettings? {
        while alert.runModal() == .alertFirstButtonReturn {
            alert.window.makeFirstResponder(nil)
            do { try metadata.validate(); return settings }
            catch { alert.informativeText = error.localizedDescription }
        }
        return nil
    }
}

enum AudioExporter {
    static var encoderURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AudioEncoder") }
    @discardableResult static func runEncoder(_ arguments: [String]) throws -> Data {
        let process = Process(); process.executableURL = encoderURL; process.arguments = arguments
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SounderError.message(String(data: failure, encoding: .utf8) ?? "Audio export failed") }
        return result
    }
    private static func riffChunk(_ name: String, _ payload: Data) throws -> Data {
        guard payload.count <= Int(UInt32.max) else { throw SounderError.message("Metadata is too large") }
        var size = UInt32(payload.count).littleEndian
        var result = Data(name.utf8)
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(payload)
        if payload.count % 2 != 0 { result.append(0) }
        return result
    }
    private static func addWAVMetadata(_ metadata: AudioMetadata, to url: URL) throws {
        guard !metadata.encoderArguments.isEmpty else { return }
        var info = Data("INFO".utf8)
        for field in AudioMetadata.fields {
            guard let name = field.riff, !metadata[keyPath: field.key].isEmpty else { continue }
            var value = Data(metadata[keyPath: field.key].utf8); value.append(0)
            info.append(try riffChunk(name, value))
        }
        // ID3 preserves all Unicode fields, including tags without a RIFF INFO equivalent.
        let id3 = try runEncoder(["--id3"] + metadata.encoderArguments)
        var tags = Data()
        if info.count > 4 { tags.append(try riffChunk("LIST", info)) }
        tags.append(try riffChunk("id3 ", id3))
        let file = try FileHandle(forUpdating: url); defer { try? file.close() }
        let header = try file.read(upToCount: 12) ?? Data()
        guard header.count == 12, header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8) else {
            throw SounderError.message("Cannot add metadata to this WAV container")
        }
        let end = try file.seekToEnd()
        guard end + UInt64(tags.count) + end % 2 - 8 <= UInt64(UInt32.max) else { throw SounderError.message("WAV file exceeds the RIFF size limit") }
        if end % 2 != 0 { try file.write(contentsOf: Data([0])) }
        try file.write(contentsOf: tags)
        var size = UInt32(try file.offset() - 8).littleEndian
        try file.seek(toOffset: 4)
        try withUnsafeBytes(of: &size) { try file.write(contentsOf: Data($0)) }
    }
    static func write(project: Project, store: AudioStore, settings: ExportSettings, to destination: URL, range: Range<Double>? = nil) throws {
        try settings.validate()
        try project.metadata.validate()
        if let range {
            guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound >= 0, range.upperBound > range.lowerBound else { throw SounderError.message("Select a nonempty time range to export") }
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("SounderExport-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        // Mix and process effects at the project rate, then resample the final mix once.
        var signal = try store.renderAudio(project)
        if let range {
            // Crop after effects so delay/reverb history before the selected start
            // remains correct. Pad empty timeline space to the exact range length.
            let first = Int((range.lowerBound * project.audioFormat.sampleRate).rounded())
            let last = Int((range.upperBound * project.audioFormat.sampleRate).rounded())
            signal = AudioSignal(channels: signal.channels.map { channel in
                let start = min(first, channel.count), end = min(last, channel.count)
                var selected = Array(channel[start..<end])
                selected.append(contentsOf: repeatElement(0, count: max(0, last - first - selected.count)))
                return selected
            })
        }
        if settings.sampleRate != project.audioFormat.sampleRate {
            let source = work.appendingPathComponent("mix.wav")
            try store.write(signal, to: source)
            signal = AudioSignal(channels: try AudioStore.decode(source, sampleRate: settings.sampleRate).channels)
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".sounder-" + UUID().uuidString + "." + settings.format.rawValue)
        defer { try? fm.removeItem(at: temporary) }
        if settings.format == .wav {
            let writer = try AudioStore(directory: work)
            writer.configure(ProjectAudioFormat(sampleRate: settings.sampleRate, channels: project.audioFormat.channels, bitDepth: settings.bitDepth))
            try writer.write(signal, to: temporary, bitDepth: settings.bitDepth)
            try addWAVMetadata(project.metadata, to: temporary)
        } else {
            let raw = work.appendingPathComponent("mix.f32")
            fm.createFile(atPath: raw.path, contents: nil)
            let file = try FileHandle(forWritingTo: raw)
            do {
                for first in stride(from: 0, to: signal.frameCount, by: 4096) {
                    let last = min(signal.frameCount, first + 4096)
                    var interleaved = [Float](); interleaved.reserveCapacity((last-first) * signal.channels.count)
                    for frame in first..<last { for channel in signal.channels { interleaved.append(channel[frame]) } }
                    try interleaved.withUnsafeBytes { try file.write(contentsOf: Data($0)) }
                }
                try file.close()
            } catch { try? file.close(); throw error }
            try runEncoder([settings.format.rawValue, String(Int(settings.sampleRate)), String(project.audioFormat.channels), raw.path, temporary.path, settings.format == .mp3 ? String(settings.mp3Bitrate) : "0.7"] + project.metadata.encoderArguments)
        }
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: destination) }
    }
}
