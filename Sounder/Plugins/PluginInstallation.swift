import AppKit
import CryptoKit
import Foundation

struct CatalogPlugin: Codable, Identifiable {
    enum Archive: String, Codable { case zip, pkg }
    let id: String
    let name: String
    let maker: String
    let category: String
    let version: String
    let homepage: URL
    let description: String
    let downloadURL: URL
    let archive: Archive
    let sha256: String
    let downloadBytes: Int64
    let bundleName: String
    let bundleIdentifier: String
    var searchText: String { name + " " + maker + " " + category + " VST3" }
    func installed(in urls: [URL]) -> URL? {
        urls.first { $0.pathExtension.lowercased() == "vst3" &&
            ($0.lastPathComponent.caseInsensitiveCompare(bundleName) == .orderedSame || Bundle(url: $0)?.bundleIdentifier == bundleIdentifier) }
    }
}

enum PluginCatalog {
    static func load(from url: URL) throws -> [CatalogPlugin] {
        let entries = try JSONDecoder().decode([CatalogPlugin].self, from: Data(contentsOf: url))
        guard Set(entries.map(\.id)).count == entries.count else { throw SounderError.message("Duplicate plug-in catalog IDs") }
        for entry in entries {
            guard entry.downloadURL.scheme == "https", entry.homepage.scheme == "https",
                  entry.bundleName == URL(fileURLWithPath: entry.bundleName).lastPathComponent,
                  entry.bundleName.hasSuffix(".vst3"), !entry.bundleIdentifier.isEmpty,
                  entry.sha256.count == 64, entry.sha256.allSatisfy({ $0.isHexDigit }), entry.downloadBytes > 0 else {
                throw SounderError.message("Invalid plug-in catalog entry: " + entry.name)
            }
        }
        return entries
    }
    static let bundled: Result<[CatalogPlugin], Error> = Result {
        guard let url = Bundle.main.url(forResource: "PluginCatalog", withExtension: "json") else { throw SounderError.message("The plug-in catalog is missing") }
        return try load(from: url)
    }
}

private final class PackageInstallLocation: NSObject, XMLParserDelegate {
    var location: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "pkg-info" { location = attributeDict["install-location"] }
    }
    static func read(_ url: URL) -> String? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        let delegate = PackageInstallLocation(); parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? delegate.location : nil
    }
}

