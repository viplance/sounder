import AVFoundation

/// One owner for block sizing, callback generations and queue accounting.
/// Rendering and scheduling stay on the caller's serial worker. Consumption
/// updates BUFFER immediately, before that worker can be delayed by DSP.
final class PlaybackOutputQueue {
    struct Ticket {
        let generation: UInt64
        let fillGeneration: UInt64
        let frames: Int
    }
    let fill = AudioBufferFill()
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pending = 0
    private(set) var capacity: Int
    private var blocks: [Int]
    private var index = 0
    var blockCount: Int { blocks.count }
    var scheduled: Int { lock.lock(); defer { lock.unlock() }; return pending }
    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    init(capacity: Int) {
        self.capacity = capacity; blocks = PlaybackBufferSize.blocks(frames: capacity)
    }
    func configure(capacity: Int) throws {
        try PlaybackBufferSize.validate(capacity)
        precondition(scheduled == 0)
        self.capacity = capacity; blocks = PlaybackBufferSize.blocks(frames: capacity); index = 0
    }
    func nextBlock() -> Int {
        defer { index = (index + 1) % blocks.count }
        return blocks[index]
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1; pending = 0; fill.reset()
    }
    func isCurrent(_ revision: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == revision
    }
    func register(frames: Int) -> Ticket {
        lock.lock(); defer { lock.unlock() }
        pending += 1
        return Ticket(generation: generation, fillGeneration: fill.enqueue(frames: frames, capacity: capacity), frames: frames)
    }
    func consumed(_ ticket: Ticket) { fill.consumed(frames: ticket.frames, generation: ticket.fillGeneration) }
    func complete(_ ticket: Ticket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == ticket.generation else { return false }
        pending -= 1
        return true
    }
    static func completionType(final: Bool, manual: Bool) -> AVAudioPlayerNodeCompletionCallbackType {
        final ? (manual ? .dataRendered : .dataPlayedBack) : .dataConsumed
    }
    func schedule(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode, worker: DispatchQueue,
                  final: Bool, manual: Bool, completion: @escaping () -> Void) {
        let ticket = register(frames: Int(buffer.frameLength))
        node.scheduleBuffer(buffer, completionCallbackType: Self.completionType(final: final, manual: manual)) { [weak self] _ in
            guard let self else { return }
            self.consumed(ticket)
            worker.async {
                guard self.complete(ticket) else { return }
                completion()
            }
        }
    }
}

/// Quantize once at the final Float32 output boundary, after mixing/fades.
struct PlaybackPCMEncoding {
    private let scale: Float?
    init(bitDepth: Int) { scale = bitDepth == 32 ? nil : (bitDepth == 16 ? 32768 : 8388608) }
    func sample(_ value: Float) -> Float {
        guard let scale else { return value }
        return min(scale - 1, (value * scale).rounded()) / scale
    }
}
