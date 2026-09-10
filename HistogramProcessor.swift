//
//  HistogramProcessor.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-03.
//

import Accelerate
import CoreGraphics

/// Computes per-channel RGB histograms from CGImage frames using vImage.
struct HistogramData {
    var red: [UInt] = Array(repeating: 0, count: 256)
    var green: [UInt] = Array(repeating: 0, count: 256)
    var blue: [UInt] = Array(repeating: 0, count: 256)
}

final class HistogramProcessor: @unchecked Sendable {
    /// Compute RGB histogram bins from a CGImage.
    /// Returns nil if the image can't be converted to an ARGB8888 vImage buffer.
    nonisolated func compute(_ image: CGImage) -> HistogramData? {
        // Create a vImage buffer from the CGImage
        guard var format = vImage_CGImageFormat(cgImage: image) else { return nil }

        var sourceBuffer = vImage_Buffer()
        defer { sourceBuffer.data?.deallocate() }

        let initError = vImageBuffer_InitWithCGImage(
            &sourceBuffer, &format, nil, image,
            vImage_Flags(kvImageNoFlags)
        )
        guard initError == kvImageNoError else { return nil }

        // We need ARGB8888 for the histogram function.
        // Convert to a standard 8-bit ARGB format if needed.
        let destFormat = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )!

        var converter: vImageConverter?
        do {
            converter = try vImageConverter.make(
                sourceFormat: format,
                destinationFormat: destFormat
            )
        } catch {
            return nil
        }

        var destBuffer = vImage_Buffer()
        defer { destBuffer.data?.deallocate() }

        let allocError = vImageBuffer_Init(
            &destBuffer,
            sourceBuffer.height,
            sourceBuffer.width,
            32,
            vImage_Flags(kvImageNoFlags)
        )
        guard allocError == kvImageNoError else { return nil }

        let convertError = vImageConvert_AnyToAny(
            converter!, &sourceBuffer, &destBuffer, nil,
            vImage_Flags(kvImageNoFlags)
        )
        guard convertError == kvImageNoError else { return nil }

        // Compute histogram — ARGB layout: [A, R, G, B]
        var histogramA = [vImagePixelCount](repeating: 0, count: 256)
        var histogramR = [vImagePixelCount](repeating: 0, count: 256)
        var histogramG = [vImagePixelCount](repeating: 0, count: 256)
        var histogramB = [vImagePixelCount](repeating: 0, count: 256)

        let histError = histogramR.withUnsafeMutableBufferPointer { rPtr in
            histogramG.withUnsafeMutableBufferPointer { gPtr in
                histogramB.withUnsafeMutableBufferPointer { bPtr in
                    histogramA.withUnsafeMutableBufferPointer { aPtr in
                        var planes: [UnsafeMutablePointer<vImagePixelCount>?] = [
                            aPtr.baseAddress, rPtr.baseAddress,
                            gPtr.baseAddress, bPtr.baseAddress
                        ]
                        return vImageHistogramCalculation_ARGB8888(
                            &destBuffer, &planes,
                            vImage_Flags(kvImageNoFlags)
                        )
                    }
                }
            }
        }
        guard histError == kvImageNoError else { return nil }

        return HistogramData(
            red: histogramR.map { UInt($0) },
            green: histogramG.map { UInt($0) },
            blue: histogramB.map { UInt($0) }
        )
    }
}
