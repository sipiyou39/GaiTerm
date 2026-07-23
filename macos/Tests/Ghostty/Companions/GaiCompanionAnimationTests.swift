#if DEBUG
import Foundation
import Testing
@testable import Ghostty

struct GaiCompanionAnimationTests {
    @Test func workingUsesExactManifestFrameBoundaries() {
        let animation = GaiCompanionAnimation.working

        #expect(animation.definition.durationMilliseconds == 820)
        #expect(animation.frame(at: 0, reduceMotion: false) == 0)
        #expect(animation.frame(at: 0.119, reduceMotion: false) == 0)
        #expect(animation.frame(at: 0.120, reduceMotion: false) == 1)
        #expect(animation.frame(at: 0.599, reduceMotion: false) == 4)
        #expect(animation.frame(at: 0.600, reduceMotion: false) == 5)
        #expect(animation.frame(at: 0.819, reduceMotion: false) == 5)
        #expect(animation.frame(at: 0.820, reduceMotion: false) == 0)
    }

    @Test func jumpingRestartsImmediatelyAfterItsFinalFrame() {
        let animation = GaiCompanionAnimation.jumping

        #expect(animation.definition.durationMilliseconds == 840)
        #expect(animation.repeatDelayMilliseconds == 0)
        #expect(animation.frame(at: 0.839, reduceMotion: false) == 4)
        #expect(animation.frame(at: 0.840, reduceMotion: false) == 0)
        #expect(animation.frame(at: 1.679, reduceMotion: false) == 4)
        #expect(animation.frame(at: 1.680, reduceMotion: false) == 0)
    }

    @Test func oneShotTerminalStatesHoldTheirRepresentativeFinalFrame() {
        #expect(GaiCompanionAnimation.ready.frame(at: 50, reduceMotion: false) == 5)
        #expect(GaiCompanionAnimation.failed.frame(at: 50, reduceMotion: false) == 7)
        #expect(GaiCompanionAnimation.ready.timeUntilNextFrame(
            at: 50,
            reduceMotion: false) == nil)
        #expect(GaiCompanionAnimation.failed.timeUntilNextFrame(
            at: 50,
            reduceMotion: false) == nil)
    }

    @Test func nextFrameDelayTracksOnlyManifestBoundaries() throws {
        let working = GaiCompanionAnimation.working

        try expectDelay(working.timeUntilNextFrame(at: 0, reduceMotion: false), equals: 0.120)
        try expectDelay(
            working.timeUntilNextFrame(at: 0.119, reduceMotion: false),
            equals: 0.001)
        try expectDelay(
            working.timeUntilNextFrame(at: 0.120, reduceMotion: false),
            equals: 0.120)
        try expectDelay(
            working.timeUntilNextFrame(at: 0.820, reduceMotion: false),
            equals: 0.120)

        let jumping = GaiCompanionAnimation.jumping
        try expectDelay(
            jumping.timeUntilNextFrame(at: 0.839, reduceMotion: false),
            equals: 0.001)
        try expectDelay(
            jumping.timeUntilNextFrame(at: 0.840, reduceMotion: false),
            equals: 0.140)
    }

    @Test func persistentFinalFrameStopsSchedulingAsSoonAsItAppears() throws {
        let ready = GaiCompanionAnimation.ready

        try expectDelay(
            ready.timeUntilNextFrame(at: 0.749, reduceMotion: false),
            equals: 0.001)
        #expect(ready.frame(at: 0.750, reduceMotion: false) == 5)
        #expect(ready.timeUntilNextFrame(at: 0.750, reduceMotion: false) == nil)
    }

    @Test func reduceMotionUsesStaticFramesAndNeverSchedulesAClock() {
        #expect(GaiCompanionAnimation.working.frame(at: 10, reduceMotion: true) == 0)
        #expect(GaiCompanionAnimation.ready.frame(at: 0, reduceMotion: true) == 5)
        #expect(GaiCompanionAnimation.failed.frame(at: 0, reduceMotion: true) == 7)
        #expect(GaiCompanionAnimation.working.timeUntilNextFrame(
            at: 0,
            reduceMotion: true) == nil)
        #expect(GaiCompanionAnimation.jumping.timeUntilNextFrame(
            at: 0,
            reduceMotion: true) == nil)
    }

    private func expectDelay(
        _ actual: TimeInterval?,
        equals expected: TimeInterval
    ) throws {
        let actual = try #require(actual)
        #expect(abs(actual - expected) < 0.000_001)
    }
}
#endif
