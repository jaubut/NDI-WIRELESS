//
//  VideoFrameView.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import SwiftUI

struct VideoFrameView: View {
    let frame: CGImage?
    let sourceName: String
    var falseColorProcessor: FalseColorProcessor?
    var histogramData: HistogramData?

    private var displayFrame: CGImage? {
        guard let frame else { return nil }
        if let processor = falseColorProcessor {
            return processor.process(frame)
        }
        return frame
    }

    var body: some View {
        ZStack {
            Color.black
            if let displayFrame {
                Image(decorative: displayFrame, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(alignment: .bottomTrailing) {
                        if let histogramData {
                            HistogramView(data: histogramData)
                                .frame(width: 200, height: 100)
                                .padding(8)
                        }
                    }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text(sourceName)
                        .font(.caption)
                        .foregroundStyle(.white)
                }
            }
        }
    }
}
