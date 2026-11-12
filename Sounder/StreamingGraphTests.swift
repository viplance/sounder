import AVFoundation

func runStreamingGraphTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }; print("PASS: \(message)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderStreaming-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AudioStore(directory: directory)
    let url = store.freshURL()
    let signal = AudioSignal(channels: [Array(repeating: Float(0.2), count: 2048), Array(repeating: Float(0.1), count: 2048)])
    try store.write(signal, to: url)
    let clip = Clip(name: "Source", source: url.path, start: 0, duration: 2048 / sampleRate, order: 1)
    let effect = PluginEffect(name: "Gain", path: "test", classID: "gain")
    let parent = Track(name: "Parent", clips: [clip], effects: [effect])
    let child = Track(name: "Child", parent: parent.id, clips: [clip], effects: [effect])
    let sibling = Track(name: "Sibling", clips: [clip])
    var gain: Float = 0.5
    let graph = try StreamingGraph(project: Project(tracks: [parent, child, sibling]), store: store) { _ in
        StreamingEffect(latency: 0, tail: 0) { $0.map { $0 * gain } }
    }
    let first = try graph.render(frames: 512)
    try check(abs(first[1000] - 0.35) < 0.000001 && abs(first[1001] - 0.175) < 0.000001, "Streaming graph applies child and parent effects once, with independent stereo and sibling tracks")
    try check(abs((graph.trackPeaks[parent.id]?.left ?? 0) - 0.15) < 1e-6 && abs((graph.trackPeaks[child.id]?.left ?? 0) - 0.1) < 1e-6 && abs((graph.trackPeaks[sibling.id]?.left ?? 0) - 0.2) < 1e-6, "Per-track meters measure post-effect stereo peaks including child-to-parent routing")
    try check(abs((graph.trackPeaks[parent.id]?.right ?? 0) - 0.075) < 1e-6 && abs((graph.trackPeaks[child.id]?.right ?? 0) - 0.05) < 1e-6 && abs((graph.trackPeaks[sibling.id]?.right ?? 0) - 0.1) < 1e-6, "Right-channel meters stay independent through child and parent effects")
    gain = 0.25
    let next = try graph.render(frames: 512)
    try check(abs(next[0] - 0.2625) < 0.000001, "Changing a live parameter changes the very next block without rebuilding the mix")
    graph.setMuted(true, trackID: parent.id)
    try check(abs(try graph.render(frames: 128)[0] - 0.2) < 0.000001, "Live parent mute silences its subtree while siblings keep playing")
    try check(graph.trackPeaks[parent.id] == StereoLevels() && graph.trackPeaks[child.id] == StereoLevels() && graph.trackPeaks[sibling.id] == StereoLevels(left: 0.2, right: 0.1), "Parent mute suppresses both its own and descendant meters while sibling meters remain live")
    graph.setMuted(false, trackID: parent.id); graph.setMuted(true, trackID: child.id)
    try check(abs(try graph.render(frames: 128)[0] - 0.25) < 0.000001, "Live child mute preserves its parent and siblings")
    graph.setMuted(false, trackID: child.id)
    try check(abs(try graph.render(frames: 128)[0] - 0.2625) < 0.000001, "Live unmute restores routed audio without rebuilding the graph")
    let delayedGraph = try StreamingGraph(project: Project(tracks: [parent, child, sibling]), store: store) { _ in
        let delay = SampleDelay(frames: 37, channels: 2)
        return StreamingEffect(latency: 37, tail: 0) { delay.apply($0) }
    }
    let delayed = try delayedGraph.render(frames: 512)
    let delayedInterior = try delayedGraph.render(frames: 512)
    try check(delayedGraph.latency == 74 && delayed.prefix(148).allSatisfy { $0 == 0 } && abs(delayedInterior[84] - 0.6) < 0.000001, "Streaming latency compensation aligns dry, child and root buses")
    var mutedParent = parent; mutedParent.muted = true
    let muted = try StreamingGraph(project: Project(tracks: [mutedParent, child]), store: store) { _ in
        StreamingEffect(latency: 0, tail: 0) { $0 }
    }
    try check(try muted.render(frames: 512).allSatisfy { $0 == 0 }, "Streaming mute silences the entire subtree")
    muted.setMuted(false, trackID: parent.id)
    try check(abs(try muted.render(frames: 32)[0] - 0.4) < 0.000001, "A track muted before Play can be unmuted in the same stream")
    var newerSilence = clip; newerSilence.id = UUID(); newerSilence.order = 2; newerSilence.source = store.freshURL().path
    try store.write(AudioSignal(channels: [[Float](repeating: 0, count: 2048), [Float](repeating: 0, count: 2048)]), to: URL(fileURLWithPath: newerSilence.source))
    let overlap = try StreamingGraph(project: Project(tracks: [Track(name: "Overlap", clips: [clip, newerSilence])]), store: store) { _ in fatalError() }
    _ = try overlap.render(frames: 512)
    try check(try overlap.render(frames: 128).allSatisfy { $0 == 0 }, "Streaming playback preserves newer silent takes after their edge crossfade")
}

/// Audio-clock-based shuttle: both audible sampling and the cursor use this
/// same integral, independent of keyboard repeat settings and UI timer jitter.
