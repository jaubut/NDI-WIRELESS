//
//  MonitorViewModel+PTZ.swift
//  NDI WIRELESS
//
//  Split out of MonitorViewModel.swift for its 600-line cap. State stays on the class.
//

import Foundation

extension MonitorViewModel {
    // MARK: - PTZ

    /// Continuous pan and tilt. Send (0, 0) to stop.
    func setPanTilt(pan: Float, tilt: Float, for sourceID: String) {
        let command = PTZCommand.panTiltSpeed(pan: PTZCommand.quantized(pan), tilt: PTZCommand.quantized(tilt))
        guard lastPanTilt[sourceID] != command else { return }
        // Recorded only once delivered: a dropped stop must not dedupe the next one.
        let delivered = sendPTZ(command, to: sourceID)
        if delivered {
            lastPanTilt[sourceID] = command
            pendingPanTiltStops.remove(sourceID)
        } else if command == .panTiltSpeed(pan: 0, tilt: 0), lastPanTilt[sourceID] != nil {
            pendingPanTiltStops.insert(sourceID)
        }
    }

    /// Continuous zoom. Send 0 to stop.
    func setZoomSpeed(_ speed: Float, for sourceID: String) {
        let command = PTZCommand.zoomSpeed(PTZCommand.quantized(speed))
        guard lastZoom[sourceID] != command else { return }
        let delivered = sendPTZ(command, to: sourceID)
        if delivered {
            lastZoom[sourceID] = command
            pendingZoomStops.remove(sourceID)
        } else if command == .zoomSpeed(0), lastZoom[sourceID] != nil {
            pendingZoomStops.insert(sourceID)
        }
    }

    /// Stop every continuous move. The control calls this whenever it goes away.
    func stopPTZ(for sourceID: String) {
        setPanTilt(pan: 0, tilt: 0, for: sourceID)
        setZoomSpeed(0, for: sourceID)
    }

    /// A deselect must never leave a camera moving. Undriven sources get no PTZ traffic.
    func stopPTZIfMoved(_ sourceID: String) {
        if lastPanTilt[sourceID] != nil || lastZoom[sourceID] != nil { stopPTZ(for: sourceID) }
    }

    /// One-shot commands (presets, AF). Continuous moves use the deduping setters.
    @discardableResult func sendPTZ(_ command: PTZCommand, to sourceID: String) -> Bool {
        guard selectedSources.contains(sourceID), let source = sourceIndex[sourceID] else { return false }
        return service.sendPTZ(command, to: source)
    }
}
