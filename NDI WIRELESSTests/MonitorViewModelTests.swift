//
//  MonitorViewModelTests.swift
//  NDI WIRELESSTests
//
//  Created by Jeremie Aubut on 2026-09-11.
//
//  Drives the view model against the mock transport on the simulator. The mock holds no
//  C resources, so these assert selection and frame-flow properties only.
//

import CoreGraphics
import Foundation
import Testing
@testable import NDI_WIRELESS

@MainActor
struct MonitorViewModelTests {
    private func source(_ id: String) -> NDISource {
        NDISource(id: id, name: id.uppercased(), ipAddress: "192.168.1.1")
    }

    private func makeViewModel() -> MonitorViewModel {
        MonitorViewModel(service: MockNDIService())
    }

    /// Wait for a frame to land, polling the main actor rather than sleeping blind.
    private func waitForFrame(
        _ viewModel: MonitorViewModel,
        id: String,
        timeoutSeconds: Double = 10
    ) async -> CGImage? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let frame = viewModel.frames[id] { return frame }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @Test func selectionKeepsItsOrderWhenOneSourceIsRemoved() {
        let viewModel = makeViewModel()
        viewModel.startReceiving(source("A"))
        viewModel.startReceiving(source("B"))
        viewModel.startReceiving(source("C"))
        #expect(viewModel.selectedSources == ["A", "B", "C"])

        viewModel.stopReceiving(source("B"))
        #expect(viewModel.selectedSources == ["A", "C"])

        viewModel.stopAll()
    }

    @Test func selectingTheSameSourceTwiceIsANoOp() {
        let viewModel = makeViewModel()
        let a = source("A")

        viewModel.startReceiving(a)
        viewModel.startReceiving(a)

        #expect(viewModel.selectedSources == ["A"])
        #expect(viewModel.sourceIndex["A"] != nil)

        // One stop still clears it: the second start never added a second entry.
        viewModel.stopReceiving(a)
        #expect(viewModel.selectedSources.isEmpty)

        viewModel.stopAll()
    }

    @Test func primarySourceFallsToTheFirstRemainingSelection() {
        let viewModel = makeViewModel()
        viewModel.startReceiving(source("A"))
        viewModel.startReceiving(source("B"))
        viewModel.startReceiving(source("C"))
        #expect(viewModel.primarySourceID == "A")

        viewModel.stopReceiving(source("A"))
        // Ordered selection, so this is deterministic rather than hash-random.
        #expect(viewModel.primarySourceID == "B")
        #expect(viewModel.primarySourceID == viewModel.selectedSources.first)

        viewModel.stopAll()
    }

    @Test func switchingToProxyHalvesTheFrameWithoutEverBlankingIt() async {
        let viewModel = makeViewModel()
        let a = source("A")
        viewModel.startReceiving(a)

        let full = await waitForFrame(viewModel, id: "A")
        #expect(full?.width == 960)

        viewModel.setBandwidth(.lowest, for: "A")
        #expect(viewModel.bandwidth["A"] == .lowest)

        // The receiver is rebuilt underneath; the last frame must stay on screen
        // throughout, so `frames` is checked on every poll, not just at the end.
        var sawProxy = false
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            #expect(viewModel.frames["A"] != nil)
            if viewModel.frames["A"]?.width == 480 {
                sawProxy = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawProxy)

        viewModel.stopAll()
    }

    // MARK: - Screenshot-mode selection policy
    //
    // The policy is exercised through the pure function rather than through a launch
    // argument: the unit target builds without `NDI_ENABLED`, so the shipping branch is
    // unreachable from an instance and would otherwise never be tested at all.

    private var demoSource: NDISource { CompositeNDIService.demoSource }

    /// A real camera can be first in the list on the shipping build — the composite
    /// appends the demo source last. Auto-selecting it would latch a screenshot run onto
    /// a live feed on set, so on that build only a `demo://` id may be taken.
    @Test func theShippingBuildNeverAutoSelectsARealSource() {
        let discovered = [source("live-cam"), demoSource]

        let shipping = MonitorViewModel.screenshotSelection(
            from: discovered, limit: 1, allowsNonDemoFallback: false
        )
        #expect(shipping.map(\.id) == [demoSource.id])

        // With no demo source at all it takes nothing rather than taking a camera.
        #expect(MonitorViewModel.screenshotSelection(
            from: [source("live-cam")], limit: 1, allowsNonDemoFallback: false
        ).isEmpty)
    }

    /// The simulator builds Mock-only and has no `demo://` source in the grid variant, so
    /// there the fallback is what puts a wall on screen.
    @Test func theMockOnlyBuildFallsBackToWhateverDiscoveryFound() {
        let discovered = [source("a"), source("b"), source("c"), source("d"), source("e")]

        let one = MonitorViewModel.screenshotSelection(
            from: discovered, limit: 1, allowsNonDemoFallback: true
        )
        #expect(one.map(\.id) == ["a"])

        // A grid takes a wall, and no more than the wall holds.
        let wall = MonitorViewModel.screenshotSelection(
            from: discovered, limit: 4, allowsNonDemoFallback: true
        )
        #expect(wall.map(\.id) == ["a", "b", "c", "d"])

        // The demo source still wins when there is one.
        let withDemo = MonitorViewModel.screenshotSelection(
            from: [source("a"), demoSource], limit: 4, allowsNonDemoFallback: true
        )
        #expect(withDemo.map(\.id) == [demoSource.id])
    }

    /// Deselecting the last source must not hand it straight back on the next discovery
    /// yield. Driven through the public surface rather than the launch argument, which
    /// cannot be set for a hosted test run.
    @Test func aDeselectSettlesTheSelectionForGood() async {
        let viewModel = makeViewModel()
        let a = source("A")

        viewModel.startReceiving(a)
        #expect(viewModel.selectedSources == ["A"])

        viewModel.stopReceiving(a)
        #expect(viewModel.selectedSources.isEmpty)

        // Discovery keeps running against the mock for a while; nothing may come back.
        viewModel.startDiscovery()
        try? await Task.sleep(for: .seconds(3))
        #expect(viewModel.selectedSources.isEmpty)

        viewModel.stopAll()
    }
}
