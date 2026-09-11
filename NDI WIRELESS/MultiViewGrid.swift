//
//  MultiViewGrid.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import SwiftUI

struct MultiViewGrid: View {
    var viewModel: MonitorViewModel

    /// Selection order is tile order, resolved through the session index. A discovery
    /// flap can no longer empty the wall or swap two tiles mid-take.
    private var activeSources: [NDISource] {
        viewModel.selectedSources.compactMap { viewModel.sourceIndex[$0] }
    }

    private var columns: [GridItem] {
        let count = activeSources.count
        let columnCount = count <= 1 ? 1 : (count <= 4 ? 2 : 3)
        return Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(activeSources) { source in
                    tile(for: source)
                }
            }
        }
        .background(.black)
        .navigationTitle("Multi View")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func tile(for source: NDISource) -> some View {
        let status = viewModel.connectionState[source.id] ?? .live
        let bandwidth = viewModel.bandwidth[source.id] ?? .highest
        // Drawn per tile, outside the frame view, for the same reason as the chip.
        let histogram: HistogramData? = viewModel.histogramData[source.id]

        VideoFrameView(
            frame: viewModel.frames[source.id],
            sourceName: source.name,
            falseColorProcessor: viewModel.isFalseColorActive
                ? viewModel.falseColorProcessor : nil,
            status: status,
            isProxy: bandwidth.isProxy
        )
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                SourceStatusChip(state: status)
                if bandwidth.isProxy {
                    ProxyBadge()
                }
            }
            .padding(4)
        }
        .overlay(alignment: .bottomLeading) {
            Text(source.name)
                .font(.caption2)
                .padding(4)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .padding(4)
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 4) {
                if let histogram {
                    HistogramView(data: histogram)
                        .frame(width: 140, height: 70)
                }
                // Only while chrome is up: the poll that feeds this is gated the same
                // way, so a hidden-chrome badge would be showing a stale number.
                if viewModel.isChromeVisible {
                    fpsBadge(for: source.id)
                }
            }
            .padding(4)
        }
        .onChange(of: viewModel.frames[source.id]) {
            viewModel.updateHistogram(for: source.id)
        }
    }

    private func fpsBadge(for sourceID: String) -> some View {
        let stats = viewModel.stats[sourceID]
        let text: String
        if let stats {
            let value = String(format: "%.0f", stats.fps)
            text = (stats.isEstimated ? "~\(value)" : value) + " fps"
        } else {
            text = "— fps"
        }

        return Text(text)
            .font(.caption2)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
    }
}
