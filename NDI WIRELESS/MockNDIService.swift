//
//  MockNDIService.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#endif

import Synchronization

/// One mock receiver's shared state.
///
/// The capture loop is detached and the view model pulls stats from the main actor, so
/// both halves are behind a lock and the isolation is declared rather than inferred.
/// The accumulator is swappable: `reconnect` starts a fresh measurement without stopping
/// the loop, which is what a re-point does on the real transport.
private nonisolated final class MockReceiver: Sendable {
    private struct State {
        var accumulator = FrameStatsAccumulator()
        var isGlitching = false
    }

    private let state = Mutex(State())

    var accumulator: FrameStatsAccumulator {
        state.withLock { (s: inout State) -> FrameStatsAccumulator in s.accumulator }
    }

    func setGlitching(_ glitching: Bool) {
        state.withLock { (s: inout State) -> Void in s.isGlitching = glitching }
    }

    /// A re-point: measurement starts over, and whatever gap was being reported ends.
    func reconnect() {
        state.withLock { (s: inout State) -> Void in
            s.accumulator = FrameStatsAccumulator()
            s.isGlitching = false
        }
    }

    /// While the scripted glitch is running there is nobody on the other end, which is
    /// what the view model reads to raise the chip.
    func snapshot() -> FrameStats {
        let (accumulator, glitching) = state.withLock { (s: inout State) -> (FrameStatsAccumulator, Bool) in
            (s.accumulator, s.isGlitching)
        }
        let snapshot = accumulator.snapshot()
        guard glitching else { return snapshot }
        return snapshot.withTransportCounters(
            received: snapshot.received,
            dropped: snapshot.dropped,
            connections: 0
        )
    }
}

final class MockNDIService: NDIService {
    private var activeReceivers: Set<String> = []
    private var receiverStates: [String: MockReceiver] = [:]

    /// When set, this is the whole of what the mock discovers and nothing else is ever
    /// yielded. Used for the built-in demo source in the shipping build, where a second
    /// invented camera would be a lie about what the app found on the network.
    private let fixedSource: NDISource?

    /// The simulator's stand-in transport: several sources, and the scripted outage that
    /// exercises the reconnect chip.
    init() {
        self.fixedSource = nil
    }

    /// One source, and no scripted outage.
    ///
    /// This is the demo feed a reviewer sees on a desk with no NDI sender on the Wi-Fi. A
    /// `RECONNECTING` chip flashing every twenty seconds would read as a broken app rather
    /// than as the resilience behaviour it demonstrates, so the glitch is off here.
    init(singleSource source: NDISource) {
        self.fixedSource = source
    }

    /// The scripted outage only belongs to the multi-source simulator mock.
    private var isGlitchScripted: Bool { fixedSource == nil }

    // Read from the detached capture loop, so isolation is declared rather than inferred
    // (the module defaults to MainActor).

    /// The mock's nominal rate. Frames are stamped from it so the accumulator dedupes
    /// and counts exactly the way it does on the real transport.
    private nonisolated static let frameRateN: Int32 = 30
    private nonisolated static let frameRateD: Int32 = 1
    /// One frame in 100-nanosecond units, matching the SDK's timestamp scale.
    private nonisolated static let timestampStep: Int64 = 333_333
    /// One tick of the capture loop, in milliseconds.
    private nonisolated static let tickMilliseconds: Int64 = 33
    /// The scripted outage: the last second of every twenty. Nothing new arrives and the
    /// receiver reports no connection, so the simulator exercises the chip and the
    /// recovery ladder without a network to unplug. It lands at the *end* of the cycle
    /// so a freshly started receiver delivers immediately.
    private nonisolated static let glitchPeriodTicks: Int64 = 20_000 / tickMilliseconds
    private nonisolated static let glitchTicks: Int64 = 1_000 / tickMilliseconds

