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
    @State private var showAbout = false
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

                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    aboutButton
                }
                #else
                ToolbarItem {
                    aboutButton
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
            .sheet(isPresented: $showAbout) {
                AboutView()
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
            requestLandscapeForScreenshots()
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

    /// Version, licences and the NDI trademark notice. An icon on its own says nothing,
    /// so it carries a label for VoiceOver and for the accessibility inspector.
    private var aboutButton: some View {
        Button {
            showAbout = true
        } label: {
            Image(systemName: "info.circle")
        }
        .accessibilityLabel("About TLS Viewer")
    }

    /// App Store screenshots are landscape: this is a monitor, and a portrait frame of a
    /// 16:9 picture is mostly black. Asked for once the scene is connected, and only when
    /// the launch argument is there — a real user's rotation is their own business.
    ///
    /// Honoured on iPhone. **Not** on iPad, which refuses with `UISceneErrorDomain` 101,
    /// "the current windowing mode does not allow for programmatic changes to interface
    /// orientation": the app declares multiple-scene support, so iPadOS treats it as
    /// fully resizable and keeps orientation under the user's control. iPad captures have
    /// to rotate the simulated device instead, which is what XCUITest's
    /// `XCUIDevice.orientation` does. Left in place because it is the right call on the
    /// phone, where the same screenshots are needed.
    private func requestLandscapeForScreenshots() {
        #if canImport(UIKit)
        guard MonitorViewModel.isLaunchedForScreenshots else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        #endif
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
