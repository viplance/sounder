import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Darwin

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
    var selectionRangeOnly = false
    init(projectFormat: ProjectAudioFormat) {
        sampleRate = projectFormat.sampleRate; bitDepth = projectFormat.bitDepth
    }
    enum CodingKeys: String, CodingKey { case format, sampleRate, bitDepth, mp3Bitrate, selectionRangeOnly }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(ExportFormat.self, forKey: .format)
        sampleRate = try values.decode(Double.self, forKey: .sampleRate)
        bitDepth = try values.decode(Int.self, forKey: .bitDepth)
        mp3Bitrate = try values.decode(Int.self, forKey: .mp3Bitrate)
        selectionRangeOnly = try values.decodeIfPresent(Bool.self, forKey: .selectionRangeOnly) ?? false
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
        alert.addButton(withTitle: "Export"); alert.addButton(withTitle: "Cancel")
        alert.closeButtonResponseIndex = 1
        alert.buttonSpacing = 6
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
        selectedRangeCheckbox.setButtonType(.switch); selectedRangeCheckbox.state = settings.selectionRangeOnly ? .on : .off
        selectedRangeCheckbox.frame = NSRect(x: 0, y: 0, width: 390, height: 24)
        selectedRangeCheckbox.isHidden = availableRange == nil; form.addSubview(selectedRangeCheckbox)
        alert.accessoryView = form
        metadataButton.useStandardTextStyle()
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
        value.selectionRangeOnly = selectedRangeCheckbox.state == .on
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
    @discardableResult static func runEncoder(_ arguments: [String], captureOutput: Bool = true, progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws -> Data {
        if cancelled() { throw CancellationError() }
        let process = Process(); process.executableURL = encoderURL; process.arguments = arguments
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        }
        // Drain both pipes and poll cancellation without waiting for the encoder
        // or letting a full stderr pipe deadlock the worker.
        var descriptors = [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor].map {
            pollfd(fd: $0, events: Int16(POLLIN), revents: 0)
        }
        var result = Data(), failure = Data(), lines = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        var terminating = false
        while descriptors.contains(where: { $0.fd >= 0 }) {
            if cancelled(), !terminating, process.isRunning { terminating = true; process.terminate() }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 50)
            if ready < 0 {
                if errno == EINTR { continue }
                throw SounderError.message("Cannot read audio encoder progress")
            }
            for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                let count = Darwin.read(descriptors[index].fd, &bytes, bytes.count)
                if count == 0 { descriptors[index].fd = -1; continue }
                if count < 0 { if errno == EINTR { continue }; throw SounderError.message("Cannot read audio encoder output") }
                let data = Data(bytes.prefix(count))
                if index == 1 { failure.append(data); continue }
                if captureOutput { result.append(data) }
                else {
                    lines.append(data)
                    while let newline = lines.firstIndex(of: 10) {
                        if let text = String(data: lines[..<newline], encoding: .utf8), text.hasPrefix("progress "), let value = Double(text.dropFirst(9)) { progress(min(1, max(0, value))) }
                        lines.removeSubrange(...newline)
                    }
                }
            }
        }
        process.waitUntilExit()
        if cancelled() { throw CancellationError() }
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
    private static func addWAVMetadata(_ metadata: AudioMetadata, to url: URL, cancelled: () -> Bool) throws {
        guard !metadata.encoderArguments.isEmpty else { return }
        var info = Data("INFO".utf8)
        for field in AudioMetadata.fields {
            guard let name = field.riff, !metadata[keyPath: field.key].isEmpty else { continue }
            var value = Data(metadata[keyPath: field.key].utf8); value.append(0)
            info.append(try riffChunk(name, value))
        }
        // ID3 preserves all Unicode fields, including tags without a RIFF INFO equivalent.
        let id3 = try runEncoder(["--id3"] + metadata.encoderArguments, cancelled: cancelled)
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
    /// Use the playback graph for export so bus routing, latency and plug-in
    /// block processing follow the same path as the audible mix.
    static func render(project: Project, store: AudioStore, cancelled: () -> Bool = { false },
                       progress: (Double, String) -> Void = { _, _ in }) throws -> AudioSignal {
        store.configure(project.audioFormat)
        let channels = project.audioFormat.channels
        let graph = try StreamingGraph.make(project: project, store: store, cancelled: cancelled)
        try graph.seek(to: 0)
        var output = Array(repeating: [Float](repeating: 0, count: graph.totalFrames), count: channels)
        for first in stride(from: 0, to: graph.totalFrames, by: PlaybackBufferSize.blockFrames) {
            if cancelled() { throw CancellationError() }
            let count = min(PlaybackBufferSize.blockFrames, graph.totalFrames - first)
            let block = try graph.render(frames: count)
            for frame in 0..<count { for channel in 0..<channels {
                output[channel][first + frame] = block[frame * channels + channel]
            } }
            progress(Double(first + count) / Double(max(1, graph.totalFrames)), "Mixing audio")
        }
        return AudioSignal(channels: output)
    }

    static func write(project: Project, store: AudioStore, settings: ExportSettings, to destination: URL, range: Range<Double>? = nil, progress: (Double, String) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) throws {
        try settings.validate()
        try project.metadata.validate()
        if let range {
            guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound >= 0, range.upperBound > range.lowerBound else { throw SounderError.message("Select a nonempty time range to export") }
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("SounderExport-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        if cancelled() { throw CancellationError() }
        let tracks = project.processingTracks, solo = TrackSoloRouting(tracks: project.processingTracks)
        var audible = Set<UUID>()
        func include(_ track: Track) {
            guard !solo.isMuted(track), solo.buses.contains(track.id), audible.insert(track.id).inserted else { return }
            for child in tracks where child.parent == track.id { include(child) }
        }
        for root in tracks where root.parent == nil { include(root) }
        let paths = Set(project.tracks.filter { audible.contains($0.id) && solo.dry.contains($0.id) }.flatMap(\.clips).filter { !$0.muted }.map(\.source)).sorted()
        for (index, path) in paths.enumerated() {
            if cancelled() { throw CancellationError() }
            if store.cache[path] == nil {
                store.cache[path] = try AudioStore.decode(URL(fileURLWithPath: path), sampleRate: project.audioFormat.sampleRate, progress: {
                    progress(0.15 * (Double(index) + $0) / Double(paths.count), $1)
                }, isCancelled: cancelled)
            }
            progress(0.15 * Double(index + 1) / Double(paths.count), "Audio loaded")
        }
        // Mix and process effects at the project rate, then resample the final mix once.
        progress(0.15, "Mixing audio")
        var signal = try render(project: project, store: store, cancelled: cancelled, progress: {
            progress(0.15 + 0.5 * $0, $1)
        })
        if cancelled() { throw CancellationError() }
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
            try store.write(signal, to: source, progress: { progress(0.65 + 0.05 * $0, "Preparing resampling") }, cancelled: cancelled)
            signal = AudioSignal(channels: try AudioStore.decode(source, sampleRate: settings.sampleRate, progress: { value, _ in
                progress(0.7 + 0.1 * value, "Resampling audio")
            }, isCancelled: cancelled).channels)
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".sounder-" + UUID().uuidString + "." + settings.format.rawValue)
        defer { try? fm.removeItem(at: temporary) }
        if settings.format == .wav {
            let writer = try AudioStore(directory: work)
            writer.configure(ProjectAudioFormat(sampleRate: settings.sampleRate, channels: project.audioFormat.channels, bitDepth: settings.bitDepth))
            try writer.write(signal, to: temporary, bitDepth: settings.bitDepth, progress: { progress(0.8 + 0.18 * $0, "Writing WAV") }, cancelled: cancelled)
            try addWAVMetadata(project.metadata, to: temporary, cancelled: cancelled)
        } else {
            let raw = work.appendingPathComponent("mix.f32")
            fm.createFile(atPath: raw.path, contents: nil)
            let file = try FileHandle(forWritingTo: raw)
            do {
                for first in stride(from: 0, to: signal.frameCount, by: 4096) {
                    if cancelled() { throw CancellationError() }
                    let last = min(signal.frameCount, first + 4096)
                    var interleaved = [Float](); interleaved.reserveCapacity((last-first) * signal.channels.count)
                    for frame in first..<last { for channel in signal.channels { interleaved.append(channel[frame]) } }
                    try interleaved.withUnsafeBytes { try file.write(contentsOf: Data($0)) }
                    progress(0.8 + 0.05 * Double(last) / Double(max(1, signal.frameCount)), "Preparing " + settings.format.title)
                }
                try file.close()
            } catch { try? file.close(); throw error }
            try runEncoder([settings.format.rawValue, String(Int(settings.sampleRate)), String(project.audioFormat.channels), raw.path, temporary.path, settings.format == .mp3 ? String(settings.mp3Bitrate) : "0.7"] + project.metadata.encoderArguments, captureOutput: false, progress: {
                progress(0.85 + 0.14 * $0, "Encoding " + settings.format.title)
            }, cancelled: cancelled)
        }
        if cancelled() { throw CancellationError() }
        progress(0.99, "Finishing export")
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: destination) }
        progress(1, "Ready")
    }
}

