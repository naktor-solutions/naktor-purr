import Testing

@testable import Barktor

// #expect captures its operands immutably, so every mutating call is hoisted
// into a local before the assertion.
struct HandsFreeLockTests {
    private let clock = ContinuousClock()

    @Test func quickDoubleTapLocksAndNextPressStops() {
        var lock = HandsFreeLock()
        let t0 = clock.now
        let first = lock.press(at: t0, recordingAlive: false)
        #expect(first == .begin)
        let tapRelease = lock.release(at: t0.advanced(by: .milliseconds(120)))
        #expect(tapRelease == .deferStop)
        let second = lock.press(at: t0.advanced(by: .milliseconds(250)), recordingAlive: true)
        #expect(second == .lock)
        #expect(lock.isLocked)
        // The locking press's own release must not stop the dictation.
        let lockedRelease = lock.release(at: t0.advanced(by: .milliseconds(400)))
        #expect(lockedRelease == .ignore)
        // The next press is the stop gesture.
        let third = lock.press(at: t0.advanced(by: .seconds(5)), recordingAlive: true)
        #expect(third == .stop)
        #expect(!lock.isLocked)
    }

    @Test func singleQuickTapStopsWhenTimerFires() {
        var lock = HandsFreeLock()
        let t0 = clock.now
        _ = lock.press(at: t0, recordingAlive: false)
        let tapRelease = lock.release(at: t0.advanced(by: .milliseconds(100)))
        #expect(tapRelease == .deferStop)
        let firstFire = lock.deferredStopFired()
        #expect(firstFire)  // the timer's cue to stop now
        let secondFire = lock.deferredStopFired()
        #expect(!secondFire)  // disarmed: a second fire is a no-op
    }

    @Test func longHoldReleaseStopsImmediately() {
        var lock = HandsFreeLock()
        let t0 = clock.now
        _ = lock.press(at: t0, recordingAlive: false)
        let holdRelease = lock.release(at: t0.advanced(by: .milliseconds(800)))
        #expect(holdRelease == .stop)
    }

    @Test func staleLockSelfHealsIntoAFreshStart() {
        var lock = HandsFreeLock()
        let t0 = clock.now
        _ = lock.press(at: t0, recordingAlive: false)
        _ = lock.release(at: t0.advanced(by: .milliseconds(100)))
        _ = lock.press(at: t0.advanced(by: .milliseconds(200)), recordingAlive: true)
        #expect(lock.isLocked)
        // Esc killed the locked dictation: the next press starts fresh,
        // it must never read as "stop".
        let pressAfterDeath = lock.press(at: t0.advanced(by: .seconds(3)), recordingAlive: false)
        #expect(pressAfterDeath == .begin)
        #expect(!lock.isLocked)
    }

    @Test func pressAfterDeferredStopBeginsPlainDictation() {
        var lock = HandsFreeLock()
        let t0 = clock.now
        _ = lock.press(at: t0, recordingAlive: false)
        _ = lock.release(at: t0.advanced(by: .milliseconds(100)))
        let fired = lock.deferredStopFired()
        #expect(fired)
        // Past the window: a plain new dictation, no lock.
        let latePress = lock.press(at: t0.advanced(by: .seconds(1)), recordingAlive: false)
        #expect(latePress == .begin)
        #expect(!lock.isLocked)
    }

    @Test func armedDeferralWithDeadRecordingBeginsFresh() {
        var lock = HandsFreeLock()
        let t0 = clock.now
        _ = lock.press(at: t0, recordingAlive: false)
        _ = lock.release(at: t0.advanced(by: .milliseconds(100)))
        // The recording died (error) before the second press: begin, don't lock.
        let press = lock.press(at: t0.advanced(by: .milliseconds(200)), recordingAlive: false)
        #expect(press == .begin)
        #expect(!lock.isLocked)
    }

    @Test func releaseWithoutPressStops() {
        var lock = HandsFreeLock()
        let release = lock.release(at: clock.now)
        #expect(release == .stop)
    }

    @Test func tapMaxHoldBoundaryIsExclusive() {
        var atThreshold = HandsFreeLock()
        let t0 = clock.now
        _ = atThreshold.press(at: t0, recordingAlive: false)
        // Exactly tapMaxHold is a hold, not a tap.
        let boundaryRelease = atThreshold.release(at: t0.advanced(by: HandsFreeLock.tapMaxHold))
        #expect(boundaryRelease == .stop)

        var justUnder = HandsFreeLock()
        _ = justUnder.press(at: t0, recordingAlive: false)
        let underRelease = justUnder.release(
            at: t0.advanced(by: HandsFreeLock.tapMaxHold - .milliseconds(1)))
        #expect(underRelease == .deferStop)
    }

    @Test func resetClearsLockAndDeferral() {
        var lock = HandsFreeLock()
        let t0 = clock.now
        _ = lock.press(at: t0, recordingAlive: false)
        _ = lock.release(at: t0.advanced(by: .milliseconds(100)))
        _ = lock.press(at: t0.advanced(by: .milliseconds(200)), recordingAlive: true)
        #expect(lock.isLocked)
        lock.reset()
        #expect(!lock.isLocked)
        let fired = lock.deferredStopFired()
        #expect(!fired)
    }
}
