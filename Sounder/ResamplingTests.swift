import Foundation
import AVFoundation

func runResamplingTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SounderError.message(message) }
        print("PASS: \(message)")
    }
    func tone(_ frequency: Double, rate: Double, amplitude: Double = 0.4) -> [Float] {
        (0..<Int(rate)).map { Float(sin(Double($0) * 2 * .pi * frequency / rate) * amplitude) }
    }
    func rms(_ values: [Float]) -> Double { sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, values.count))) }
    func projection(_ values: [Float], frequency: Double, rate: Double) -> (amplitude: Double, phase: Double) {
        var sine = 0.0, cosine = 0.0
        let first = Int(rate * 0.1), last = min(values.count, Int(rate * 0.9))
        for i in first..<last {
            let angle = Double(i) * 2 * .pi * frequency / rate
            sine += Double(values[i]) * sin(angle); cosine += Double(values[i]) * cos(angle)
        }
        let factor = 2 / Double(last - first)
        return (hypot(sine, cosine) * factor, atan2(cosine, sine))
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderResampling-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try AudioStore(directory: directory)
    let destination = try AudioStore(directory: directory)
    // Both passband and stopband tests use a source rate above the project rate.
    for frequency in [1000.0, 19000.0, 30000.0] {
        source.configure(ProjectAudioFormat(sampleRate: 96_000))
        let path = source.freshURL(); try source.write(tone(frequency, rate: 96_000), to: path)
        destination.configure(ProjectAudioFormat(sampleRate: 44_100))
        let converted = try destination.load(path.path).samples
        try check(converted.count == 44_100, "Mastering SRC preserves exact duration at \(Int(frequency)) Hz")
        if frequency < 22_050 {
            let response = projection(converted, frequency: frequency, rate: 44_100)
            let gainDB = 20 * log10(response.amplitude / 0.4)
            try check(abs(gainDB) < 0.05 && abs(response.phase) < 0.002, String(format: "SRC passband %.0f Hz: gain %.5f dB, phase %.6f rad", frequency, gainDB, response.phase))
        } else {
            let middle = Array(converted[4410..<39690])
            let rejectionDB = 20 * log10(max(1e-15, rms(middle)) / (0.4 / sqrt(2)))
            try check(rejectionDB < -90, String(format: "SRC suppresses out-of-band alias by %.1f dB", -rejectionDB))
        }
    }
    // Mix independently recorded/imported sources with different rates, channel
    // counts and integer/float encodings, then change the project format twice.
    source.configure(ProjectAudioFormat(sampleRate: 44_100))
    let mono16 = source.freshURL(); try source.write(AudioSignal(channels: [tone(1000, rate: 44_100, amplitude: 0.2)]), to: mono16, bitDepth: 16)
    source.configure(ProjectAudioFormat(sampleRate: 96_000))
    let stereo24 = source.freshURL(); try source.write(AudioSignal(channels: [tone(3000, rate: 96_000, amplitude: 0.15), tone(5000, rate: 96_000, amplitude: 0.1)]), to: stereo24, bitDepth: 24)
    source.configure(ProjectAudioFormat(sampleRate: 48_000))
    let stereo32 = source.freshURL(); try source.write(AudioSignal(channels: [tone(7000, rate: 48_000, amplitude: 0.1), tone(7000, rate: 48_000, amplitude: -0.05)]), to: stereo32)
    let urls = [mono16, stereo24, stereo32]
    let originals = try urls.map { try Data(contentsOf: $0) }
    let tracks = urls.enumerated().map { i, url in Track(name: "Source \(i)", clips: [Clip(name: "Source", source: url.path, start: 0.1, duration: 1, order: i)]) }
    for format in [ProjectAudioFormat(), ProjectAudioFormat(sampleRate: 44_100, channels: 1, bitDepth: 16), ProjectAudioFormat(sampleRate: 96_000, channels: 2), ProjectAudioFormat()] {
        let mix = try destination.renderAudio(Project(tracks: tracks, audioFormat: format))
        try check(mix.channels.count == format.channels && mix.frameCount == Int(1.1 * format.sampleRate), "Mixed source formats follow project \(format.label)")
        let first = Int(format.sampleRate * 0.2), last = Int(format.sampleRate)
        for channel in 0..<format.channels {
            var squaredError = 0.0
            for i in first..<last {
                let time = Double(i) / format.sampleRate - 0.1
                let mono = sin(time * 2 * .pi * 1000) * 0.2
                let left = mono + sin(time * 2 * .pi * 3000) * 0.15 + sin(time * 2 * .pi * 7000) * 0.1
                let right = mono + sin(time * 2 * .pi * 5000) * 0.1 - sin(time * 2 * .pi * 7000) * 0.05
                let expected = format.channels == 1 ? (left + right) * 0.5 : (channel == 0 ? left : right)
                let error = Double(mix.channels[channel][i]) - expected
                squaredError += error * error
            }
            let error = sqrt(squaredError / Double(last - first))
            try check(error < 0.00006, String(format: "Mixed channel %d stays time-aligned (RMS error %.8f)", channel + 1, error))
        }
        let output = destination.freshURL(); try destination.write(mix, to: output, bitDepth: format.bitDepth)
        let file = try AVAudioFile(forReading: output)
        try check(file.fileFormat.sampleRate == format.sampleRate && file.fileFormat.channelCount == format.channels && file.fileFormat.streamDescription.pointee.mBitsPerChannel == format.bitDepth, "Final playback/export WAV uses the common project format")
    }
    try check(try urls.map { try Data(contentsOf: $0) } == originals, "Switching project format never rewrites or repeatedly resamples source files")
}
