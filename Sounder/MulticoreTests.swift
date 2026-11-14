import AppKit
import AVFoundation

private final class RenderConcurrencyProbe {
    private let lock = NSLock()
    private var active = 0
    private var threads = Set<UInt32>()
    private(set) var maximum = 0
    func enter() {
        lock.lock(); active += 1; maximum = max(maximum, active)
        threads.insert(pthread_mach_thread_np(pthread_self())); lock.unlock()
    }
    func leave() { lock.lock(); active -= 1; lock.unlock() }
    var threadCount: Int { lock.lock(); defer { lock.unlock() }; return threads.count }
}

func runMulticoreTests(benchmark: Bool = false) throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let independent = (0..<8).map { Track(name: "Worker \($0)") }
    let plan = try AudioRenderPlan(tracks: independent, minimumCost: 0.001)
    let probe = RenderConcurrencyProbe()
    try plan.perform { _ in
        probe.enter(); defer { probe.leave() }
        Thread.sleep(forTimeInterval: 0.005)
    }
    try check(plan.workerCount == min(8, ProcessInfo.processInfo.activeProcessorCount) &&
              (plan.workerCount == 1 || (probe.maximum > 1 && probe.threadCount > 1)),
              "Independent audio jobs run concurrently on a CPU-bounded shared worker pool")
    var failed = false
    do { try plan.perform { _ in throw CancellationError() } } catch is CancellationError { failed = true }
    let progress = PlaybackPreparation(); progress.plan(frames: 800)
    try plan.perform { _ in progress.advance(frames: 100) }
    try check(failed && progress.bufferPercent == 40,
              "Failed jobs drain safely, the pool is reusable and parallel BUFFER accounting loses no completed work")
    // Simultaneous preparation/export plans must not wait on each other's
    // dependency nodes or exhaust the pool with recursively waiting tasks.
    let other = try AudioRenderPlan(tracks: independent, minimumCost: 0.001)
    let group = DispatchGroup(), results = [AudioRenderResult<Error?>(nil), AudioRenderResult<Error?>(nil)]
    for (index, concurrent) in [plan, other].enumerated() {
        group.enter(); DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do { try concurrent.perform { _ in Thread.sleep(forTimeInterval: 0.001) } }
            catch { results[index].value = error }
        }
    }
    try check(group.wait(timeout: .now() + 5) == .success && results.allSatisfy { $0.value == nil },
              "Concurrent playback/export plans share workers without dependency deadlocks")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderMulticore-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory), source = store.freshURL()
    let tone = (0..<9600).map { Float(sin(Double($0) * 0.07) * 0.04) }
    try store.write(AudioSignal(channels: [tone, tone.map { -$0 * 0.3 }]), to: source)
    func effect(_ id: String) -> PluginEffect { PluginEffect(name: id, path: "test", classID: id) }
    var tracks = (0..<8).map { index -> Track in
        Track(name: "Bus \(index)", clips: [Clip(name: "Tone", source: source.path, start: Double(index % 3) * 0.003, offset: 0.01, duration: 0.16, order: index)], effects: [effect(index % 2 == 0 ? "delay" : "gain")])
    }
    tracks[1].parent = tracks[0].id; tracks[2].parent = tracks[1].id
    var project = Project(tracks: tracks); project.masterEffects = [effect("gain")]; project.masterVolumeDB = -3
    func makeEffect(_ effect: PluginEffect) -> StreamingEffect {
        let delay = effect.classID == "delay" ? 7 : 0
        var history = [Float](repeating: 0, count: max(1, delay * 2)), cursor = 0
        return StreamingEffect(latency: delay, tail: delay) { input in
            input.map { sample in
                if delay == 0 { return tanh(sample * 0.75) }
                let previous = history[cursor]; history[cursor] = sample
                cursor = (cursor + 1) % history.count; return previous
            }
        }
    }
    let serial = try StreamingGraph(project: project, store: store, parallel: false, makeEffect: makeEffect)
    let parallel = try StreamingGraph(project: project, store: store, makeEffect: makeEffect)
    for block in 0..<32 {
        if block == 4 { serial.setMuted(true, trackID: tracks[3].id); parallel.setMuted(true, trackID: tracks[3].id) }
        if block == 7 { serial.setMuted(false, trackID: tracks[3].id); parallel.setMuted(false, trackID: tracks[3].id) }
        if block == 10 { serial.setSolo([tracks[2].id]); parallel.setSolo([tracks[2].id]) }
        if block == 14 { serial.setSolo([]); parallel.setSolo([]) }
        if block == 18 {
            var changed = tracks[0]; changed.volumeDB = -8; changed.pan = -0.5
            serial.setTrackMix(changed); parallel.setTrackMix(changed)
        }
        if block == 23 { try serial.seek(to: 1200); try parallel.seek(to: 1200) }
        let count = block % 2 == 0 ? 512 : 96
        let expected = try serial.render(frames: count), actual = try parallel.render(frames: count)
        guard expected == actual, serial.trackPeaks == parallel.trackPeaks, serial.position == parallel.position else {
            throw SounderError.message("Multicore audio or meters differ at block \(block)")
        }
    }
    try check(true, "Multicore streaming is sample-identical with nesting, master FX, latency, tails, mute/solo, live mix, short buffers and seeks")
    store.processEffects = { samples, effects in
        effects.reduce(samples) { output, _ in output.map { tanh($0 * 0.75) } }
    }
    let expected = try store.renderAudio(project, parallel: false)
    var percentages: [Double] = []
    let actual = try store.renderAudio(project, renderProgress: { value, _ in percentages.append(value) })
    try check(actual.channels == expected.channels && percentages.last == 1 && zip(percentages, percentages.dropFirst()).allSatisfy { $0 <= $1 },
              "Parallel offline mix preserves exact PCM, dependency order and monotonic export progress")
    var settings = ExportSettings(projectFormat: project.audioFormat); settings.format = .wav; settings.bitDepth = 32
    let exported = directory.appendingPathComponent("multicore.wav")
    // Export now uses live hosts rather than AudioStore's offline test hook.
    // Keep synthetic processors in the graph tests above; exercise file export
    // with the same nested routing and gains, without fake plug-in paths.
    var exportProject = project
    exportProject.masterEffects = []
    for index in exportProject.tracks.indices { exportProject.tracks[index].effects = [] }
    let exportExpected = try store.renderAudio(exportProject, parallel: false)
    try AudioExporter.write(project: exportProject, store: store, settings: settings, to: exported)
    let decoded = try AudioStore.decode(exported, sampleRate: 48_000)
    try check(decoded.channels == exportExpected.channels, "WAV export preserves the verified nested routing and mix gains")

    if benchmark {
        var benchmarkProject = Project(tracks: tracks.map { track in var t = track; t.parent = nil; return t })
        benchmarkProject.masterEffects = []
        func measured(_ parallel: Bool, heavy: Bool) throws -> Double {
            let graph = try StreamingGraph(project: benchmarkProject, store: store, parallel: parallel) { _ in
                var state: UInt64 = 7
                return StreamingEffect(latency: 0, tail: 0) { input in
                    if heavy { for _ in 0..<200_000 { state = state &* 2862933555777941757 &+ 3037000493 } }
                    return input.map { $0 + Float(state & 255) * 1e-12 }
                }
            }
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<128 { _ = try graph.render(frames: 512) }
            return ProcessInfo.processInfo.systemUptime - start
        }
        for heavy in [false, true] {
            let sequential = try measured(false, heavy: heavy), concurrent = try measured(true, heavy: heavy)
            print(String(format: "BENCHMARK %@: serial %.3f s, multicore %.3f s, %.2fx", heavy ? "8 CPU-heavy DSP branches" : "8 lightweight branches", sequential, concurrent, sequential / concurrent))
        }
    }
}

