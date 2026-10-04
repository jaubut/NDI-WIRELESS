//
//  AudioLevelMeter.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-10-04.
//
//  Peak meters, measured where the audio lands. Pure Swift with no NDI types, like
//  `FrameStatsAccumulator`: the mock and the real transport share it, and the unit
//  target can drive it on the simulator. The capture loop is the only writer. The meter
//  view reads it at its own redraw rate through the view model, and never through
//  `@Observable` state.
//

import Foundation
import Synchronization

/// One read of the meters for a single source.
nonisolated struct AudioLevels: Sendable, Equatable {
    /// Per-channel peak in dBFS, clamped to `AudioLevelMeter.floorDB`...0 and decaying
    /// at the release rate.
    var channels: [Float]
    /// A channel reached full scale within the last `clipHoldSeconds`.
    var isClipped: Bool
}

nonisolated final class AudioLevelMeter: Sendable {
    /// Bottom of the scale. Anything quieter reads as the floor.
    static let floorDB: Float = -60
    /// How far a held peak falls each second, about a PPM's fall-back. Calibration knob.
    static let releaseDBPerSecond: Float = 12
    /// How long the clip lamp stays lit after the last over.
    static let clipHoldSeconds: Double = 2

    /// NDI float audio is not dBFS. Under the SDK convention, 1.0 is +4 dBu, with 20 dB of
    /// headroom before digital full scale. That is also the default `reference_level` of
    /// `NDIlib_util_audio_to_interleaved_16s_v2`.
    /// Calibration knob: if the Mac sender passes Core Audio floats through unscaled
    /// (1.0 = 0 dBFS), this has to be 0. Check it with a known tone.
    static let headroomDB: Float = 20

    private nonisolated struct State {
        var levels: [Float] = []
        var updatedAt: Double?
        var clippedAt: Double?
    }

    private let state = Mutex(State())

    init() {}

    /// Absolute linear peak per channel of one planar float block (NDI's audio layout).
    static func peaks(
        planar data: UnsafePointer<Float>,
        channelStrideInBytes: Int,
        channels: Int,
        samples: Int
    ) -> [Float] {
        let floatsPerChannel = channelStrideInBytes / MemoryLayout<Float>.stride
        guard channels > 0, samples > 0, floatsPerChannel >= samples else { return [] }
        return (0..<channels).map { channel in
            let start = data + channel * floatsPerChannel
            var peak: Float = 0
            for i in 0..<samples {
                peak = max(peak, abs(start[i]))
            }
            return peak
        }
    }

    /// Linear NDI sample value to dBFS, clamped to the meter's scale.
    static func dbfs(_ linear: Float) -> Float {
        guard linear > 0 else { return floorDB }
        let db = 20 * log10(linear) - headroomDB
        return min(0, max(floorDB, db))
    }

    /// Record one block's per-channel linear peaks.
    func record(peaks: [Float], at now: Double = FrameStatsAccumulator.now()) {
        let incoming = peaks.map(Self.dbfs)
        let clipped = incoming.contains { $0 >= 0 }
        state.withLock { (s: inout State) -> Void in
            let held = s.levels.count == incoming.count
                ? Self.decayed(s.levels, since: s.updatedAt, now: now)
                : incoming
            s.levels = zip(held, incoming).map { max($0, $1) }
            s.updatedAt = now
            if clipped { s.clippedAt = now }
        }
    }

    /// The meters as they stand now, or nil before any audio has been recorded.
    func snapshot(at now: Double = FrameStatsAccumulator.now()) -> AudioLevels? {
        state.withLock { (s: inout State) -> AudioLevels? in
            guard !s.levels.isEmpty else { return nil }
            let isClipped = s.clippedAt.map { now - $0 < Self.clipHoldSeconds } ?? false
            return AudioLevels(
                channels: Self.decayed(s.levels, since: s.updatedAt, now: now),
                isClipped: isClipped
            )
        }
    }

    /// Release applied up to `now`. When a feed stops sending audio, its meter falls back
    /// to the floor. It does not stay frozen at the last level.
    private static func decayed(_ levels: [Float], since: Double?, now: Double) -> [Float] {
        guard let since else { return levels }
        let drop = Float(max(0, now - since)) * releaseDBPerSecond
        return levels.map { max(floorDB, $0 - drop) }
    }
}
