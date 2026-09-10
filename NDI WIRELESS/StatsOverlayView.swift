//
//  StatsOverlayView.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-09-11.
//
//  Receive health, plus the bandwidth control. Drawn by the call sites in their unscaled
//  overlay layer, never inside the video subtree — pinch-zoom must not move or magnify it.
//

import SwiftUI

struct StatsOverlayView: View {
    let stats: FrameStats?
    let bandwidth: NDIBandwidthMode
    let setBandwidth: (NDIBandwidthMode) -> Void

    private var bandwidthBinding: Binding<NDIBandwidthMode> {
        Binding(get: { bandwidth }, set: { setBandwidth($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                readout("FPS", fpsText)
                readout("MS", msText)
                readout("DROPPED", droppedText)
                readout("LATE", lateText, footnote: "local estimate")
            }

            HStack(spacing: 8) {
                Picker("Bandwidth", selection: bandwidthBinding) {
                    ForEach(NDIBandwidthMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .labelsHidden()

                if bandwidth.isProxy {
                    ProxyBadge()
                }
            }
        }
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
    }

    // MARK: - Readouts

    /// Nothing to report renders as an em dash. There is no zero to fall back on: a
    /// missing reading and a reading of zero mean different things on set.
    private var fpsText: String {
        guard let stats else { return "—" }
        let value = String(format: "%.1f", stats.fps)
        return stats.isEstimated ? "~\(value)" : value
    }

    private var msText: String {
        guard let ms = stats?.msSinceLastFrame else { return "—" }
        return String(Int(ms.rounded()))
    }

    private var droppedText: String {
        guard let stats else { return "—" }
        return String(stats.dropped)
    }

    private var lateText: String {
        guard let stats else { return "—" }
        return String(stats.late)
    }

    @ViewBuilder
    private func readout(_ label: String, _ value: String, footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            Text(value)
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
            if let footnote {
                Text(footnote)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// Shown while a feed is not delivering. The count-up is driven by SwiftUI, not by a
/// timer of ours, so the chip costs nothing while it sits there.
struct SourceStatusChip: View {
    let state: SourceConnectionState

    var body: some View {
        if case .reconnecting(let since) = state {
            HStack(spacing: 4) {
                Image(systemName: "wifi.exclamationmark")
                Text("RECONNECTING")
                Text(since, style: .timer)
                    .monospacedDigit()
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.orange.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
        }
    }
}

/// The picture is the sender's low-resolution proxy — false colour and the histogram
/// are reading that, not the full-resolution frame.
struct ProxyBadge: View {
    var body: some View {
        Text("PROXY")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.yellow.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
    }
}

#Preview {
    StatsOverlayView(
        stats: FrameStats(
            fps: 29.97, msSinceLastFrame: 34, received: 1200,
            dropped: 2, late: 1, isEstimated: false, connections: 1
        ),
        bandwidth: .lowest,
        setBandwidth: { _ in }
    )
    .padding()
    .background(.black)
}
