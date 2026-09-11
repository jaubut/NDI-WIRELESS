//
//  ContentView.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @State var viewModel: MonitorViewModel
    @State private var showSourcePicker = false
    @Environment(\.scenePhase) private var scenePhase

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
            .overlay(alignment: .bottom) {
                if viewModel.isChromeVisible && !viewModel.selectedSources.isEmpty {
                    ToolboxView(viewModel: viewModel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onTapGesture {
                guard !viewModel.selectedSources.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.isChromeVisible.toggle()
                }
            }
            .toolbar(viewModel.isChromeVisible ? .visible : .hidden, for: .navigationBar)
            #if os(iOS)
            .statusBarHidden(!viewModel.isChromeVisible)
            #endif
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
        // Keep the screen awake while a source is being monitored; an iPad sleeping
        // in front of a client mid-take is a failure mode, not a battery saver.
        .onChange(of: viewModel.selectedSources.isEmpty, initial: true) { _, isEmpty in
            setKeepAwake(!isEmpty)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { setKeepAwake(!viewModel.selectedSources.isEmpty) }
        }
        .onDisappear { setKeepAwake(false) }
        .preferredColorScheme(.dark)
    }

    private func setKeepAwake(_ on: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}

#Preview {
    ContentView(viewModel: MonitorViewModel(service: MockNDIService()))
}
