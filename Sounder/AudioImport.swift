import AppKit
import UniformTypeIdentifiers

/// Finder publishes file URLs; some file managers still publish a filename array.
enum AudioFileDrop {
    static let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, filenames]
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        let modern = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let legacy = (pasteboard.propertyList(forType: filenames) as? [String] ?? []).map { URL(fileURLWithPath: $0) }
        var seen = Set<URL>()
        return (modern + legacy).filter { url in
            url.isFileURL && !url.hasDirectoryPath &&
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true &&
            seen.insert(url.standardizedFileURL).inserted
        }
    }
}

enum AudioImportPlacement { case singleTrack, separateTracks }

final class ImportPlacementDialog: NSObject {
    let alert = CompactSettingsAlert()
    let single = PointerButton(title: "One track", target: nil, action: nil)
    let separate = PointerButton(title: "Separate tracks", target: nil, action: nil)
    var placement: AudioImportPlacement { separate.state == .on ? .separateTracks : .singleTrack }
    override init() {
        super.init()
        alert.messageText = "Import multiple files"
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        for (index, button) in [separate, single].enumerated() {
            button.setButtonType(.radio); button.target = self; button.action = #selector(selectPlacement(_:))
            button.frame = NSRect(x: 0, y: index == 0 ? 32 : 0, width: 300, height: 24)
            form.addSubview(button)
        }
        separate.state = .on
        alert.accessoryView = form; alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = separate
    }
    @objc private func selectPlacement(_ sender: NSButton) {
        single.state = sender === single ? .on : .off
        separate.state = sender === separate ? .on : .off
    }
    @discardableResult func handleSelectionKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.window === alert.window, NSApp.modalWindow === alert.window,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              [UInt16(48), 125, 126].contains(event.keyCode) else { return false }
        let next = placement == .separateTracks ? single : separate
        selectPlacement(next); alert.window.makeFirstResponder(next)
        return true
    }
    func runModal() -> AudioImportPlacement? {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleSelectionKey(event) == true ? nil : event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal() == .alertFirstButtonReturn ? placement : nil
    }
}

struct ImportedAudio {
    let name: String
    let url: URL
    let data: AudioData
}

final class AudioFileProgressRow: NSView {
    let progress = NSProgressIndicator()
    let status = NSTextField(labelWithString: "Waiting")
    init(url: URL) {
        super.init(frame: NSRect(x: 0, y: 0, width: 508, height: 74))
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium); name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = url.path; name.frame = NSRect(x: 0, y: 49, width: 508, height: 20); addSubview(name)
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.frame = NSRect(x: 0, y: 29, width: 508, height: 12); addSubview(progress)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 0, y: 6, width: 508, height: 18); status.lineBreakMode = .byTruncatingTail; addSubview(status)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(fraction: Double, phase: String) {
        progress.doubleValue = fraction
        status.stringValue = phase == "Ready" || phase == "Cancelled" || phase.hasPrefix("Failed:") ? phase : "\(phase) · \(Int(fraction * 100))%"
        status.textColor = phase.hasPrefix("Failed:") ? .systemRed : phase == "Ready" ? .systemGreen : .secondaryLabelColor
        status.toolTip = status.stringValue
    }
}

