import Foundation

/// Compiles track dependencies once. Only ready nodes enter the shared pool;
/// deterministic summation stays in the parent, independent of completion order.
final class AudioRenderPlan {
    let tracks: [Track]
    let children: [[Int]]
    let roots: [Int]
    private let scheduler: SNAudioRenderPlan
    private let parallel: Bool
    var workerCount: Int { parallel ? scheduler.workerCount : 1 }
    init(tracks: [Track], parallel: Bool = true, minimumCost: Double = 0.00001) throws {
        var ordered: [Track] = [], seen = Set<UUID>(), groups: [[Int]] = []
        let hierarchy = Dictionary(grouping: tracks, by: \.parent)
        func visit(_ track: Track) throws -> Int {
            guard seen.insert(track.id).inserted else { throw SounderError.message("Invalid track hierarchy") }
            let children = try (hierarchy[track.id] ?? []).map(visit)
            let index = ordered.count; ordered.append(track); groups.append(children); return index
        }
        roots = try (hierarchy[nil] ?? []).map(visit)
        guard ordered.count == tracks.count else { throw SounderError.message("Invalid track hierarchy") }
        self.tracks = ordered; children = groups; self.parallel = parallel
        var parents = [Int](repeating: -1, count: tracks.count)
        for (parent, children) in groups.enumerated() { for child in children { parents[child] = parent } }
        scheduler = try SNAudioRenderPlan(parents: parents.map(NSNumber.init), costs: ordered.map {
            NSNumber(value: minimumCost + Double($0.effects.filter { !$0.bypassed }.count) * 0.001)
        })
    }
    func perform(_ process: (Int) throws -> Void) throws {
        if !parallel { for index in tracks.indices { try process(index) }; return }
        let lock = NSLock(); var failure: Error?
        let success = scheduler.perform { index in
            do { try process(index); return true }
            catch { lock.lock(); if failure == nil { failure = error }; lock.unlock(); return false }
        }
        if !success { throw failure ?? SounderError.message("Audio rendering failed") }
    }
}

/// Each result has exactly one writer, and is read only after its dependency
/// completes. Keeping slots separate avoids concurrent mutation of a Swift Array.
final class AudioRenderResult<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
