//
//  NDI_WIRELESSApp.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import SwiftUI

@main
struct NDI_WIRELESSApp: App {
    var body: some Scene {
        WindowGroup {
            #if NDI_ENABLED
            // The shipping build always has one source: the network's, plus a built-in
            // demo so the app is reviewable and screenshot-able on a desk with no sender.
            ContentView(viewModel: MonitorViewModel(service: CompositeNDIService(
                real: RealNDIService(),
                demo: MockNDIService(singleSource: CompositeNDIService.demoSource)
            )))
            #else
            ContentView(viewModel: MonitorViewModel(service: MockNDIService()))
            #endif
        }
    }
}
