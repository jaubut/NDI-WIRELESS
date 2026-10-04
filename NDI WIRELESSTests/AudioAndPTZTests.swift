//
//  AudioAndPTZTests.swift
//  NDI WIRELESSTests
//
//  Created by Jeremie Aubut on 2026-10-04.
//
//  Meter maths with time injected, and the PTZ path through the view model against the
//  mock. The mock cannot prove a real head moves. That check happens on the iPad.
//

import CoreGraphics
import Foundation
import Testing
@testable import NDI_WIRELESS

struct AudioLevelMeterTests {
    /// NDI float level that reads `db` dBFS once the 20 dB headroom is applied.
    private func linear(dbfs db: Float) -> Float {
        powf(10, (db + AudioLevelMeter.headroomDB) / 20)
    }

    @Test func peaksAreReadPerPlanarChannelHonouringTheStride() {
        // Two channels of three samples, laid out with a stride of four floats. The
        // padding holds a value that must never be read.
        let planar: [Float] = [0.1, -0.7, 0.2, 99, 0.05, 0.3, -0.4, 99]
        let peaks = planar.withUnsafeBufferPointer {
            AudioLevelMeter.peaks(
                planar: $0.baseAddress!,
                channelStrideInBytes: 4 * MemoryLayout<Float>.stride,
                channels: 2,
                samples: 3
            )
        }
        #expect(peaks == [0.7, 0.4])
    }

    @Test func aStrideShorterThanTheBlockReadsNothing() {
        let planar: [Float] = [1, 1]
        let peaks = planar.withUnsafeBufferPointer {
            AudioLevelMeter.peaks(planar: $0.baseAddress!, channelStrideInBytes: 4, channels: 1, samples: 2)
        }
        #expect(peaks.isEmpty)
    }

    @Test func levelsApplyTheNDIHeadroomAndClampToTheScale() {
        #expect(AudioLevelMeter.dbfs(1.0) == -AudioLevelMeter.headroomDB)
        #expect(abs(AudioLevelMeter.dbfs(linear(dbfs: -12)) - -12) < 0.01)
        #expect(AudioLevelMeter.dbfs(0) == AudioLevelMeter.floorDB)
        #expect(AudioLevelMeter.dbfs(1_000) == 0)
    }

    @Test func nothingIsReportedBeforeTheFirstBlock() {
        #expect(AudioLevelMeter().snapshot(at: 0) == nil)
    }

    @Test func aHeldPeakFallsAtTheReleaseRate() {
        let meter = AudioLevelMeter()
        meter.record(peaks: [linear(dbfs: -10)], at: 100)
        // A quieter block one second later must not pull the meter straight down.
        meter.record(peaks: [linear(dbfs: -50)], at: 101)

        let level = meter.snapshot(at: 101)!.channels[0]
        #expect(abs(level - (-10 - AudioLevelMeter.releaseDBPerSecond)) < 0.01)

        // A feed that goes silent falls to the floor rather than freezing.
        #expect(meter.snapshot(at: 200)!.channels[0] == AudioLevelMeter.floorDB)
    }

    @Test func theClipLampHoldsThenClears() {
        let meter = AudioLevelMeter()
        meter.record(peaks: [linear(dbfs: 1), linear(dbfs: -30)], at: 10)
        #expect(meter.snapshot(at: 10 + AudioLevelMeter.clipHoldSeconds - 0.1)!.isClipped)
        #expect(!meter.snapshot(at: 10 + AudioLevelMeter.clipHoldSeconds + 0.1)!.isClipped)
    }

    @Test func aChannelCountChangeStartsOver() {
        let meter = AudioLevelMeter()
        meter.record(peaks: [linear(dbfs: -6), linear(dbfs: -6)], at: 0)
        meter.record(peaks: [linear(dbfs: -40)], at: 0)
        let channels = meter.snapshot(at: 0)!.channels
        #expect(channels.count == 1)
        #expect(abs(channels[0] - -40) < 0.01)
    }
}