func runMulticorePluginTest(path: String, classID: String, state: Data) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderMulticoreVST-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory), source = store.freshURL()
    let tone = (0..<12_000).map { Float(sin(Double($0) * 0.05) * 0.02) }
    try store.write(AudioSignal(channels: [tone, tone.map { $0 * 0.3 }]), to: source)
    let project = Project(tracks: (0..<4).map { index in
        Track(name: "VST \(index)", clips: [Clip(name: "Tone", source: source.path, start: 0, duration: 0.25, order: index)],
              effects: [PluginEffect(name: "Real VST", path: path, classID: classID, state: state)])
    })
    let probe = RenderConcurrencyProbe()
    var retained: [SNPluginHost] = []
    let graph = try StreamingGraph(project: project, store: store) { effect in
        let host = try SNPluginHost(path: path, classID: classID, state: effect.state)
        retained.append(host); try host.beginStreaming(2)
        return StreamingEffect(latency: host.latency, tail: host.tail) { input in
            probe.enter(); defer { probe.leave() }
            let result = try host.processBlock(input.withUnsafeBytes { Data($0) }, channels: 2)
            return result.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }
    // Measure audible output after declared lookahead. Canary's 19632-frame
    // latency exceeds the entire 32-block observation window; measuring from
    // cold DSP falsely reports a concurrency failure because energy is zero.
    try graph.seek(to: 0)
    var energy = 0.0
    for _ in 0..<32 {
        let output = try graph.render(frames: 512)
        guard output.allSatisfy(\.isFinite) else { throw SounderError.message("Parallel VST produced invalid audio") }
        energy += output.reduce(0) { $0 + Double($1 * $1) }
    }
    guard energy > 0.001, retained.count == 4 else {
        throw SounderError.message("Native VST produced no compensated audio (energy: \(energy), instances: \(retained.count), latency: \(graph.latency))")
    }
    guard ProcessInfo.processInfo.activeProcessorCount == 1 || (probe.maximum > 1 && probe.threadCount > 1) else {
        throw SounderError.message("Independent native VST processors did not run concurrently")
    }
    let serial = try store.renderAudio(project, parallel: false), parallel = try store.renderAudio(project)
    let difference = zip(serial.channels.flatMap { $0 }, parallel.channels.flatMap { $0 }).map { abs($0 - $1) }.max() ?? 0
    guard serial.frameCount == parallel.frameCount, difference < 0.00001 else {
        throw SounderError.message("Parallel native VST export differs from serial rendering: \(difference)")
    }
    var settings = ExportSettings(projectFormat: project.audioFormat); settings.format = .wav
    try AudioExporter.write(project: project, store: store, settings: settings, to: directory.appendingPathComponent("effects.wav"))
    print("PASS: Four independent native \(URL(fileURLWithPath: path).pathExtension.uppercased()) processors execute concurrently; offline/export PCM matches serial rendering (max error \(difference))")
}
