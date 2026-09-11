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
}
