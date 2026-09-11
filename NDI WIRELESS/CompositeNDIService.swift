//
//  CompositeNDIService.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-09-10.
//
//  One built-in source alongside whatever is on the network.
//
//  App Review runs the app on a desk with no NDI sender on the Wi-Fi, so a build that
//  only ever shows "Searching..." is a build that cannot be reviewed. This wraps the real
//  transport and a single-source mock, and routes by id prefix: `demo://` goes to the
//  mock, everything else to the real service. The real service is untouched — it stays
//  the only file that speaks to the NDI C API.
//

import CoreGraphics
import Foundation

/// The real transport plus one demo source, presented as a single `NDIService`.
///
/// Routing is by id prefix rather than by bookkeeping, so there is no state to keep in
/// sync: a source either carries `demo://` or it does not.
final class CompositeNDIService: NDIService {
    /// Ids that belong to the built-in demo rather than to the network.
    static let demoIDPrefix = "demo://"

    /// The one source that is always there. The name is what App Review and the App Store
    /// screenshots show, so it says plainly that this is a demo and not a camera.
    static let demoSource = NDISource(
        id: "\(demoIDPrefix)test-pattern",
        name: "Demo — Test Pattern",
        ipAddress: "Built-in"
    )

    static func isDemo(_ sourceID: String) -> Bool {
        sourceID.hasPrefix(demoIDPrefix)
    }

    private let real: NDIService
    private let demo: NDIService

    /// Both sides are taken as the protocol, not as concrete types: `RealNDIService` only
    /// exists behind `NDI_ENABLED`, so this file has to compile on the simulator too.
    init(real: NDIService, demo: NDIService) {
        self.real = real
        self.demo = demo
    }

    // MARK: - Discovery

    /// Network sources first, the demo source last.
    ///
    /// The two streams are merged rather than chained, so the demo row is on screen before
    /// the finder has said anything and stays there when the finder yields an empty list —
    /// which is exactly the case this whole type exists for.
    func discoverSources() -> AsyncStream<[NDISource]> {
        let real = self.real
        let demo = self.demo

        return AsyncStream { continuation in
            let merged = MergedSources()

            let demoTask = Task { @MainActor in
                for await sources in demo.discoverSources() {
                    merged.demo = sources
                    continuation.yield(merged.all)
                }
            }

            let realTask = Task { @MainActor in
                for await sources in real.discoverSources() {
                    merged.real = sources
                    continuation.yield(merged.all)
                }
            }

            continuation.onTermination = { _ in
                demoTask.cancel()
                realTask.cancel()
            }
        }
    }

    // MARK: - Receiving

    func startReceiving(from source: NDISource, bandwidth: NDIBandwidthMode) -> AsyncStream<CGImage> {
        service(for: source.id).startReceiving(from: source, bandwidth: bandwidth)
    }

    func stopReceiving(from source: NDISource) {
        service(for: source.id).stopReceiving(from: source)
    }

    /// Both sides: a selection can span the demo and the network, and neither half knows
    /// about the other.
    func stopAll() {
        real.stopAll()
        demo.stopAll()
    }

    func stats(for source: NDISource) -> FrameStats? {
        service(for: source.id).stats(for: source)
    }

    func reconnect(_ source: NDISource) {
        service(for: source.id).reconnect(source)
    }

    // MARK: - Private

    private func service(for sourceID: String) -> NDIService {
        Self.isDemo(sourceID) ? demo : real
    }
}

/// The last list each side reported, so a yield from one does not drop the other's rows.
///
/// Isolation is declared rather than inferred: it is written from the two merge tasks,
/// both of which are explicitly on the main actor.
@MainActor
private final class MergedSources {
    var real: [NDISource] = []
    var demo: [NDISource] = []

    var all: [NDISource] { real + demo }
}
