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

    private var source: NDISource? {
        viewModel.discoveredSources.first { $0.id == viewModel.primarySourceID }
    }

    var body: some View {
        VideoFrameView(
            frame: viewModel.primarySourceID.flatMap { viewModel.frames[$0] },
            sourceName: source?.name ?? "No Source",
            falseColorProcessor: viewModel.isFalseColorActive
                ? viewModel.falseColorProcessor : nil,
            histogramData: viewModel.primarySourceID.flatMap {
                viewModel.histogramData[$0]
            }
        )
        .scaleEffect(effectiveScale)
        .offset(effectiveOffset)
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
        .ignoresSafeArea()
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
}
