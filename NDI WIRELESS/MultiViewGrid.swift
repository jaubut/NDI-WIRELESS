//
//  MultiViewGrid.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import SwiftUI

struct MultiViewGrid: View {
    var viewModel: MonitorViewModel

    private var activeSources: [NDISource] {
        viewModel.discoveredSources.filter { viewModel.selectedSources.contains($0.id) }
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
                    VideoFrameView(
                        frame: viewModel.frames[source.id],
                        sourceName: source.name
                    )
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        Text(source.name)
                            .font(.caption2)
                            .padding(4)
                            .background(.black.opacity(0.6))
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                    .onTapGesture {
                        viewModel.selectPrimary(source)
                    }
                }
            }
        }
        .background(.black)
        .navigationTitle("Multi View")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
