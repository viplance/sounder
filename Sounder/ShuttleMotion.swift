import AVFoundation

struct ShuttleMotion {
    static let maximumRate = 8.0
    static let releaseDuration = 0.25
    static let brakingDuration = 0.25
    let start: Double
    let direction: Double
    let end: Double
    var initialSpeed = 0.0
    var target: Double? = nil
    var targetSpeed: Double { target ?? direction * Self.maximumRate }
    var settlingDuration: Double { rampTime }
    func settled(at time: Double) -> Bool { time >= rampTime }
    private var isRelease: Bool { target == 0 || target == 1 }
    private var isHeldTurn: Bool { !isRelease && initialSpeed * targetSpeed < 0 }
    private var turnTime: Double {
        isHeldTurn ? Self.brakingDuration : sqrt(abs(initialSpeed) / acceleration)
    }
    private var acceleration: Double {
        isRelease ? abs(targetSpeed - initialSpeed) / (Self.releaseDuration * Self.releaseDuration) : 4
    }
    private var rampTime: Double {
        guard targetSpeed != initialSpeed else { return 0 }
        if isHeldTurn { return turnTime + sqrt(abs(targetSpeed) / acceleration) }
        return isRelease ? Self.releaseDuration : sqrt(abs(targetSpeed - initialSpeed) / acceleration)
    }
    func speed(at time: Double) -> Double {
        let sign = targetSpeed >= initialSpeed ? 1.0 : -1.0
        if time >= rampTime { return targetSpeed }
        let t = max(0, time)
        if isHeldTurn {
            if t < turnTime { return initialSpeed * (1 - pow(t / turnTime, 2)) }
            return sign * acceleration * pow(t - turnTime, 2)
        }
        return initialSpeed + sign * acceleration * t * t
    }
    func distance(at time: Double) -> Double {
        let t = max(0, time), a = min(t, rampTime)
        let sign = targetSpeed >= initialSpeed ? 1.0 : -1.0
        if isHeldTurn {
            // Integrate the same two phases used by the audio resampler and cursor.
            let brakingTime = min(a, turnTime), reverseTime = max(0, a - turnTime)
            let brakingDistance = initialSpeed * (brakingTime - pow(brakingTime, 3) / (3 * turnTime * turnTime))
            return brakingDistance + sign * acceleration * pow(reverseTime, 3) / 3 + targetSpeed * max(0, t - rampTime)
        }
        return initialSpeed * a + sign * acceleration * a * a * a / 3 + targetSpeed * max(0, t - rampTime)
    }
    func position(at time: Double) -> Double {
        if initialSpeed * targetSpeed < 0 {
            let turn = turnTime
            if time >= turn {
                let pivot = min(end, max(0, start + distance(at: turn)))
                return min(end, max(0, pivot + distance(at: time) - distance(at: turn)))
            }
        }
        return min(end, max(0, start + distance(at: time)))
    }
    func reachedBoundary(at time: Double) -> Bool {
        if targetSpeed == 0 && settled(at: time) { return true }
        return direction < 0 ? position(at: time) <= 0 : position(at: time) >= end
    }
}

// A private source/cache snapshot avoids decoding on the UI thread. Read only
// the small window needed by the next output block; never instantiate plug-ins
// or prepare a full-project mix just to move the cursor.
