import Foundation
import AVFoundation

enum NameRules {
    static let maximumLength = 100
    static func normalized(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

let sampleRate = 48_000.0
enum FadeCurve: String, Codable, CaseIterable {
    case linear, smooth, exponential, logarithmic
    var title: String { switch self { case .linear: return "Linear"; case .smooth: return "S-curve"; case .exponential: return "Exponential"; case .logarithmic: return "Logarithmic" } }
    func value(_ progress: Double) -> Double {
        let t = max(0, min(1, progress))
        switch self { case .linear: return t; case .smooth: return t * t * (3 - 2 * t); case .exponential: return t * t; case .logarithmic: return sqrt(t) }
    }
}
struct Clip: Codable, Identifiable {
    static let minimumDuration = 0.010
    var id = UUID()
    var name: String
    var source: String
    var start: Double
    var offset: Double = 0
    var duration: Double
    var order: Int
    var gain = 1.0
    var muted = false
    var fadeInBaked = false
    var fadeOutBaked = false
    var volumeDB = 0.0
    var pan = 0.0
    var fadeInMS = 10.0
    var fadeOutMS = 10.0
    var fadeInCurve = FadeCurve.linear
    var fadeOutCurve = FadeCurve.linear
    var end: Double { start + duration }

    var volumeGain: Double { gain * pow(10, volumeDB / 20) }
    func panGain(channel: Int, channels: Int) -> Double {
        guard channels > 1 else { return 1 }
        let attenuation = channel == 0 ? max(0, pan) : max(0, -pan)
        return attenuation >= 90 ? 0 : cos(attenuation / 90 * .pi / 2)
    }
    func fadeLengths(frames: Int, sampleRate: Double) -> (Double, Double) {
        let available = Double(max(0, frames - 1))
        var first = min(available, fadeInMS * sampleRate / 1000), last = min(available, fadeOutMS * sampleRate / 1000)
        if first + last > available { let scale = available / (first + last); first *= scale; last *= scale }
        return (first, last)
    }
    func changingFade(left: Bool, durationMS: Double? = nil, curve: FadeCurve? = nil) -> Clip {
        guard durationMS?.isFinite != false else { return self }
        var result = self
        if left {
            result.fadeInMS = durationMS.map { max(0, min(duration * 1000, $0)) } ?? fadeInMS
            result.fadeInCurve = curve ?? fadeInCurve
            if result.fadeInMS != fadeInMS || result.fadeInCurve != fadeInCurve { result.fadeInBaked = false }
        } else {
            result.fadeOutMS = durationMS.map { max(0, min(duration * 1000, $0)) } ?? fadeOutMS
            result.fadeOutCurve = curve ?? fadeOutCurve
            if result.fadeOutMS != fadeOutMS || result.fadeOutCurve != fadeOutCurve { result.fadeOutBaked = false }
        }
        return result
    }
    func resized(leftEdge: Bool, by delta: Double, sourceDuration: Double) -> Clip {
        var result = self
        // A source shorter than 10 ms cannot be extended with invented audio.
        let minimum = min(Self.minimumDuration, duration, sourceDuration)
        if leftEdge {
            let shift = max(-min(start, offset), min(delta, duration - minimum))
            result.start += shift; result.offset += shift; result.duration -= shift
            if shift != 0 { result.fadeInBaked = false }
        } else {
            result.duration = max(minimum, min(duration + delta, sourceDuration - offset))
            if result.duration != duration { result.fadeOutBaked = false }
        }
        return result
    }
}
extension Clip {
    enum CodingKeys: String, CodingKey { case id, name, source, start, offset, duration, order, gain, muted, fadeInBaked, fadeOutBaked, volumeDB, pan, fadeInMS, fadeOutMS, fadeInCurve, fadeOutCurve }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
        source = try values.decode(String.self, forKey: .source); start = try values.decode(Double.self, forKey: .start)
        offset = try values.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        duration = try values.decode(Double.self, forKey: .duration); order = try values.decode(Int.self, forKey: .order)
        volumeDB = try values.decodeIfPresent(Double.self, forKey: .volumeDB) ?? 0
        pan = try values.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        fadeInMS = try values.decodeIfPresent(Double.self, forKey: .fadeInMS) ?? 10
        fadeOutMS = try values.decodeIfPresent(Double.self, forKey: .fadeOutMS) ?? 10
        fadeInCurve = try values.decodeIfPresent(FadeCurve.self, forKey: .fadeInCurve) ?? .linear
        fadeOutCurve = try values.decodeIfPresent(FadeCurve.self, forKey: .fadeOutCurve) ?? .linear
        guard volumeDB.isFinite, (-48...24).contains(volumeDB), pan.isFinite, (-90...90).contains(pan), fadeInMS.isFinite, fadeInMS >= 0, fadeOutMS.isFinite, fadeOutMS >= 0 else { throw SounderError.message("Invalid fragment settings") }
        fadeInBaked = try values.decodeIfPresent(Bool.self, forKey: .fadeInBaked) ?? false
        fadeOutBaked = try values.decodeIfPresent(Bool.self, forKey: .fadeOutBaked) ?? false
        muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        gain = try values.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        guard gain.isFinite && gain >= 0 else { throw SounderError.message("Invalid fragment gain") }
    }
}
enum FragmentNormalization {
    static func validate(_ level: Double) throws {
        guard level.isFinite && (-120...0).contains(level) else { throw SounderError.message("Enter a maximum level between -120 and 0 dBFS.") }
    }
    static func peak(for clip: Clip, data: AudioData, sampleRate: Double) -> Double {
        let first = min(data.frameCount, max(0, Int(clip.offset * sampleRate)))
        let last = min(data.frameCount, first + max(0, Int(clip.duration * sampleRate)))
        var peak = 0.0
        for channel in data.channels {
            for sample in channel[first..<last] where sample.isFinite { peak = max(peak, abs(Double(sample))) }
        }
        return peak
    }
    static func gain(for clip: Clip, data: AudioData, sampleRate: Double, level: Double) -> Double {
        let peak = peak(for: clip, data: data, sampleRate: sampleRate) * pow(10, clip.volumeDB / 20)
        return peak > 0 ? pow(10, level / 20) / peak : clip.gain
    }
}
struct FragmentSettings: Equatable {
    var volumeDB: Double
    var pan: Double
    var fadeInMS: Double
    var fadeOutMS: Double
    var fadeInCurve: FadeCurve
    var fadeOutCurve: FadeCurve
    init(_ clip: Clip) {
        volumeDB = clip.volumeDB; pan = clip.pan; fadeInMS = clip.fadeInMS; fadeOutMS = clip.fadeOutMS
        fadeInCurve = clip.fadeInCurve; fadeOutCurve = clip.fadeOutCurve
    }
    static func maximumVolume(clip: Clip, peak: Double) throws -> Double {
        let maximum = peak > 0 && clip.gain > 0 ? min(24, -20 * log10(peak) - 20 * log10(clip.gain)) : 24
        guard maximum >= -48 else { throw SounderError.message("Normalize this source before adjusting its volume.") }
        return maximum
    }
    func applying(to clip: Clip, peak: Double) throws -> Clip {
        guard volumeDB.isFinite, pan.isFinite, fadeInMS.isFinite, fadeOutMS.isFinite,
              fadeInMS >= 0, fadeOutMS >= 0 else { throw SounderError.message("Enter valid volume, pan and nonnegative fade times.") }
        var result = clip
        result.volumeDB = max(-48, min(volumeDB, try Self.maximumVolume(clip: clip, peak: peak)))
        result.pan = max(-90, min(90, pan)); result.fadeInMS = fadeInMS; result.fadeOutMS = fadeOutMS
        result.fadeInCurve = fadeInCurve; result.fadeOutCurve = fadeOutCurve
        if fadeInMS != clip.fadeInMS || fadeInCurve != clip.fadeInCurve { result.fadeInBaked = false }
        if fadeOutMS != clip.fadeOutMS || fadeOutCurve != clip.fadeOutCurve { result.fadeOutBaked = false }
        return result
    }
}
struct Track: Codable, Identifiable {
    var id = UUID()
    var name: String
    var parent: UUID?
    var muted = false
    var solo = false
    var clips: [Clip] = []
    var effects: [PluginEffect] = []
    var nextTakeNumber = 1
    var volumeDB = 0.0
    var pan = 0.0
    func outputGain(channel: Int, channels: Int) -> Double {
        let gain = volumeDB <= -60 ? 0 : pow(10, volumeDB / 20)
        guard channels > 1 else { return gain }
        let attenuation = channel == 0 ? max(0, pan) : max(0, -pan)
        return gain * cos(attenuation / 90 * .pi / 2)
    }
    func applyMix(to signal: AudioSignal) -> AudioSignal {
        AudioSignal(channels: signal.channels.enumerated().map { channel, samples in
            let gain = Float(outputGain(channel: channel, channels: signal.channels.count))
            return samples.map { $0 * gain }
        })
    }
}
// Soloed parent buses include their subtree. Soloed children still pass through
// ancestor effects, without adding the ancestors' own fragments or other branches.
struct TrackSoloRouting {
    var dry: Set<UUID>
    var buses: Set<UUID> = []
    init(tracks: [Track], soloIDs: Set<UUID>? = nil) {
        let all = Set(tracks.map(\.id))
        let selected = (soloIDs ?? Set(tracks.filter(\.solo).map(\.id))).intersection(all)
        guard !selected.isEmpty else { dry = all; buses = all; return }
        dry = selected
        var previous: Set<UUID> = []
        while previous != dry {
            previous = dry
            for track in tracks where track.parent.map({ dry.contains($0) }) == true { dry.insert(track.id) }
        }
        buses = dry
        previous = []
        while previous != buses {
            previous = buses
            for track in tracks where buses.contains(track.id) { if let parent = track.parent { buses.insert(parent) } }
        }
    }
}
struct FragmentClipboard: Codable {
    struct Item: Codable {
        var clip: Clip
        var row: Int
        var trackName: String
    }
    var items: [Item]
}
enum TrackHierarchy {
    static let maximumDepth = 2
    static let limitMessage = "Tracks can be nested at most 2 levels"