/// Owns the import window on the main thread; decoding uses no shared cache or UI.
final class AudioImportController: NSObject, NSWindowDelegate {
    weak var editor: Editor?
    let urls: [URL]
    let directory: URL
    let sampleRate: Double
    let targetTrack: UUID?
    let start: Double
    let placement: AudioImportPlacement
    private(set) var isRunning = false
    private(set) var fractions: [Double]
    private(set) var statuses: [String]
    private(set) var window: NSWindow!
    private var rows: [AudioFileProgressRow] = []
    private let button = PointerButton()
    private let queue = DispatchQueue(label: "Sounder.import", qos: .userInitiated)
    private let cancellationLock = NSLock()
    private var cancelled = false
    // Only the import worker accesses throttling state.
    private var lastProgressTime = 0.0
    private var lastPhase = ""
    var completed: (() -> Void)?
    init(editor: Editor, urls: [URL], placement: AudioImportPlacement = .singleTrack, destination: (track: UUID?, start: Double)? = nil) {
        self.editor = editor; self.urls = urls; directory = editor.audio.directory
        self.placement = placement
        sampleRate = editor.audio.sampleRate
        if let destination { targetTrack = destination.track; start = destination.start }
        else { targetTrack = editor.selectedTrack; start = editor.cursor }
        fractions = Array(repeating: 0, count: urls.count); statuses = Array(repeating: "Waiting", count: urls.count)
    }
    private var isCancelled: Bool { cancellationLock.lock(); defer { cancellationLock.unlock() }; return cancelled }
    func startImport() {
        guard !urls.isEmpty, !isRunning else { return }
        isRunning = true
        let visibleHeight = CGFloat(min(6, urls.count)) * 74
        let height = visibleHeight + 70
        window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: height))
        window.title = "Import audio"; window.delegate = self; window.isReleasedWhenClosed = false
        let root = PopupBackgroundView(); root.wantsLayer = true; root.layer?.backgroundColor = panelColor.cgColor; window.contentView = root
        let scroll = NSScrollView(frame: NSRect(x: 22, y: 54, width: 516, height: visibleHeight))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 508, height: CGFloat(urls.count) * 74))
        for (index, url) in urls.enumerated() {
            let row = AudioFileProgressRow(url: url); row.frame.origin.y = CGFloat(urls.count - index - 1) * 74
            content.addSubview(row); rows.append(row)
        }
        scroll.documentView = content; root.addSubview(scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, content.frame.height - visibleHeight)))
        button.title = "Cancel"; button.target = self; button.action = #selector(pressButton); button.bezelStyle = .rounded
        button.frame = NSRect(x: 426, y: 12, width: 112, height: 30); root.addSubview(button)
        window.center(); window.makeKeyAndOrderFront(nil)
        editor?.update()
        // Enqueue work after showing the window. No decoding or copying runs on main.
        DispatchQueue.main.async { [self] in queue.async { [self] in performImport() } }
    }
    private func publish(_ index: Int, _ fraction: Double, _ phase: String, force: Bool = false) {
        let time = ProcessInfo.processInfo.systemUptime
        guard force || phase != lastPhase || time - lastProgressTime >= 0.04 else { return }
        lastProgressTime = time; lastPhase = phase
        DispatchQueue.main.async { [self] in
            fractions[index] = max(fractions[index], min(1, fraction)); statuses[index] = phase
            rows[index].update(fraction: fractions[index], phase: phase)
        }
    }
    private func copy(_ source: URL, to destination: URL, index: Int) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = try input.seekToEnd(); try input.seek(toOffset: 0)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw SounderError.message("Cannot create an imported audio file") }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: UInt64 = 0
        while true {
            if isCancelled { throw CancellationError() }
            let data = try input.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data); copied += UInt64(data.count)
            publish(index, 0.15 * Double(copied) / Double(max(1, size)), "Copying file")
        }
    }
    private func performImport() {
        var imported: [ImportedAudio] = [], failures = 0
        for (index, url) in urls.enumerated() {
            if isCancelled { publish(index, 0, "Cancelled", force: true); continue }
            let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
            do {
                publish(index, 0, "Copying file", force: true)
                try copy(url, to: destination, index: index)
                let data = try AudioStore.decode(destination, sampleRate: sampleRate, progress: { fraction, phase in
                    self.publish(index, 0.15 + 0.85 * fraction, phase)
                }, isCancelled: { self.isCancelled })
                guard data.frameCount > 0 else { throw SounderError.message("The file contains no audio") }
                if isCancelled { throw CancellationError() }
                imported.append(ImportedAudio(name: url.deletingPathExtension().lastPathComponent, url: destination, data: data))
                publish(index, 1, "Ready", force: true)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                if error is CancellationError { publish(index, 0, "Cancelled", force: true) }
                else { failures += 1; publish(index, 0, "Failed: " + error.localizedDescription, force: true) }
            }
        }
        let results = imported, failed = failures
        DispatchQueue.main.async { [self] in
            isRunning = false
            editor?.finishAudioImport(results, track: targetTrack, start: start, placement: placement)
            if failed > 0 { editor?.error(SounderError.message("Could not import \(failed) file(s). See the import window for details.")) }
            button.title = "Close"; button.isEnabled = true
            let completion = completed; completed = nil; completion?()
            if failed == 0 { close() }
        }
    }
    func cancel() {
        cancellationLock.lock(); cancelled = true; cancellationLock.unlock()
        if isRunning { button.title = "Cancelling…"; button.isEnabled = false }
    }
    @objc private func pressButton() { if isRunning { cancel() } else { close() } }
    func close() {
        guard !isRunning else { cancel(); return }
        window?.orderOut(nil)
        if editor?.importer === self { editor?.importer = nil }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { pressButton(); return false }
}

