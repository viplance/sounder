import AppKit
import AVFoundation
import UniformTypeIdentifiers


/// Persist only successful opens/saves; tests can supply an isolated preferences suite.
final class RecentProjectHistory {
    struct Entry: Codable, Equatable {
        var path: String
        var name: String
        var url: URL { URL(fileURLWithPath: path) }
    }
    private static let key = "Sounder.recentProjects"
    private let preferences: UserDefaults?
    private(set) var entries: [Entry]
    var changed: (() -> Void)?

    init(preferences: UserDefaults?) {
        self.preferences = preferences
        let data = preferences?.data(forKey: Self.key)
        var seen = Set<String>()
        entries = Array(((data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? [])
            .filter { $0.path.hasPrefix("/") && seen.insert($0.path).inserted }.prefix(100))
    }
    func remember(_ url: URL, name: String) {
        let path = url.standardizedFileURL.path
        entries.removeAll { $0.path == path }
        entries.insert(Entry(path: path, name: name), at: 0)
        entries = Array(entries.prefix(100))
        persist()
    }
    func removeIfMissing(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let path = url.standardizedFileURL.path
        guard entries.contains(where: { $0.path == path }) else { return }
        entries.removeAll { $0.path == path }
        persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { preferences?.set(data, forKey: Self.key) }
        changed?()
    }
}

/// Main-thread preview state for one input; each writer owns conversion and disk I/O.
final class TrackRecording {
    let track: UUID?
    let recorder: LiveRecorder
    var start: Double
    var end: Double
    var cursor: Double
    var peaks: [Float] = []
    var channelPeaks: [[Float]]
    var partialPeak: Float?
    var partialChannelPeaks: [Float?]
    init(track: UUID?, recorder: LiveRecorder, start: Double) {
        self.track = track; self.recorder = recorder; self.start = start; end = start; cursor = start
        channelPeaks = Array(repeating: [], count: recorder.format.channels)
        partialChannelPeaks = Array(repeating: nil, count: recorder.format.channels)
    }
    func consumeUpdate() -> (levels: StereoLevels, failure: Error?) {
        let update = recorder.writer.consumeUpdate()
        if let loop = update.loop {
            let count = (loop.frameCount + 127) / 128
            if loop.resetWaveform {
                channelPeaks = Array(repeating: Array(repeating: 0, count: count), count: recorder.format.channels)
                peaks = Array(repeating: 0, count: count)
            } else if peaks.count < count {
                peaks.append(contentsOf: repeatElement(0, count: count - peaks.count))
                for channel in channelPeaks.indices {
                    channelPeaks[channel].append(contentsOf: repeatElement(0, count: count - channelPeaks[channel].count))
                }
            }
            for (index, peaks) in loop.peakPatches where index < count {
                for channel in peaks.indices { channelPeaks[channel][index] = peaks[channel] }
                self.peaks[index] = peaks.max() ?? 0
            }
            partialPeak = nil; partialChannelPeaks = Array(repeating: nil, count: recorder.format.channels)
            start = Double(loop.startFrame) / recorder.format.sampleRate
            end = Double(loop.startFrame + loop.frameCount) / recorder.format.sampleRate
            cursor = Double(loop.cursorFrame) / recorder.format.sampleRate
        } else {
            peaks.append(contentsOf: update.peaks); partialPeak = update.partialPeak
            for channel in update.channelPeaks.indices { channelPeaks[channel].append(contentsOf: update.channelPeaks[channel]) }
            partialChannelPeaks = update.partialChannelPeaks
            cursor = start + Double(update.frames) / recorder.format.sampleRate
            end = cursor
        }
        func channelPeak(_ channel: Int) -> Float {
            guard !update.partialChannelPeaks.isEmpty else { return 0 }
            let index = min(channel, update.partialChannelPeaks.count - 1)
            if update.loop != nil { return update.partialChannelPeaks[index] ?? 0 }
            return max(update.channelPeaks[index].max() ?? 0, update.partialChannelPeaks[index] ?? 0)
        }
        return (StereoLevels(left: channelPeak(0), right: channelPeak(1)), update.failure)
    }
}

final class Editor: NSObject {
    // App controllers opt into nonblocking preparation; synchronous operation
    // remains available for deterministic offline audio clients/tests.
    var preparesPlaybackInBackground = false { didSet { if preparesPlaybackInBackground { scheduleIdlePreparation() } else { idlePreparation?.cancel() } } }
    var keepsPluginsRunning = false {
        didSet {
            if keepsPluginsRunning {
                do {
                    midiInput = try LiveMIDIInput(received: { [weak self] messages in
                        DispatchQueue.main.async { self?.receiveMIDI(messages) }
                    }, disconnected: { [weak self] source in self?.releaseMIDI(source: source) })
                } catch { self.error(error) }
                scheduleLiveEffects()
            } else { midiInput = nil; releaseMIDI(); discardLiveEffects() }
        }
    }
    private var midiInput: LiveMIDIInput?
    private var midiRecipients: [UInt64: [UUID: SNPluginHost]] = [:]
    private var effectsJob: PlaybackPreparation?
    private var effectsJobKey: Data?
    private(set) var liveEffectsPlayer: LivePlayback?
    private var liveEffectsKey: Data?
    private struct LiveEffectsConfiguration: Equatable {
        let format: ProjectAudioFormat
        let output: AudioEndpoint
        let buffer: Int
    }
    private var liveEffectsConfiguration: LiveEffectsConfiguration?
    private var failedEffectsKey: Data?
    private var effectsMeterTimer: Timer?
    var isMeteringAudio: Bool {
        isPlaying || isRecording || liveEffectsPlayer?.isAuditioningEffects == true ||
            pausedPlayer.map { !$0.pauseComplete || $0.isAuditioningEffects } == true
    }
    func shutdownLivePlugins() { keepsPluginsRunning = false }
    private func cancelEffectsPreparation() { effectsJob?.cancel(); effectsJob = nil; effectsJobKey = nil }
    private func discardLiveEffects() {
        cancelEffectsPreparation(); effectsMeterTimer?.invalidate(); effectsMeterTimer = nil
        let previous = liveEffectsPlayer; liveEffectsPlayer = nil; liveEffectsKey = nil; liveEffectsConfiguration = nil
        previous?.stop()
    }
    private func releaseMIDI(source: UInt32? = nil) {
        let keys = midiRecipients.keys.filter { source == nil || $0 >> 4 == UInt64(source!) }
        for key in keys { midiRecipients.removeValue(forKey: key)?.values.forEach { $0.allNotesOff() } }
    }
    func receiveMIDI(_ messages: [LiveMIDIMessage]) {
        let targets = Set(recordingTargets)
        var recipients: [UUID: SNPluginHost] = [:]
        for track in project.tracks where targets.contains(track.id) && !track.effectsBypassed {
            for effect in track.effects where !effect.bypassed {
                if let host = pluginHosts[effect.id], host.acceptsMIDI { recipients[effect.id] = host }
            }
        }
        if !project.masterEffectsBypassed {
            for effect in project.masterEffects where !effect.bypassed {
                if let host = pluginHosts[effect.id], host.acceptsMIDI { recipients[effect.id] = host }
            }
        }
        for message in messages {
            let key = UInt64(message.source) << 4 | UInt64(message.status & 15)
            var hosts = midiRecipients[key] ?? [:]
            for (id, host) in recipients { hosts[id] = host }
            let noteOn = message.status & 0xF0 == 0x90 && message.data2 > 0
            for host in (noteOn ? recipients : hosts).values { host.sendMIDIStatus(message.status, data1: message.data1, data2: message.data2) }
            midiRecipients[key] = hosts
        }
    }
    private func startEffectsMeters() {
        guard effectsMeterTimer == nil else { return }
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self, !self.isPlaying, !self.isRecording,
                  let monitor = self.liveEffectsPlayer ?? self.pausedPlayer, monitor.isProcessingLiveEffects else { return }
            let peaks = monitor.consumeEffectsPeaks()
            guard !peaks.isEmpty else { return } // No new output yet; retain the last real sample.
            self.updateTrackMeters(peaks, effectsOnly: true)
            self.transportChanged?()
        }
        effectsMeterTimer = timer; RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
    }
    private func watchLiveEffects(_ playback: LivePlayback, key: Data) {
        playback.finished = { [weak self, weak playback] error in
            guard let self, let playback, self.liveEffectsPlayer === playback, let error else { return }
            self.liveEffectsPlayer = nil; self.liveEffectsKey = nil; self.failedEffectsKey = key
            playback.stop(); self.stopTrackMeters(); self.error(error)
        }
        startEffectsMeters()
    }
    private func scheduleLiveEffects() {
        guard keepsPluginsRunning, !isPlaying, !isRecording, !isShuttling, !requestingMic,
              !isImporting, !isOpening, !isExporting, !isNormalizing,
              preparation == nil, preparationRequest == nil else { return }
        // Pause owns the processor even while its audible source fade is still
        // queued. isAuditioningEffects becomes true only after that fade drains.
        if pausedPlayer != nil { cancelEffectsPreparation(); startEffectsMeters(); return }
        guard player == nil else { return }
        guard !project.activeEffects.isEmpty else { discardLiveEffects(); return }
        guard let key = try? mixCacheKey(), failedEffectsKey != key else { return }
        let config = LiveEffectsConfiguration(format: project.audioFormat, output: project.defaultOutput, buffer: project.playbackBufferSize)
        if liveEffectsKey == key, let liveEffectsPlayer, liveEffectsPlayer.isAuditioningEffects {
            liveEffectsPlayer.setEffectsPosition(cursor, tempo: project.tempo); return
        }
        guard effectsJobKey != key else { return }
        cancelEffectsPreparation()
        let job = PlaybackPreparation(), snapshot = project, directory = audio.directory
        let hosts = pluginHosts, position = cursor
        effectsJob = job; effectsJobKey = key
        preparationQueue.async { [weak self] in
            do {
                try job.check()
                let store = try AudioStore(directory: directory); store.configure(snapshot.audioFormat)
                var processors: [UUID: SNPluginHost] = [:]
                for effect in snapshot.activeEffects {
                    try job.check()
                    processors[effect.id] = try hosts[effect.id] ?? SNPluginHost(path: effect.path, classID: effect.classID, state: effect.state, sampleRate: snapshot.audioFormat.sampleRate)
                }
                let graph = try Self.makeGraph(project: snapshot, store: store, hosts: processors, cancelled: { job.isCancelled }, preservePluginState: true, includeAudioSources: false)
                try job.check()
                let ready = processors
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.effectsJob === job, !job.isCancelled else { return }
                    guard (try? self.mixCacheKey()) == key, self.player == nil, self.pausedPlayer == nil,
                          !self.isRecording, self.preparation == nil, self.preparationRequest == nil,
                          !ready.contains(where: { id, host in self.pluginHosts[id].map { $0 !== host } ?? false }) else {
                        self.cancelEffectsPreparation(); self.scheduleLiveEffects(); return
                    }
                    self.pluginHosts.merge(ready) { current, _ in current }
                    if self.liveEffectsConfiguration == config, let existing = self.liveEffectsPlayer, existing.isProcessingLiveEffects {
                        existing.replaceEffectsGraph(graph, at: self.cursor, hosts: Array(ready.values), tempo: snapshot.tempo)
                        self.liveEffectsKey = key; self.effectsJob = nil; self.effectsJobKey = nil; self.startEffectsMeters()
                        return
                    }
                    let previous = self.liveEffectsPlayer, factory = self.makePlayback, worker = self.preparationQueue
                    worker.async { [weak self] in
                        do {
                            try job.check(); previous?.stop(); try job.check()
                            let monitor = try factory(graph, snapshot.audioFormat, position)
                            try monitor.configureBufferSize(snapshot.playbackBufferSize); try monitor.configureOutput(snapshot.defaultOutput)
                            try job.check()
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.effectsJob === job, !job.isCancelled,
                                      self.player == nil, self.pausedPlayer == nil, self.preparationRequest == nil else {
                                    worker.async { monitor.stop() }; return
                                }
                                // Publish ownership BEFORE starting DSP. Play/Stop
                                // can now cancel/join this engine even if its ready
                                // callback has not yet reached the main thread.
                                self.liveEffectsPlayer = monitor; self.liveEffectsKey = key; self.liveEffectsConfiguration = config
                                monitor.finished = { [weak self, weak monitor] failure in
                                    guard let self, let monitor, let failure, self.effectsJob === job else { return }
                                    self.cancelEffectsPreparation(); self.failedEffectsKey = key
                                    if self.liveEffectsPlayer === monitor { self.liveEffectsPlayer = nil; self.liveEffectsKey = nil }
                                    worker.async { monitor.stop() }; self.error(failure)
                                }
                                worker.async { [weak self] in
                                    do {
                                        try job.check()
                                        try monitor.startEffects(at: position, hosts: Array(ready.values), tempo: snapshot.tempo)
                                        try job.check()
                                        DispatchQueue.main.async { [weak self] in
                                            guard let self, self.effectsJob === job, !job.isCancelled,
                                                  self.liveEffectsPlayer === monitor else {
                                                worker.async { monitor.stop() }; return
                                            }
                                            self.effectsJob = nil; self.effectsJobKey = nil
                                            self.watchLiveEffects(monitor, key: key)
                                        }
                                    } catch {
                                        monitor.stop()
                                        DispatchQueue.main.async { [weak self] in
                                            guard let self, self.effectsJob === job else { return }
                                            self.effectsJob = nil; self.effectsJobKey = nil
                                            if self.liveEffectsPlayer === monitor { self.liveEffectsPlayer = nil; self.liveEffectsKey = nil }
                                            if !job.isCancelled { self.failedEffectsKey = key; self.error(error) }
                                        }
                                    }
                                }
                            }
                        } catch {
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.effectsJob === job else { return }
                                self.effectsJob = nil; self.effectsJobKey = nil
                                if !job.isCancelled { self.failedEffectsKey = key; self.error(error) }
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.effectsJob === job else { return }
                    self.effectsJob = nil; self.effectsJobKey = nil
                    if !job.isCancelled { self.failedEffectsKey = key; self.error(error) }
                }
            }
        }
    }
    private let preparationQueue = DispatchQueue(label: "Sounder.playback.prepare", qos: .userInitiated)
    private var preparation: PlaybackPreparation?
    private var preparationTarget: (key: Data, start: Double)?
    private struct PlaybackRequest {
        let rememberStart: Bool
        let forRecording: Bool
        let completed: (() -> Void)?
    }
    // Survives invalidation while the replacement graph is being prepared.
    // Only explicit transport cancellation or completion clears the request.
    private var preparationRequest: PlaybackRequest?
    private var idlePreparation: DispatchWorkItem?
    private(set) var standbyPlayer: LivePlayback?
    private var standbyKey: Data?
    var isPreparingPlayback: Bool { preparationRequest != nil }
    var isPrebuffering: Bool { preparation != nil && preparationRequest == nil }
    var canEditPlaybackBuffer: Bool {
        !isPlaying && !isRecording && !isShuttling && !isPreparingPlayback && !isPrebuffering && !requestingMic && !isExporting && !isImporting && !isOpening
    }
    var playbackBufferLabel: String {
        PlaybackBufferSize.durationLabel(frames: project.playbackBufferSize, sampleRate: project.audioFormat.sampleRate)
    }
    func setPlaybackBufferSize(_ frames: Int) throws {
        try PlaybackBufferSize.validate(frames)
        guard canEditPlaybackBuffer, frames != project.playbackBufferSize else { return }
        checkpoint(); project.playbackBufferFrames = frames; update()
    }
    func editPlaybackBuffer(using edit: (Int) -> Int?) throws {
        guard canEditPlaybackBuffer else { return }
        idlePreparation?.cancel(); idlePreparation = nil
        defer { scheduleIdlePreparation() }
        if let frames = edit(project.playbackBufferSize) { try setPlaybackBufferSize(frames) }
    }
    private var preparedPosition: Double { (max(0, cursor) * project.audioFormat.sampleRate).rounded() / project.audioFormat.sampleRate }

