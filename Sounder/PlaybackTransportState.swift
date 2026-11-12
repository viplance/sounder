import Foundation

/// Worker-owned rendering phase. Intent is separate because Pause/Stop must
/// become visible while a slow DSP block still owns the rendering worker.
enum PlaybackRenderPhase {
    case inactive, timeline, fadingOut, idleEffects
    var active: Bool { self != .inactive }
}

/// Short, DSP-free UI/control snapshot. No caller holds this lock while
/// waiting for the rendering worker or calling a plug-in.
final class PlaybackTransportState {
    enum Intent { case play, pause, resume }
    enum Pause { case pending, complete(Double) }
    struct Snapshot {
        var intent: Intent = .play
        var pause: Pause = .pending
        var pauseTarget = 0.0
        var isShuttling = false
        var returnReady = false
        var shuttleUsesProcessedCache = false
        var stopping = false
        var auditionPosition: Double?
        var effectsMetersReady = false
        var isPaused: Bool { intent == .pause }
        var pausePosition: Double? {
            if case let .complete(position) = pause { return position }
            return nil
        }
    }
    private let lock = NSLock()
    private var value = Snapshot()
    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ change: (inout Snapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }; change(&value)
    }
}
