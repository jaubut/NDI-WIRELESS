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

    var body: some View {
        ZStack {
            Color.black
            if let frame {
                Image(decorative: frame, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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
