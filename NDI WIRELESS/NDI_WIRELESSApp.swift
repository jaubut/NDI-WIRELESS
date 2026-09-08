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
            ContentView(viewModel: MonitorViewModel(service: MockNDIService()))
        }
    }
}
