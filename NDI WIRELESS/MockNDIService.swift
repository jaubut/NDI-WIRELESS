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

final class MockNDIService: NDIService {
    private var activeReceivers: Set<String> = []

    func discoverSources() -> AsyncStream<[NDISource]> {
        AsyncStream { continuation in
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

    func startReceiving(from source: NDISource) -> AsyncStream<CGImage> {
        activeReceivers.insert(source.id)

        return AsyncStream { continuation in
            let task = Task.detached {
                var hue: CGFloat = CGFloat(abs(source.id.hashValue % 100)) / 100.0
                while !Task.isCancelled {
                    if let image = Self.generateTestPattern(
                        width: 960, height: 540, hue: hue
                    ) {
                        continuation.yield(image)
                    }
                    hue += 0.005
                    if hue > 1 { hue = 0 }
                    try? await Task.sleep(for: .milliseconds(33))
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func stopReceiving(from source: NDISource) {
        activeReceivers.remove(source.id)
    }

    func stopAll() {
        activeReceivers.removeAll()
    }

    // MARK: - Test Pattern Generation (CoreGraphics only)

    private static func generateTestPattern(
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

    private static func colorFromHSB(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> CGColor {
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
