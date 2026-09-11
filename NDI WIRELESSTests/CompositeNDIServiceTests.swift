//
//  CompositeNDIServiceTests.swift
//  NDI WIRELESSTests
//
//  Created by Jeremie Aubut on 2026-09-10.
//
//  Routing is the whole of this type's behaviour, so it is driven against two stubs: a
//  call sent to the wrong half is a demo pattern shown in place of a camera, or a camera
//  quietly not received at all.
//

import CoreGraphics
import Foundation
import Testing
@testable import NDI_WIRELESS

/// Records what it was asked to do and answers with whatever the test set up.
///
/// Explicitly `@MainActor` — the app module defaults to it, the test module does not.
@MainActor
private final class StubNDIService: NDIService {
    enum Call: Equatable {
        case discoverSources
        case startReceiving(String)
        case stopReceiving(String)
        case stopAll
        case stats(String)
        case reconnect(String)
    }

    private(set) var calls: [Call] = []

    /// What this stub's finder reports. Nil means a finder that never says anything —
    /// the case the demo source exists for.
    var discovered: [NDISource]?

    private var continuation: AsyncStream<[NDISource]>.Continuation?

    func yieldDiscovery(_ sources: [NDISource]) {
        continuation?.yield(sources)
    }

    func discoverSources() -> AsyncStream<[NDISource]> {
        calls.append(.discoverSources)
        return AsyncStream { continuation in
            self.continuation = continuation
            if let discovered {
                continuation.yield(discovered)
            }
        }
    }

    func startReceiving(from source: NDISource, bandwidth: NDIBandwidthMode) -> AsyncStream<CGImage> {
        calls.append(.startReceiving(source.id))
        return AsyncStream { _ in }
    }

    func stopReceiving(from source: NDISource) {
        calls.append(.stopReceiving(source.id))
    }

    func stopAll() {
        calls.append(.stopAll)
    }

    func stats(for source: NDISource) -> FrameStats? {
        calls.append(.stats(source.id))
        return FrameStats(fps: 30, msSinceLastFrame: 20, received: 1)
    }

    func reconnect(_ source: NDISource) {
        calls.append(.reconnect(source.id))
    }
}

/// A main-actor box for what the merged stream last produced.
///
/// A plain local `var` captured by a `Task` closure is a mutation from concurrently
/// executing code; the box keeps the mutation on the actor that owns it.
@MainActor
private final class LatestSources {
    var ids: [String] = []
    var count: Int { ids.count }
    /// Set when the stream finishes rather than merely going quiet — the difference
    /// between a discovery that stopped and one that is still running with nothing to say.
    var didFinish = false
}

/// Counts frames as they land, so "did anything arrive after the stop" is answerable.
@MainActor
private final class FrameCounter {
    var count = 0
}

@MainActor
struct CompositeNDIServiceTests {
    private let camera = NDISource(id: "CAM (Studio)", name: "CAM", ipAddress: "192.168.1.10")
    private var demoSource: NDISource { CompositeNDIService.demoSource }