    static func orderedRows(_ tracks: [Track]) -> [(Track, Int)] {
        var result: [(Track, Int)] = []
        func append(_ parent: UUID?, depth: Int) {
            for track in tracks where track.parent == parent {
                result.append((track, depth)); append(track.id, depth: depth + 1)
            }
        }
        append(nil, depth: 0)
        return result
    }

    static func validate(_ tracks: [Track]) throws {
        let ids = Set(tracks.map(\.id))
        guard ids.count == tracks.count else { throw SounderError.message("Invalid track IDs") }
        for track in tracks {
            var visited: Set<UUID> = [track.id]
            var parent = track.parent
            var depth = 0
            while let id = parent {
                guard ids.contains(id), visited.insert(id).inserted else { throw SounderError.message("Invalid track hierarchy") }
                depth += 1
                guard depth <= maximumDepth else { throw SounderError.message(limitMessage) }
                parent = tracks.first(where: { $0.id == id })?.parent
            }
        }
    }
}
// Keep projects saved before effects and per-track take numbering readable.
extension Track {
    enum CodingKeys: String, CodingKey { case id, name, parent, muted, solo, clips, effects, nextTakeNumber, volumeDB, pan }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        parent = try values.decodeIfPresent(UUID.self, forKey: .parent)
        muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        solo = try values.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        clips = try values.decode([Clip].self, forKey: .clips)
        effects = try values.decodeIfPresent([PluginEffect].self, forKey: .effects) ?? []
        nextTakeNumber = max(1, try values.decodeIfPresent(Int.self, forKey: .nextTakeNumber) ?? 1)
        volumeDB = try values.decodeIfPresent(Double.self, forKey: .volumeDB) ?? 0
        pan = try values.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        guard volumeDB.isFinite, (-60...12).contains(volumeDB), pan.isFinite, (-90...90).contains(pan) else { throw SounderError.message("Invalid track volume or pan") }
    }
}
struct ProjectAudioFormat: Codable, Equatable {
    static let supportedRates: [Double] = [44_100, 48_000, 88_200, 96_000, 192_000]
    var sampleRate = 48_000.0
    var channels = 2
    var bitDepth = 24
    var rateLabel: String {
        let rate = sampleRate / 1000
        return (rate.rounded() == rate ? String(Int(rate)) : String(format: "%.1f", rate)) + " kHz"
    }
    var label: String {
        "\(rateLabel) \(channels == 1 ? "MONO" : "STEREO") · \(bitDepth) bit"
    }
    func validate() throws {
        guard Self.supportedRates.contains(sampleRate), [1, 2].contains(channels), [16, 24, 32].contains(bitDepth) else {
            throw SounderError.message("Unsupported project audio format")
        }
    }
}
extension ProjectAudioFormat {
    enum CodingKeys: String, CodingKey { case sampleRate, channels, bitDepth }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sampleRate = try values.decode(Double.self, forKey: .sampleRate)
        channels = try values.decode(Int.self, forKey: .channels)
        // Projects saved before bit depth selection used Float32 audio.
        bitDepth = try values.decodeIfPresent(Int.self, forKey: .bitDepth) ?? 32
        try validate()
    }
    var recordingSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
         AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: bitDepth,
         AVLinearPCMIsFloatKey: bitDepth == 32, AVLinearPCMIsBigEndianKey: false]
    }
}
struct Project: Codable {
    static let masterID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var tracks: [Track] = [Track(name: "Audio 01")]
    var masterVolumeDB = 0.0
    var masterEffects: [PluginEffect] = []
    var masterTrack: Track { Track(id: Self.masterID, name: "Master", effects: masterEffects, volumeDB: masterVolumeDB) }
    var processingTracks: [Track] {
        tracks.map { track in
            var routed = track
            if routed.parent == nil { routed.parent = Self.masterID }
            return routed
        } + [masterTrack]
    }
    var allEffects: [PluginEffect] { tracks.flatMap(\.effects) + masterEffects }
    var nextOrder = 1
    var name: String? = nil
    var audioFormat = ProjectAudioFormat()
    var exportSettings: ExportSettings?
    var exportSettingsConfirmed = false
    var metadata = AudioMetadata()
    var tempo = 120.0
    var tempoMode = false
    var metronomeEnabled = false
    var loopEnabled = false
    var normalizationLevel = -1.0
    var defaultExportSettings: ExportSettings {
        if exportSettingsConfirmed, let exportSettings { return exportSettings }
        return ExportSettings(projectFormat: audioFormat)
    }
}
extension Project {
    enum CodingKeys: String, CodingKey { case tracks, masterVolumeDB, masterEffects, nextOrder, name, audioFormat, exportSettings, exportSettingsConfirmed, metadata, tempo, tempoMode, metronomeEnabled, loopEnabled, normalizationLevel }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try values.decode([Track].self, forKey: .tracks)
        masterVolumeDB = try values.decodeIfPresent(Double.self, forKey: .masterVolumeDB) ?? 0
        masterEffects = try values.decodeIfPresent([PluginEffect].self, forKey: .masterEffects) ?? []
        guard masterVolumeDB.isFinite, (-60...12).contains(masterVolumeDB) else { throw SounderError.message("Invalid master volume") }
        nextOrder = try values.decodeIfPresent(Int.self, forKey: .nextOrder) ?? 1
        name = try values.decodeIfPresent(String.self, forKey: .name)
        audioFormat = try values.decodeIfPresent(ProjectAudioFormat.self, forKey: .audioFormat) ?? ProjectAudioFormat(channels: 1, bitDepth: 32)
        try audioFormat.validate()
        exportSettings = try values.decodeIfPresent(ExportSettings.self, forKey: .exportSettings)
        try exportSettings?.validate()
        metadata = try values.decodeIfPresent(AudioMetadata.self, forKey: .metadata) ?? AudioMetadata()
        try metadata.validate()
        // Earlier builds remembered dialog choices before a file was exported.
        exportSettingsConfirmed = try values.decodeIfPresent(Bool.self, forKey: .exportSettingsConfirmed) ?? false
        tempo = try values.decodeIfPresent(Double.self, forKey: .tempo) ?? 120
        tempoMode = try values.decodeIfPresent(Bool.self, forKey: .tempoMode) ?? false
        metronomeEnabled = try values.decodeIfPresent(Bool.self, forKey: .metronomeEnabled) ?? false
        loopEnabled = try values.decodeIfPresent(Bool.self, forKey: .loopEnabled) ?? false
        normalizationLevel = try values.decodeIfPresent(Double.self, forKey: .normalizationLevel) ?? -1
        try FragmentNormalization.validate(normalizationLevel)
        guard tempo.isFinite && (20...300).contains(tempo) else { throw SounderError.message("Tempo must be between 20 and 300 BPM") }
    }
}
struct AudioSignal {
    var channels: [[Float]]
    var frameCount: Int { channels.first?.count ?? 0 }
    var mono: [Float] {
        guard channels.count > 1 else { return channels.first ?? [] }
        return (0..<frameCount).map { frame in channels.reduce(Float(0)) { $0 + $1[frame] } / Float(channels.count) }
    }
    func slice(_ range: Range<Int>) -> AudioSignal { AudioSignal(channels: channels.map { Array($0[range]) }) }
}
struct AudioData {
    let channels: [[Float]]
    var samples: [Float] { AudioSignal(channels: channels).mono }
    var frameCount: Int { channels.first?.count ?? 0 }
    let channelPeaks: [[Float]]
    // Combined peaks remain useful for metering and validation, never for stereo drawing.
    var peaks: [Float] {
        (0..<(channelPeaks.first?.count ?? 0)).map { i in channelPeaks.reduce(Float(0)) { max($0, $1[i]) } }
    }
    init(_ samples: [Float]) { self.init(channels: [samples]) }
    init(channels: [[Float]], progress: (Double) -> Void = { _ in }) {
        self.channels = channels
        channelPeaks = channels.enumerated().map { channel, samples in
            stride(from: 0, to: samples.count, by: 128).map { first in
                if first % 131_072 == 0 { progress((Double(channel) + Double(first) / Double(max(1, samples.count))) / Double(channels.count)) }
                return samples[first..<min(first + 128, samples.count)].reduce(Float(0)) { max($0, abs($1)) }
            }
        }
    }
}
// Peaks of the fragment's dry output, before track effects and overlap composition.
struct FragmentWaveformKey: Equatable {
    let source: String
    let first: Int
    let frames: Int
    let rate: Double
    let channels: Int
    let values: [Double]
    let curves: [FadeCurve]
    let baked: [Bool]
    init(_ clip: Clip, rate: Double, channels: Int) {
        source = clip.source; self.rate = rate; self.channels = channels
        let start = Int(clip.start * rate)
        first = Int((clip.offset - clip.start) * rate) + start
        frames = max(0, Int(clip.end * rate) - start)
        values = [clip.gain, clip.volumeDB, clip.pan, clip.fadeInMS, clip.fadeOutMS]
        curves = [clip.fadeInCurve, clip.fadeOutCurve]; baked = [clip.fadeInBaked, clip.fadeOutBaked]
    }
}
enum FragmentWaveform {
    static func peaks(_ audio: AudioData, clip: Clip, rate: Double, channels requestedChannels: Int, cancelled: () -> Bool = { false }) -> [[Float]]? {
        // Centered mono has identical stereo outputs: show a single full-height lane.
        let channels = audio.channels.count == 1 && clip.pan == 0 ? 1 : requestedChannels
        let key = FragmentWaveformKey(clip, rate: rate, channels: channels)
        let (fadeIn, fadeOut) = clip.fadeLengths(frames: key.frames, sampleRate: rate)
        let gains = (0..<channels).map { clip.volumeGain * clip.panGain(channel: $0, channels: channels) }
        var result = Array(repeating: [Float](), count: channels)
        for first in stride(from: 0, to: key.frames, by: 128) {
            if cancelled() { return nil }
            var peaks = Array(repeating: Float(0), count: channels)
            for frame in first..<min(first + 128, key.frames) {
                let source = key.first + frame
                guard source >= 0 && source < audio.frameCount else { continue }
                let incoming = clip.fadeInBaked || fadeIn == 0 ? 1 : clip.fadeInCurve.value(Double(frame) / fadeIn)
                let outgoing = clip.fadeOutBaked || fadeOut == 0 ? 1 : clip.fadeOutCurve.value(Double(key.frames - 1 - frame) / fadeOut)
                let envelope = min(incoming, outgoing)
                for channel in 0..<channels {
                    let sample = channels == 1 ? audio.channels.reduce(Float(0)) { $0 + $1[source] } / Float(audio.channels.count) : audio.channels[min(channel, audio.channels.count - 1)][source]
                    peaks[channel] = max(peaks[channel], abs(Float(Double(sample) * gains[channel] * envelope)))
                }
            }
            for channel in 0..<channels { result[channel].append(peaks[channel]) }
        }
        return result
    }
}
final class AudioStore {
    var cache: [String: AudioData] = [:]
    // Optional test processor; production uses the multichannel VST host.
    var processEffects: (([Float], [PluginEffect]) throws -> [Float])?
    private(set) var sampleRate = 48_000.0
    func configure(_ format: ProjectAudioFormat) {
        if sampleRate != format.sampleRate { sampleRate = format.sampleRate; cache.removeAll() }
    }
    let directory: URL
    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sounder/Recordings")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }
    func freshURL() -> URL { directory.appendingPathComponent(UUID().uuidString + ".wav") }
    func sourceDuration(_ path: String) throws -> Double {
        if let data = cache[path] { return Double(data.frameCount) / sampleRate }
        // Read file metadata only; edge dragging must not decode a whole recording.
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        return Double(file.length) / file.processingFormat.sampleRate
    }
    func load(_ path: String) throws -> AudioData {
        if let data = cache[path] { return data }
        let data = try Self.decode(URL(fileURLWithPath: path), sampleRate: sampleRate)
        cache[path] = data
        return data
    }
    /// Decodes on the caller's queue without touching the shared timeline cache.
    static func decode(_ url: URL, sampleRate: Double, progress: (Double, String) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }) throws -> AudioData {
        if isCancelled() { throw CancellationError() }
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: min(2, file.processingFormat.channelCount))!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw SounderError.message("Cannot convert this audio format") }
        // Always resample the preserved source directly to the current project clock.
        // Mastering prioritizes fidelity; decoding is cached until the rate changes.
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.primeMethod = .normal
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192)!
        var channels = [[Float]](repeating: [], count: Int(target.channelCount))
        let estimate = Int(ceil(Double(file.length) * sampleRate / file.processingFormat.sampleRate))
        for channel in channels.indices { channels[channel].reserveCapacity(estimate) }
        var readFailure: Error?
        progress(0, "Decoding audio")
        while true {
            if isCancelled() { throw CancellationError() }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                guard file.framePosition < file.length else { inputStatus.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: input, frameCount: min(input.frameCapacity, max(1, requested)))
                    inputStatus.pointee = .haveData; return input
                } catch { readFailure = error; inputStatus.pointee = .endOfStream; return nil }
            }
            if let readFailure { throw readFailure }
            if let conversionError { throw conversionError }
            if status == .error { throw SounderError.message("Audio conversion failed") }
            if let pcm = output.floatChannelData {
                for channel in channels.indices { channels[channel].append(contentsOf: UnsafeBufferPointer(start: pcm[channel], count: Int(output.frameLength))) }
            }
            progress(0.85 * Double(file.framePosition) / Double(max(1, file.length)), "Decoding audio")
            if status == .endOfStream { break }
            if output.frameLength == 0 { throw SounderError.message("Audio conversion produced no data") }
        }
        progress(0.85, "Preparing waveforms")
        let data = AudioData(channels: channels) { progress(0.85 + 0.15 * $0, "Preparing waveforms") }
        if isCancelled() { throw CancellationError() }
        progress(1, "Ready")
        return data
    }
    func write(_ samples: [Float], to url: URL) throws { try write(AudioSignal(channels: [samples]), to: url) }
    func write(_ signal: AudioSignal, to url: URL, bitDepth: Int = 32) throws {
        guard [16, 24, 32].contains(bitDepth) else { throw SounderError.message("Unsupported WAV bit depth") }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(signal.channels.count))!
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        settings[AVLinearPCMBitDepthKey] = bitDepth
        settings[AVLinearPCMIsFloatKey] = bitDepth == 32
        settings[AVLinearPCMIsBigEndianKey] = false
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536)!
        for i in stride(from: 0, to: signal.frameCount, by: 65_536) {
            let count = min(65_536, signal.frameCount - i)
            chunk.frameLength = AVAudioFrameCount(count)
            for channel in signal.channels.indices { for j in 0..<count { chunk.floatChannelData![channel][j] = signal.channels[channel][i + j] } }
            try file.write(from: chunk)
        }
    }
    func render(_ project: Project, range: Range<Double>? = nil, onlyTrack: UUID? = nil) throws -> [Float] {
        try renderAudio(project, range: range, onlyTrack: onlyTrack).mono
    }
    func renderAudio(_ project: Project, range: Range<Double>? = nil, onlyTrack: UUID? = nil, sourceFrames: Range<Int>? = nil) throws -> AudioSignal {
        try project.audioFormat.validate()
        configure(project.audioFormat)
        let channelCount = project.audioFormat.channels
        func silence(_ frames: Int) -> AudioSignal { AudioSignal(channels: [[Float]](repeating: [Float](repeating: 0, count: frames), count: channelCount)) }
        let end = project.tracks.flatMap(\.clips).map(\.end).max() ?? 0
        // Render from project zero so delay/reverb history is correct when seeking.
        // Fragment joining is deliberately dry and excludes child buses and effects.
        let region = onlyTrack == nil ? 0..<max(0, end) : (sourceFrames.map { (Double($0.lowerBound) / sampleRate)..<(Double($0.upperBound) / sampleRate) } ?? range ?? 0..<max(0, end))
        let length = max(0, sourceFrames?.count ?? Int((region.upperBound - region.lowerBound) * sampleRate))
        func raw(_ track: Track) throws -> AudioSignal {
            var lane = silence(length)
            // Composite oldest first. A new fragment wins outside its edge
            // ramps; within each 10 ms ramp it crossfades with the audio below.
            for clip in track.clips.sorted(by: { $0.order < $1.order }) where !clip.muted {
                let clipFirst = sourceFrames.map { Int(clip.start * sampleRate) - $0.lowerBound } ?? Int((clip.start - region.lowerBound) * sampleRate)
                let clipLast = sourceFrames.map { Int(clip.end * sampleRate) - $0.lowerBound } ?? Int((clip.end - region.lowerBound) * sampleRate)
                let first = max(0, clipFirst), last = min(length, clipLast)
                guard last > first else { continue }
                let audio = try load(clip.source)
                let (fadeIn, fadeOut) = clip.fadeLengths(frames: clipLast - clipFirst, sampleRate: sampleRate)
                let gains = (0..<channelCount).map { clip.volumeGain * clip.panGain(channel: $0, channels: channelCount) }
                for frame in first..<last {
                    let sourceFrame = sourceFrames.map { Int((clip.offset - clip.start) * sampleRate) + $0.lowerBound + frame } ?? (Int((region.lowerBound - clip.start + clip.offset) * sampleRate) + frame)
                    let incoming = fadeIn == 0 ? 1 : clip.fadeInCurve.value(Double(frame - clipFirst) / fadeIn)
                    let outgoing = fadeOut == 0 ? 1 : clip.fadeOutCurve.value(Double(clipLast - 1 - frame) / fadeOut)
                    let weight = min(incoming, outgoing)
                    let sourceWeight = min(clip.fadeInBaked ? 1 : incoming, clip.fadeOutBaked ? 1 : outgoing)
                    for channel in 0..<channelCount {
                        var sample: Float = 0
                        if sourceFrame >= 0 && sourceFrame < audio.frameCount {
                            if channelCount == 1 { sample = audio.channels.reduce(Float(0)) { $0 + $1[sourceFrame] } / Float(audio.channels.count) }
                            else { sample = audio.channels[min(channel, audio.channels.count - 1)][sourceFrame] }
                        }
                        lane.channels[channel][frame] = Float(Double(lane.channels[channel][frame]) * (1 - weight) + Double(sample) * gains[channel] * sourceWeight)
                    }
                }
            }
            return lane
        }
        if let onlyTrack { return try project.tracks.first(where: { $0.id == onlyTrack }).map { try raw($0) } ?? silence(length) }
        func sum(_ source: AudioSignal, into destination: inout AudioSignal) {
            for channel in 0..<channelCount {
                if destination.channels[channel].count < source.frameCount { destination.channels[channel].append(contentsOf: repeatElement(0, count: source.frameCount - destination.channels[channel].count)) }
                for i in 0..<source.frameCount { destination.channels[channel][i] += source.channels[channel][i] }
            }
        }
        let processingTracks = project.processingTracks
        let solo = TrackSoloRouting(tracks: processingTracks)
        var visited = Set<UUID>()
        func bus(_ track: Track) throws -> AudioSignal {
            guard visited.insert(track.id).inserted else { throw SounderError.message("Invalid track hierarchy") }
            guard !track.muted, solo.buses.contains(track.id) else { return silence(length) }
            var signal = solo.dry.contains(track.id) ? try raw(track) : silence(length)
            for child in processingTracks where child.parent == track.id { sum(try bus(child), into: &signal) }
            if track.id != Project.masterID || !track.effects.isEmpty {
                if let processEffects { signal = AudioSignal(channels: try signal.channels.map { try processEffects($0, track.effects) }) }
                else { signal = try PluginProcessing.apply(signal, effects: track.effects, format: project.audioFormat) }
            }
            return track.applyMix(to: signal)
        }
        var mix = silence(length)
        for track in processingTracks where track.parent == nil { sum(try bus(track), into: &mix) }
        mix.channels = mix.channels.map { $0.map { $0.isFinite ? min(1, max(-1, $0)) : 0 } }
        if let range {
            let first = min(mix.frameCount, max(0, Int(range.lowerBound * sampleRate)))
            let last = min(mix.frameCount, max(first, Int(range.upperBound * sampleRate)))
            return mix.slice(first..<last)
        }
        return mix
    }
}
enum ProjectStorage {
    private static func requireFile(_ url: URL) throws {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
            throw SounderError.message("Choose a .sounder project file")
        }
    }
    static func save(_ project: Project, to url: URL, additionalSources: Set<String> = []) throws -> (project: Project, sources: [String: String]) {
        try requireFile(url)
        let fm = FileManager.default, document = url
        let media = document.deletingLastPathComponent().appendingPathComponent("media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        var saved = project, sources: [String: String] = [:], copied: [URL] = []
        var canonicalTargets: [String: URL] = [:]
        func prepare(_ path: String) throws -> URL {
            let original = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let target: URL
            if let existing = canonicalTargets[original.path] { target = existing }
            else if original.deletingLastPathComponent() == media.standardizedFileURL.resolvingSymlinksInPath() {
                guard fm.fileExists(atPath: original.path) else { throw SounderError.message("Audio file is missing: " + original.lastPathComponent) }
                target = media.appendingPathComponent(original.lastPathComponent)
            } else {
                var candidate = media.appendingPathComponent(original.lastPathComponent)
                while fm.fileExists(atPath: candidate.path) {
                    candidate = media.appendingPathComponent(UUID().uuidString).appendingPathExtension(original.pathExtension)
                }
                try fm.copyItem(at: original, to: candidate); copied.append(candidate); target = candidate
            }
            canonicalTargets[original.path] = target; sources[path] = target.path
            return target
        }
        do {
            for i in saved.tracks.indices { for j in saved.tracks[i].clips.indices {
                let target = try prepare(saved.tracks[i].clips[j].source)
                saved.tracks[i].clips[j].source = "media/" + target.lastPathComponent
            } }
            // Retain recorded takes reachable through Undo/Redo or the clipboard too.
            for path in additionalSources.sorted() { _ = try prepare(path) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: document, options: .atomic)
            return (saved, sources)
        } catch {
            for file in copied { try? fm.removeItem(at: file) }
            throw error
        }
    }
    static func load(from url: URL) throws -> Project {
        try requireFile(url)
        let document = url, base = document.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let media = base.appendingPathComponent("media", isDirectory: true).resolvingSymlinksInPath()
        var loaded = try JSONDecoder().decode(Project.self, from: Data(contentsOf: document))
        try TrackHierarchy.validate(loaded.tracks)
        for i in loaded.tracks.indices { for j in loaded.tracks[i].clips.indices {
            let clip = loaded.tracks[i].clips[j]
            guard clip.start.isFinite, clip.offset.isFinite, clip.duration.isFinite, clip.start >= 0, clip.offset >= 0, clip.duration > 0 else { throw SounderError.message("Invalid fragment timing") }
            let source = base.appendingPathComponent(clip.source).standardizedFileURL.resolvingSymlinksInPath()
            guard clip.source.hasPrefix("media/"), source.path.hasPrefix(media.path + "/"), source.path.hasPrefix(base.path == "/" ? "/" : base.path + "/") else { throw SounderError.message("Audio must be inside the project's media folder") }
            loaded.tracks[i].clips[j].source = source.path
        } }
        loaded.nextOrder = max(loaded.nextOrder, (loaded.tracks.flatMap(\.clips).map(\.order).max() ?? 0) + 1)
        return loaded
    }
}
enum SounderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