/// Installs only the catalog's VST3 bundle. Packages are expanded as data;
/// installer scripts are never executed and system-wide plug-ins are untouched.
final class PluginInstallController: NSObject, NSWindowDelegate, URLSessionDownloadDelegate {
    let plugin: CatalogPlugin
    let destinationDirectory: URL
    private(set) var isRunning = false
    private(set) var window: NSWindow!
    private(set) var fraction = 0.0
    private(set) var failure: Error?
    private let row: AudioFileProgressRow
    private let button = PointerButton()
    private let worker = DispatchQueue(label: "Sounder.plugin.install", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private var lastProgressTime = 0.0
    private var lastPhase = ""
    private var session: URLSession?
    private var download: URLSessionDownloadTask?
    private let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderPlugin-" + UUID().uuidString)
    var stateChanged: (() -> Void)?
    var completed: ((Result<URL, Error>) -> Void)?
    var closed: (() -> Void)?
    init(plugin: CatalogPlugin, destinationDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/VST3")) {
        self.plugin = plugin; self.destinationDirectory = destinationDirectory
        row = AudioFileProgressRow(url: URL(fileURLWithPath: plugin.name + " " + plugin.version))
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func check() throws { if isCancelled { throw CancellationError() } }
    /// A local archive uses the identical verification/install path for offline tests.
    func start(localArchive: URL? = nil) {
        guard window == nil else { return }
        isRunning = true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 144), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Install plug-in"; window.delegate = self; window.isReleasedWhenClosed = false
        window.level = .floating; window.hidesOnDeactivate = false
        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = panelColor.cgColor; window.contentView = root
        row.frame.origin = NSPoint(x: 22, y: 54); root.addSubview(row); row.update(fraction: 0, phase: "Connecting")
        button.title = "Cancel"; button.bezelStyle = .rounded; button.target = self; button.action = #selector(pressButton)
        button.frame = NSRect(x: 426, y: 12, width: 112, height: 30); root.addSubview(button)
        window.center(); window.makeKeyAndOrderFront(nil); stateChanged?()
        worker.async { [self] in
            do {
                try check(); try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
                if let localArchive { performInstall(localArchive); return }
                let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 900
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
                lock.lock(); self.session = session
                let task = session.downloadTask(with: plugin.downloadURL); download = task
                let stop = cancelled; lock.unlock()
                if stop { task.cancel() }; task.resume()
            } catch { finish(.failure(error)) }
        }
    }
    private func publish(_ value: Double, _ phase: String, indeterminate: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard phase != lastPhase || now - lastProgressTime >= 0.04 else { lock.unlock(); return }
        lastPhase = phase; lastProgressTime = now; lock.unlock()
        DispatchQueue.main.async { [self] in
            guard isRunning else { return }
            fraction = max(fraction, min(0.99, value)); row.update(fraction: fraction, phase: phase)
            row.progress.isIndeterminate = indeterminate
            if indeterminate { row.progress.startAnimation(nil); row.status.stringValue = phase }
            else { row.progress.stopAnimation(nil) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : plugin.downloadBytes
        publish(0.70 * min(1, Double(totalBytesWritten) / Double(max(1, total))), "Downloading")
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try check()
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw SounderError.message("The manufacturer download is unavailable") }
            let archive = workDirectory.appendingPathComponent("download." + plugin.archive.rawValue)
            // URLSession owns location only until this delegate method returns.
            try FileManager.default.moveItem(at: location, to: archive)
            worker.async { [self] in performInstall(archive) }
        } catch { worker.async { [self] in finish(.failure(error)) } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { worker.async { [self] in finish(.failure(isCancelled ? CancellationError() : error)) } }
    }
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        try check()
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        let log = workDirectory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        task.standardOutput = handle; task.standardError = handle
        lock.lock()
        do { if cancelled { throw CancellationError() }; process = task; try task.run(); lock.unlock() }
        catch { process = nil; lock.unlock(); throw error }
        task.waitUntilExit()
        lock.lock(); process = nil; lock.unlock()
        try check()
        let output = String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)
        guard task.terminationStatus == 0 else { throw SounderError.message("Cannot prepare \(plugin.name): " + output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return output
    }
    private func relativeFiles(in directory: URL) -> [(String, URL)] {
        // Keep the enumerator's relative names. URL enumerators can change
        // /var to /private/var on macOS, making prefix-length slicing unsafe.
        guard let items = FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String] else { return [] }
        return items.map { ($0, directory.appendingPathComponent($0)) }
    }
    private func files(in directory: URL) -> [URL] { relativeFiles(in: directory).map { $0.1 } }
    private func canonicalPath(_ url: URL) throws -> String {
        guard let path = realpath(url.path, nil) else { throw SounderError.message("Cannot resolve plug-in files") }
        defer { free(path) }
        return String(cString: path)
    }
    private func bundle(in directory: URL) -> URL? {
        files(in: directory).first { $0.lastPathComponent == plugin.bundleName && Bundle(url: $0)?.bundleIdentifier == plugin.bundleIdentifier }
    }
    private func prepare(_ archive: URL) throws -> URL {
        let root = workDirectory.appendingPathComponent("expanded")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if plugin.archive == .zip {
            let listing = try run("/usr/bin/unzip", ["-Z1", archive.path])
            guard listing.split(separator: "\n").allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else { throw SounderError.message("Unsafe paths in the plug-in archive") }
            _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, root.path])
        }
        if let bundle = bundle(in: root) { return bundle }
        let packages = plugin.archive == .pkg ? [archive] : files(in: root).filter { $0.pathExtension == "pkg" && !$0.deletingLastPathComponent().path.contains(".pkg/") }
        for (index, package) in packages.enumerated() {
            try check(); publish(0.80, "Unpacking macOS package", indeterminate: true)
            let expanded = root.appendingPathComponent("package-\(index)")
            _ = try run("/usr/sbin/pkgutil", ["--expand-full", package.path, expanded.path])
            if let bundle = bundle(in: expanded) { return bundle }
            // Some component packages install Payload/Contents directly into
            // a bundle specified by install-location (notably TDR's packages).
            for info in files(in: expanded) where info.lastPathComponent == "PackageInfo" {
                guard let location = PackageInstallLocation.read(info), URL(fileURLWithPath: location).lastPathComponent == plugin.bundleName else { continue }
                let payload = info.deletingLastPathComponent().appendingPathComponent("Payload")
                let wrapper = workDirectory.appendingPathComponent(plugin.bundleName)
                if FileManager.default.fileExists(atPath: payload.appendingPathComponent("Contents/Info.plist").path) {
                    try FileManager.default.copyItem(at: payload, to: wrapper)
                    if Bundle(url: wrapper)?.bundleIdentifier == plugin.bundleIdentifier { return wrapper }
                    try FileManager.default.removeItem(at: wrapper)
                }
            }
        }
        throw SounderError.message("The download does not contain the expected macOS VST3: " + plugin.bundleName)
    }
    private func performInstall(_ archive: URL) {
        let result: Result<URL, Error>
        do {
            try check(); publish(0.70, "Verifying download")
            let input = try FileHandle(forReadingFrom: archive); defer { try? input.close() }
            var hash = SHA256(), read: Int64 = 0
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try check(); hash.update(data: data); read += Int64(data.count)
                publish(0.70 + 0.10 * min(1, Double(read) / Double(plugin.downloadBytes)), "Verifying download")
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == plugin.sha256.lowercased() else { throw SounderError.message("The manufacturer download has changed or is incomplete. Update Sounder's plug-in catalog before installing.") }
            publish(0.80, "Unpacking plug-in", indeterminate: true)
            let source = try prepare(archive).resolvingSymlinksInPath()
            guard let info = Bundle(url: source), info.bundleIdentifier == plugin.bundleIdentifier, let executable = info.executableURL else { throw SounderError.message("Invalid VST3 bundle") }
            let contentPaths = relativeFiles(in: source)
            let contents = contentPaths.map { $0.1 }
            let canonicalRoot = try canonicalPath(source)
            for file in contents {
                if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
                   !(try canonicalPath(file)).hasPrefix(canonicalRoot + "/") { throw SounderError.message("Unsafe link in the plug-in bundle") }
            }
            publish(0.82, "Checking Apple Silicon plug-in", indeterminate: true)
            _ = try run("/usr/bin/lipo", ["-verify_arch", "arm64", executable.path])
            _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
            try check()
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let target = destinationDirectory.appendingPathComponent(plugin.bundleName)
            if FileManager.default.fileExists(atPath: target.path) {
                guard Bundle(url: target)?.bundleIdentifier == plugin.bundleIdentifier else { throw SounderError.message("A different plug-in already uses this file name") }
                result = .success(target)
            } else {
                let staging = destinationDirectory.appendingPathComponent(".Sounder-install-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                let copy = staging.appendingPathComponent(plugin.bundleName)
                try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
                let total = contents.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                var copied: Int64 = 0
                for (relative, file) in contentPaths {
                    try check()
                    let destination = copy.appendingPathComponent(relative)
                    let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                    if values.isSymbolicLink == true {
                        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: FileManager.default.destinationOfSymbolicLink(atPath: file.path))
                    } else if values.isDirectory == true { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
                    else { try FileManager.default.copyItem(at: file, to: destination) }
                    copied += Int64(values.fileSize ?? 0)
                    publish(0.85 + 0.13 * Double(copied) / Double(max(1, total)), "Installing VST3")
                }
                try check()
                _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", copy.path])
                try check(); try FileManager.default.moveItem(at: copy, to: target)
                result = .success(target)
            }
        } catch { result = .failure(error) }
        finish(result)
    }
    private func finish(_ result: Result<URL, Error>) {
        try? FileManager.default.removeItem(at: workDirectory)
        lock.lock(); let session = session; self.session = nil; download = nil; lock.unlock()
        session?.finishTasksAndInvalidate()
        DispatchQueue.main.async { [self] in
            guard isRunning else { return }
            isRunning = false; row.progress.isIndeterminate = false; row.progress.stopAnimation(nil)
            button.title = "Close"; button.isEnabled = true
            switch result {
            case .success: fraction = 1; row.update(fraction: 1, phase: "Ready")
            case .failure(let error): failure = error; row.update(fraction: fraction, phase: error is CancellationError ? "Cancelled" : "Failed: " + error.localizedDescription)
            }
            stateChanged?(); let callback = completed; completed = nil; callback?(result)
            if failure == nil || failure is CancellationError { close() }
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = download, active = process; lock.unlock()
        task?.cancel(); if active?.isRunning == true { active?.terminate() }
        if isRunning { button.title = "Cancelling…"; button.isEnabled = false }
    }
    @objc private func pressButton() { if isRunning { cancel() } else { close() } }
    func close() {
        guard !isRunning else { cancel(); return }
        window?.orderOut(nil); let callback = closed; closed = nil; callback?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { pressButton(); return false }
}
