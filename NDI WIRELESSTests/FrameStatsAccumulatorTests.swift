//
//  FrameStatsAccumulatorTests.swift
//  NDI WIRELESSTests
//
//  Created by Jeremie Aubut on 2026-09-11.
//
//  Time is injected at every call site, so these assert behaviour rather than sleep.
//

import Testing
@testable import NDI_WIRELESS

struct FrameStatsAccumulatorTests {
    /// 30000/1001 — a real sender's rate, not a round 30.
    private static let rateN: Int32 = 30_000
    private static let rateD: Int32 = 1_001
    private static let interval = Double(rateD) / Double(rateN)

    @Test func fpsIsMeasuredOverTheWindowAndOldFramesLeaveIt() {
        let accumulator = FrameStatsAccumulator()
        let start = 100.0

        // One second of frames at the sender's nominal rate.
        for i in 0..<30 {
            let landed = accumulator.record(
                timestamp: Int64(i), timecode: 0,
                frameRateN: Self.rateN, frameRateD: Self.rateD,
                at: start + Double(i) * Self.interval
            )
            #expect(landed)
        }

        let measured = accumulator.snapshot(at: start + 29 * Self.interval)
        #expect(abs(measured.fps - 29.97) < 0.1)
        #expect(measured.received == 30)

        // A frame far outside the window leaves nothing else to measure against.
        _ = accumulator.record(
            timestamp: 999, timecode: 0,
            frameRateN: Self.rateN, frameRateD: Self.rateD,
            at: start + 60
        )
        let afterGap = accumulator.snapshot(at: start + 60)
        #expect(afterGap.fps == 0)
        #expect(afterGap.received == 31)
    }

    @Test func aGapLongerThanTheNominalIntervalCountsAsLate() {
        let accumulator = FrameStatsAccumulator()
        let start = 500.0

        _ = accumulator.record(
            timestamp: 1, timecode: 0,
            frameRateN: Self.rateN, frameRateD: Self.rateD, at: start
        )
        // On time: one nominal interval later.
        _ = accumulator.record(
            timestamp: 2, timecode: 0,
            frameRateN: Self.rateN, frameRateD: Self.rateD, at: start + Self.interval
        )
        #expect(accumulator.snapshot(at: start + Self.interval).late == 0)

        // Late: six intervals later, well past the 1.5x tolerance.
        _ = accumulator.record(
            timestamp: 3, timecode: 0,
            frameRateN: Self.rateN, frameRateD: Self.rateD, at: start + 7 * Self.interval
        )
        #expect(accumulator.snapshot(at: start + 7 * Self.interval).late == 1)
    }

    @Test func aRepeatedTimestampIsNotANewFrame() {
        let accumulator = FrameStatsAccumulator()

        #expect(accumulator.record(timestamp: 42, timecode: 7, frameRateN: 30, frameRateD: 1, at: 10))
        #expect(!accumulator.record(timestamp: 42, timecode: 7, frameRateN: 30, frameRateD: 1, at: 10.033))
        #expect(!accumulator.record(timestamp: 42, timecode: 7, frameRateN: 30, frameRateD: 1, at: 10.066))
        #expect(accumulator.record(timestamp: 43, timecode: 8, frameRateN: 30, frameRateD: 1, at: 10.1))

        let measured = accumulator.snapshot(at: 10.1)
        #expect(measured.received == 2)
        #expect(!measured.isEstimated)
    }

    @Test func anUndefinedTimestampFallsBackToTimecodeThenToEveryPoll() {
        // Sender publishes no timestamp but a real timecode: dedupe still works, and
        // the reading is still exact.
        let viaTimecode = FrameStatsAccumulator()
        #expect(viaTimecode.record(timestamp: Int64.max, timecode: 900, frameRateN: 30, frameRateD: 1, at: 1))
        #expect(!viaTimecode.record(timestamp: Int64.max, timecode: 900, frameRateN: 30, frameRateD: 1, at: 1.033))
        #expect(viaTimecode.record(timestamp: Int64.max, timecode: 901, frameRateN: 30, frameRateD: 1, at: 1.066))
        #expect(!viaTimecode.snapshot(at: 1.066).isEstimated)
        #expect(viaTimecode.snapshot(at: 1.066).received == 2)

        // Sender publishes neither: count every poll, and say so.
        let estimated = FrameStatsAccumulator()
        for i in 0..<3 {
            #expect(estimated.record(
                timestamp: Int64.max, timecode: Int64.max,
                frameRateN: 30, frameRateD: 1, at: 1 + Double(i) * 0.033
            ))
        }
        let measured = estimated.snapshot(at: 1.066)
        #expect(measured.isEstimated)
        #expect(measured.received == 3)
    }

    @Test func aStarvedPollReportsTheGapAndNoRate() {
        let accumulator = FrameStatsAccumulator()
        _ = accumulator.record(timestamp: 1, timecode: 1, frameRateN: 30, frameRateD: 1, at: 200)

        let measured = accumulator.snapshot(at: 203)
        #expect(measured.fps == 0)
        #expect(measured.msSinceLastFrame != nil)
        #expect(abs((measured.msSinceLastFrame ?? 0) - 3000) < 1)

        // Nothing has ever landed: no reading at all, rather than a zero.
        #expect(FrameStatsAccumulator().snapshot(at: 0).msSinceLastFrame == nil)
    }
}
