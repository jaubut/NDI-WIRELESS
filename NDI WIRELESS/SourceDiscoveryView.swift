//
//  SourceDiscoveryView.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import SwiftUI

struct SourceDiscoveryView: View {
    var viewModel: MonitorViewModel

    var body: some View {
        List(viewModel.discoveredSources) { source in
            HStack {
                VStack(alignment: .leading) {
                    Text(source.name)
                        .font(.headline)
                    Text(source.ipAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.selectedSources.contains(source.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .imageScale(.large)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.toggleSource(source)
            }
        }
        .navigationTitle("NDI Sources")
        .overlay {
            if viewModel.discoveredSources.isEmpty {
                ContentUnavailableView(
                    "Searching...",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Looking for NDI sources on your network")
                )
            }
        }
    }
}
