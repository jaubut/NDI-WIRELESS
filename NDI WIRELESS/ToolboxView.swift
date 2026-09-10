//
//  ToolboxView.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import SwiftUI

struct ToolboxView: View {
    var viewModel: MonitorViewModel

    var body: some View {
        HStack(spacing: 20) {
            ForEach(MonitorTool.allCases) { tool in
                Button {
                    viewModel.toggleTool(tool)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tool.systemImage)
                            .font(.title2)
                        Text(tool.label)
                            .font(.caption2)
                    }
                    .foregroundStyle(
                        viewModel.activeTools.contains(tool) ? .yellow : .white
                    )
                }

            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 8)
    }
}
