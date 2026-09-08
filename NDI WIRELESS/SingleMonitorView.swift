//
//  SingleMonitorView.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import SwiftUI

struct SingleMonitorView: View {
    var viewModel: MonitorViewModel

    private var source: NDISource? {
        viewModel.discoveredSources.first { $0.id == viewModel.primarySourceID }
    }

    var body: some View {
        VideoFrameView(
            frame: viewModel.primarySourceID.flatMap { viewModel.frames[$0] },
            sourceName: source?.name ?? "No Source"
        )
        .ignoresSafeArea()
        .onTapGesture(count: 2) {
            viewModel.layoutMode = .multi
        }
        .navigationTitle(source?.name ?? "Monitor")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }
}
