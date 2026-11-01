import Foundation
import AVFoundation

enum NameRules {
    static let maximumLength = 100
    static func normalized(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

let sampleRate = 48_000.0
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
    var end: Double { start + duration }

    func resized(leftEdge: Bool, by delta: Double, sourceDuration: Double) -> Clip {
        var result = self
        // A source shorter than 10 ms cannot be extended with invented audio.
        let minimum = min(Self.minimumDuration, duration, sourceDuration)
        if leftEdge {
            let shift = max(-min(start, offset), min(delta, duration - minimum))
            result.start += shift; result.offset += shift; result.duration -= shift
        } else {
            result.duration = max(minimum, min(duration + delta, sourceDuration - offset))
        }
        return result
    }
}
extension Clip {
    enum CodingKeys: String, CodingKey { case id, name, source, start, offset, duration, order, gain }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
        source = try values.decode(String.self, forKey: .source); start = try values.decode(Double.self, forKey: .start)
        offset = try values.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        duration = try values.decode(Double.self, forKey: .duration); order = try values.decode(Int.self, forKey: .order)
        gain = try values.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        guard gain.isFinite && gain >= 0 else { throw SounderError.message("Invalid fragment gain") }
    }
}
enum FragmentNormalization {
    static func validate(_ level: Double) throws {
        guard level.isFinite && (-120...0).contains(level) else { throw SounderError.message("Enter a maximum level between -120 and 0 dBFS.") }
    }
    static func gain(for clip: Clip, data: AudioData, sampleRate: Double, level: Double) -> Double {
        let first = min(data.frameCount, max(0, Int(clip.offset * sampleRate)))
        let last = min(data.frameCount, first + max(0, Int(clip.duration * sampleRate)))
        var peak = 0.0
        for channel in data.channels {
            for sample in channel[first..<last] where sample.isFinite { peak = max(peak, abs(Double(sample))) }
        }
        return peak > 0 ? pow(10, level / 20) / peak : clip.gain
    }
}
struct Track: Codable, Identifiable {
    var id = UUID()
    var name: String
    var parent: UUID?
    var muted = false
    var clips: [Clip] = []
    var effects: [PluginEffect] = []
    var nextTakeNumber = 1
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
    enum CodingKeys: String, CodingKey { case id, name, parent, muted, clips, effects, nextTakeNumber }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        parent = try values.decodeIfPresent(UUID.self, forKey: .parent)
        muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        clips = try values.decode([Clip].self, forKey: .clips)
        effects = try values.decodeIfPresent([PluginEffect].self, forKey: .effects) ?? []
        nextTakeNumber = max(1, try values.decodeIfPresent(Int.self, forKey: .nextTakeNumber) ?? 1)
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
    var tracks: [Track] = [Track(name: "Audio 01")]
    var nextOrder = 1
    var name: String? = nil
    var audioFormat = ProjectAudioFormat()
    var exportSettings: ExportSettings?
    var exportSettingsConfirmed = false
    var tempo = 120.0
    var tempoMode = false
    var metronomeEnabled = false
    var normalizationLevel = -1.0
    var defaultExportSettings: ExportSettings {
        if exportSettingsConfirmed, let exportSettings { return exportSettings }
        return ExportSettings(projectFormat: audioFormat)
    }
}
extension Project {
    enum CodingKeys: String, CodingKey { case tracks, nextOrder, name, audioFormat, exportSettings, exportSettingsConfirmed, tempo, tempoMode, metronomeEnabled, normalizationLevel }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try values.decode([Track].self, forKey: .tracks)
        nextOrder = try values.decodeIfPresent(Int.self, forKey: .nextOrder) ?? 1
        name = try values.decodeIfPresent(String.self, forKey: .name)
        audioFormat = try values.decodeIfPresent(ProjectAudioFormat.self, forKey: .audioFormat) ?? ProjectAudioFormat(channels: 1, bitDepth: 32)
        try audioFormat.validate()
        exportSettings = try values.decodeIfPresent(ExportSettings.self, forKey: .exportSettings)
        try exportSettings?.validate()
        // Earlier builds remembered dialog choices before a file was exported.
        exportSettingsConfirmed = try values.decodeIfPresent(Bool.self, forKey: .exportSettingsConfirmed) ?? false
        tempo = try values.decodeIfPresent(Double.self, forKey: .tempo) ?? 120
        tempoMode = try values.decodeIfPresent(Bool.self, forKey: .tempoMode) ?? false
        metronomeEnabled = try values.decodeIfPresent(Bool.self, forKey: .metronomeEnabled) ?? false
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
    func renderAudio(_ project: Project, range: Range<Double>? = nil, onlyTrack: UUID? = nil) throws -> AudioSignal {
        try project.audioFormat.validate()
        configure(project.audioFormat)
        let channelCount = project.audioFormat.channels
        func silence(_ frames: Int) -> AudioSignal { AudioSignal(channels: [[Float]](repeating: [Float](repeating: 0, count: frames), count: channelCount)) }
        let end = project.tracks.flatMap(\.clips).map(\.end).max() ?? 0
        // Render from project zero so delay/reverb history is correct when seeking.
        // Fragment joining is deliberately dry and excludes child buses and effects.
        let region = onlyTrack == nil ? 0..<max(0, end) : (range ?? 0..<max(0, end))
        let length = max(0, Int((region.upperBound - region.lowerBound) * sampleRate))
        func raw(_ track: Track) throws -> AudioSignal {
            var lane = silence(length)
            // Oldest first: a newer fragment overwrites, even when its sample is silence.
            for clip in track.clips.sorted(by: { $0.order < $1.order }) {
                let audio = try load(clip.source)
                let first = max(0, Int((clip.start - region.lowerBound) * sampleRate))
                let last = min(length, Int((clip.end - region.lowerBound) * sampleRate))
                guard last > first else { continue }
                for frame in first..<last {
                    let sourceFrame = Int((region.lowerBound - clip.start + clip.offset) * sampleRate) + frame
                    for channel in 0..<channelCount {
                        var sample: Float = 0
                        if sourceFrame >= 0 && sourceFrame < audio.frameCount {
                            if channelCount == 1 { sample = audio.channels.reduce(Float(0)) { $0 + $1[sourceFrame] } / Float(audio.channels.count) }
                            else { sample = audio.channels[min(channel, audio.channels.count - 1)][sourceFrame] }
                        }
                        lane.channels[channel][frame] = Float(Double(sample) * clip.gain)
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
        var visited = Set<UUID>()
        func bus(_ track: Track) throws -> AudioSignal {
            guard visited.insert(track.id).inserted else { throw SounderError.message("Invalid track hierarchy") }
            guard !track.muted else { return silence(length) }
            var signal = try raw(track)
            for child in project.tracks where child.parent == track.id { sum(try bus(child), into: &signal) }
            if let processEffects { return AudioSignal(channels: try signal.channels.map { try processEffects($0, track.effects) }) }
            return try PluginProcessing.apply(signal, effects: track.effects, format: project.audioFormat)
        }
        var mix = silence(length)
        for track in project.tracks where track.parent == nil { sum(try bus(track), into: &mix) }
        mix.channels = mix.channels.map { $0.map { $0.isFinite ? min(1, max(-1, $0)) : 0 } }
        if let range {
            let first = min(mix.frameCount, max(0, Int(range.lowerBound * sampleRate)))
            let last = min(mix.frameCount, max(first, Int(range.upperBound * sampleRate)))
            return mix.slice(first..<last)
        }
        return mix
    }
}
enum SounderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
