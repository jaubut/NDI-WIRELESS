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
            row(for: source)
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

    @ViewBuilder
    private func row(for source: NDISource) -> some View {
        let isSelected = viewModel.selectedSources.contains(source.id)

        HStack {
            VStack(alignment: .leading) {
                Text(source.name)
                    .font(.headline)
                Text(source.ipAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.toggleSource(source)
            }

            Spacer()

            // Reachable here so grid sources can be switched to proxy without going
            // through the single view first.
            Picker("Bandwidth", selection: bandwidthBinding(for: source.id)) {
                ForEach(NDIBandwidthMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .imageScale(.large)
            }
        }
    }

    private func bandwidthBinding(for sourceID: String) -> Binding<NDIBandwidthMode> {
        Binding(
            get: { viewModel.bandwidth[sourceID] ?? .highest },
            set: { viewModel.setBandwidth($0, for: sourceID) }
        )
    }
}
