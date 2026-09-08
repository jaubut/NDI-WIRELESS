//
//  HistogramView.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-03.
//

import SwiftUI

/// Semi-transparent RGB histogram overlay rendered with Canvas.
struct HistogramView: View {
    let data: HistogramData

    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let binCount = 256
            let binWidth = width / CGFloat(binCount)

            // Find the global max across R/G/B to normalize heights consistently.
            // Skip bin 0 and bin 255 to avoid spikes from clipped black/white.
            let maxCount = max(
                data.red[1..<255].max() ?? 1,
                data.green[1..<255].max() ?? 1,
                data.blue[1..<255].max() ?? 1,
                1
            )

            // Draw each channel as a filled path
            drawChannel(
                context: context, bins: data.red, color: .red,
                maxCount: maxCount, binWidth: binWidth,
                height: height, binCount: binCount
            )
            drawChannel(
                context: context, bins: data.green, color: .green,
                maxCount: maxCount, binWidth: binWidth,
                height: height, binCount: binCount
            )
            drawChannel(
                context: context, bins: data.blue, color: .blue,
                maxCount: maxCount, binWidth: binWidth,
                height: height, binCount: binCount
            )
        }
        .background(.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func drawChannel(
        context: GraphicsContext, bins: [UInt], color: Color,
        maxCount: UInt, binWidth: CGFloat, height: CGFloat, binCount: Int
    ) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: height))

        for i in 0..<binCount {
            let normalized = CGFloat(bins[i]) / CGFloat(maxCount)
            let barHeight = min(normalized, 1.0) * height
            let x = CGFloat(i) * binWidth
            path.addLine(to: CGPoint(x: x, y: height - barHeight))
        }

        path.addLine(to: CGPoint(x: CGFloat(binCount) * binWidth, y: height))
        path.closeSubpath()

        context.fill(path, with: .color(color.opacity(0.4)))

        // Draw the outline on top
        var outline = Path()
        outline.move(to: CGPoint(x: 0, y: height))
        for i in 0..<binCount {
            let normalized = CGFloat(bins[i]) / CGFloat(maxCount)
            let barHeight = min(normalized, 1.0) * height
            let x = CGFloat(i) * binWidth
            outline.addLine(to: CGPoint(x: x, y: height - barHeight))
        }

        context.stroke(outline, with: .color(color.opacity(0.8)), lineWidth: 1)
    }
}
