//
//  MonitorTool.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import Foundation

enum MonitorTool: String, CaseIterable, Identifiable, Hashable {
    case falseColor
    case histogram
    case audioMeters

    var id: String { rawValue }

    var label: String {
        switch self {
        case .falseColor: return "False Color"
        case .histogram:  return "Histogram"
        case .audioMeters: return "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .falseColor: return "paintpalette"
        case .histogram:  return "chart.bar"
        case .audioMeters: return "waveform"
        }
    }
}
