import Foundation
import CoreMIDI

struct LiveMIDIMessage: Equatable {
    let source: UInt32
    let status: UInt8
    let data1: UInt8
    let data2: UInt8
}

enum LiveMIDIDecoder {
    /// CoreMIDI translates MIDI 1 devices/running status into complete UMPs.
    static func decode(_ words: UnsafeBufferPointer<UInt32>, source: UInt32) -> [LiveMIDIMessage] {
        var result: [LiveMIDIMessage] = [], index = 0
        while index < words.count {
            let word = words[index], type = word >> 28
            let size: Int
            switch type { case 3, 4: size = 2; case 5, 13, 15: size = 4; default: size = 1 }
            guard index + size <= words.count else { break }
            if type == 2 {
                let status = UInt8((word >> 16) & 255)
                if (0x80...0xEF).contains(status) {
                    result.append(LiveMIDIMessage(source: source, status: status, data1: UInt8((word >> 8) & 127), data2: UInt8(word & 127)))
                }
            }
            index += size
        }
        return result
    }
}

/// Receives every connected source without changing the system's MIDI setup.
/// The high-priority CoreMIDI callback only decodes and enqueues small messages.
final class LiveMIDIInput {
    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private var connected = Set<MIDIEndpointRef>()
    private let received: ([LiveMIDIMessage]) -> Void
    private let disconnected: (UInt32) -> Void
    init(received: @escaping ([LiveMIDIMessage]) -> Void, disconnected: @escaping (UInt32) -> Void) throws {
        self.received = received; self.disconnected = disconnected
        let status = MIDIClientCreateWithBlock("Sounder live instruments" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        guard status == noErr else { throw SounderError.message("Cannot open MIDI input (\(status))") }
        let input = MIDIInputPortCreateWithProtocol(client, "Sounder instruments" as CFString, ._1_0, &port) { [weak self] list, reference in
            guard let self else { return }
            let source = UInt32(truncatingIfNeeded: UInt(bitPattern: reference))
            var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIEventPacket.self)
            for _ in 0..<list.pointee.numPackets {
                let data = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!).assumingMemoryBound(to: UInt32.self)
                let messages = LiveMIDIDecoder.decode(UnsafeBufferPointer(start: data, count: Int(packet.pointee.wordCount)), source: source)
                if !messages.isEmpty { self.received(messages) }
                packet = UnsafePointer(MIDIEventPacketNext(packet))
            }
        }
        guard input == noErr else { MIDIClientDispose(client); client = 0; throw SounderError.message("Cannot connect MIDI input (\(input))") }
        refresh()
    }
    private func refresh() {
        guard port != 0 else { return }
        let sources = Set((0..<MIDIGetNumberOfSources()).map(MIDIGetSource).filter { $0 != 0 })
        for source in connected.subtracting(sources) { MIDIPortDisconnectSource(port, source); disconnected(source) }
        connected.formIntersection(sources)
        for source in sources.subtracting(connected) {
            if MIDIPortConnectSource(port, source, UnsafeMutableRawPointer(bitPattern: UInt(source))) == noErr { connected.insert(source) }
        }
    }
    deinit { if port != 0 { MIDIPortDispose(port) }; if client != 0 { MIDIClientDispose(client) } }
}
