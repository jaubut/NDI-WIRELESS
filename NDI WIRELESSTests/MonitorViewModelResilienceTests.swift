//
//  MonitorViewModelResilienceTests.swift
//  NDI WIRELESSTests
//
//  Created by Jeremie Aubut on 2026-09-11.
//
//  Mock-only: this suite runs on the simulator against in-target fakes, where no NDI
//  symbol is linked — it asserts view-model behaviour and call ordering, never C teardown.
//

import CoreGraphics
import Foundation
import Testing
@testable import NDI_WIRELESS

/// Records what the view model asks of the transport, and keeps a live count of the frame
/// streams it has handed out: an orphaned receive task shows up as a second live stream
/// for the same id.
///
/// Explicitly `@MainActor` — the app module defaults to it, the test module does not.
@MainActor
private final class SpyNDIService: NDIService {
    enum Call: Equatable {
        case startReceiving(String)
        case reconnect(String)
        case stopReceiving(String)
        case stopAll
    }

    private(set) var calls: [Call] = []
    private(set) var liveStreams: [String: Int] = [:]
    /// Every stop, paired with the ids that still had a live receive task at that moment.
    private(set) var stopsWhileLive: [(call: Call, live: Set<String>)] = []

    /// Asked at each stop. The test wires this to the view model.
    var liveReceiverIDs: () -> Set<String> = { [] }

    /// When set, the transport reports a feed with nobody on the other end and no new
    /// frames — what drives the escalation ladder past its first step.
    var isStarved = false

    private var discoveryContinuation: AsyncStream<[NDISource]>.Continuation?
    private var received: [String: Int64] = [:]

    // MARK: - Test control

    /// True once the view model's discovery task has actually asked for the stream. It
    /// starts on the next main-actor hop, not on the call, so a yield before this is lost.
    var hasDiscoveryStream: Bool { discoveryContinuation != nil }

    func yieldDiscovery(_ sources: [NDISource]) {
        discoveryContinuation?.yield(sources)
    }

    func count(_ call: Call) -> Int {
        calls.filter { $0 == call }.count
    }

    // MARK: - NDIService

    func discoverSources() -> AsyncStream<[NDISource]> {
        AsyncStream { continuation in
            discoveryContinuation = continuation
        }
    }

    func startReceiving(from source: NDISource, bandwidth: NDIBandwidthMode) -> AsyncStream<CGImage> {
        let sourceID = source.id
        calls.append(.startReceiving(sourceID))
        received[sourceID] = 0

        return AsyncStream { continuation in
            liveStreams[sourceID, default: 0] += 1
            if let image = Self.onePixel() {
                received[sourceID] = (received[sourceID] ?? 0) + 1
                continuation.yield(image)
            }
            continuation.onTermination = { [weak self] _ in
                // Bound to a `let` before the hop: capturing the weak `var` itself in
                // concurrent code is an error under the Swift 6 language mode.
                let spy = self
                Task { @MainActor in
                    spy?.liveStreams[sourceID, default: 0] -= 1
                }
            }
        }
    }

    func stopReceiving(from source: NDISource) {
        calls.append(.stopReceiving(source.id))
        stopsWhileLive.append((.stopReceiving(source.id), liveReceiverIDs()))
    }

    func stopAll() {
        calls.append(.stopAll)
        stopsWhileLive.append((.stopAll, liveReceiverIDs()))
    }

    func stats(for source: NDISource) -> FrameStats? {
        guard liveStreams[source.id, default: 0] > 0 else { return nil }
        return FrameStats(
            fps: isStarved ? 0 : 30,
            msSinceLastFrame: isStarved ? 9_000 : 20,
            received: received[source.id] ?? 0,
            dropped: 0,
            late: 0,
            isEstimated: false,
            connections: isStarved ? 0 : 1
        )
    }

    func reconnect(_ source: NDISource) {
        calls.append(.reconnect(source.id))
    }

    private nonisolated static func onePixel() -> CGImage? {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }
}

@MainActor
struct MonitorViewModelResilienceTests {
    private func source(_ id: String) -> NDISource {
        NDISource(id: id, name: id.uppercased(), ipAddress: "192.168.1.1")
    }

    /// Path changes are driven by hand, so the real monitor is parked out of the way
    /// rather than left to fire on whatever the test machine's Wi-Fi is doing.
    private func makeViewModel(_ service: NDIService) -> MonitorViewModel {
        let viewModel = MonitorViewModel(
            service: service,
            pathMonitor: NetworkPathMonitor(debounceSeconds: 3_600)
        )
        // The ladder's real timings are 6 s and 20 s; these are the same ladder, in
        // proportion, at a speed a test can sit through.
        viewModel.rebuildAfterSeconds = 0.3
        viewModel.rediscoverAfterSeconds = 0.6
        return viewModel
    }

    private var pathChange: PathChange {
        PathChange(isSatisfied: true, interfaceFingerprint: "wifi:en0|10.0.0.1")
    }

    /// Start discovery and put a first list on the wire, once the view model is actually
    /// listening for one.
    private func startDiscovery(
        _ viewModel: MonitorViewModel,
        _ spy: SpyNDIService,
        with sources: [NDISource]
    ) async {
        viewModel.startDiscovery()
        #expect(await waitUntil { spy.hasDiscoveryStream })
        spy.yieldDiscovery(sources)
    }