    var bufferPercent: Double {
        if let player { return player.bufferFill.percent }
        if let shuttle { return shuttle.bufferFill.percent }
        var retained = 0.0
        if let graph = mixCache?.graph {
            let first = max(0, Int(cursor * project.audioFormat.sampleRate)) + graph.latency
            let capacity = project.playbackBufferSize
            let end = min(graph.totalFrames + graph.latency, first + capacity)
            if end > first { retained = graph.outputCache.retainedReadiness(in: first..<end) }
            else { retained = graph.outputCache.retainedReadiness(in: 0..<0) }
        }
        if let ready = standbyPlayer, ready.start == preparedPosition { return 100 }
        // Retained PCM is only the source stage. It cannot certify that live
        // processors/history and the first queued buffers are ready to start.
        return max(min(40, retained), preparation?.bufferPercent ?? 0)
    }
    var bufferDescription: String {
        if let preparation { return preparation.description + " · existing audio remains cached" }
        if isPlaying || isRecording { return "Prepared audio in the playback queue" }
        return "Retained audio cache · next playback position is prepared automatically"
    }
    private func discardStandbyPlayback() {
        let standby = standbyPlayer; standbyPlayer = nil; standbyKey = nil
        standby?.stop()
    }
    private func cancelPlaybackPreparation() {
        idlePreparation?.cancel(); idlePreparation = nil
        preparation?.cancel(); preparation = nil; preparationTarget = nil; preparationRequest = nil
    }
    private func scheduleIdlePreparation() {
        idlePreparation?.cancel(); idlePreparation = nil
        if preparation == nil, preparationRequest != nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.preparation == nil, let request = self.preparationRequest else { return }
                self.preparePlayback(request)
            }
            idlePreparation = work
            DispatchQueue.main.async(execute: work)
            return
        }
        if keepsPluginsRunning {
            scheduleLiveEffects()
            if !project.activeEffects.isEmpty { return }
        }
        guard preparesPlaybackInBackground, !isPlaying, !isRecording, !isShuttling,
              !requestingMic, !isExporting, !isImporting, !isOpening, !isNormalizing, !isPreparingPlayback,
              duration > 0, preparedPosition < duration, !(pausedPlayer != nil && pausedCursorIsCurrent) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying, !self.isRecording, !self.isShuttling,
                  !self.requestingMic, !self.isExporting, !self.isImporting, !self.isOpening, !self.isNormalizing, !self.isPreparingPlayback else { return }
            self.preparePlayback(rememberStart: false, forRecording: false, speculative: true)
        }
        idlePreparation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    var project = Project()
    private static let playbackBufferPreference = "playbackBufferFrames"
    private let preferences: UserDefaults?
    let audio: AudioStore
    var selectedTrack: UUID?
    var selection = Set<UUID>()
    var cursor = 0.0
    private(set) var lastPlaybackStart: Double?
    private(set) var playbackScrollRequest: UInt64 = 0
    var range: ClosedRange<Double>? { didSet { updateLoop() } }
    var zoom = 70.0
    var captureTimelineView: (() -> TimelineViewState?)?
    private(set) var timelineViewRestoreID: UInt64 = 0
    var changed: (() -> Void)?
    var transportChanged: (() -> Void)?
    let notifications: ToastCenter
    var undoStack: [Project] = []
    var redoStack: [Project] = []
    var dirty = false
    var projectURL: URL?
    let recentProjects: RecentProjectHistory
    var projectOpened: (() -> Void)?
    var player: LivePlayback?
    private var pausedPlayer: LivePlayback?
    private var pausedMixKey: Data?
    private var followsPausedCursor = false
    private var pausedCursorSnapshot: Double?
    private var pausedCursorIsCurrent: Bool { followsPausedCursor && pausedCursorSnapshot == cursor }
    private(set) var shuttle: ShuttlePlayback?
    private var shuttleGesture: (direction: Double, resume: Bool)?
    private var shuttleReleasing = false
    private var mixCache: (key: Data, graph: StreamingGraph)?
    func invalidateMixCache() {
        let request = preparationRequest
        cancelPlaybackPreparation()
        preparationRequest = request
        discardStandbyPlayback(); mixCache = nil; discardPausedPlayback()
    }
    private func discardPausedPlayback() {
        guard let paused = pausedPlayer else { return }
        if pausedCursorIsCurrent { cursor = paused.currentTime }
        pausedPlayer = nil; pausedMixKey = nil; followsPausedCursor = false
        timer?.invalidate(); timer = nil
        paused.stop()
    }
    private func mixCacheKey() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var renderProject = project; renderProject.timelineRange = nil; renderProject.timelineCursor = 0; renderProject.timelineView = nil
        return try encoder.encode(renderProject)
    }
    var isShuttling: Bool { shuttleGesture != nil }
    private(set) var trackMeters: [UUID: StereoTrackLevelMeter] = [:]
    private let makeRecorder: ((URL, ProjectAudioFormat) throws -> LiveRecorder)?
    private let makePlayback: (StreamingGraph, ProjectAudioFormat, Double) throws -> LivePlayback
    var pluginHosts: [UUID: SNPluginHost] = [:]
    var pluginWindows: [UUID: PluginEditorWindow] = [:]
    var effectsWindows: [UUID: EffectsWindow] = [:]
    private(set) var recordings: [TrackRecording] = []
    var recorder: LiveRecorder? { recordings.first?.recorder }
    var recordingPeaks: [Float] { recordings.first?.peaks ?? [] }
    var recordingChannelPeaks: [[Float]] { recordings.first?.channelPeaks ?? [] }
    var recordingPartialChannelPeaks: [Float?] { recordings.first?.partialChannelPeaks ?? [] }
    var recordingPartialPeak: Float? { recordings.first?.partialPeak }
    var recordingURL: URL? { recorder?.url }
    var recordingTrack: UUID? { recordings.first?.track }
    var recordingStart: Double { recordings.first?.start ?? recordingOrigin }
    var recordingEnd: Double { recordings.first?.end ?? 0 }
    func recording(for track: UUID) -> TrackRecording? { recordings.first { $0.track == track } }
    var recordingTargets: [UUID] {
        let armed = TrackHierarchy.orderedRows(project.tracks).map { $0.0 }.filter(\.recordArmed).map(\.id)
        if !armed.isEmpty { return armed }
        return project.tracks.first(where: { $0.id == selectedTrack }).map { [$0.id] } ?? []
    }
    var canArmTracks: Bool { !isRecording && !isShuttling && !requestingMic && !isExporting && !isImporting && !isOpening && !isNormalizing }
    func toggleRecordArm(_ id: UUID) {
        guard canArmTracks, let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        checkpoint(); project.tracks[index].recordArmed.toggle(); update()
    }
    private var recordingOrigin = 0.0
    private var pendingRecordedSources = Set<String>()
    private var recordedSourceCleanup: [String: String] = [:]
    var timer: Timer?
    var projectOpener: ProjectOpenController?
    var isOpening: Bool { projectOpener?.isRunning == true }
    var pluginInstaller: PluginInstallController?
    private var pendingPluginActivations: [() -> Void] = []
    func activateInstalledPlugin(_ url: URL, completed: @escaping (URL) -> Void) {
        if canEditEffects { completed(url) }
        else { pendingPluginActivations.append { completed(url) } }
    }
    var isInstallingPlugin: Bool { pluginInstaller?.isRunning == true }
    func installPlugin(_ plugin: CatalogPlugin, completed: @escaping (URL) -> Void) {
        guard canEditEffects, !isInstallingPlugin else { return }
        if let installed = plugin.installed(in: PluginProcessing.installed()) { completed(installed); return }
        pluginInstaller?.close()
        let job = PluginInstallController(plugin: plugin); pluginInstaller = job
        job.stateChanged = { [weak self] in self?.update() }
        job.completed = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                for window in self.effectsWindows.values { window.scan() }
                self.activateInstalledPlugin(url, completed: completed)
            case .failure(let error): if !(error is CancellationError) { self.error(error) }
            }
        }
        job.closed = { [weak self, weak job] in
            if self?.pluginInstaller === job { self?.pluginInstaller = nil; self?.update() }
        }
        job.start()
    }
    var importer: AudioImportController?
    private(set) var isNormalizing = false
    var isImporting: Bool { importer?.isRunning == true }
    var exporter: AudioExportController?
    var isExporting: Bool { exporter?.isRunning == true }
    var requestingMic = false
    var isRecording: Bool { recorder != nil }
    var isPlaying: Bool { player?.isPlaying == true || shuttle?.isPlaying == true }
    var canRecord: Bool { !isPreparingPlayback && !isRecording && !isShuttling && !requestingMic && !isExporting && !isImporting && !isOpening && !isNormalizing }
    var busy: Bool { isInstallingPlugin || isPreparingPlayback || isRecording || isPlaying || isShuttling || requestingMic || isExporting || isImporting || isOpening || isNormalizing }
    var canExport: Bool { !busy && duration > 0 }
    var duration: Double { project.tracks.flatMap(\.clips).map(\.end).max() ?? 0 }
    var projectName: String { project.name ?? projectURL?.deletingPathExtension().lastPathComponent ?? "MY PROJECT" }
    var suggestedFilename: String { projectName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".sounder" }
    var selectedIndex: Int? { project.tracks.firstIndex { $0.id == selectedTrack } }
    init(store: AudioStore, notifications: ToastCenter = ToastCenter(), preferences: UserDefaults? = nil,
         makeRecorder: ((URL, ProjectAudioFormat) throws -> LiveRecorder)? = nil,
         makePlayback: @escaping (StreamingGraph, ProjectAudioFormat, Double) throws -> LivePlayback = { LivePlayback(graph: $0, format: $1, start: $2) }) {
        recentProjects = RecentProjectHistory(preferences: preferences)
        audio = store; self.notifications = notifications; self.preferences = preferences
        self.makeRecorder = makeRecorder; self.makePlayback = makePlayback
        super.init()
        let preferred = preferences?.integer(forKey: Self.playbackBufferPreference) ?? 0
        project.playbackBufferFrames = (try? PlaybackBufferSize.validate(preferred)) != nil ? preferred : PlaybackBufferSize.initialFrames
        audio.configure(project.audioFormat)
        selectedTrack = project.tracks.first?.id
    }
    private func activatePendingPlugins() {
        guard canEditEffects && !pendingPluginActivations.isEmpty else { return }
        let pending = pendingPluginActivations; pendingPluginActivations = []
        pending.forEach { $0() }
    }
    func update(_ text: String? = nil) {
        activatePendingPlugins()
        if let text { notifications.show(text, style: .success) }
        for window in effectsWindows.values { window.refreshAvailability() }
        changed?()
        scheduleIdlePreparation()
    }
    func hint(_ key: UXHint, _ text: String) { notifications.hint(key, text) }
    func error(_ error: Error) { notifications.show(error.localizedDescription, style: .error); activatePendingPlugins(); changed?() }
    func setAudioInput(_ input: AudioEndpoint?, trackID: UUID? = nil) {
        guard !busy else { return }
        do {
            try input?.validate()
            if let trackID {
                guard let index = project.tracks.firstIndex(where: { $0.id == trackID }), project.tracks[index].input != input else { return }
                checkpoint(); project.tracks[index].input = input
            } else {
                let route = input ?? AudioEndpoint()
                guard project.defaultInput != route else { return }
                checkpoint(); project.defaultInput = route
            }
            update()
        } catch { self.error(error) }
    }
    func setAudioOutput(_ output: AudioEndpoint) {
        guard !busy, project.defaultOutput != output else { return }
        do { try output.validate(); checkpoint(); project.defaultOutput = output; update() }
        catch { self.error(error) }
    }
    func checkpoint() { invalidateMixCache(); undoStack.append(project); if undoStack.count > 50 { undoStack.removeFirst() }; redoStack = []; dirty = true }
    func undo() { guard !busy else { return }; flushPluginEdits(); guard let previous = undoStack.popLast() else { return }; redoStack.append(project); project = previous; dirty = true; reconcile(); update("Undo") }
    func redo() { guard !busy else { return }; flushPluginEdits(); guard let next = redoStack.popLast() else { return }; undoStack.append(project); project = next; dirty = true; reconcile(); update("Redo") }
    func reconcile() {
        discardLiveEffects(); releaseMIDI()
        invalidateMixCache()
        closePluginWindows(capture: false)
        pluginHosts = [:]
        for window in Array(effectsWindows.values) {
            if window.exists { window.reload(notifyEditor: false) } else { window.done() }
        }
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
        discardLiveEffects(); releaseMIDI()
        flushPluginEdits(); checkpoint(); closePluginWindows(capture: false); pluginHosts = [:]
        project.audioFormat = format; audio.configure(format)
        update("Audio format: " + format.label)
    }
    func addTrack(nested: Bool = false) {
        guard !busy else { return }
        let track = Track(name: "Audio " + String(format: "%02d", project.tracks.count + 1), parent: nested ? selectedTrack : nil)
        do { try TrackHierarchy.validate(project.tracks + [track]) }
        catch { notifications.show(TrackHierarchy.limitMessage, style: .hint); return }
        var insertion = project.tracks.endIndex
        if let active = project.tracks.first(where: { $0.id == selectedTrack }) {
            if nested {
                insertion = project.tracks.firstIndex(where: { $0.parent == active.id }) ?? (selectedIndex! + 1)
            } else {
                // A new root follows the active root's entire subtree, keeping
                // children together even when the active row is nested.
                var root = active
                while let parent = root.parent, let ancestor = project.tracks.first(where: { $0.id == parent }) { root = ancestor }
                let roots = project.tracks.filter { $0.parent == nil }
                if let index = roots.firstIndex(where: { $0.id == root.id }), index + 1 < roots.count {
                    insertion = project.tracks.firstIndex(where: { $0.id == roots[index + 1].id })!
                }
            }
        }
        checkpoint()
        project.tracks.insert(track, at: insertion); selectedTrack = track.id; selection = []; update(nested ? "Nested track added" : "Track added")
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
        let alert = ActionChoiceAlert(); alert.cancellationIndex = 1; alert.messageText = "Delete track?"; alert.informativeText = "This removes the track, its fragments and nested tracks. You can undo this action."; alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
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
    func setFragmentFade(_ id: UUID, left: Bool, durationMS: Double? = nil, curve: FadeCurve? = nil) {
        guard !busy, let i = project.tracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }),
              let j = project.tracks[i].clips.firstIndex(where: { $0.id == id }) else { return }
        let original = project.tracks[i].clips[j], edited = original.changingFade(left: left, durationMS: durationMS, curve: curve)
        guard FragmentSettings(original) != FragmentSettings(edited) else { return }
        checkpoint(); project.tracks[i].clips[j] = edited; update()
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
        guard EditorModalBackdrop.run({ panel.runModal() }) == .OK else { return }
        var placement = AudioImportPlacement.singleTrack
        if panel.urls.count > 1 {
            guard let chosen = ImportPlacementDialog().runModal() else { return }
            placement = chosen
        }
        importAudio(urls: panel.urls, placement: placement)
    }
    func importAudio(urls: [URL], placement: AudioImportPlacement = .singleTrack, destination: (track: UUID?, start: Double)? = nil) {
        guard !busy, !urls.isEmpty else { return }
        if player != nil || pausedPlayer != nil { stop() }
        importer?.close()
        let job = AudioImportController(editor: self, urls: urls, placement: placement, destination: destination)
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
            if let first = ordered.firstIndex(where: { $0 == track }) {
                targets = Array(ordered.dropFirst(first).prefix(imported.count))
            } else { targets = [] }
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
        guard canRecord else { return }
        requestingMic = true; update()
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }; self.requestingMic = false
                guard granted else { self.error(SounderError.message("Allow Sounder to use the microphone in System Settings → Privacy & Security → Microphone.")); return }
                do {
                    if self.recordingTargets.isEmpty {
                        self.checkpoint()
                        let track = Track(name: "Audio " + String(format: "%02d", self.project.tracks.count + 1))
                        self.project.tracks.append(track); self.selectedTrack = track.id
                    }
                    try self.startRecording()
                } catch { self.error(error) }
            }
        }
    }
    func startRecording(at position: Double? = nil, tracks: [UUID]? = nil) throws {
        if preparesPlaybackInBackground, player == nil {
            guard !isPreparingPlayback else { return }
            if let position { cursor = position }
            preparePlayback(rememberStart: true, forRecording: true) { [weak self] in
                guard let self else { return }
                do { try self.startRecording(at: position, tracks: tracks) } catch { self.error(error) }
            }
            return
        }
        let wasPlaying = isPlaying
        let targets = tracks ?? recordingTargets
        guard !targets.isEmpty else { throw SounderError.message("Select a track for recording") }
        var pending: [TrackRecording] = []
        do {
            // Prepare every input before starting capture. The backing mix and
            // its single metronome remain shared by all recording tracks.
            if let player { try player.prepareForRecording() }
            else { startPlayback(forRecording: true) }
            guard let player else { throw SounderError.message("Cannot start recording playback") }
            // Read source position and DAC time from one output timestamp. Two
            // reads can fall on opposite sides of a loop/queued seek boundary.
            let liveAnchor = wasPlaying ? player.recordingAnchor(at: position) : nil
            let origin = position ?? liveAnchor?.sourceTime ?? (wasPlaying ? player.currentTime : player.start)
            let captureClock = RecordingHostClock()
            // Freeze the output cycle before input setup can cross a loop wrap.
            let liveHost = liveAnchor?.hostTime
            if let liveHost { captureClock.set(hostTime: liveHost) }
            for id in targets {
                guard let track = project.tracks.first(where: { $0.id == id }) else { continue }
                let url = audio.freshURL()
                let capture: LiveRecorder
                do {
                    capture = try makeRecorder?(url, project.audioFormat) ?? LiveRecorder(url: url, format: project.audioFormat, input: track.input ?? project.defaultInput)
                } catch { try? FileManager.default.removeItem(at: url); throw error }
                pending.append(TrackRecording(track: id, recorder: capture, start: origin))
                if let loopRange { try capture.configureLoop(loopRange, start: origin) }
                capture.metronome.configure(bpm: project.tempo, enabled: false, start: origin)
                if !player.engine.isInManualRenderingMode { capture.configureSynchronization(clock: captureClock) }
            }
            guard !pending.isEmpty else { throw SounderError.message("Select a track for recording") }
            let timedCapture = pending.contains { $0.recorder.usesHardwareClock } && !player.engine.isInManualRenderingMode
            if wasPlaying && timedCapture {
                guard liveHost != nil else { throw SounderError.message("The playback audio clock is not ready for recording. Try Record again.") }
            }
            for take in pending { try take.recorder.start() }
            if !wasPlaying {
                if timedCapture {
                    // Capture is ready first. Schedule both timelines from a
                    // common future instant; discard microphone pre-roll.
                    let startSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time()) + 0.010
                    let host = AVAudioTime.hostTime(forSeconds: startSeconds)
                    captureClock.set(hostTime: AVAudioTime.hostTime(forSeconds: startSeconds + player.recordingOutputLatency))
                    player.beginPreparedPlayback(at: host)
                } else { player.beginPreparedPlayback() }
            }
            cursor = origin
            for take in pending { take.start = cursor; take.end = cursor; take.cursor = cursor }
            activateRecordings(pending)
        } catch {
            for take in pending { _ = take.recorder.stop(save: false); try? FileManager.default.removeItem(at: take.recorder.url) }
            if wasPlaying { player?.cancelRecordingPreparation() } else { stopPlayback() }
            throw error
        }
    }
    private func clearRecordingState() { recordings = [] }
    private func restartRecording() {
        guard !recordings.isEmpty else { return }
        let start = recordingOrigin, targets = recordings.compactMap(\.track)
        let previous = recordings
        timer?.invalidate(); timer = nil
        for take in previous {
            _ = take.recorder.stop(save: false)
            try? FileManager.default.removeItem(at: take.recorder.url)
        }
        clearRecordingState(); cursor = start
        do {
            player?.seek(to: start)
            try startRecording(at: start, tracks: targets)
        } catch { stopPlayback(); self.error(error) }
        update()
    }
    func activateRecording(_ recorder: LiveRecorder) {
        activateRecordings([TrackRecording(track: selectedTrack, recorder: recorder, start: cursor)])
    }
    private func activateRecordings(_ takes: [TrackRecording]) {
        recordings = takes; recordingOrigin = cursor
        for (index, take) in takes.enumerated() {
            take.recorder.metronome.configure(bpm: project.tempo, enabled: project.metronomeIsAudible && player == nil && index == 0, start: cursor)
        }
        startTimer(); update()
    }
    func showsTrackMeter(_ id: UUID) -> Bool { isPlaying || isRecording || (trackMeters[id]?.peak ?? 0) > 0 }
    func displayedTrackMeter(_ track: Track) -> StereoTrackLevelMeter {
        var meter = trackMeters[track.id] ?? StereoTrackLevelMeter()
        // Playback is already metered after the fader. Capture snapshots are
        // source PCM; apply the current controls to both bars and held peaks.
        if recording(for: track.id) != nil {
            let left = track.outputGain(channel: 0, channels: project.audioFormat.channels)
            let right = track.outputGain(channel: 1, channels: project.audioFormat.channels)
            meter.left.level *= left; meter.left.peak *= left
            meter.right.level *= right; meter.right.peak *= right
        }
        return meter
    }
    private func updateTrackMeters(_ peaks: [UUID: StereoLevels], at time: Double = ProcessInfo.processInfo.systemUptime, effectsOnly: Bool = false) {
        let ids = Set(project.tracks.map(\.id)).union([Project.masterID])
        trackMeters = trackMeters.filter { ids.contains($0.key) }
        for id in ids {
            var meter = trackMeters[id] ?? StereoTrackLevelMeter()
            meter.update(peaks[id] ?? StereoLevels(), at: time); trackMeters[id] = meter
            if effectsOnly {
                // Idle DSP already contains the real tails. A meter release
                // must not invent a tail for a silent dry bus or a finished FX.
                trackMeters[id]?.left.level = Double(peaks[id]?.left ?? 0)
                trackMeters[id]?.right.level = Double(peaks[id]?.right ?? 0)
            }
        }
    }
    private var effectMeterTracks: Set<UUID> {
        let tracks = project.processingTracks
        let parents = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in track.parent.map { (track.id, $0) } })
        var ids = Set<UUID>()
        for track in tracks where track.effects.contains(where: { !$0.bypassed }) {
            var current: UUID? = track.id
            while let id = current, ids.insert(id).inserted { current = parents[id] }
        }
        return ids
    }
    private var meterStopRevision: UInt64 = 0
    private func stopTrackMeters(preserving ids: Set<UUID> = []) {
        meterStopRevision &+= 1
        let revision = meterStopRevision
        for id in Array(trackMeters.keys) where !ids.contains(id) { trackMeters[id]?.clearLevels() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.isPlaying, !self.isRecording, self.meterStopRevision == revision else { return }
            // Expire held readouts without disturbing a live DSP handoff.
            guard self.liveEffectsPlayer == nil, self.pausedPlayer?.isAuditioningEffects != true else { return }
            self.updateTrackMeters([:])
            if let notify = self.transportChanged { notify() } else { self.changed?() }
        }
    }
    func updateRecordingWaveform(handleFailure: Bool = true) {
        guard !recordings.isEmpty else { return }
        var peaks = player.map { $0.consumeTrackPeaks(at: $0.currentTime) } ?? [:]
        var failed = false
        for take in recordings {
            let update = take.consumeUpdate()
            if let track = take.track { peaks[track] = update.levels }
            failed = failed || update.failure != nil
        }
        cursor = recordings[0].cursor
        updateTrackMeters(peaks)
        if handleFailure, failed { stop() }
    }
    func updateTransportPosition() {
        if recorder != nil { updateRecordingWaveform() }
        else if let player {
            cursor = player.currentTime
            updateTrackMeters(player.consumeTrackPeaks(at: cursor))
            if shuttleReleasing, player.returnReady, abs(player.currentSpeed - 1) < 1e-8 {
                player.completeReturn(); shuttleReleasing = false; shuttleGesture = nil; changed?()
            }
        } else if let shuttle { cursor = shuttle.currentTime }
        else if followsPausedCursor, let pausedPlayer {
            if !pausedPlayer.pauseComplete { updateTrackMeters(pausedPlayer.consumeTrackPeaks(at: pausedPlayer.currentTime)) }
            if pausedCursorIsCurrent { cursor = pausedPlayer.currentTime; pausedCursorSnapshot = cursor }
            else { followsPausedCursor = false; timer?.invalidate(); timer = nil }
        }
        if let transportChanged { transportChanged() } else { changed?() }
    }
    /// Read only the audible clock at display cadence; meter/capture work stays at 25 Hz.
    func updateTransportFrame() {
        guard recorder == nil else { return }
        if let player { cursor = player.currentTime }
        else if let shuttle { cursor = shuttle.currentTime }
        else if pausedCursorIsCurrent, let pausedPlayer {
            cursor = pausedPlayer.currentTime; pausedCursorSnapshot = cursor
        }
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
    func effectChain(for trackID: UUID) -> [PluginEffect]? {
        trackID == Project.masterID ? project.masterEffects : project.tracks.first(where: { $0.id == trackID })?.effects
    }
    var canEditEffects: Bool { !isRecording && !isShuttling && !requestingMic && !isExporting && !isImporting && !isOpening && !isNormalizing }
    func showEffects(for trackID: UUID) {
        guard canEditEffects, effectChain(for: trackID) != nil else { return }
        if trackID != Project.masterID { selectedTrack = trackID; update() }
        EffectsWindow(editor: self, trackID: trackID).run()
    }
    var canToggleEffects: Bool { !isRecording && !isShuttling && !requestingMic && !isExporting && !isImporting && !isOpening && !isNormalizing }
    func effectsBypassed(for trackID: UUID) -> Bool {
        trackID == Project.masterID ? project.masterEffectsBypassed : project.tracks.first(where: { $0.id == trackID })?.effectsBypassed ?? false
    }
    func toggleAllEffects(for trackID: UUID) {
        guard canToggleEffects, let chain = effectChain(for: trackID), !chain.isEmpty else { return }
        checkpoint()
        if trackID == Project.masterID { project.masterEffectsBypassed.toggle() }
        else if let index = project.tracks.firstIndex(where: { $0.id == trackID }) { project.tracks[index].effectsBypassed.toggle() }
        effectsChanged()
        effectsWindows[trackID]?.reload(notifyEditor: false)
        update()
    }
    func setEffectChain(_ effects: [PluginEffect], for trackID: UUID) {
        if trackID == Project.masterID { project.masterEffects = effects }
        else if let index = project.tracks.firstIndex(where: { $0.id == trackID }) { project.tracks[index].effects = effects }
    }
    func setEffectState(_ state: Data, effectID: UUID) {
        if let index = project.masterEffects.firstIndex(where: { $0.id == effectID }) { project.masterEffects[index].state = state }
        else if let track = project.tracks.firstIndex(where: { $0.effects.contains(where: { $0.id == effectID }) }),
                let effect = project.tracks[track].effects.firstIndex(where: { $0.id == effectID }) { project.tracks[track].effects[effect].state = state }
    }
    func flushPluginEdits() { for window in Array(pluginWindows.values) { window.captureChanges() } }
    // Files/presets/impulse responses can change without any normalized
    // parameter or edit notification. Save the complete authoritative hosts,
    // including processors whose editors have already been closed.
    func capturePluginStates() throws {
        var states: [(UUID, Data)] = []
        for effect in project.allEffects {
            if let host = pluginHosts[effect.id] { states.append((effect.id, try host.saveState())) }
        }
        for (id, state) in states { setEffectState(state, effectID: id) }
    }
    func closePluginWindows(capture: Bool = true) { for window in Array(pluginWindows.values) { window.close(capture: capture) } }
    func toggleTempoMode() { checkpoint(); project.tempoMode.toggle(); updateMetronome(); update() }
    func setTempo(_ bpm: Double) {
        guard bpm.isFinite, (20...300).contains(bpm), bpm != project.tempo else { return }
        checkpoint(); project.tempo = bpm; updateMetronome(); update("Tempo updated")
    }
    var loopRange: Range<Double>? {
        guard project.loopEnabled else { return nil }
        if let range, range.lowerBound.isFinite, range.upperBound.isFinite,
           range.lowerBound >= 0, (range.upperBound - range.lowerBound) * audio.sampleRate >= 1 {
            return range.lowerBound..<range.upperBound
        }
        return duration > 0 ? 0..<duration : nil
    }
    var canToggleLoop: Bool { !isRecording && !isShuttling && !requestingMic && !isExporting && !isImporting && !isOpening && !isNormalizing }
    func toggleLoop() {
        guard canToggleLoop else { return }
        checkpoint(); project.loopEnabled.toggle(); updateLoop(); update()
    }
    private func updateLoop() { player?.setLoop(loopRange) }
    func toggleMetronome() {
        checkpoint(); project.metronomeEnabled.toggle(); updateMetronome(); update()
    }
    private func updateMetronome() {
        player?.setMetronome(tempo: project.tempo, enabled: project.metronomeIsAudible)
        for (index, take) in recordings.enumerated() {
            take.recorder.metronome.configure(bpm: project.tempo, enabled: project.metronomeIsAudible && player == nil && index == 0)
        }
    }
    var canAdjustTrackMix: Bool { !isShuttling && !requestingMic && !isExporting && !isImporting && !isOpening && !isNormalizing }
    @discardableResult func setTrackMix(_ id: UUID, volumeDB: Double? = nil, pan: Double? = nil, checkpoint shouldCheckpoint: Bool = true) -> Bool {
        if id == Project.masterID {
            guard canAdjustTrackMix, let volumeDB, volumeDB.isFinite else { return false }
            let volume = max(-60, min(12, volumeDB))
            guard volume != project.masterVolumeDB else { return false }
            if shouldCheckpoint { checkpoint() } else { invalidateMixCache(); dirty = true }
            project.masterVolumeDB = volume; player?.setTrackMix(project.masterTrack)
            liveEffectsPlayer?.setTrackMix(project.masterTrack)
            update(); return true
        }
        guard canAdjustTrackMix, let i = project.tracks.firstIndex(where: { $0.id == id }) else { return false }
        var track = project.tracks[i]
        if let volumeDB, volumeDB.isFinite { track.volumeDB = max(-60, min(12, volumeDB)) }
        if let pan, pan.isFinite { track.pan = max(-90, min(90, pan)) }
        guard track.volumeDB != project.tracks[i].volumeDB || track.pan != project.tracks[i].pan else { return false }
        if shouldCheckpoint { checkpoint() }
        else { invalidateMixCache(); dirty = true }
        project.tracks[i] = track; player?.setTrackMix(track)
        liveEffectsPlayer?.setTrackMix(track)
        update(); return true
    }
    func toggleMute(_ trackID: UUID) {
        guard !isRecording, !isShuttling, !requestingMic, !isExporting, !isImporting, !isOpening,
              let index = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        checkpoint()
        project.tracks[index].muted.toggle()
        player?.setMuted(project.tracks[index].muted, trackID: trackID)
        liveEffectsPlayer?.setMuted(project.tracks[index].muted, trackID: trackID)
        if pausedPlayer?.isAuditioningEffects == true { pausedPlayer?.setMuted(project.tracks[index].muted, trackID: trackID) }
        update()
    }
    func toggleSolo(_ trackID: UUID) {
        guard !isRecording, !isShuttling, !requestingMic, !isExporting, !isImporting, !isOpening,
              let index = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        checkpoint()
        project.tracks[index].solo.toggle()
        player?.setSolo(Set(project.tracks.filter(\.solo).map(\.id)))
        liveEffectsPlayer?.setSolo(Set(project.tracks.filter(\.solo).map(\.id)))
        if pausedPlayer?.isAuditioningEffects == true { pausedPlayer?.setSolo(Set(project.tracks.filter(\.solo).map(\.id))) }
        update()
    }
    func effectsChanged() {
        let playing = isPlaying
        invalidateMixCache()
        if isRecording || isShuttling { stop() }
        else if player != nil || pausedPlayer != nil { stopPlayback() }
        let ids = Set(project.allEffects.map(\.id))
        let active = Set(project.activeEffects.map(\.id))
        for key in Array(midiRecipients.keys) {
            for (id, host) in midiRecipients[key] ?? [:] where !active.contains(id) { host.allNotesOff() }
            midiRecipients[key] = midiRecipients[key]?.filter { active.contains($0.key) }
        }
        pluginHosts = pluginHosts.filter { ids.contains($0.key) }
        if playing { startPlayback(rememberStart: false) } else { update() }
    }
    // Stop detaches timeline transport. Its live FX graph can keep rendering
    // silence on the same engine, independently of the visible cursor.
    private func stopPlayback(at position: Double? = nil, preserveEffects: Bool = false) {
        timer?.invalidate(); timer = nil
        guard let playback = player ?? pausedPlayer else { return }
        let stoppedPosition = position ?? (player != nil || pausedCursorIsCurrent ? playback.currentTime : cursor)
        player = nil; pausedPlayer = nil; pausedMixKey = nil; followsPausedCursor = false // Detach before callbacks.
        if preserveEffects && keepsPluginsRunning && !project.activeEffects.isEmpty {
            cancelEffectsPreparation()
            liveEffectsPlayer?.stop(); liveEffectsPlayer = playback
            liveEffectsKey = try? mixCacheKey()
            liveEffectsConfiguration = LiveEffectsConfiguration(format: project.audioFormat, output: project.defaultOutput, buffer: project.playbackBufferSize)
            playback.auditionEffects(at: stoppedPosition, hosts: project.activeEffects.compactMap { pluginHosts[$0.id] }, tempo: project.tempo)
            if let key = liveEffectsKey { watchLiveEffects(playback, key: key) }
        } else { playback.stop() }
        stopTrackMeters(preserving: liveEffectsPlayer === playback ? effectMeterTracks : [])
        cursor = stoppedPosition
    }
    func seek(to position: Double) {
        guard !isRecording, !requestingMic, !isExporting, !isImporting, !isOpening, position.isFinite else { return }
        let target = max(0, position)
        if preparation != nil || preparationRequest != nil {
            let request = preparationRequest
            cancelPlaybackPreparation()
            cursor = target
            preparePlayback(request)
            return
        }
        if !isShuttling, let playback = player, playback.isPlaying {
            guard loopRange.map({ target <= $0.upperBound }) == true || target < Double(playback.graph.totalFrames) / audio.sampleRate else {
                stopPlayback(at: target, preserveEffects: true); update(); return
            }
            playback.seek(to: target)
            playbackScrollRequest &+= 1
            lastPlaybackStart = playback.start
            cursor = playback.currentTime
            update(); return
        }
        if player == nil, pausedPlayer != nil, !isShuttling {
            followsPausedCursor = false; timer?.invalidate(); timer = nil
            cursor = target; update(); return
        }
        let continuePlaying = shuttleGesture?.resume ?? isPlaying
        endShuttle(resume: false)
        stopPlayback()
        cursor = target
        if continuePlaying { startPlayback() } else { update() }
    }
    func playPause() {
        if isPreparingPlayback { cancelPlaybackPreparation(); update(); return }
        if isShuttling { endShuttle(resume: false); return }
        if isRecording {
            stop(returningTo: recordingOrigin); return
        }
        guard !requestingMic, !isExporting, !isImporting && !isOpening else { return }
        if let playback = player {
            do {
                try playback.pause()
                pausedMixKey = try mixCacheKey(); pausedPlayer = playback; player = nil
                followsPausedCursor = true; cursor = playback.currentTime; pausedCursorSnapshot = cursor
                playback.didPause = { [weak self, weak playback] position in
                    guard let self, let playback, self.pausedPlayer === playback else { return }
                    self.stopTrackMeters(preserving: playback.isAuditioningEffects ? self.effectMeterTracks : [])
                    guard self.pausedCursorIsCurrent else { self.update(); return }
                    self.cursor = position; self.pausedCursorSnapshot = position; self.timer?.invalidate(); self.timer = nil; self.update()
                }
                update()
            } catch { stopPlayback(); self.error(error) }
            return
        }
        startPlayback()
    }
    func restartFromLastStart() {
        if isRecording { restartRecording(); return }
        guard !requestingMic, !isExporting, !isImporting && !isOpening else { return }
        let start = lastPlaybackStart ?? 0
        if !isShuttling, isPlaying { seek(to: start); return }
        endShuttle(resume: false)
        followsPausedCursor = false
        cursor = start
        startPlayback()
    }
    private func playbackHosts() throws -> [UUID: SNPluginHost] {
        var hosts: [UUID: SNPluginHost] = [:]
        for effect in project.activeEffects { hosts[effect.id] = try pluginHost(effect) }
        return hosts
    }
    private static func makeGraph(project: Project, store: AudioStore, hosts: [UUID: SNPluginHost], dryGraph: StreamingGraph? = nil, processedCache: ProcessedMixCache? = nil, progress: (Int) -> Void = { _ in }, cancelled: () -> Bool = { false }, preservePluginState: Bool = false, includeAudioSources: Bool = true) throws -> StreamingGraph {
        try StreamingGraph(project: project, store: store, dryGraph: dryGraph, processedCache: processedCache, preparationProgress: progress, cancelled: cancelled, includeAudioSources: includeAudioSources) { effect in
            guard !cancelled() else { throw CancellationError() }
            guard let host = hosts[effect.id] else { throw SounderError.message("Effect processor is unavailable") }
            if preservePluginState { try host.ensureStreaming(project.audioFormat.channels) }
            else { try host.beginStreaming(project.audioFormat.channels) }
            guard host.latency <= Int(store.sampleRate * 30) else { throw SounderError.message("Plug-in latency exceeds the supported 30-second maximum") }
            let channels = project.audioFormat.channels
            return StreamingEffect(latency: host.latency, tail: host.tail) { samples in
                let data = try host.processBlock(samples.withUnsafeBytes { Data($0) }, channels: channels)
                return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
    }
    private func playbackGraph() throws -> StreamingGraph {
        let previous = mixCache?.key == (try mixCacheKey()) ? mixCache?.graph : nil
        return try Self.makeGraph(project: project, store: audio, hosts: playbackHosts(), dryGraph: previous, processedCache: previous?.outputCache)
    }
    func beginShuttle(direction: Double) {
        guard !isPreparingPlayback, !isRecording, !requestingMic, !isExporting, !isImporting, !isOpening, !isNormalizing, duration > 0 else { return }
        discardPausedPlayback()
        let direction = direction < 0 ? -1.0 : 1.0
        if shuttleGesture?.direction == direction && !shuttleReleasing { return }
        shuttleReleasing = false
        let resume = shuttleGesture?.resume ?? isPlaying
        shuttleGesture = (direction, resume)
        if let shuttle { shuttle.changeDirection(direction); update(); return }
        do {
            let store = try AudioStore(directory: audio.directory)
            store.configure(project.audioFormat); store.cache = audio.cache
            let cached = mixCache?.key == (try mixCacheKey()) ? mixCache?.graph : nil
            let source = DryShuttleSource(project: project, store: store, processed: cached?.outputCache, latency: cached?.latency ?? 0, frameCount: max(cached?.totalFrames ?? 0, Int(cursor * project.audioFormat.sampleRate) + 1))
            if let player {
                // The same engine, node and queued output continue running.
                // The next buffer changes speed from +1, without a new start.
                player.beginShuttle(source: source, direction: direction)
                cursor = player.currentTime
            } else {
                let playback = ShuttlePlayback(source: source, start: cursor, direction: direction)
                try playback.configureOutput(project.defaultOutput)
                shuttle = playback
                playback.finished = { [weak self, weak playback] failure in
                    guard let self, let playback, self.shuttle === playback else { return }
                    self.cursor = failure == nil && !self.shuttleReleasing ? ((self.shuttleGesture?.direction ?? direction) < 0 ? 0 : playback.motion.end) : playback.currentTime
                    self.shuttle = nil; playback.stop(); self.timer?.invalidate(); self.timer = nil
                    if self.shuttleReleasing { self.shuttleReleasing = false; self.shuttleGesture = nil }
                    if let failure { self.endShuttle(resume: false); self.error(failure) } else { self.update() }
                }
                playback.start()
            }
            startTimer(); update()
        } catch { endShuttle(resume: false); self.error(error) }
    }
    func releaseShuttle() {
        guard let gesture = shuttleGesture, !shuttleReleasing else { return }
        shuttleReleasing = true
        if let shuttle { shuttle.release(); update(); return }
        guard let player else {
            shuttleReleasing = false; shuttleGesture = nil
            if gesture.resume { startPlayback(rememberStart: false) } else { update() }
            return
        }
        guard gesture.resume else { endShuttle(resume: false); return }
        do {
            let snapshot = project, hosts = try playbackHosts(), key = try mixCacheKey()
            let store = try AudioStore(directory: audio.directory)
            store.configure(snapshot.audioFormat); store.cache = audio.cache
            let previous = player.snapshotGraph
            player.restored = { [weak self, weak player] graph in
                guard let self, let player, self.player === player else { return }
                if (try? self.mixCacheKey()) == key { self.mixCache = (key, graph) }
                self.updateTransportPosition()
            }
            player.releaseShuttle { cancelled in
                try Self.makeGraph(project: snapshot, store: store, hosts: hosts, dryGraph: previous, cancelled: cancelled)
            }
            update()
        } catch { endShuttle(resume: false); self.error(error) }
    }
    func endShuttle(resume: Bool = true) {
        guard let gesture = shuttleGesture else { return }
        if player?.isShuttling == true { stopPlayback() }
        if let shuttle {
            cursor = shuttle.currentTime
            self.shuttle = nil; shuttle.stop()
        }
        timer?.invalidate(); timer = nil; shuttleGesture = nil; shuttleReleasing = false
        if resume && gesture.resume { startPlayback() } else { update() }
    }
    private func startPlayback(rememberStart: Bool = true, forRecording: Bool = false) {
        do {
            guard duration > 0 || forRecording else { return }
            flushPluginEdits()
            if !forRecording, let playback = pausedPlayer, pausedMixKey == (try mixCacheKey()) {
                let position = pausedCursorIsCurrent ? playback.pausePosition : max(0, cursor)
                guard loopRange.map({ position <= $0.upperBound }) == true || position < Double(playback.graph.totalFrames) / audio.sampleRate else { update(); return }
                pausedPlayer = nil; pausedMixKey = nil; followsPausedCursor = false
                player = playback
                playback.setMetronome(tempo: project.tempo, enabled: project.metronomeIsAudible)
                playback.setLoop(loopRange)
                try playback.resume(to: position)
                playback.didResume = { [weak self, weak playback] in
                    guard let self, let playback, self.player === playback else { return }
                    self.updateTransportPosition()
                }
                if rememberStart { lastPlaybackStart = playback.start; if !forRecording { playbackScrollRequest &+= 1 } }
                cursor = playback.currentTime; startTimer(); update(); return
            }
            if preparesPlaybackInBackground || keepsPluginsRunning {
                preparePlayback(rememberStart: rememberStart, forRecording: forRecording); return
            }
            discardPausedPlayback()
            let graph = try playbackGraph()
            let start = max(0, cursor)
            guard forRecording || loopRange.map({ start <= $0.upperBound }) == true || start < Double(graph.totalFrames) / audio.sampleRate else { update(); return }
            cursor = start
            let playback = try makePlayback(graph, project.audioFormat, start)
            try playback.configureBufferSize(project.playbackBufferSize)
            try playback.configureOutput(project.defaultOutput)
            try activatePlayback(playback, key: mixCacheKey(), rememberStart: rememberStart, forRecording: forRecording, alreadyStarted: false)
        } catch { player?.stop(); player = nil; self.error(error) }
    }
    private func activatePlayback(_ playback: LivePlayback, key: Data, rememberStart: Bool, forRecording: Bool, alreadyStarted: Bool) throws {
            playback.finished = { [weak self, weak playback] failure in
                guard let self, let playback else { return }
                if self.pausedPlayer === playback {
                    if let failure { self.stopPlayback(); self.error(failure); self.update() }
                    return
                }
                guard self.player === playback else { return }
                if self.isRecording {
                    guard let failure else { return } // An older natural-end callback cannot stop a new take.
                    self.stop(); self.error(failure)
                    return
                }
                if self.shuttleReleasing {
                    self.stopPlayback(at: failure == nil ? (self.lastPlaybackStart ?? playback.start) : playback.currentTime)
                    self.shuttleGesture = nil; self.shuttleReleasing = false; self.update()
                    if let failure { self.error(failure) }
                    return
                }
                if let gesture = self.shuttleGesture {
                    self.stopPlayback(at: failure == nil ? (gesture.direction < 0 ? 0 : Double(playback.graph.totalFrames) / self.audio.sampleRate) : playback.currentTime)
                    if let failure { self.endShuttle(resume: false); self.error(failure) } else { self.update() }
                    return
                }
                let returnPosition = self.lastPlaybackStart ?? playback.start
                self.stopPlayback(at: failure == nil ? returnPosition : playback.currentTime, preserveEffects: failure == nil)
                self.update()
                if let failure { self.error(failure) }
            }
            player = playback
            mixCache = (key, playback.graph)
            playback.continuesEffectsWhenPaused = keepsPluginsRunning
            playback.configureLiveHosts(project.activeEffects.compactMap { pluginHosts[$0.id] })
            playback.setMetronome(tempo: project.tempo, enabled: project.metronomeIsAudible)
            playback.setLoop(loopRange)
            if alreadyStarted {
                if !forRecording { playback.beginPreparedPlayback() }
            } else {
                if forRecording { try playback.prepareForRecording() }
                try playback.startPlayback(playImmediately: !forRecording)
            }
            cursor = playback.start
            if rememberStart { lastPlaybackStart = playback.start; if !forRecording { playbackScrollRequest &+= 1 } }
            startTimer(); update()
    }
    private func preparePlayback(_ request: PlaybackRequest?) {
        preparePlayback(rememberStart: request?.rememberStart ?? false,
                        forRecording: request?.forRecording ?? false,
                        speculative: request == nil, completed: request?.completed)
    }
    private func preparePlayback(rememberStart: Bool, forRecording: Bool, speculative: Bool = false, completed: (() -> Void)? = nil) {
        guard duration > 0 || forRecording else { preparationRequest = nil; update(); return }
        flushPluginEdits()
        let key: Data
        do { key = try mixCacheKey() } catch { preparationRequest = nil; if !speculative { self.error(error) }; return }
        let start = preparedPosition
        if let ready = standbyPlayer, standbyKey == key, ready.start == start {
            guard !speculative else { return }
            standbyPlayer = nil; standbyKey = nil; preparationRequest = nil
            do {
                if forRecording { try ready.prepareForRecording() }
                try activatePlayback(ready, key: key, rememberStart: rememberStart, forRecording: forRecording, alreadyStarted: true)
                completed?()
            } catch { stopPlayback(); self.error(error) }
            return
        }
        if preparation != nil, preparationTarget?.key == key, preparationTarget?.start == start {
            if !speculative {
                preparationRequest = PlaybackRequest(rememberStart: rememberStart, forRecording: forRecording, completed: completed)
                update()
            }
            return
        }
        cancelEffectsPreparation()
        if let pausedPlayer, pausedPlayer.isAuditioningEffects {
            liveEffectsPlayer = pausedPlayer; liveEffectsKey = pausedMixKey
            self.pausedPlayer = nil; pausedMixKey = nil; followsPausedCursor = false
        }
        let audition = keepsPluginsRunning ? liveEffectsPlayer : nil
        let liveState = keepsPluginsRunning
        cancelPlaybackPreparation(); discardStandbyPlayback(); discardPausedPlayback()
        let job = PlaybackPreparation(), snapshot = project
        let cached = audio.cache, directory = audio.directory, existingHosts = pluginHosts
        let factory = makePlayback, loop = loopRange
        preparationTarget = (key, start)
        preparationRequest = speculative ? nil : PlaybackRequest(rememberStart: rememberStart, forRecording: forRecording, completed: completed)
        let previous = mixCache?.key == key ? mixCache?.graph : nil
        preparation = job; update()
        preparationQueue.async { [weak self] in
            defer { if audition != nil { DispatchQueue.main.async { self?.scheduleLiveEffects() } } }
            var playback: LivePlayback?
            do {
                try job.check()
                let store = try AudioStore(directory: directory)
                store.configure(snapshot.audioFormat); store.cache = cached
                let rate = snapshot.audioFormat.sampleRate
                let extent = max(0, snapshot.tracks.flatMap(\.clips).map(\.end).max() ?? 0)
                let paths = previous == nil ? Set(snapshot.tracks.flatMap(\.clips).filter { !$0.muted }.map(\.source)).sorted() : []
                let missing = try paths.filter { store.cache[$0] == nil }.map { ($0, try store.sourceDuration($0) * rate) }
                let mixing = previous == nil ? snapshot.tracks.flatMap(\.clips).filter { !$0.muted }.reduce(0.0) { $0 + $1.duration * rate } : 0
                let interleaving = previous == nil ? extent * rate * Double(snapshot.tracks.count) : 0
                job.plan(frames: missing.reduce(0.0) { $0 + $1.1 } + mixing + interleaving)
                for (path, cost) in missing {
                    try job.check(); job.setPhase("Decoding " + URL(fileURLWithPath: path).lastPathComponent)
                    var done = 0.0
                    let data = try AudioStore.decode(URL(fileURLWithPath: path), sampleRate: rate, progress: { fraction, _ in
                        let next = min(1, max(done, fraction)); job.advance(frames: (next - done) * cost); done = next
                    }, isCancelled: { job.isCancelled })
                    store.cache[path] = data
                }
                job.setPhase(previous == nil ? "Preparing tracks and effects" : "Reusing prepared tracks")
                var hosts: [UUID: SNPluginHost] = [:]
                for effect in snapshot.activeEffects {
                    try job.check()
                    hosts[effect.id] = try existingHosts[effect.id] ?? SNPluginHost(path: effect.path, classID: effect.classID, state: effect.state, sampleRate: snapshot.audioFormat.sampleRate)
                }
                let graph = try Self.makeGraph(project: snapshot, store: store, hosts: hosts, dryGraph: previous, processedCache: previous?.outputCache, progress: { job.advance(frames: Double($0)) }, cancelled: { job.isCancelled }, preservePluginState: liveState)
                try job.check()
                guard forRecording || loop.map({ start <= $0.upperBound }) == true || start < Double(graph.totalFrames) / snapshot.audioFormat.sampleRate else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.preparation === job else { return }
                        self.preparation = nil; self.preparationTarget = nil; self.preparationRequest = nil; self.update()
                    }
                    return
                }
                let prepared = try factory(graph, snapshot.audioFormat, start); playback = prepared
                try job.check()
                try prepared.configureBufferSize(snapshot.playbackBufferSize)
                job.setPhase("Preparing playback audio")
                try prepared.configureOutput(snapshot.defaultOutput)
                prepared.setMetronome(tempo: snapshot.tempo, enabled: snapshot.metronomeIsAudible)
                prepared.setLoop(loop)
                if forRecording { try prepared.prepareForRecording() }
                let history = prepared.graph.needsHistory && !liveState ? Double(Int((start * rate).rounded()) + prepared.graph.latency) : 0
                let ahead = Double(snapshot.playbackBufferSize)
                job.beginRendering(frames: history + ahead)
                try job.check(); audition?.stop(); try job.check()
                if liveState { for host in hosts.values { host.setTransportPlaying(true, position: Int64((start * rate).rounded()), tempo: snapshot.tempo) } }
                try prepared.startPlayback(playImmediately: false, continueEffects: liveState, cancelled: { job.isCancelled }, progress: { job.advance(frames: Double($0)) })
                try job.check()
                let readyHosts = hosts, readySources = store.cache
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.preparation === job, !job.isCancelled else {
                        DispatchQueue.global(qos: .utility).async { prepared.stop() }; return
                    }
                    guard (try? self.mixCacheKey()) == key, self.preparedPosition == start else {
                        let request = self.preparationRequest
                        self.cancelPlaybackPreparation()
                        self.preparationQueue.async { prepared.stop() }
                        if let request { self.preparePlayback(request) } else { self.scheduleIdlePreparation() }
                        return
                    }
                    let request = self.preparationRequest
                    // A plug-in editor may have opened while this worker was
                    // creating processors. Keep its host authoritative; never
                    // publish a graph connected to a different instance.
                    if readyHosts.contains(where: { id, host in
                        self.pluginHosts[id].map { $0 !== host } ?? false
                    }) {
                        self.cancelPlaybackPreparation()
                        self.preparationQueue.async { prepared.stop() }
                        self.preparePlayback(request)
                        return
                    }
                    self.preparation = nil; self.preparationTarget = nil; self.preparationRequest = nil
                    self.audio.cache.merge(readySources) { current, _ in current }
                    self.pluginHosts.merge(readyHosts) { _, prepared in prepared }
                    if self.liveEffectsPlayer === audition { self.liveEffectsPlayer = nil; self.liveEffectsKey = nil }
                    self.mixCache = (key, prepared.graph)
                    guard let request else {
                        self.standbyPlayer = prepared; self.standbyKey = key
                        self.update(); return
                    }
                    do {
                        if request.forRecording && !forRecording { try prepared.prepareForRecording() }
                        try self.activatePlayback(prepared, key: key, rememberStart: request.rememberStart, forRecording: request.forRecording, alreadyStarted: true)
                        request.completed?()
                    } catch { self.stopPlayback(); self.error(error) }
                }
            } catch {
                playback?.stop()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.preparation === job else { return }
                    self.preparation = nil; self.preparationTarget = nil; self.preparationRequest = nil
                    if !job.isCancelled { self.error(error) }
                }
            }
        }
    }
    func stopAndReturnToStart() {
        let start = isRecording ? recordingOrigin : (lastPlaybackStart ?? 0)
        stop(returningTo: start)
    }
    func stop() { stop(returningTo: nil) }
    private func stop(returningTo position: Double?) {
        cancelPlaybackPreparation()
        endShuttle(resume: false)
        stopPlayback(at: position, preserveEffects: true)
        if !recordings.isEmpty {
            let takes = recordings
            let failures = takes.map { $0.recorder.stop() }
            updateRecordingWaveform(handleFailure: false)
            clearRecordingState()
            var saved: [(Int, Clip)] = []
            var errors: [Error] = []
            for (take, failure) in zip(takes, failures) {
                do {
                    guard let index = project.tracks.firstIndex(where: { $0.id == take.track }) else { continue }
                    let url = take.recorder.url
                    let data = try audio.load(url.path)
                    guard data.frameCount > 0 else {
                        try? FileManager.default.removeItem(at: url)
                        throw failure ?? SounderError.message("No audio was captured. Check the selected input device.")
                    }
                    pendingRecordedSources.insert(url.path)
                    let clip = Clip(name: "\(project.tracks[index].name) \(project.tracks[index].nextTakeNumber)", source: url.path, start: take.start, duration: Double(data.frameCount) / audio.sampleRate, order: project.nextOrder + saved.count)
                    saved.append((index, clip))
                    if let failure { errors.append(SounderError.message("Recording interrupted; captured audio was saved. " + failure.localizedDescription)) }
                } catch { errors.append(error) }
            }
            if !saved.isEmpty {
                checkpoint()
                for (index, clip) in saved {
                    project.tracks[index].nextTakeNumber += 1; project.tracks[index].clips.append(clip)
                }
                project.nextOrder += saved.count; selection = Set(saved.map { $0.1.id })
                cursor = saved.map { $0.1.end }.max() ?? cursor
                if errors.isEmpty { notifications.show("Recording saved", style: .success) }
            }
            if let position { cursor = position }
            for error in errors { self.error(error) }
        }
        clearRecordingState()
        // Commit the cursor together with the take. Publishing the recording
        // end and then the return point makes the viewport jump twice and can
        // launch speculative preparation for the intermediate position.
        if let position { cursor = position }
        stopTrackMeters(preserving: liveEffectsPlayer != nil ? effectMeterTracks : [])
        update()
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
        guard !busy else { return false }
        var destination = projectURL
        if destination == nil || `as` {
            let panel = NSSavePanel(); panel.nameFieldStringValue = suggestedFilename; panel.canCreateDirectories = true
            guard EditorModalBackdrop.run({ panel.runModal() }) == .OK else { return false }; destination = panel.url
        }
        do { try save(to: destination!); return true }
        catch { self.error(error); return false }
    }
    func save(to url: URL) throws {
        guard !busy else { throw SounderError.message("Wait for the current operation before saving") }
        flushPluginEdits()
        try capturePluginStates()
        var snapshot = project; snapshot.name = projectName; snapshot.timelineRange = range; snapshot.timelineCursor = cursor
        snapshot.timelineView = captureTimelineView?() ?? TimelineViewState(zoom: zoom, x: project.timelineView?.x ?? 0, y: project.timelineView?.y ?? 0)
        try snapshot.timelineView?.validate()
        let saved = try ProjectStorage.save(snapshot, to: url, additionalSources: pendingRecordedSources)
        func remapped(_ original: Project) -> Project {
            var result = original
            for i in result.tracks.indices { for j in result.tracks[i].clips.indices {
                if let path = saved.sources[result.tracks[i].clips[j].source] { result.tracks[i].clips[j].source = path }
            } }
            return result
        }
        for (source, target) in saved.sources { if let data = audio.cache[source] { audio.cache[target] = data } }
        project = remapped(project); project.name = saved.project.name; project.timelineRange = snapshot.timelineRange; project.timelineCursor = snapshot.timelineCursor; project.timelineView = snapshot.timelineView
        undoStack = undoStack.map(remapped); redoStack = redoStack.map(remapped)
        let pasteboard = NSPasteboard.general
        if let bytes = pasteboard.data(forType: Self.fragmentPasteboardType),
           var payload = try? JSONDecoder().decode(FragmentClipboard.self, from: bytes) {
            var changed = false
            for i in payload.items.indices {
                if let target = saved.sources[payload.items[i].clip.source] { payload.items[i].clip.source = target; changed = true }
            }
            if changed, let updated = try? JSONEncoder().encode(payload) { pasteboard.setData(updated, forType: Self.fragmentPasteboardType) }
        }
        for source in pendingRecordedSources {
            if let target = saved.sources[source], source != target { recordedSourceCleanup[source] = target }
        }
        pendingRecordedSources.subtract(saved.sources.keys)
        recentProjects.remember(url, name: saved.project.name ?? url.deletingPathExtension().lastPathComponent)
        projectURL = url; dirty = false; notifications.show("Saved \(url.lastPathComponent)", style: .saved); update()
        preferences?.set(project.playbackBufferSize, forKey: Self.playbackBufferPreference)
        // Commit paths before removing temporary takes: saved media always survives a failure.
        for (source, target) in recordedSourceCleanup {
            guard FileManager.default.fileExists(atPath: target) else { continue }
            do {
                if FileManager.default.fileExists(atPath: source) { try FileManager.default.removeItem(atPath: source) }
                recordedSourceCleanup.removeValue(forKey: source); audio.cache.removeValue(forKey: source)
            } catch { self.error(SounderError.message("Project saved, but the temporary take could not be removed: " + error.localizedDescription)) }
        }
    }
    func confirmDiscard() -> Bool {
        flushPluginEdits()
        guard dirty else { return true }
        let alert = ActionChoiceAlert(); alert.icon = NSApp.applicationIconImage
        alert.cancellationIndex = 2; alert.messageText = "Save changes to this project?"; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() { case .alertFirstButtonReturn: return save(); case .alertSecondButtonReturn: return true; default: return false }
    }
    func open() {
        guard !busy, confirmDiscard() else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sounder")!]
        panel.allowsOtherFileTypes = false
        guard EditorModalBackdrop.run({ panel.runModal() }) == .OK, let url = panel.url, url.pathExtension.lowercased() == "sounder" else { return }
        do { try startProjectOpen(from: url) }
        catch { self.error(error) }
    }
    func open(from url: URL) throws {
        guard !busy else { throw SounderError.message("Stop the current operation before opening a project") }
        recentProjects.removeIfMissing(url)
        let prepared = try PreparedProject.load(from: url)
        finishProjectOpen(prepared, from: url)
    }
    func startProjectOpen(from url: URL) throws {
        guard !busy else { throw SounderError.message("Stop the current operation before opening a project") }
        recentProjects.removeIfMissing(url)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
        cancelPlaybackPreparation(); discardStandbyPlayback()
        projectOpener?.close()
        let job = ProjectOpenController(editor: self, url: url)
        projectOpener = job; job.start()
    }
    func finishProjectOpen(_ prepared: PreparedProject, from url: URL) {
        discardPausedPlayback()
        pendingRecordedSources = []; recordedSourceCleanup = [:]
        project = prepared.project; projectURL = url
        audio.configure(project.audioFormat); audio.cache = prepared.sources
        undoStack = []; redoStack = []; selection = []; cursor = project.timelineCursor
        zoom = project.timelineView?.zoom ?? 70
        timelineViewRestoreID &+= 1
        lastPlaybackStart = nil; range = project.timelineRange; dirty = false
        recentProjects.remember(url, name: projectName)
        reconcile(); update()
        projectOpened?()
    }
    func export() {
        guard canExport else { return }
        let options = ExportOptionsController(settings: project.defaultExportSettings, range: range, metadata: project.metadata)
        guard let settings = options.runModal() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: settings.format.rawValue) ?? .audio]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = projectName.replacingOccurrences(of: "/", with: "-") + "." + settings.format.rawValue
        guard EditorModalBackdrop.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do { try startAudioExport(to: url, settings: settings, range: options.selectedRange, metadata: options.metadata) } catch { self.error(error) }
    }
    func startAudioExport(to url: URL, settings: ExportSettings, range: Range<Double>? = nil, metadata: AudioMetadata? = nil) throws {
        guard canExport else { return }
        try settings.validate()
        try (metadata ?? project.metadata).validate()
        flushPluginEdits()
        try capturePluginStates()
        cancelPlaybackPreparation(); discardStandbyPlayback()
        exporter?.close()
        let job = AudioExportController(editor: self, destination: url, settings: settings, range: range, metadata: metadata ?? project.metadata)
        exporter = job; job.start()
    }
    func export(to url: URL, settings: ExportSettings, range: Range<Double>? = nil, metadata: AudioMetadata? = nil) throws {
        flushPluginEdits()
        try capturePluginStates()
        var exportedProject = project
        if let metadata { exportedProject.metadata = metadata }
        try AudioExporter.write(project: exportedProject, store: audio, settings: settings, to: url, range: range)
        finishAudioExport(to: url, settings: settings, metadata: exportedProject.metadata)
    }
    func finishAudioExport(to url: URL, settings: ExportSettings, metadata: AudioMetadata) {
        if settings != project.exportSettings || !project.exportSettingsConfirmed || metadata != project.metadata {
            checkpoint(); project.exportSettings = settings; project.exportSettingsConfirmed = true
            project.metadata = metadata
        }
        update("Exported \(url.lastPathComponent)")
    }
}
