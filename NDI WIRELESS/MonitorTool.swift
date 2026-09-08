//
//  MonitorTool.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import Foundation

enum MonitorTool: String, CaseIterable, Identifiable, Hashable {
    case falseColor
    case zoom
    case histogram

    var id: String { rawValue }

    var label: String {
        switch self {
        case .falseColor: return "False Color"
        case .zoom:       return "Zoom"
        case .histogram:  return "Histogram"
        }
    }

    var systemImage: String {
        switch self {
        case .falseColor: return "paintpalette"
        case .zoom:       return "magnifyingglass"
        case .histogram:  return "chart.bar"
        }
    }
}
