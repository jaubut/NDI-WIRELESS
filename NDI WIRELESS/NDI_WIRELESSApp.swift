//
//  NDI_WIRELESSApp.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import Foundation
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
            ContentView(viewModel: MonitorViewModel(service: Self.simulatorService()))
            #endif
        }
    }

    /// The simulator's transport, chosen by the launch arguments.
    ///
    /// A single-view screenshot run gets the demo source on its own, so the source list
    /// and the monitor shot show exactly the row the review notes describe. A grid run
    /// keeps the four-camera mock, because a wall of one tile and three black rectangles
    /// is not a screenshot of a multi-view. Neither branch exists on the shipping build.
    private static func simulatorService() -> NDIService {
        let arguments = ProcessInfo.processInfo.arguments
        let wantsDemoOnly = arguments.contains(MonitorViewModel.screenshotModeArgument)
            && !arguments.contains(MonitorViewModel.screenshotGridArgument)

        return wantsDemoOnly
            ? MockNDIService(singleSource: CompositeNDIService.demoSource)
            : MockNDIService()
    }
}
