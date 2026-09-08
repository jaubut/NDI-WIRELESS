//
//  FalseColorProcessor.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//
//  EL Zone System false color processor.
//  Maps luminance to a 15-zone color scale (Ed Lachman ASC) using a
//  CIColorCube 3D LUT for single-pass GPU processing.
//

import CoreImage
import CoreGraphics

final class FalseColorProcessor: @unchecked Sendable {
    private let context: CIContext
    private let lutData: Data
    private let lutSize: Int = 64

    init() {
        context = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
        lutData = Self.buildELZoneLUT(size: 64)
    }

    func process(_ cgImage: CGImage) -> CGImage? {
        let ciInput = CIImage(cgImage: cgImage)

        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        filter.setValue(lutSize, forKey: "inputCubeDimension")
        filter.setValue(lutData, forKey: "inputCubeData")
        filter.setValue(ciInput, forKey: kCIInputImageKey)

        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }

    // MARK: - LUT Construction

    private static func buildELZoneLUT(size: Int) -> Data {
        let entryCount = size * size * size * 4
        var floats = [Float](repeating: 0, count: entryCount)

        var offset = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let rf = Float(r) / Float(size - 1)
                    let gf = Float(g) / Float(size - 1)
                    let bf = Float(b) / Float(size - 1)

                    // Rec. 709 luminance
                    let luminance = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf

                    // Map luminance to EL Zone color
                    let (zr, zg, zb) = elZoneColor(for: luminance)

                    floats[offset]     = zr
                    floats[offset + 1] = zg
                    floats[offset + 2] = zb
                    floats[offset + 3] = 1.0
                    offset += 4
                }
            }
        }

        return floats.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: entryCount * MemoryLayout<Float>.size) { ptr in
                UnsafeBufferPointer(start: ptr, count: entryCount * MemoryLayout<Float>.size)
            })
        }
    }

    // MARK: - EL Zone Color Mapping

    /// Maps a sRGB luminance value (0..1) to an EL Zone color.
    /// 18% gray in sRGB ≈ 0.463. Each zone = 1 stop (2x light).
    private static func elZoneColor(for luminance: Float) -> (Float, Float, Float) {
        let gray18: Float = 0.463

        let stops: Float
        if luminance <= 0.001 {
            stops = -7
        } else {
            stops = log2f(luminance / gray18)
        }

        // EL Zone System: 15 zones from -6 to +6 stops
        // Boundaries are at the midpoint between adjacent zones.
        // Colors follow the standard EL Zone scale.
        switch stops {
        case ..<(-5.5):  return (0.00, 0.00, 0.00) // Zone -6: Black (clip)
        case ..<(-4.5):  return (0.25, 0.00, 0.40) // Zone -5: Dark Purple
        case ..<(-3.5):  return (0.45, 0.00, 0.70) // Zone -4: Purple
        case ..<(-2.5):  return (0.00, 0.10, 0.90) // Zone -3: Blue
        case ..<(-1.5):  return (0.00, 0.35, 0.55) // Zone -2: Dark Teal
        case ..<(-0.75): return (0.00, 0.40, 0.00) // Zone -1: Dark Green
        case ..<(-0.25): return (0.00, 0.70, 0.00) // Zone -½: Green
        case ..<( 0.25): return (0.46, 0.46, 0.46) // Zone  0: Gray (18%)
        case ..<( 0.75): return (0.55, 0.75, 0.00) // Zone +½: Yellow-Green
        case ..<( 1.25): return (1.00, 1.00, 0.00) // Zone +1: Yellow
        case ..<( 1.75): return (0.85, 0.65, 0.00) // Zone +1½: Amber
        case ..<( 2.5):  return (1.00, 0.45, 0.00) // Zone +2: Orange
        case ..<( 3.5):  return (1.00, 0.20, 0.00) // Zone +3: Red-Orange
        case ..<( 4.5):  return (1.00, 0.00, 0.00) // Zone +4: Red
        case ..<( 5.5):  return (1.00, 0.30, 0.70) // Zone +5: Pink/Magenta
        default:         return (1.00, 1.00, 1.00) // Zone +6: White (clip)
        }
    }
}
