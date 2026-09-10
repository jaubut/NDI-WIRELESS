//
//  SingleMonitorView.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import SwiftUI

struct SingleMonitorView: View {
    var viewModel: MonitorViewModel

    @State private var steadyScale: CGFloat = 1.0
    @GestureState private var gestureScale: CGFloat = 1.0
    @State private var steadyOffset: CGSize = .zero
    @GestureState private var gestureDrag: CGSize = .zero

    private var effectiveScale: CGFloat {
        max(1.0, min(steadyScale * gestureScale, 10.0))
    }

    private var effectiveOffset: CGSize {
        CGSize(
            width: steadyOffset.width + gestureDrag.width,
            height: steadyOffset.height + gestureDrag.height
        )
    }

    /// From the session index, never from discovery: a source that drops off the
    /// network keeps its title instead of going blank mid-take.
    private var source: NDISource? {
        viewModel.primarySourceID.flatMap { viewModel.sourceIndex[$0] }
    }

    private var sourceID: String? { viewModel.primarySourceID }

    private var status: SourceConnectionState {
        sourceID.flatMap { viewModel.connectionState[$0] } ?? .live
    }

    private var bandwidth: NDIBandwidthMode {
        sourceID.flatMap { viewModel.bandwidth[$0] } ?? .highest
    }

    /// Drawn here, not inside `VideoFrameView`: the histogram used to scale and drift
    /// with the pinch because it lived in the scaled subtree.
    private var histogram: HistogramData? {
        sourceID.flatMap { viewModel.histogramData[$0] }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoFrameView(
                frame: sourceID.flatMap { viewModel.frames[$0] },
                sourceName: source?.name ?? "No Source",
                falseColorProcessor: viewModel.isFalseColorActive
                    ? viewModel.falseColorProcessor : nil,
                status: status,
                isProxy: bandwidth.isProxy
            )
            .scaleEffect(effectiveScale)
            .offset(effectiveOffset)
            .ignoresSafeArea()

            overlayLayer
        }
        .simultaneousGesture(
            MagnifyGesture()
                .updating($gestureScale) { value, state, _ in
                    state = value.magnification
                }
                .onEnded { value in
                    let newScale = max(1.0, min(steadyScale * value.magnification, 10.0))
                    steadyScale = newScale
                    if newScale == 1.0 {
                        withAnimation(.easeOut(duration: 0.2)) {
                            steadyOffset = .zero
                        }
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .updating($gestureDrag) { value, state, _ in
                    guard effectiveScale > 1.0 else { return }
                    state = value.translation
                }
                .onEnded { value in
                    guard effectiveScale > 1.0 else { return }
                    steadyOffset = CGSize(
                        width: steadyOffset.width + value.translation.width,
                        height: steadyOffset.height + value.translation.height
                    )
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.easeOut(duration: 0.2)) {
                steadyScale = 1.0
                steadyOffset = .zero
            }
        }
        .navigationTitle(source?.name ?? "Monitor")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: viewModel.frames[viewModel.primarySourceID ?? ""]) {
            if let id = viewModel.primarySourceID {
                viewModel.updateHistogram(for: id)
            }
        }
        .onChange(of: viewModel.isHistogramActive) {
            if let id = viewModel.primarySourceID {
                if viewModel.isHistogramActive {
                    viewModel.updateHistogram(for: id)
                } else {
                    viewModel.histogramData.removeValue(forKey: id)
                }
            }
        }
    }

    /// Everything that must stay put and stay legible while the picture zooms.
    @ViewBuilder
    private var overlayLayer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SourceStatusChip(state: status)
                if bandwidth.isProxy {
                    ProxyBadge()
                }
                Spacer()
            }

            Spacer()

            HStack(alignment: .bottom) {
                if viewModel.isChromeVisible, let id = sourceID {
                    StatsOverlayView(
                        stats: viewModel.stats[id],
                        bandwidth: bandwidth,
                        setBandwidth: { viewModel.setBandwidth($0, for: id) }
                    )
                }
                Spacer()
                if let histogram {
                    HistogramView(data: histogram)
                        .frame(width: 200, height: 100)
                }
            }
        }
        .padding(12)
    }
}