    @discardableResult
    private func waitUntil(
        timeoutSeconds: Double = 5,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aDiscoveryFlapKeepsTilesOrderAndFrames() async {
        let spy = SpyNDIService()
        let viewModel = makeViewModel(spy)

        await startDiscovery(viewModel, spy, with: [source("a"), source("b"), source("c")])
        #expect(await waitUntil { viewModel.discoveredSources.count == 3 })

        viewModel.startReceiving(source("a"))
        viewModel.startReceiving(source("b"))
        viewModel.startReceiving(source("c"))
        #expect(await waitUntil {
            viewModel.frames["a"] != nil && viewModel.frames["b"] != nil
                && viewModel.frames["c"] != nil
        })

        // The flap: everything disappears from discovery, then a reordered subset
        // comes back — exactly what an access-point change looks like from here.
        spy.yieldDiscovery([])
        #expect(await waitUntil { viewModel.discoveredSources.isEmpty })
        spy.yieldDiscovery([source("c"), source("a")])
        #expect(await waitUntil { viewModel.discoveredSources.count == 2 })

        // What MultiViewGrid renders, resolved the same way it resolves it.
        let tiles = viewModel.selectedSources.compactMap { viewModel.sourceIndex[$0] }
        #expect(tiles.map(\.id) == ["a", "b", "c"])
        #expect(viewModel.frames["a"] != nil)
        #expect(viewModel.frames["b"] != nil)
        #expect(viewModel.frames["c"] != nil)
        // The single view's title comes from the same index, so it survives too.
        #expect(viewModel.primarySourceID == "a")
        #expect(viewModel.sourceIndex["b"]?.name == "B")

        viewModel.stopAll()
    }

    @Test func theLadderNeverStopsAReceiverThatIsStillLive() async {
        let spy = SpyNDIService()
        let viewModel = makeViewModel(spy)
        spy.liveReceiverIDs = { [weak viewModel] in viewModel?.receivingSourceIDs ?? [] }

        await startDiscovery(viewModel, spy, with: [source("a"), source("b")])
        viewModel.startReceiving(source("a"))
        viewModel.startReceiving(source("b"))
        #expect(await waitUntil { viewModel.frames["a"] != nil && viewModel.frames["b"] != nil })

        // Nothing is coming back: the ladder runs all the way to step 3.
        spy.isStarved = true
        viewModel.handlePathChange(pathChange)
        #expect(await waitUntil { spy.count(.startReceiving("a")) == 2 })
        try? await Task.sleep(for: .seconds(0.5))

        // The whole recovery ran without ever telling the transport to stop: a rebuild
        // goes through `resubscribe`, which cancels its own task and re-subscribes.
        #expect(spy.count(.stopReceiving("a")) == 0)
        #expect(spy.count(.stopReceiving("b")) == 0)
        #expect(spy.count(.stopAll) == 0)
        // It did escalate — one rebuild each, not none.
        #expect(spy.count(.startReceiving("b")) == 2)

        // The teardown paths are allowed to stop; the invariant is *when*.
        viewModel.stopReceiving(source("a"))
        viewModel.stopAll()
        #expect(spy.count(.stopAll) == 1)
        for stop in spy.stopsWhileLive {
            if case .stopReceiving(let id) = stop.call {
                #expect(!stop.live.contains(id))
            } else {
                #expect(stop.live.isEmpty)
            }
        }
    }

    @Test func twoPathChangesLeaveOneReconnectEachAndOneLiveTaskPerSource() async {
        let spy = SpyNDIService()
        let viewModel = makeViewModel(spy)

        await startDiscovery(viewModel, spy, with: [source("a"), source("b")])
        viewModel.startReceiving(source("a"))
        viewModel.startReceiving(source("b"))
        #expect(await waitUntil { viewModel.frames["a"] != nil && viewModel.frames["b"] != nil })
        #expect(spy.count(.startReceiving("a")) == 1)

        spy.isStarved = true
        viewModel.handlePathChange(pathChange)
        #expect(spy.count(.reconnect("a")) == 1)
        #expect(spy.count(.reconnect("b")) == 1)

        // Second change while the first ladder is still waiting on its rebuild.
        try? await Task.sleep(for: .milliseconds(200))
        viewModel.handlePathChange(pathChange)

        // Exactly one re-point per selected source per change, no more.
        #expect(spy.count(.reconnect("a")) == 2)
        #expect(spy.count(.reconnect("b")) == 2)

        // The first ladder was cancelled before it could rebuild, so there is one rebuild
        // and one live stream per id — not two tasks racing to write `frames[id]`.
        #expect(await waitUntil { spy.count(.startReceiving("a")) == 2 })
        #expect(await waitUntil { spy.liveStreams["a"] == 1 && spy.liveStreams["b"] == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(spy.liveStreams["a"] == 1)
        #expect(spy.liveStreams["b"] == 1)
        #expect(spy.count(.startReceiving("a")) == 2)
        #expect(spy.count(.startReceiving("b")) == 2)

        viewModel.stopAll()
    }

    @Test func aPathChangeAgainstTheMockKeepsTheWallAndItsPicture() async {
        let viewModel = makeViewModel(MockNDIService())
        viewModel.startDiscovery()
        viewModel.startReceiving(source("obs-1"))
        viewModel.startReceiving(source("camera-1"))
        #expect(await waitUntil {
            viewModel.frames["obs-1"] != nil && viewModel.frames["camera-1"] != nil
        })

        viewModel.handlePathChange(pathChange)

        // Through the whole ladder: same tiles, same order, never a blank one.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            #expect(viewModel.selectedSources == ["obs-1", "camera-1"])
            #expect(viewModel.frames["obs-1"] != nil)
            #expect(viewModel.frames["camera-1"] != nil)
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Discovery was re-run rather than switched off.
        #expect(viewModel.isDiscovering)

        viewModel.stopAll()
    }
}
