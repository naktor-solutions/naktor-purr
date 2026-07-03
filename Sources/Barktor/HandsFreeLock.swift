import Foundation

// Wispr-style hands-free lock for hold-to-talk: a quick tap followed by a
// quick second press locks the recording on, so the user can dictate without
// holding the key; the next press stops it. This is a pure decision table
// over caller-supplied instants - AppCoordinator owns the real deferred-stop
// timer, this type owns the timing rules so they stay unit-testable.
struct HandsFreeLock {
    enum PressDecision: Equatable { case begin, lock, stop }
    enum ReleaseDecision: Equatable { case stop, deferStop, ignore }

    // A release under tapMaxHold reads as a tap (not a talk), so its stop is
    // deferred by secondPressWindow to wait for the locking second press.
    // Real dictations shorter than tapMaxHold don't survive anyway (they sit
    // under the batch minKeepSamples floor), so the deferral delays nothing
    // the user would ever see transcribed.
    static let tapMaxHold: Duration = .milliseconds(350)
    static let secondPressWindow: Duration = .milliseconds(300)

    private(set) var isLocked = false
    private var pressedAt: ContinuousClock.Instant?
    private var deferredStopArmed = false

    // recordingAlive: the dictation this lock refers to still exists
    // (state == .recording, or the streaming session is still starting up).
    mutating func press(
        at now: ContinuousClock.Instant, recordingAlive: Bool
    ) -> PressDecision {
        if isLocked {
            isLocked = false
            // The locked dictation can die under us (Esc cancel, engine
            // error): a press then means "start fresh", never "stop".
            guard recordingAlive else {
                pressedAt = now
                return .begin
            }
            pressedAt = nil
            return .stop
        }
        if deferredStopArmed, recordingAlive {
            deferredStopArmed = false
            isLocked = true
            return .lock
        }
        deferredStopArmed = false
        pressedAt = now
        return .begin
    }

    mutating func release(at now: ContinuousClock.Instant) -> ReleaseDecision {
        if isLocked { return .ignore }
        guard let pressedAt, now - pressedAt < Self.tapMaxHold else { return .stop }
        deferredStopArmed = true
        return .deferStop
    }

    // True exactly once per armed deferral: the timer's cue to perform the
    // stop it was holding back.
    mutating func deferredStopFired() -> Bool {
        guard deferredStopArmed else { return false }
        deferredStopArmed = false
        return true
    }

    mutating func reset() {
        isLocked = false
        deferredStopArmed = false
        pressedAt = nil
    }
}
