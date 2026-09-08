//
//  ContentView.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import SwiftUI

struct ContentView: View {
    @State var viewModel: MonitorViewModel
    @State private var showSourcePicker = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.selectedSources.isEmpty {
                    SourceDiscoveryView(viewModel: viewModel)
                } else {
                    switch viewModel.layoutMode {
                    case .single:
                        SingleMonitorView(viewModel: viewModel)
                    case .multi:
                        MultiViewGrid(viewModel: viewModel)
                    }
                }
            }
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSourcePicker = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                }
                #else
                ToolbarItem {
                    Button {
                        showSourcePicker = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                }
                #endif

                if !viewModel.selectedSources.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Picker("Layout", selection: $viewModel.layoutMode) {
                            Image(systemName: "rectangle.fill")
                                .tag(LayoutMode.single)
                            Image(systemName: "rectangle.grid.2x2.fill")
                                .tag(LayoutMode.multi)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                    }
                }
            }
            .sheet(isPresented: $showSourcePicker) {
                NavigationStack {
                    SourceDiscoveryView(viewModel: viewModel)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSourcePicker = false }
                            }
                        }
                }
            }
        }
        .task {
            viewModel.startDiscovery()
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView(viewModel: MonitorViewModel(service: MockNDIService()))
}
