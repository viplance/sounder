import Foundation

/// Input-rate sample coordinates, before conversion and loop replacement.
/// A missing device timestamp continues the physical packet interval, even
/// when that interval was discarded as pre-roll or overlaps retained audio.
struct RecordingPacketTimeline {
    struct Placement: Equatable {
        let padding: Int
        let skip: Int
        let remaining: Int
    }
    private(set) var nextPacketFrame: Int?
    private(set) var nextInputFrame = 0
    mutating func place(offset: Int, frames: Int) -> Placement {
        precondition(frames >= 0)
        nextPacketFrame = offset + frames
        let padding = max(0, offset - nextInputFrame)
        nextInputFrame += padding
        let skip = min(max(0, nextInputFrame - offset), frames)
        let remaining = frames - skip
        nextInputFrame += remaining
        return Placement(padding: padding, skip: skip, remaining: remaining)
    }
}