    private func waitUntil(timeoutSeconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func theDemoSourceIsNamedAndPrefixedExactlyAsTheStoreListingExpects() {
        #expect(demoSource.name == "Demo — Test Pattern")
        #expect(demoSource.id.hasPrefix("demo://"))
        #expect(CompositeNDIService.isDemo(demoSource.id))
        #expect(!CompositeNDIService.isDemo(camera.id))
    }

    @Test func aDemoIdGoesToTheDemoServiceAndEverythingElseToTheReal() {
        let real = StubNDIService()
        let demo = StubNDIService()
        let composite = CompositeNDIService(real: real, demo: demo)

        _ = composite.startReceiving(from: demoSource, bandwidth: .highest)
        _ = composite.startReceiving(from: camera, bandwidth: .lowest)
        composite.stopReceiving(from: demoSource)
        composite.stopReceiving(from: camera)
        _ = composite.stats(for: demoSource)
        _ = composite.stats(for: camera)
        composite.reconnect(demoSource)
        composite.reconnect(camera)

        #expect(demo.calls == [
            .startReceiving(demoSource.id),
            .stopReceiving(demoSource.id),
            .stats(demoSource.id),
            .reconnect(demoSource.id),
        ])
        #expect(real.calls == [
            .startReceiving(camera.id),
            .stopReceiving(camera.id),
            .stats(camera.id),
            .reconnect(camera.id),
        ])
    }

    @Test func stopAllReachesBothHalves() {
        let real = StubNDIService()
        let demo = StubNDIService()
        let composite = CompositeNDIService(real: real, demo: demo)

        composite.stopAll()

        #expect(real.calls == [.stopAll])
        #expect(demo.calls == [.stopAll])
    }

    @Test func discoveryAppendsTheDemoSourceAfterTheNetworksOwn() async {
        let real = StubNDIService()
        real.discovered = [camera]
        let demo = StubNDIService()
        demo.discovered = [demoSource]
        let composite = CompositeNDIService(real: real, demo: demo)

        let latest = LatestSources()
        let task = Task { @MainActor in
            for await sources in composite.discoverSources() {
                latest.ids = sources.map(\.id)
            }
        }

        #expect(await waitUntil { latest.count == 2 })
        #expect(latest.ids == [camera.id, demoSource.id])

        task.cancel()
    }

    /// The case this whole type exists for: App Review's desk, where the finder never
    /// reports anything. The demo row still has to be on screen.
    @Test func theDemoSourceSurvivesAFinderThatNeverYields() async {
        let real = StubNDIService()
        real.discovered = nil
        let demo = StubNDIService()
        demo.discovered = [demoSource]
        let composite = CompositeNDIService(real: real, demo: demo)

        let latest = LatestSources()
        let task = Task { @MainActor in
            for await sources in composite.discoverSources() {
                latest.ids = sources.map(\.id)
            }
        }

        #expect(await waitUntil { latest.ids == [demoSource.id] })

        // And an explicitly empty network list does not drop it either.
        real.yieldDiscovery([])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(latest.ids == [demoSource.id])

        // The network coming back adds to it rather than replacing it.
        real.yieldDiscovery([camera])
        #expect(await waitUntil { latest.count == 2 })
        #expect(latest.ids == [camera.id, demoSource.id])

        task.cancel()
    }

    /// Restricted to one source, and no scripted outage: a reviewer must not see a
    /// `RECONNECTING` chip on the one feed the app is able to show them.
    @Test func theSingleSourceMockYieldsOnlyThatSource() async {
        let mock = MockNDIService(singleSource: demoSource)

        let latest = LatestSources()
        let task = Task { @MainActor in
            for await sources in mock.discoverSources() {
                latest.ids = sources.map(\.id)
            }
        }

        #expect(await waitUntil { latest.count == 1 })
        #expect(latest.ids == [demoSource.id])

        // The multi-source mock grows to four after a couple of seconds; this one must not.
        try? await Task.sleep(for: .seconds(3))
        #expect(latest.ids == [demoSource.id])

        task.cancel()
    }

    /// The demo feed delivers frames through the composite, so the screenshot and the
    /// review session have a picture rather than a spinner.
    @Test func theDemoSourceDeliversFramesThroughTheComposite() async {
        let composite = CompositeNDIService(
            real: StubNDIService(),
            demo: MockNDIService(singleSource: demoSource)
        )
        let viewModel = MonitorViewModel(
            service: composite,
            pathMonitor: NetworkPathMonitor(debounceSeconds: 3_600)
        )

        viewModel.startReceiving(demoSource)
        #expect(await waitUntil { viewModel.frames[demoSource.id] != nil })

        viewModel.stopAll()
    }

    /// `stopAll` has to mean stop. The merge tasks belong to the composite, not to either
    /// child, so forwarding alone would leave them running and the stream open forever;
    /// the view model cancelling its own iteration is what used to hide that.
    @Test func stopAllEndsTheDiscoveryStreamAndTheDemoFeed() async {
        let demo = MockNDIService(singleSource: demoSource)
        let composite = CompositeNDIService(real: StubNDIService(), demo: demo)

        let latest = LatestSources()
        let discovery = Task { @MainActor in
            for await sources in composite.discoverSources() {
                latest.ids = sources.map(\.id)
            }
            latest.didFinish = true
        }

        let frames = FrameCounter()
        let receiving = Task { @MainActor in
            for await _ in composite.startReceiving(from: demoSource, bandwidth: .highest) {
                frames.count += 1
            }
        }

        #expect(await waitUntil { latest.ids == [demoSource.id] })
        #expect(await waitUntil { frames.count > 0 })
        #expect(!latest.didFinish)

        composite.stopAll()

        // The stream ends on its own; nobody cancelled the iteration.
        #expect(await waitUntil { latest.didFinish })

        // And the demo capture loop is done: whatever was in flight may land, but the
        // count must stop moving.
        try? await Task.sleep(for: .milliseconds(300))
        let settled = frames.count
        try? await Task.sleep(for: .milliseconds(500))
        #expect(frames.count == settled)

        discovery.cancel()
        receiving.cancel()
    }

    /// Dropping the stream still works, and does not leave a dead session behind on a
    /// service that lives for the process.
    @Test func droppingTheDiscoveryStreamStopsTheMergeWithoutStopAll() async {
        let real = StubNDIService()
        real.discovered = [camera]
        let composite = CompositeNDIService(real: real, demo: StubNDIService())

        let latest = LatestSources()
        let task = Task { @MainActor in
            for await sources in composite.discoverSources() {
                latest.ids = sources.map(\.id)
            }
            latest.didFinish = true
        }
        #expect(await waitUntil { latest.ids == [camera.id] })

        task.cancel()
        #expect(await waitUntil { latest.didFinish })

        // A second stream still works afterwards.
        let second = LatestSources()
        let secondTask = Task { @MainActor in
            for await sources in composite.discoverSources() {
                second.ids = sources.map(\.id)
            }
        }
        #expect(await waitUntil { second.ids == [camera.id] })
        secondTask.cancel()
    }
}
