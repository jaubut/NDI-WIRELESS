//
//  PTZControlView.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-10-04.
//
//  Pan/tilt joystick, hold-to-zoom, four presets and auto focus. Shown only for a source
//  whose sender advertises PTZ.
//
//  Every continuous move is driven by `@GestureState`, which resets on end *and* on
//  cancel. A move stops when the finger lifts, when the system steals the touch, and when
//  the control disappears. A camera left panning into a wall is the failure this file is
//  built around.
//

import SwiftUI

struct PTZControlView: View {
    let setPanTilt: (_ pan: Float, _ tilt: Float) -> Void
    let setZoom: (Float) -> Void
    let send: (PTZCommand) -> Void
    let stop: () -> Void

    private static let stickRadius: CGFloat = 50
    /// Hold-to-zoom speed. Calibration knob: full speed overshoots on most heads.
    private static let zoomSpeed: Float = 0.5
    private static let presetCount = 4

    @GestureState private var stick: CGSize = .zero
    @GestureState private var isZoomingIn = false
    @GestureState private var isZoomingOut = false

    var body: some View {
        VStack(spacing: 10) {
            joystick

            HStack(spacing: 8) {
                holdButton("minus.magnifyingglass", label: "Zoom out", state: $isZoomingOut)
                holdButton("plus.magnifyingglass", label: "Zoom in", state: $isZoomingIn)
                Button("AF") { send(.autoFocus) }
                    .font(.caption.weight(.bold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15), in: Circle())
                    .accessibilityLabel("Auto focus")
            }

            HStack(spacing: 6) {
                ForEach(0..<Self.presetCount, id: \.self) { preset in
                    presetButton(preset)
                }
            }
        }
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
        .onChange(of: stick) { _, offset in
            let (pan, tilt) = Self.speeds(for: offset)
            setPanTilt(pan, tilt)
        }
        .onChange(of: isZoomingIn) { updateZoom() }
        .onChange(of: isZoomingOut) { updateZoom() }
        .onDisappear { stop() }
    }

    // MARK: - Joystick

    private var joystick: some View {
        let knob = Self.clampedToRadius(stick)
        return ZStack {
            Circle().fill(.white.opacity(0.12))
            Circle().stroke(.white.opacity(0.3), lineWidth: 1)
            Circle()
                .fill(.white.opacity(0.8))
                .frame(width: 28, height: 28)
                .offset(knob)
        }
        .frame(width: Self.stickRadius * 2, height: Self.stickRadius * 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($stick) { value, state, _ in
                    state = value.translation
                }
        )
        .accessibilityLabel("Pan and tilt")
    }

    /// Drag offset to SDK speeds. The SDK's positive pan is left and positive tilt is up,
    /// so a drag right (+x) pans negative and a drag up (-y) tilts positive.
    static func speeds(for offset: CGSize) -> (pan: Float, tilt: Float) {
        let knob = clampedToRadius(offset)
        return (Float(-knob.width / stickRadius), Float(-knob.height / stickRadius))
    }

    private static func clampedToRadius(_ offset: CGSize) -> CGSize {
        let length = (offset.width * offset.width + offset.height * offset.height).squareRoot()
        guard length > stickRadius else { return offset }
        let scale = stickRadius / length
        return CGSize(width: offset.width * scale, height: offset.height * scale)
    }

    // MARK: - Zoom

    private func updateZoom() {
        if isZoomingIn == isZoomingOut {
            setZoom(0)
        } else {
            setZoom(isZoomingIn ? Self.zoomSpeed : -Self.zoomSpeed)
        }
    }

    private func holdButton(
        _ systemImage: String,
        label: String,
        state: GestureState<Bool>
    ) -> some View {
        Image(systemName: systemImage)
            .frame(width: 36, height: 36)
            .background(.white.opacity(state.wrappedValue ? 0.4 : 0.15), in: Circle())
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating(state) { _, held, _ in held = true }
            )
            .accessibilityLabel(label)
    }

    // MARK: - Presets

    /// Tap recalls. Storing goes behind the context menu: overwriting a preset by accident
    /// mid-take would be the expensive mistake.
    private func presetButton(_ preset: Int) -> some View {
        Button("\(preset + 1)") { send(.recallPreset(preset)) }
            .font(.caption.monospacedDigit())
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .contextMenu {
                Button("Store Preset \(preset + 1)") { send(.storePreset(preset)) }
            }
            .accessibilityLabel("Preset \(preset + 1)")
            .accessibilityHint("Recalls the preset. Long press to store the current position.")
    }
}

#Preview {
    PTZControlView(setPanTilt: { _, _ in }, setZoom: { _ in }, send: { _ in }, stop: {})
        .padding()
        .background(.black)
}
