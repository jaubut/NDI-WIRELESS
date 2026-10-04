//
//  AudioMeterView.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-10-04.
//
//  Peak meters for one source. The view pulls levels on its own 15 Hz timeline, so only
//  this small subtree redraws at meter rate. The video does not. Drawn by the call sites in
//  their unscaled overlay layer, like the stats overlay.
//

import SwiftUI

struct AudioMeterView: View {
    /// Pulled once per timeline tick. Pass `viewModel.audioLevels(for:)`.
    let levels: () -> AudioLevels?
    var barHeight: CGFloat = 120
    var barWidth: CGFloat = 8

    /// A 16-channel sender would make sixteen hairlines. Show the first eight.
    private static let maxChannels = 8

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { _ in
            meters(levels())
        }
    }

    @ViewBuilder
    private func meters(_ levels: AudioLevels?) -> some View {
        let channels = Array((levels?.channels ?? []).prefix(Self.maxChannels))

        VStack(spacing: 4) {
            Circle()
                .fill(levels?.isClipped == true ? Color.red : Color.white.opacity(0.2))
                .frame(width: 8, height: 8)

            if channels.isEmpty {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(height: barHeight)
            } else {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(channels.indices, id: \.self) { index in
                        bar(channels[index])
                    }
                }
            }

            Text("dBFS")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio levels")
        .accessibilityValue(accessibilityText(channels, isClipped: levels?.isClipped == true))
    }

    private func bar(_ db: Float) -> some View {
        let fraction = CGFloat((db - AudioLevelMeter.floorDB) / -AudioLevelMeter.floorDB)
        return ZStack(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.12))
            Rectangle()
                .fill(Self.color(for: db))
                .frame(height: barHeight * max(0, min(1, fraction)))
        }
        .frame(width: barWidth, height: barHeight)
    }

    /// EBU-ish zones. Above -6 dBFS is hot, and -18 dBFS is about where dialogue should sit.
    private static func color(for db: Float) -> Color {
        if db > -6 { return .red }
        if db > -18 { return .yellow }
        return .green
    }

    private func accessibilityText(_ channels: [Float], isClipped: Bool) -> String {
        guard !channels.isEmpty else { return "No audio" }
        let values = channels.map { "\(Int($0.rounded())) dB" }.joined(separator: ", ")
        return isClipped ? "\(values), clipping" : values
    }
}

#Preview {
    AudioMeterView(levels: { AudioLevels(channels: [-12, -4], isClipped: true) })
        .padding()
        .background(.black)
}
