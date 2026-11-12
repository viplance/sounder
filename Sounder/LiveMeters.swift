import AVFoundation

struct TrackLevelMeter {
    var level = 0.0
    var peak = 0.0
    private var peakTime = -Double.infinity
    private var updatedAt: Double?
    static func decibels(_ amplitude: Double) -> Double { amplitude > 0 ? 20 * log10(amplitude) : -.infinity }
    var fraction: Double { max(0, min(1, (Self.decibels(level) + 60) / 60)) }
    var peakText: String { peak > 0 ? String(format: "%.1f dB", Self.decibels(peak)) : "" }
    mutating func update(_ amplitude: Double, at time: Double) {
        let value = amplitude.isFinite ? max(0, amplitude) : 0
        let elapsed = max(0, time - (updatedAt ?? time))
        level = max(value, level * pow(10, -24 * elapsed / 20))
        if level < 0.001 { level = 0 }
        if value >= peak { peak = value; peakTime = time }
        else if time - peakTime >= 1 { peak = value }
        updatedAt = time
    }
}

// Independent output-channel peaks; mono output is shown equally in L/R.
struct StereoLevels: Equatable {
    var left: Float = 0
    var right: Float = 0
    mutating func merge(_ other: StereoLevels) {
        left = max(left, other.left); right = max(right, other.right)
    }
}

struct StereoTrackLevelMeter {
    var left = TrackLevelMeter()
    var right = TrackLevelMeter()
    var peak: Double { max(left.peak, right.peak) }
    var level: Double { max(left.level, right.level) }
    mutating func update(_ levels: StereoLevels, at time: Double) {
        left.update(Double(levels.left), at: time); right.update(Double(levels.right), at: time)
    }
    mutating func clearLevels() { left.level = 0; right.level = 0 }
}

// Small snapshots follow scheduled audio time, rather than exposing render-ahead
// peaks early. The UI only takes a short lock, never waits on the audio worker.
final class PlaybackMeterBuffer {
    private let lock = NSLock()
    private typealias Entry = (frame: Int, peaks: [UUID: StereoLevels])
    private var storage = [Entry?](repeating: nil, count: 512)
    private var head = 0
    private var count = 0
    func append(frame: Int, peaks: [UUID: StereoLevels]) {
        lock.lock(); defer { lock.unlock() }
        if count == storage.count { storage[head] = nil; head = (head + 1) % storage.count; count -= 1 }
        storage[(head + count) % storage.count] = (frame, peaks); count += 1
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        while count > 0 { storage[head] = nil; head = (head + 1) % storage.count; count -= 1 }
        head = 0
    }
    func consume(through frame: Int) -> [UUID: StereoLevels] {
        lock.lock(); defer { lock.unlock() }
        var result: [UUID: StereoLevels] = [:]
        while count > 0, let item = storage[head], item.frame <= frame {
            for (id, peak) in item.peaks { result[id, default: StereoLevels()].merge(peak) }
            storage[head] = nil; head = (head + 1) % storage.count; count -= 1
        }
        return result
    }
}