/// Worker-owned project and PCM, published together only after validation succeeds.
struct PreparedProject {
    let project: Project
    let sources: [String: AudioData]
    static func load(from url: URL, progress: (Double, String) -> Void = { _, _ in },
                     cancelled: () -> Bool = { false }) throws -> PreparedProject {
        if cancelled() { throw CancellationError() }
        progress(0, "Reading project")
        let project = try ProjectStorage.load(from: url)
        let clips = project.tracks.flatMap(\.clips)
        var sources: [String: AudioData] = [:]
        var seen = Set<String>()
        let paths = clips.map(\.source).filter { seen.insert($0).inserted }
        for (index, path) in paths.enumerated() {
            if cancelled() { throw CancellationError() }
            sources[path] = try AudioStore.decode(URL(fileURLWithPath: path), sampleRate: project.audioFormat.sampleRate,
                progress: { fraction, phase in
                    progress((Double(index) + fraction) / Double(paths.count), phase + ": " + URL(fileURLWithPath: path).lastPathComponent)
                }, isCancelled: cancelled)
        }
        for clip in clips {
            if cancelled() { throw CancellationError() }
            guard let data = sources[clip.source],
                  clip.offset + clip.duration <= Double(data.frameCount) / project.audioFormat.sampleRate + 0.001 else {
                throw SounderError.message("Fragment exceeds its audio file")
            }
        }
        if cancelled() { throw CancellationError() }
        return PreparedProject(project: project, sources: sources)
    }
}

/// Matches the compact export window; all document reads and audio preparation run on its worker.
final class ProjectOpenController: NSObject, NSWindowDelegate {
    weak var editor: Editor?
    let url: URL
    private(set) var isRunning = false
    private(set) var fraction = 0.0
    private(set) var failure: Error?
    private(set) var window: NSWindow!
    private let row: AudioFileProgressRow
    private let button = PointerButton()
    private let queue = DispatchQueue(label: "Sounder.project.open", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    // Accessed only by the worker.
    private var lastProgressTime = 0.0
    init(editor: Editor, url: URL) {
        self.editor = editor; self.url = url; row = AudioFileProgressRow(url: url)
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func start() {
        guard !isRunning, window == nil else { return }
        isRunning = true
        window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 144))
        window.title = "Open project"; window.delegate = self; window.isReleasedWhenClosed = false
        let root = PopupBackgroundView(); root.wantsLayer = true; root.layer?.backgroundColor = panelColor.cgColor; window.contentView = root
        row.frame.origin = NSPoint(x: 22, y: 54); root.addSubview(row)
        row.update(fraction: 0, phase: "Reading project")
        button.title = "Cancel"; button.bezelStyle = .rounded; button.target = self; button.action = #selector(pressButton)
        button.frame = NSRect(x: 426, y: 12, width: 112, height: 30); root.addSubview(button)
        window.center(); window.makeKeyAndOrderFront(nil); editor?.update()
        DispatchQueue.main.async { [self] in queue.async { [self] in performOpen() } }
    }
    private func publish(_ value: Double, _ phase: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProgressTime >= 0.04 else { return }
        lastProgressTime = now
        DispatchQueue.main.async { [self] in
            fraction = max(fraction, min(0.99, value)); row.update(fraction: fraction, phase: phase)
        }
    }
    private func performOpen() {
        let result = Result { try PreparedProject.load(from: url, progress: { self.publish($0, $1) }, cancelled: { self.isCancelled }) }
        DispatchQueue.main.async { [self] in
            guard editor?.projectOpener === self else { return }
            isRunning = false; button.title = "Close"; button.isEnabled = true
            // Cancel can arrive after the worker finishes but before publication.
            let outcome: Result<PreparedProject, Error> = isCancelled ? .failure(CancellationError()) : result
            switch outcome {
            case .success(let prepared):
                fraction = 1; row.update(fraction: 1, phase: "Ready")
                editor?.finishProjectOpen(prepared, from: url)
            case .failure(let error):
                failure = error
                row.update(fraction: fraction, phase: error is CancellationError ? "Cancelled" : "Failed: " + error.localizedDescription)
                editor?.update()
                if !(error is CancellationError) { editor?.error(error) }
            }
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
        if editor?.projectOpener === self { editor?.projectOpener = nil }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { pressButton(); return false }
}
