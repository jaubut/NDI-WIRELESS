//
//  VideoFrameView.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import SwiftUI

/// The picture, and nothing else.
///
/// Status chip, PROXY badge and histogram are drawn by the call sites, outside the
/// subtree that pinch-zoom scales: an overlay drawn in here magnifies and drifts with
/// the picture, which is how the histogram used to behave.
struct VideoFrameView: View {
    let frame: CGImage?
    let sourceName: String
    var falseColorProcessor: FalseColorProcessor?
    /// Defaulted so the two existing call sites keep compiling against the memberwise init.
    var status: SourceConnectionState = .live
    var isProxy: Bool = false

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
                    // A proxy is already soft; smoothing it costs less than pretending
                    // it deserves the full-resolution filter.
                    .interpolation(isProxy ? .medium : .high)
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 8) {
                    if status.isLive {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(.orange)
                    }
                    Text(sourceName)
                        .font(.caption)
                        .foregroundStyle(.white)
                }
            }
        }
    }
}
