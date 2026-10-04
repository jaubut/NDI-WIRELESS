//
//  NDIService.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import CoreGraphics
import Foundation

/// Receiver bandwidth, mirroring `NDIlib_recv_bandwidth_e`.
///
/// `.lowest` asks the sender for a low-resolution proxy: cheap on a crowded set
/// network, but false colour and the histogram are then read off the proxy, so the
/// UI has to say so (`PROXY`).
nonisolated enum NDIBandwidthMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case highest
    case lowest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .highest: return "Full"
        case .lowest:  return "Proxy"
        }
    }

    var isProxy: Bool { self == .lowest }
}

/// How a selected source is doing right now.
///
/// `since` is kept from the moment the gap opened, so the chip can count up rather
/// than resetting on every poll.
nonisolated enum SourceConnectionState: Equatable, Sendable {
    case live
    case reconnecting(since: Date)

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}

/// One PTZ instruction, mirroring the `NDIlib_recv_ptz_*` calls (`Recv.ex.h`).
///
/// Speeds run -1...1 and presets 0...99, as in the SDK. The real transport clamps the
/// values, so a stray gesture value can never reach the camera out of range.
nonisolated enum PTZCommand: Equatable, Sendable {
    /// Continuous move. Positive pan is **left** and positive tilt is **up**, per the SDK.
    /// (0, 0) stops.
    case panTiltSpeed(pan: Float, tilt: Float)
    /// Continuous zoom: positive zooms in (tele), negative zooms out (wide), 0 stops.
    case zoomSpeed(Float)
    case recallPreset(Int)
    case storePreset(Int)
    case autoFocus

    static let presetRange = 0...99

    /// Joystick resolution: a drag only reaches the camera when this step changes.
    static let speedStep: Float = 0.1

    /// A speed clamped to -1...1 and snapped to `speedStep`. Non-finite reads as stop.
    static func quantized(_ speed: Float) -> Float {
        guard speed.isFinite else { return 0 }
        return (min(1, max(-1, speed)) / speedStep).rounded() * speedStep
    }

    /// The same command with every value clamped to the range the SDK accepts.
    var clamped: PTZCommand {
        func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(-1, v)) : 0 }
        func preset(_ n: Int) -> Int { min(Self.presetRange.upperBound, max(Self.presetRange.lowerBound, n)) }
        switch self {
        case .panTiltSpeed(let pan, let tilt): return .panTiltSpeed(pan: unit(pan), tilt: unit(tilt))
        case .zoomSpeed(let speed): return .zoomSpeed(unit(speed))
        case .recallPreset(let n): return .recallPreset(preset(n))
        case .storePreset(let n): return .storePreset(preset(n))
        case .autoFocus: return .autoFocus
        }
    }
}

protocol NDIService: AnyObject {
    /// Discover sources on the network. Yields updated source lists over time.
    func discoverSources() -> AsyncStream<[NDISource]>

    /// Start receiving video frames from a source at the requested bandwidth.
    /// The stream carries *new* frames only — repeats from the frame sync are dropped.
    func startReceiving(from source: NDISource, bandwidth: NDIBandwidthMode) -> AsyncStream<CGImage>

    /// Stop receiving from a source.
    func stopReceiving(from source: NDISource)

    /// Stop all receivers and discovery.
    func stopAll()

    /// A snapshot of receive health for a source, or nil when nothing is receiving it.
    /// Pull this; never push it — the frame rate is not a UI refresh rate.
    func stats(for source: NDISource) -> FrameStats?

    /// Re-point an existing receiver at its source after the network moved.
    ///
    /// The cheap half of the recovery ladder: it must never destroy or replace a
    /// receiver, only ask the one that is already there to find its sender again. A
    /// source that is not being received is a no-op, not an error.
    func reconnect(_ source: NDISource)

    /// Current audio peak meters for a source, or nil before any audio has been recorded.
    /// Pulled by the meter view at its own redraw rate, like `stats(for:)`. Never pushed.
    func audioLevels(for source: NDISource) -> AudioLevels?

    /// The sender advertises PTZ control (`NDIlib_recv_ptz_is_supported`). False when
    /// nothing is receiving the source.
    func isPTZSupported(_ source: NDISource) -> Bool

    /// Send one PTZ instruction to the camera behind a source. When nothing is receiving
    /// the source, this does nothing.
    func sendPTZ(_ command: PTZCommand, to source: NDISource)
}