@MainActor
struct PTZTests {
    private let camera = NDISource(id: "cam", name: "CAM", ipAddress: "192.168.1.1")

    @Test func commandsAreClampedToTheSDKRange() {
        #expect(PTZCommand.panTiltSpeed(pan: 3, tilt: .nan).clamped == .panTiltSpeed(pan: 1, tilt: 0))
        #expect(PTZCommand.zoomSpeed(-2).clamped == .zoomSpeed(-1))
        #expect(PTZCommand.recallPreset(150).clamped == .recallPreset(99))
        #expect(PTZCommand.storePreset(-1).clamped == .storePreset(0))
    }

    @Test func aDragRightPansNegativeAndADragUpTiltsPositive() {
        let right = PTZControlView.speeds(for: CGSize(width: 500, height: 0))
        #expect(right.pan == -1 && right.tilt == 0)

        let up = PTZControlView.speeds(for: CGSize(width: 0, height: -25))
        #expect(up.pan == 0 && abs(up.tilt - 0.5) < 0.001)
    }

    @Test func aDragOnlySendsWhenTheQuantisedSpeedChanges() {
        let mock = MockNDIService(ptzSourceIDs: [camera.id])
        let viewModel = MonitorViewModel(service: mock)
        viewModel.startReceiving(camera)

        viewModel.setPanTilt(pan: 0.31, tilt: 0, for: camera.id)
        viewModel.setPanTilt(pan: 0.29, tilt: 0, for: camera.id)  // same step: silent
        viewModel.setPanTilt(pan: 0.5, tilt: 0, for: camera.id)
        viewModel.stopPTZ(for: camera.id)
        viewModel.stopPTZ(for: camera.id)  // already stopped: silent

        let q = PTZCommand.quantized
        #expect(mock.sentPTZCommands.map { $0.command } == [
            .panTiltSpeed(pan: q(0.3), tilt: 0),
            .panTiltSpeed(pan: q(0.5), tilt: 0),
            .panTiltSpeed(pan: 0, tilt: 0),
            .zoomSpeed(0),
        ])

        viewModel.stopAll()
    }

    @Test func nothingReachesASourceThatIsNotSelected() {
        let mock = MockNDIService(ptzSourceIDs: [camera.id])
        let viewModel = MonitorViewModel(service: mock)
        viewModel.startReceiving(camera)
        viewModel.stopReceiving(camera)

        viewModel.sendPTZ(.recallPreset(1), to: camera.id)
        viewModel.setZoomSpeed(0.5, for: camera.id)
        #expect(mock.sentPTZCommands.isEmpty)

        viewModel.stopAll()
    }

    @Test func thePollFindsWhichSourcesHavePTZ() async {
        let other = NDISource(id: "other", name: "OTHER", ipAddress: "192.168.1.2")
        let viewModel = MonitorViewModel(service: MockNDIService(ptzSourceIDs: [camera.id]))
        viewModel.startReceiving(camera)
        viewModel.startReceiving(other)

        let deadline = Date().addingTimeInterval(5)
        while viewModel.ptzCapableSources.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(viewModel.ptzCapableSources == [camera.id])

        viewModel.stopReceiving(camera)
        #expect(viewModel.ptzCapableSources.isEmpty)

        viewModel.stopAll()
    }

    @Test func theMockMetersMoveOnceFramesFlow() async {
        let viewModel = MonitorViewModel(service: MockNDIService())
        viewModel.startReceiving(camera)

        let deadline = Date().addingTimeInterval(5)
        var levels: AudioLevels?
        while levels == nil, Date() < deadline {
            levels = viewModel.audioLevels(for: camera.id)
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(levels?.channels.count == 2)
        #expect(levels.map { $0.channels.allSatisfy { $0 > AudioLevelMeter.floorDB } } == true)

        viewModel.stopAll()
    }
}