/// Owns the export UI; the worker uses an immutable project/cache snapshot.
final class AudioExportController: NSObject, NSWindowDelegate {
    weak var editor: Editor?
    let destination: URL
    let settings: ExportSettings
    let project: Project
    let range: Range<Double>?
    private let directory: URL
    private let sources: [String: AudioData]
    private(set) var isRunning = false
    private(set) var fraction = 0.0
    private(set) var failure: Error?
    private(set) var window: NSWindow!
    private let row: AudioFileProgressRow
    private let button = PointerButton()
    private let queue = DispatchQueue(label: "Sounder.export", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var lastProgressTime = 0.0
    var completed: (() -> Void)?
    init(editor: Editor, destination: URL, settings: ExportSettings, range: Range<Double>?, metadata: AudioMetadata) {
        self.editor = editor; self.destination = destination; self.settings = settings; self.range = range
        var snapshot = editor.project; snapshot.metadata = metadata; project = snapshot
        directory = editor.audio.directory; sources = editor.audio.cache
        row = AudioFileProgressRow(url: destination)
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func start() {
        guard !isRunning, window == nil else { return }
        isRunning = true
        window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 144))
        window.title = "Export audio"; window.delegate = self; window.isReleasedWhenClosed = false
        let root = PopupBackgroundView(); root.wantsLayer = true; root.layer?.backgroundColor = panelColor.cgColor; window.contentView = root
        row.frame.origin = NSPoint(x: 22, y: 54); root.addSubview(row)
        row.update(fraction: 0, phase: "Preparing export")
        button.title = "Cancel"; button.bezelStyle = .rounded; button.target = self; button.action = #selector(pressButton)
        button.frame = NSRect(x: 426, y: 12, width: 112, height: 30); root.addSubview(button)
        window.center(); window.makeKeyAndOrderFront(nil); editor?.update()
        DispatchQueue.main.async { [self] in queue.async { [self] in performExport() } }
    }
    private func publish(_ value: Double, _ phase: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard value == 1 || now - lastProgressTime >= 0.04 else { return }
        lastProgressTime = now
        DispatchQueue.main.async { [self] in
            fraction = max(fraction, min(1, value)); row.update(fraction: fraction, phase: phase)
        }
    }
    private func performExport() {
        let result: Result<Void, Error>
        do {
            let store = try AudioStore(directory: directory)
            store.configure(project.audioFormat); store.cache = sources
            try AudioExporter.write(project: project, store: store, settings: settings, to: destination, range: range,
                                    progress: { self.publish($0, $1) }, cancelled: { self.isCancelled })
            result = .success(())
        } catch { result = .failure(error) }
        DispatchQueue.main.async { [self] in
            isRunning = false; button.title = "Close"; button.isEnabled = true
            switch result {
            case .success:
                fraction = 1; row.update(fraction: 1, phase: "Ready")
                editor?.finishAudioExport(to: destination, settings: settings, metadata: project.metadata)
            case .failure(let error):
                failure = error
                row.update(fraction: fraction, phase: error is CancellationError ? "Cancelled" : "Failed: " + error.localizedDescription)
                editor?.update()
                if !(error is CancellationError) { editor?.error(error) }
            }
            let callback = completed; completed = nil; callback?()
            if failure == nil || failure is CancellationError { close() }
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        if isRunning { button.title = "Cancelling…"; button.isEnabled = false }
    }
    @objc private func pressButton() { if isRunning { cancel() } else { close() } }
    func close() {
        guard !isRunning else { cancel(); return }
        window?.orderOut(nil)
        if editor?.exporter === self { editor?.exporter = nil }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { pressButton(); return false }
}
