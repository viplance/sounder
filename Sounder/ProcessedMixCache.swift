import AVFoundation

// Retaining processed PCM lets shuttle reuse effects without running processors
// in reverse. A short I/O lock also covers overlapping cancelled/new shuttles.
final class ProcessedMixCache {
    let url: URL
    private let file: FileHandle
    private let lock = NSLock()
    let channels: Int
    private var extent = 0
    private var regions: [Range<Int>] = []
    // Bounded write combining on the existing worker; no second producer or
    // asynchronous readiness. Reads flush under the same short I/O lock.
    private var pending: [Float] = []
    private var pendingFrame = 0
    private let writeBatchFrames = 4096
    private var writes = 0
    var diskWrites: Int { lock.lock(); defer { lock.unlock() }; return writes }
    var frames: Int { lock.lock(); defer { lock.unlock() }; return extent }
    func cachedRegions(in range: Range<Int>) -> [Range<Int>] {
        lock.lock(); defer { lock.unlock() }
        return regions.compactMap {
            let first = max(range.lowerBound, $0.lowerBound), last = min(range.upperBound, $0.upperBound)
            return first < last ? first..<last : nil
        }
    }
    /// Readiness of retained PCM plus the requested next window. Moving the
    /// marker may add missing work, but never erases already calculated ranges.
    func retainedReadiness(in range: Range<Int>) -> Double {
        lock.lock(); defer { lock.unlock() }
        let retained = regions.reduce(0) { $0 + $1.count }
        guard retained > 0 else { return 0 }
        let ready = regions.reduce(0) { $0 + max(0, min($1.upperBound, range.upperBound) - max($1.lowerBound, range.lowerBound)) }
        let missing = max(0, range.count - ready)
        return Double(retained) / Double(retained + missing) * 100
    }
    init(channels: Int) throws {
        self.channels = channels
        url = FileManager.default.temporaryDirectory.appendingPathComponent("Sounder-mix-" + UUID().uuidString + ".pcm")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw SounderError.message("Cannot create playback cache") }
        do {
            file = try FileHandle(forUpdating: url)
            // The open handle retains the data, but a crash or forced quit can
            // never leave a full-length temporary recording on disk.
            try FileManager.default.removeItem(at: url)
        }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    func invalidate() { lock.lock(); regions.removeAll(); pending.removeAll(keepingCapacity: true); extent = 0; lock.unlock() }
    func append(_ samples: [Float]) throws { try write(samples, at: frames) }
    func write(_ samples: [Float], at frame: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty else { return }
        if !pending.isEmpty && pendingFrame + pending.count / channels != frame { try flush() }
        if pending.count + samples.count > writeBatchFrames * channels { try flush() }
        if pending.isEmpty { pendingFrame = frame }
        // Oversized writes bypass staging; normal DSP blocks coalesce without
        // growing RAM with project duration or the number of discontinuities.
        if samples.count >= writeBatchFrames * channels {
            try flush()
            try writeDisk(samples, at: frame)
        } else {
            pending.append(contentsOf: samples)
            if pending.count >= writeBatchFrames * channels { try flush() }
        }
        let end = frame + samples.count / channels
        extent = max(extent, end)
        var merged = frame..<end, result: [Range<Int>] = []
        for region in regions {
            if region.upperBound < merged.lowerBound { result.append(region) }
            else if region.lowerBound > merged.upperBound { result.append(merged); merged = region }
            else { merged = min(region.lowerBound, merged.lowerBound)..<max(region.upperBound, merged.upperBound) }
        }
        result.append(merged); regions = result
    }
    private func writeDisk(_ samples: [Float], at frame: Int) throws {
        try file.seek(toOffset: UInt64(frame * channels * MemoryLayout<Float>.size))
        try samples.withUnsafeBytes { try file.write(contentsOf: $0) }
        writes += 1
    }
    private func flush() throws {
        guard !pending.isEmpty else { return }
        try writeDisk(pending, at: pendingFrame)
        pending.removeAll(keepingCapacity: true)
    }
    func read(_ range: Range<Int>) throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard !range.isEmpty else { return [] }
        precondition(regions.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound })
        try flush()
        try file.seek(toOffset: UInt64(range.lowerBound * channels * MemoryLayout<Float>.size))
        let count = range.count * channels * MemoryLayout<Float>.size
        var data = Data()
        while data.count < count {
            guard let next = try file.read(upToCount: count - data.count), !next.isEmpty else { throw SounderError.message("Incomplete playback cache") }
            data.append(next)
        }
        return data.withUnsafeBytes { bytes in
            (0..<(range.count * channels)).map { bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
        }
    }
    deinit { try? file.close(); try? FileManager.default.removeItem(at: url) }
}

