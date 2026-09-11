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
        List {
            Section {
                ForEach(viewModel.discoveredSources) { source in
                    row(for: source)
                }
            } footer: {
                // An empty network is the normal state on a desk, not a fault. Say what
                // the app looks for, and point at the source that is always there.
                Text(
                    """
                    No sources? TLS Viewer discovers NDI® senders on the same Wi-Fi. \
                    Use the demo source to explore the tools.
                    """
                )
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

    @ViewBuilder
    private func row(for source: NDISource) -> some View {
        let isSelected = viewModel.selectedSources.contains(source.id)

        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(.headline)
                    // Says outright that this row is not a camera on the network.
                    if CompositeNDIService.isDemo(source.id) {
                        Text("DEMO")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
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
