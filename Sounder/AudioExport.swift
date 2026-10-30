import AppKit
import AVFoundation
import UniformTypeIdentifiers

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
    private var showsRateError = false
    init(settings: ExportSettings) {
        super.init()
        alert.messageText = "Export audio"
        alert.icon = NSImage(size: .zero)
        alert.addButton(withTitle: "Export…"); alert.addButton(withTitle: "Cancel")
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 154))
        let rows: [(String, NSPopUpButton)] = [("Format", formats), ("Sample rate", rates), ("Bit depth", depths), ("MP3 bitrate", bitrates)]
        for (index, row) in rows.enumerated() {
            let y = CGFloat(120 - index * 36)
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
        note.frame = NSRect(x: 0, y: 0, width: 390, height: 54); note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; form.addSubview(note)
        alert.accessoryView = form; changed()
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
            for view in form.subviews where view !== note { view.frame.origin.y += shift }
            form.frame.size.height += shift
            showsRateError = invalidMP3Rate
            alert.layout()
        }
    }
    func runModal() -> ExportSettings? { alert.runModal() == .alertFirstButtonReturn ? settings : nil }
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
    static func write(project: Project, store: AudioStore, settings: ExportSettings, to destination: URL) throws {
        try settings.validate()
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("SounderExport-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        // Mix and process effects at the project rate, then resample the final mix once.
        var signal = try store.renderAudio(project)
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
            try runEncoder([settings.format.rawValue, String(Int(settings.sampleRate)), String(project.audioFormat.channels), raw.path, temporary.path, settings.format == .mp3 ? String(settings.mp3Bitrate) : "0.7"])
        }
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: destination) }
    }
}
