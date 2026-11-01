import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class Editor: NSObject {
    var project = Project()
    let audio: AudioStore
    var selectedTrack: UUID?
    var selection = Set<UUID>()
    var cursor = 0.0
    private(set) var lastPlaybackStart: Double?
    var range: ClosedRange<Double>?
    var zoom = 70.0
    var changed: (() -> Void)?
    let notifications: ToastCenter
    var undoStack: [Project] = []
    var redoStack: [Project] = []
    var dirty = false
    var projectURL: URL?
    var player: LivePlayback?
    private(set) var trackMeters: [UUID: TrackLevelMeter] = [:]
    private let makeRecorder: (URL, ProjectAudioFormat) throws -> LiveRecorder
    private let makePlayback: (StreamingGraph, ProjectAudioFormat, Double) throws -> LivePlayback
    var pluginHosts: [UUID: SNPluginHost] = [:]
    var pluginWindows: [UUID: PluginEditorWindow] = [:]
    var effectsWindows: [UUID: EffectsWindow] = [:]
    var recorder: LiveRecorder?
    var recordingPeaks: [Float] = []
    var recordingChannelPeaks: [[Float]] = []
    var recordingPartialChannelPeaks: [Float?] = []
    var recordingPartialPeak: Float?
    var recordingURL: URL?
    var recordingTrack: UUID?
    var recordingStart = 0.0
    var timer: Timer?
    var importer: AudioImportController?
    private(set) var isNormalizing = false
    var isImporting: Bool { importer?.isRunning == true }
    var requestingMic = false
    var isRecording: Bool { recorder != nil }
    var isPlaying: Bool { player?.isPlaying == true }
    var busy: Bool { isRecording || isPlaying || requestingMic || isImporting || isNormalizing }
    var canExport: Bool { !busy && duration > 0 }
    var duration: Double { project.tracks.flatMap(\.clips).map(\.end).max() ?? 0 }
    var projectName: String { project.name ?? projectURL?.deletingPathExtension().lastPathComponent ?? "MY PROJECT" }
    var suggestedFilename: String { projectName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".sounder" }
    var selectedIndex: Int? { project.tracks.firstIndex { $0.id == selectedTrack } }
    init(store: AudioStore, notifications: ToastCenter = ToastCenter(),
         makeRecorder: @escaping (URL, ProjectAudioFormat) throws -> LiveRecorder = { try LiveRecorder(url: $0, format: $1) },
         makePlayback: @escaping (StreamingGraph, ProjectAudioFormat, Double) throws -> LivePlayback = { LivePlayback(graph: $0, format: $1, start: $2) }) {
        audio = store; self.notifications = notifications; self.makeRecorder = makeRecorder; self.makePlayback = makePlayback
        super.init()
        audio.configure(project.audioFormat)
        selectedTrack = project.tracks.first?.id
    }
    func update(_ text: String? = nil) {
        if let text { notifications.show(text, style: .success) }
        changed?()
    }
    func hint(_ key: UXHint, _ text: String) { notifications.hint(key, text) }
    func error(_ error: Error) { notifications.show(error.localizedDescription, style: .error); changed?() }
    func checkpoint() { undoStack.append(project); if undoStack.count > 50 { undoStack.removeFirst() }; redoStack = []; dirty = true }
    func undo() { guard !busy else { return }; flushPluginEdits(); guard let previous = undoStack.popLast() else { return }; redoStack.append(project); project = previous; dirty = true; reconcile(); update("Undo") }
    func redo() { guard !busy else { return }; flushPluginEdits(); guard let next = redoStack.popLast() else { return }; undoStack.append(project); project = next; dirty = true; reconcile(); update("Redo") }
    func reconcile() {
        closePluginWindows(capture: false)
        pluginHosts = [:]
        for window in Array(effectsWindows.values) { window.done() }
        audio.configure(project.audioFormat)
        if !project.tracks.contains(where: { $0.id == selectedTrack }) { selectedTrack = project.tracks.first?.id }
        selection = selection.intersection(Set(project.tracks.flatMap(\.clips).map(\.id)))
    }
    func renameProject(_ name: String) {
        let trimmed = NameRules.normalized(name)
        guard !trimmed.isEmpty, trimmed != projectName else { return }
        checkpoint(); project.name = trimmed; update("Project renamed")
    }
    func setAudioFormat(_ format: ProjectAudioFormat) throws {
        guard !busy, format != project.audioFormat else { return }
        try format.validate()
        flushPluginEdits(); checkpoint(); closePluginWindows(capture: false); pluginHosts = [:]
        project.audioFormat = format; audio.configure(format)
        update("Audio format: " + format.label)
    }
    func addTrack(nested: Bool = false) {
        guard !busy else { return }
        let track = Track(name: "Audio " + String(format: "%02d", project.tracks.count + 1), parent: nested ? selectedTrack : nil)
        do { try TrackHierarchy.validate(project.tracks + [track]) }
        catch { notifications.show(TrackHierarchy.limitMessage, style: .hint); return }
        checkpoint()
        project.tracks.append(track); selectedTrack = track.id; selection = []; update(nested ? "Nested track added" : "Track added")
    }
    func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var previous = 0
        while previous != result.count { previous = result.count; for track in project.tracks where track.parent.map({ result.contains($0) }) == true { result.insert(track.id) } }
        return result
    }
    func reparent(_ child: UUID, to parent: UUID?) {
        guard !busy, let index = project.tracks.firstIndex(where: { $0.id == child }), parent == nil || !descendants(of: child).contains(parent!) else { return }
        var tracks = project.tracks; tracks[index].parent = parent
        do { try TrackHierarchy.validate(tracks) }
        catch { notifications.show(TrackHierarchy.limitMessage, style: .hint); return }
        guard project.tracks[index].parent != parent else { return }
        checkpoint(); project.tracks = tracks; update("Track hierarchy updated")
    }
    func removeTrack() {
        guard !busy else { return }
        guard let index = selectedIndex else { notifications.show("Select a track to delete", style: .hint); return }
        let id = project.tracks[index].id
        let alert = NSAlert(); alert.messageText = "Delete track?"; alert.informativeText = "This removes the track, its fragments and nested tracks. You can undo this action."; alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        checkpoint(); let ids = descendants(of: id); project.tracks.removeAll { ids.contains($0.id) }; reconcile(); notifications.show("Track deleted", style: .error); update()
    }
    func deleteClips() {
        guard !busy else { return }
        guard !selection.isEmpty else { notifications.show("Select fragments to delete", style: .hint); return }
        checkpoint()
        for i in project.tracks.indices { project.tracks[i].clips.removeAll { selection.contains($0.id) } }; selection = []; notifications.show("Fragments deleted", style: .error); update()
    }
    static let fragmentPasteboardType = NSPasteboard.PasteboardType("enotix.Sounder.fragments")
    func selectAllFragments() {
        selection = Set(project.tracks.flatMap(\.clips).map(\.id)); update()
    }
    func copyFragments(to pasteboard: NSPasteboard = .general) {
        let rows = TrackHierarchy.orderedRows(project.tracks)
        let selectedRows = rows.indices.filter { rows[$0].0.clips.contains(where: { selection.contains($0.id) }) }
        guard let firstRow = selectedRows.first,
              let start = project.tracks.flatMap(\.clips).filter({ selection.contains($0.id) }).map(\.start).min() else { return }
        let items = selectedRows.flatMap { row in
            rows[row].0.clips.filter { selection.contains($0.id) }.map { clip -> FragmentClipboard.Item in
                var copy = clip; copy.start -= start
                return .init(clip: copy, row: row - firstRow, trackName: rows[row].0.name)
            }
        }
        guard let data = try? JSONEncoder().encode(FragmentClipboard(items: items)) else { return }
        pasteboard.clearContents(); pasteboard.setData(data, forType: Self.fragmentPasteboardType)
    }
    func pasteFragments(from pasteboard: NSPasteboard = .general) {
        guard !busy, let data = pasteboard.data(forType: Self.fragmentPasteboardType),
              let payload = try? JSONDecoder().decode(FragmentClipboard.self, from: data), !payload.items.isEmpty else { return }
        do {
            for item in payload.items {
                let clip = item.clip
                guard (0...10_000).contains(item.row), clip.start.isFinite, clip.start >= 0,
                      clip.offset.isFinite, clip.offset >= 0, clip.duration.isFinite, clip.duration > 0,
                      clip.offset + clip.duration <= (try audio.sourceDuration(clip.source)) + 0.001 else { throw SounderError.message("Copied audio is unavailable or invalid") }
            }
            var targets = TrackHierarchy.orderedRows(project.tracks).map { $0.0.id }
            let base = targets.firstIndex(where: { $0 == selectedTrack }) ?? 0
            let required = base + payload.items.map(\.row).max()! + 1
            checkpoint()
            while targets.count < required {
                let row = targets.count - base
                let name = NameRules.normalized(payload.items.first(where: { $0.row == row })?.trackName ?? "Audio " + String(format: "%02d", targets.count + 1))
                let track = Track(name: name.isEmpty ? "Audio" : name)
                project.tracks.append(track); targets.append(track.id)
            }
            selection = []
            for item in payload.items.sorted(by: { $0.clip.order < $1.clip.order }) {
                var clip = item.clip; clip.id = UUID(); clip.start += cursor; clip.order = project.nextOrder; project.nextOrder += 1
                let index = project.tracks.firstIndex { $0.id == targets[base + item.row] }!
                project.tracks[index].clips.append(clip); selection.insert(clip.id)
            }
            selectedTrack = targets[base]; update()
        } catch { self.error(error) }
    }
    func normalize(to level: Double, completion: (() -> Void)? = nil) {
        guard !busy else { completion?(); return }
        let clips = project.tracks.flatMap(\.clips).filter { selection.contains($0.id) }
        guard !clips.isEmpty else { notifications.show("Select fragments to normalize", style: .hint); completion?(); return }
        do { try FragmentNormalization.validate(level) } catch { self.error(error); completion?(); return }
        let rate = audio.sampleRate, cached = audio.cache
        isNormalizing = true; update()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                var prepared: [String: AudioData] = [:], gains: [UUID: Double] = [:]
                for clip in clips {
                    let data: AudioData
                    if let available = prepared[clip.source] ?? cached[clip.source] { data = available }
                    else { data = try AudioStore.decode(URL(fileURLWithPath: clip.source), sampleRate: rate) }
                    prepared[clip.source] = data
                    gains[clip.id] = FragmentNormalization.gain(for: clip, data: data, sampleRate: rate, level: level)
                }
                let results = gains, cache = prepared
                DispatchQueue.main.async { [self] in
                    checkpoint()
                    for i in project.tracks.indices {
                        for j in project.tracks[i].clips.indices {
                            if let gain = results[project.tracks[i].clips[j].id] { project.tracks[i].clips[j].gain = gain }
                        }
                    }
                    for (path, data) in cache { audio.cache[path] = data }
                    project.normalizationLevel = level; isNormalizing = false; update("Normalization completed"); completion?()
                }
            } catch {
                DispatchQueue.main.async { [self] in isNormalizing = false; self.error(error); completion?() }
            }
        }
    }
    func setFragmentSettings(_ id: UUID, settings: FragmentSettings, peak: Double) throws {
        guard !busy, let i = project.tracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }),
              let j = project.tracks[i].clips.firstIndex(where: { $0.id == id }) else { return }
        let original = project.tracks[i].clips[j]
        let edited = try settings.applying(to: original, peak: peak)
        guard FragmentSettings(edited) != FragmentSettings(original) else { return }
        checkpoint(); project.tracks[i].clips[j] = edited; update("Fragment updated")
    }
    func fragmentsAreMuted(_ ids: Set<UUID>) -> Bool {
        let clips = project.tracks.flatMap(\.clips).filter { ids.contains($0.id) }
        return !clips.isEmpty && clips.allSatisfy(\.muted)
    }
    func toggleFragmentMute(_ ids: Set<UUID>? = nil) {
        guard !busy else { return }
        let targets = ids ?? selection
        guard project.tracks.flatMap(\.clips).contains(where: { targets.contains($0.id) }) else {
            notifications.show("Select fragments to mute or unmute", style: .hint); return
        }
        let muted = !fragmentsAreMuted(targets)
        checkpoint()
        for i in project.tracks.indices {
            for j in project.tracks[i].clips.indices where targets.contains(project.tracks[i].clips[j].id) { project.tracks[i].clips[j].muted = muted }
        }
        update()
    }
    func fragmentLayerNeighbor(_ id: UUID, up: Bool) -> UUID? {
        guard let track = project.tracks.first(where: { $0.clips.contains(where: { $0.id == id }) }) else { return nil }
        let clips = track.clips.sorted { $0.order < $1.order }
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
        let clip = clips[index]
        let candidates = up ? Array(clips.dropFirst(index + 1)) : Array(clips.prefix(index).reversed())
        return candidates.first { $0.start < clip.end && $0.end > clip.start }?.id
    }
    private func fragmentLayerChanges(_ ids: Set<UUID>, up: Bool) -> [(index: Int, clips: [Clip])] {
        var changes: [(Int, [Clip])] = []
        for index in project.tracks.indices {
            let original = project.tracks[index].clips.sorted { $0.order < $1.order }
            var clips = original
            let moving = original.filter { ids.contains($0.id) }
            // Process the leading edge first so selected neighbors move together
            // rather than swapping with each other or undoing each other's moves.
            for clip in up ? Array(moving.reversed()) : moving {
                guard let from = clips.firstIndex(where: { $0.id == clip.id }) else { continue }
                let candidates = up ? Array(clips.indices.dropFirst(from + 1)) : Array(clips.indices.prefix(from).reversed())
                guard let to = candidates.first(where: { !ids.contains(clips[$0].id) && clips[$0].start < clip.end && clips[$0].end > clip.start }) else { continue }
                clips.insert(clips.remove(at: from), at: to)
            }
            if clips.map(\.id) != original.map(\.id) { changes.append((index, clips)) }
        }
        return changes
    }
    func canMoveFragmentLayers(_ ids: Set<UUID>, up: Bool) -> Bool { !fragmentLayerChanges(ids, up: up).isEmpty }
    func moveFragmentLayer(_ id: UUID, up: Bool) { moveFragmentLayers([id], up: up) }
    func moveFragmentLayers(_ ids: Set<UUID>, up: Bool) {
        guard !busy else { return }
        let changes = fragmentLayerChanges(ids, up: up)
        guard !changes.isEmpty else { return }
        checkpoint()
        for change in changes {
            var clips = change.clips
            for i in clips.indices { clips[i].order = project.nextOrder; project.nextOrder += 1 }
            project.tracks[change.index].clips = clips
        }
        update()
    }
    func importAudio() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var placement = AudioImportPlacement.singleTrack
        if panel.urls.count > 1 {
            guard let chosen = ImportPlacementDialog().runModal() else { return }
            placement = chosen
        }
        importAudio(urls: panel.urls, placement: placement)
    }
    func importAudio(urls: [URL], placement: AudioImportPlacement = .singleTrack) {
        guard !busy, !urls.isEmpty else { return }
        if player != nil { stop() }
        importer?.close()
        let job = AudioImportController(editor: self, urls: urls, placement: placement)
        importer = job; job.startImport()
    }
    func finishAudioImport(_ imported: [ImportedAudio], track: UUID?, start: Double, placement: AudioImportPlacement = .singleTrack) {
        guard !imported.isEmpty else { update(); return }
        checkpoint()
        var targets: [UUID]
        switch placement {
        case .singleTrack:
            var target = project.tracks.firstIndex { $0.id == track }
            if target == nil { project.tracks.append(Track(name: "Audio 01")); target = project.tracks.count - 1 }
            targets = Array(repeating: project.tracks[target!].id, count: imported.count)
        case .separateTracks:
            // Use the same hierarchy order as the visible timeline, including children.
            let ordered = TrackHierarchy.orderedRows(project.tracks).map { $0.0.id }
            let first = ordered.firstIndex(where: { $0 == track }) ?? 0
            targets = Array(ordered.dropFirst(first).prefix(imported.count))
            while targets.count < imported.count {
                let name = NameRules.normalized(imported[targets.count].name)
                let added = Track(name: name.isEmpty ? "Audio " + String(format: "%02d", project.tracks.count + 1) : name)
                project.tracks.append(added); targets.append(added.id)
            }
        }
        selectedTrack = targets[0]
        var position = start, clips: [Clip] = []
        for (index, item) in imported.enumerated() {
            // Publish prepared data under the final source path before the first draw.
            audio.cache[item.url.path] = item.data
            let clip = Clip(name: item.name, source: item.url.path, start: position, duration: Double(item.data.frameCount) / audio.sampleRate, order: project.nextOrder + index)
            let target = project.tracks.firstIndex { $0.id == targets[index] }!
            project.tracks[target].clips.append(clip); clips.append(clip)
            if placement == .singleTrack { position += clip.duration }
        }
        project.nextOrder += clips.count
        selection = Set(clips.map(\.id)); update("Imported \(clips.count) fragment(s)")
    }
    func record() {
        guard !busy else { return }
        if player != nil { stop() }
        requestingMic = true; update()
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }; self.requestingMic = false
                guard granted else { self.error(SounderError.message("Allow Sounder to use the microphone in System Settings → Privacy & Security → Microphone.")); return }
                do {
                    if self.selectedIndex == nil { self.addTrack() }
                    try self.startRecording()
                } catch { self.error(error) }
            }
        }
    }
    private func startRecording() throws {
        let url = audio.freshURL()
        do {
            let recorder = try makeRecorder(url, project.audioFormat)
            recorder.metronome.configure(bpm: project.tempo, enabled: project.metronomeEnabled, start: cursor)
            try recorder.start()
            activateRecording(recorder)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
    private func clearRecordingState() {
        recordingURL = nil; recordingTrack = nil
        recordingPeaks = []; recordingPartialPeak = nil
        recordingChannelPeaks = []; recordingPartialChannelPeaks = []
    }
    private func restartRecording() {
        guard let recorder else { return }
        let start = recordingStart, track = recordingTrack, url = recordingURL
        stopPlayback() // Invalidate the transport timer before replacing capture.
        _ = recorder.stop(); self.recorder = nil
        clearRecordingState()
        cursor = start; selectedTrack = track
        do {
            if let url { try FileManager.default.removeItem(at: url) }
            try startRecording()
        } catch { self.error(error) }
        update()
    }
    func activateRecording(_ recorder: LiveRecorder) {
        recorder.metronome.configure(bpm: project.tempo, enabled: project.metronomeEnabled, start: cursor)
        recordingPeaks = []; recordingPartialPeak = nil
        recordingChannelPeaks = Array(repeating: [], count: recorder.format.channels); recordingPartialChannelPeaks = Array(repeating: nil, count: recorder.format.channels)
        recordingURL = recorder.url; recordingTrack = selectedTrack; recordingStart = cursor
        self.recorder = recorder; startTimer(); update()
    }
    func showsTrackMeter(_ id: UUID) -> Bool { isPlaying || isRecording || (trackMeters[id]?.peak ?? 0) > 0 }
    private func updateTrackMeters(_ peaks: [UUID: Float], at time: Double = ProcessInfo.processInfo.systemUptime) {
        let ids = Set(project.tracks.map(\.id))
        trackMeters = trackMeters.filter { ids.contains($0.key) }
        for id in ids {
            var meter = trackMeters[id] ?? TrackLevelMeter()
            meter.update(Double(peaks[id] ?? 0), at: time); trackMeters[id] = meter
        }
    }
    private func stopTrackMeters() {
        for id in Array(trackMeters.keys) { trackMeters[id]?.level = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.isPlaying, !self.isRecording else { return }
            self.updateTrackMeters([:]); self.changed?()
        }
    }
    func updateRecordingWaveform() {
        guard let recorder else { return }
        let update = recorder.writer.consumeUpdate()
        recordingPeaks.append(contentsOf: update.peaks); recordingPartialPeak = update.partialPeak
        for channel in update.channelPeaks.indices { recordingChannelPeaks[channel].append(contentsOf: update.channelPeaks[channel]) }
        recordingPartialChannelPeaks = update.partialChannelPeaks
        cursor = recordingStart + Double(update.frames) / recorder.format.sampleRate
        if let recordingTrack {
            let peak = max(update.peaks.max() ?? 0, update.partialPeak ?? 0)
            updateTrackMeters([recordingTrack: peak])
        }
        if update.failure != nil { stop() }
    }
    func updateTransportPosition() {
        if recorder != nil { updateRecordingWaveform() }
        else if let player {
            cursor = player.currentTime
            updateTrackMeters(player.consumeTrackPeaks(at: cursor))
        }
        changed?()
    }
    func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.updateTransportPosition() }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        self.timer = timer
    }
    func pluginHost(_ effect: PluginEffect) throws -> SNPluginHost {
        if let host = pluginHosts[effect.id] { return host }
        let host = try SNPluginHost(path: effect.path, classID: effect.classID, state: effect.state, sampleRate: project.audioFormat.sampleRate)
        pluginHosts[effect.id] = host
        return host
    }
    func flushPluginEdits() { for window in Array(pluginWindows.values) { window.captureChanges() } }
    func closePluginWindows(capture: Bool = true) { for window in Array(pluginWindows.values) { window.close(capture: capture) } }
    func toggleTempoMode() { checkpoint(); project.tempoMode.toggle(); update() }
    func setTempo(_ bpm: Double) {
        guard bpm.isFinite, (20...300).contains(bpm), bpm != project.tempo else { return }
        checkpoint(); project.tempo = bpm; updateMetronome(); update("Tempo updated")
    }
    func toggleMetronome() {
        checkpoint(); project.metronomeEnabled.toggle(); updateMetronome(); update()
    }
    private func updateMetronome() {
        player?.setMetronome(tempo: project.tempo, enabled: project.metronomeEnabled)
        recorder?.metronome.configure(bpm: project.tempo, enabled: project.metronomeEnabled)
    }
    func toggleMute(_ trackID: UUID) {
        guard !isRecording, !requestingMic, !isImporting,
              let index = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        checkpoint()
        project.tracks[index].muted.toggle()
        player?.setMuted(project.tracks[index].muted, trackID: trackID)
        update()
    }
    func toggleSolo(_ trackID: UUID) {
        guard !isRecording, !requestingMic, !isImporting,
              let index = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        checkpoint()
        project.tracks[index].solo.toggle()
        player?.setSolo(Set(project.tracks.filter(\.solo).map(\.id)))
        update()
    }
    func effectsChanged() {
        let playing = isPlaying
        if player != nil { stop() }
        let ids = Set(project.tracks.flatMap(\.effects).map(\.id))
        pluginHosts = pluginHosts.filter { ids.contains($0.key) }
        if playing { startPlayback(rememberStart: false) }
    }
    // There is no retained paused stream: cursor is the sole stopped position.
    private func stopPlayback(at position: Double? = nil) {
        timer?.invalidate(); timer = nil
        guard let playback = player else { return }
        let stoppedPosition = position ?? playback.currentTime
        player = nil // Detach before stop can publish any completion callbacks.
        playback.stop()
        stopTrackMeters()
        cursor = stoppedPosition
    }
    func seek(to position: Double) {
        guard !isRecording, !requestingMic, !isImporting, position.isFinite else { return }
        let continuePlaying = isPlaying
        stopPlayback()
        cursor = max(0, position)
        if continuePlaying { startPlayback() } else { update() }
    }
    func playPause() {
        if isRecording {
            let start = recordingStart
            stop(); cursor = start; update(); return
        }
        guard !requestingMic, !isImporting else { return }
        if player != nil { stop(); return }
        startPlayback()
    }
    func restartFromLastStart() {
        if isRecording { restartRecording(); return }
        guard !requestingMic, !isImporting else { return }
        let start = lastPlaybackStart ?? 0
        stopPlayback()
        cursor = start
        startPlayback()
    }
    private func startPlayback(rememberStart: Bool = true) {
        do {
            guard duration > 0 else { return }
            flushPluginEdits()
            let graph = try StreamingGraph(project: project, store: audio) { effect in
                let host = try self.pluginHost(effect)
                try host.beginStreaming(self.project.audioFormat.channels)
                guard host.latency <= Int(self.audio.sampleRate * 30) else { throw SounderError.message("Plug-in latency exceeds the supported 30-second maximum") }
                let channels = self.project.audioFormat.channels
                return StreamingEffect(latency: host.latency, tail: host.tail) { samples in
                    let data = try host.processBlock(samples.withUnsafeBytes { Data($0) }, channels: channels)
                    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                }
            }
            let start = max(0, cursor)
            guard start < Double(graph.totalFrames) / audio.sampleRate else { update(); return }
            cursor = start
            let playback = try makePlayback(graph, project.audioFormat, start)
            playback.finished = { [weak self, weak playback] failure in
                guard let self, let playback, self.player === playback else { return }
                let returnPosition = self.lastPlaybackStart ?? playback.start
                self.stopPlayback(at: failure == nil ? returnPosition : playback.currentTime)
                self.update()
                if let failure { self.error(failure) }
            }
            player = playback
            playback.setMetronome(tempo: project.tempo, enabled: project.metronomeEnabled)
            try playback.startPlayback()
            cursor = playback.start
            if rememberStart { lastPlaybackStart = playback.start }
            startTimer(); update()
        } catch { player?.stop(); player = nil; self.error(error) }
    }
    func stopAndReturnToStart() {
        let start = isRecording ? recordingStart : (lastPlaybackStart ?? 0)
        stop(); cursor = start; update()
    }
    func stop() {
        stopPlayback()
        if let recorder {
            let failure = recorder.stop(); self.recorder = nil
            do {
                if let url = recordingURL, let index = project.tracks.firstIndex(where: { $0.id == recordingTrack }) {
                    let data = try audio.load(url.path)
                    guard data.frameCount > 0 else {
                        if let failure { throw failure }
                        throw SounderError.message("No audio was captured. Check the selected input device.")
                    }
                    checkpoint()
                    let clip = Clip(name: "\(project.tracks[index].name) \(project.tracks[index].nextTakeNumber)", source: url.path, start: recordingStart, duration: Double(data.frameCount) / audio.sampleRate, order: project.nextOrder)
                    project.tracks[index].nextTakeNumber += 1
                    project.nextOrder += 1; project.tracks[index].clips.append(clip); selection = [clip.id]
                    cursor = clip.end
                    if failure == nil { notifications.show("Recording saved", style: .success) }
                    else if let failure { self.error(SounderError.message("Recording interrupted; captured audio was saved. " + failure.localizedDescription)) }
                }
            } catch { self.error(error) }
        }
        clearRecordingState(); stopTrackMeters(); update()
    }
    func split() {
        guard !busy else { return }
        let targets = project.tracks.flatMap(\.clips).filter { selection.contains($0.id) && cursor > $0.start && cursor < $0.end }
        guard !targets.isEmpty else { notifications.show("Select a fragment and place the playhead inside it to split", style: .hint); return }
        checkpoint()
        for i in project.tracks.indices {
            var next: [Clip] = []
            for clip in project.tracks[i].clips {
                if targets.contains(where: { $0.id == clip.id }) {
                    var left = clip; var right = clip; right.id = UUID()
                    left.duration = cursor - clip.start; left.fadeOutBaked = false; right.fadeInBaked = false; right.start = cursor; right.offset += left.duration; right.duration -= left.duration
                    next += [left, right]; selection.insert(right.id)
                } else { next.append(clip) }
            }; project.tracks[i].clips = next
        }; update()
    }
    func trim() {
        guard !busy else { return }
        guard let range, !selection.isEmpty else { notifications.show("Drag over the ruler to select a range, then trim selected fragments", style: .hint); return }
        checkpoint()
        for i in project.tracks.indices {
            project.tracks[i].clips = project.tracks[i].clips.compactMap { original in
                guard selection.contains(original.id) else { return original }
                let start = max(original.start, range.lowerBound), end = min(original.end, range.upperBound)
                guard end > start else { return nil }
                var clip = original
                if start != original.start { clip.fadeInBaked = false }; if end != original.end { clip.fadeOutBaked = false }
                clip.offset += start - clip.start; clip.start = start; clip.duration = end - start; return clip
            }
        }; reconcile(); update("Trimmed to selected range")
    }
    func join() {
        guard !busy else { return }
        guard let index = selectedIndex else { notifications.show("Shift click at least two fragments on one track to join", style: .hint); return }
        let clips = project.tracks[index].clips.filter { selection.contains($0.id) }
        guard clips.count >= 2, let start = clips.map(\.start).min(), let end = clips.map(\.end).max() else { notifications.show("Shift click at least two fragments on one track to join", style: .hint); return }
        do {
            var subset = project; subset.tracks[index].clips = clips
            let samples = try audio.renderAudio(subset, range: start..<end, onlyTrack: project.tracks[index].id)
            let url = audio.freshURL(); try audio.write(samples, to: url); checkpoint()
            let clip = Clip(name: "Joined \(clips.count) fragments", source: url.path, start: start, duration: end - start, order: project.nextOrder, fadeInBaked: true, fadeOutBaked: true)
            project.nextOrder += 1; project.tracks[index].clips.removeAll { selection.contains($0.id) }; project.tracks[index].clips.append(clip); selection = [clip.id]; update("Fragments joined")
        } catch { self.error(error) }
    }
    func save(as: Bool = false) -> Bool {
        guard !isRecording, !isImporting, !isNormalizing else { return false }
        var destination = projectURL
        if destination == nil || `as` {
            let panel = NSSavePanel(); panel.nameFieldStringValue = suggestedFilename; panel.canCreateDirectories = true
            guard panel.runModal() == .OK else { return false }; destination = panel.url
        }
        do {
            let url = destination!; let fm = FileManager.default
            let media = url.appendingPathComponent("Media"); try fm.createDirectory(at: media, withIntermediateDirectories: true)
            flushPluginEdits()
            var saved = project
            saved.name = projectName
            for i in saved.tracks.indices { for j in saved.tracks[i].clips.indices {
                let original = URL(fileURLWithPath: saved.tracks[i].clips[j].source)
                let target = media.appendingPathComponent(original.lastPathComponent)
                if original.standardizedFileURL != target.standardizedFileURL && !fm.fileExists(atPath: target.path) { try fm.copyItem(at: original, to: target) }
                saved.tracks[i].clips[j].source = "Media/" + target.lastPathComponent
            } }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: url.appendingPathComponent("project.json"), options: .atomic)
            project.name = saved.name; projectURL = url; dirty = false; update("Saved \(url.lastPathComponent)"); return true
        } catch { self.error(error); return false }
    }
    func confirmDiscard() -> Bool {
        flushPluginEdits()
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to this project?"; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() { case .alertFirstButtonReturn: return save(); case .alertSecondButtonReturn: return true; default: return false }
    }
    func open() {
        guard !busy, confirmDiscard() else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var loaded = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url.appendingPathComponent("project.json")))
            try TrackHierarchy.validate(loaded.tracks)
            audio.configure(loaded.audioFormat)
            for i in loaded.tracks.indices {
                for j in loaded.tracks[i].clips.indices {
                    let c = loaded.tracks[i].clips[j]
                    guard c.start.isFinite, c.offset.isFinite, c.duration.isFinite, c.start >= 0, c.offset >= 0, c.duration > 0 else { throw SounderError.message("Invalid fragment timing") }
                    let source = url.appendingPathComponent(c.source).standardizedFileURL
                    guard source.path.hasPrefix(url.standardizedFileURL.path + "/") else { throw SounderError.message("Audio must be inside the project") }
                    let data = try audio.load(source.path)
                    guard c.offset + c.duration <= Double(data.frameCount) / audio.sampleRate + 0.001 else { throw SounderError.message("Fragment exceeds its audio file") }
                    loaded.tracks[i].clips[j].source = source.path
                }
            }
            loaded.nextOrder = max(loaded.nextOrder, (loaded.tracks.flatMap(\.clips).map(\.order).max() ?? 0) + 1)
            project = loaded; projectURL = url; undoStack = []; redoStack = []; selection = []; cursor = 0; lastPlaybackStart = nil; range = nil; dirty = false; reconcile(); update("Project opened")
        } catch { audio.configure(project.audioFormat); self.error(error) }
    }
    func export() {
        guard canExport else { return }
        let options = ExportOptionsController(settings: project.defaultExportSettings, range: range)
        guard let settings = options.runModal() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: settings.format.rawValue) ?? .audio]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = projectName.replacingOccurrences(of: "/", with: "-") + "." + settings.format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try export(to: url, settings: settings, range: options.selectedRange) } catch { self.error(error) }
    }
    func export(to url: URL, settings: ExportSettings, range: Range<Double>? = nil) throws {
        flushPluginEdits()
        try AudioExporter.write(project: project, store: audio, settings: settings, to: url, range: range)
        if settings != project.exportSettings || !project.exportSettingsConfirmed {
            checkpoint(); project.exportSettings = settings; project.exportSettingsConfirmed = true
        }
        update("Exported \(url.lastPathComponent)")
    }
}
