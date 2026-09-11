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
}