    func discoverSources() -> AsyncStream<[NDISource]> {
        if let fixedSource {
            // Yielded once and never revised. The stream stays open rather than finishing,
            // so a consumer that merges it with another finder keeps its subscription.
            return AsyncStream { continuation in
                continuation.yield([fixedSource])
            }
        }

        return AsyncStream { continuation in
            let initial = [
                NDISource(id: "obs-1", name: "OBS (Studio)", ipAddress: "192.168.1.10"),
                NDISource(id: "camera-1", name: "PTZ Camera 1", ipAddress: "192.168.1.20"),
            ]
            continuation.yield(initial)

            let task = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                let updated = initial + [
                    NDISource(id: "vmix-1", name: "vMix Output", ipAddress: "192.168.1.30"),
                    NDISource(id: "ndi-hx-1", name: "NDI HX Camera", ipAddress: "192.168.1.40"),
                ]
                continuation.yield(updated)
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func startReceiving(from source: NDISource, bandwidth: NDIBandwidthMode) -> AsyncStream<CGImage> {
        let sourceID = source.id
        activeReceivers.insert(sourceID)

        let receiver = MockReceiver()
        receiverStates[sourceID] = receiver

        // `.lowest` stands in for the SDK's proxy stream: same picture, half the size.
        let width = bandwidth == .lowest ? 480 : 960
        let height = bandwidth == .lowest ? 270 : 540
        let seed = CGFloat(abs(sourceID.hashValue % 100)) / 100.0
        let isGlitchScripted = self.isGlitchScripted

        return AsyncStream { continuation in
            let task = Task.detached {
                var hue = seed
                var tick: Int64 = 0
                while !Task.isCancelled {
                    tick += 1

                    // Scripted outage: stop delivering and report no connection. The
                    // clock keeps running, so the gap the accumulator measures after it
                    // is the real one.
                    let glitching = isGlitchScripted
                        && tick % Self.glitchPeriodTicks
                            >= Self.glitchPeriodTicks - Self.glitchTicks
                    receiver.setGlitching(glitching)

                    if !glitching {
                        let isNewFrame = receiver.accumulator.record(
                            timestamp: tick * Self.timestampStep,
                            timecode: tick * Self.timestampStep,
                            frameRateN: Self.frameRateN,
                            frameRateD: Self.frameRateD
                        )

                        if isNewFrame, let image = Self.generateTestPattern(
                            width: width, height: height, hue: hue
                        ) {
                            continuation.yield(image)
                        }
                    }

                    hue += 0.005
                    if hue > 1 { hue = 0 }
                    try? await Task.sleep(for: .milliseconds(Self.tickMilliseconds))
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func stats(for source: NDISource) -> FrameStats? {
        receiverStates[source.id]?.snapshot()
    }

    /// The mock's re-point: measurement starts over on a receiver that keeps running,
    /// exactly like `NDIlib_recv_connect` on a live instance.
    func reconnect(_ source: NDISource) {
        receiverStates[source.id]?.reconnect()
    }

    func stopReceiving(from source: NDISource) {
        activeReceivers.remove(source.id)
        receiverStates.removeValue(forKey: source.id)
    }

    func stopAll() {
        activeReceivers.removeAll()
        receiverStates.removeAll()
    }

    // MARK: - Test Pattern Generation (CoreGraphics only)

    private nonisolated static func generateTestPattern(
        width: Int, height: Int, hue: CGFloat
    ) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw color bars
        let barCount = 8
        let barWidth = CGFloat(width) / CGFloat(barCount)
        for i in 0..<barCount {
            let barHue = (hue + CGFloat(i) / CGFloat(barCount)).truncatingRemainder(dividingBy: 1.0)
            let color = Self.colorFromHSB(hue: barHue, saturation: 0.7, brightness: 0.85)
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: CGFloat(i) * barWidth, y: 0, width: barWidth, height: CGFloat(height)))
        }

        return ctx.makeImage()
    }

    private nonisolated static func colorFromHSB(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> CGColor {
        // HSB to RGB conversion
        let c = brightness * saturation
        let x = c * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c

        let r, g, b: CGFloat
        switch hue * 6 {
        case 0..<1: (r, g, b) = (c, x, 0)
        case 1..<2: (r, g, b) = (x, c, 0)
        case 2..<3: (r, g, b) = (0, c, x)
        case 3..<4: (r, g, b) = (0, x, c)
        case 4..<5: (r, g, b) = (x, 0, c)
        default:    (r, g, b) = (c, 0, x)
        }

        return CGColor(red: r + m, green: g + m, blue: b + m, alpha: 1)
    }
}
