//
//  FrameStatsAccumulator.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-09-11.
//
//  Receive health, measured where the frames land. Pure Swift: no NDI types, so the
//  mock and the real transport share one implementation and the unit target can drive
//  it on the simulator.
//
//  Isolation is declared, not inferred: the capture loops are detached and are the only
//  writers, the view model reads a snapshot at 1 Hz from the main actor, and the module
//  builds under `-swift-version 5`, where a data-race mistake is only a warning.
//

import Foundation
import Synchronization

/// One pull of receive health for a single source.
nonisolated struct FrameStats: Sendable, Equatable {
    /// Frames per second over the accumulator's window. 0 until two frames have landed.
    var fps: Double = 0
    /// Milliseconds since the last *new* frame. Nil until the first frame lands.
    var msSinceLastFrame: Double?
    /// Video frames taken delivery of. The SDK's counter on the real transport.
    var received: Int64 = 0
    /// Video frames the SDK reports dropped. Always 0 on the mock.
    var dropped: Int64 = 0
    /// Local estimate — *not* an SDK counter: gaps longer than
    /// `lateTolerance` x the sender's nominal frame interval.
    var late: Int = 0
    /// True when the sender publishes no usable timestamp, so every poll had to be
    /// counted as a frame and the rate is approximate. The UI marks this with `~`.
    var isEstimated: Bool = false
    /// Receiver-side connection count (`NDIlib_recv_get_no_connections`). 1 on the mock.
    var connections: Int = 1

    /// Overlay the transport's own counters on a locally accumulated snapshot.
    func withTransportCounters(received: Int64, dropped: Int64, connections: Int) -> FrameStats {
        var copy = self
        copy.received = received
        copy.dropped = dropped
        copy.connections = connections
        return copy
    }
}

/// Counts *new* frames for one source and answers "how healthy is this feed".
///
/// `framesync_capture_video` can hand back the same frame repeatedly, so a rate counted
/// from poll iterations is a lie. Frames are identified by the SDK timestamp, falling
/// back to the timecode, and only then — when the sender publishes neither — by counting
/// every poll and flagging the result as estimated.
nonisolated final class FrameStatsAccumulator: Sendable {
    /// Frames older than this leave the rate window.
    static let windowSeconds: Double = 2.0
    /// A gap longer than this multiple of the nominal frame interval counts as late.
    static let lateTolerance: Double = 1.5

    private struct State {
        var lastKey: Int64?
        var lastArrival: Double?
        var arrivals: [Double] = []
        var accepted: Int64 = 0
        var late: Int = 0
        var nominalInterval: Double?
        var isEstimated = false
    }

    private let state = Mutex(State())

    init() {}

    /// Monotonic seconds. Not wall clock: it must not jump when the clock is corrected.
    static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    /// Record one captured frame.
    /// - Returns: true when this is a frame the consumer has not seen yet.
    @discardableResult
    func record(
        timestamp: Int64,
        timecode: Int64,
        frameRateN: Int32,
        frameRateD: Int32,
        at now: Double = FrameStatsAccumulator.now()
    ) -> Bool {
        state.withLock { (s: inout State) -> Bool in
            // `NDIlib_recv_timestamp_undefined` is INT64_MAX; so is the synthesize
            // sentinel on timecode. Either one means "this sender did not tell us".
            var key: Int64?
            if timestamp != Int64.max {
                key = timestamp
            } else if timecode != Int64.max {
                key = timecode
            }

            s.isEstimated = key == nil
            if let key {
                guard key != s.lastKey else { return false }
                s.lastKey = key
            }

            if frameRateN > 0, frameRateD > 0 {
                s.nominalInterval = Double(frameRateD) / Double(frameRateN)
            }
            if let previous = s.lastArrival,
               let nominal = s.nominalInterval,
               now - previous > nominal * Self.lateTolerance {
                s.late += 1
            }

            s.lastArrival = now
            s.accepted += 1
            s.arrivals.append(now)
            Self.prune(&s.arrivals, before: now - Self.windowSeconds)
            return true
        }
    }

    /// Current health. Safe to call from any isolation, including while the loop runs.
    func snapshot(at now: Double = FrameStatsAccumulator.now()) -> FrameStats {
        state.withLock { (s: inout State) -> FrameStats in
            Self.prune(&s.arrivals, before: now - Self.windowSeconds)
            return FrameStats(
                fps: Self.rate(of: s.arrivals),
                msSinceLastFrame: s.lastArrival.map { (now - $0) * 1000 },
                received: s.accepted,
                dropped: 0,
                late: s.late,
                isEstimated: s.isEstimated,
                connections: 1
            )
        }
    }

    private static func prune(_ arrivals: inout [Double], before cutoff: Double) {
        while let first = arrivals.first, first < cutoff {
            arrivals.removeFirst()
        }
    }

    /// Rate across the window's span, not a count per wall second: with a partly filled
    /// window the span is what the samples actually cover.
    private static func rate(of arrivals: [Double]) -> Double {
        guard arrivals.count >= 2, let first = arrivals.first, let last = arrivals.last else {
            return 0
        }
        let span = last - first
        guard span > 0 else { return 0 }
        return Double(arrivals.count - 1) / span
    }
}
