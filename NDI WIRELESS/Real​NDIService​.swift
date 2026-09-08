//
//  RealNDIService.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//
//  SETUP INSTRUCTIONS:
//  To enable real NDI support, you must configure the Xcode project:
//
//  1. Add the NDI static library:
//     - Go to Build Phases > Link Binary With Libraries
//     - Add /Library/NDI SDK for Apple/lib/iOS/libndi_ios.a (for iOS)
//       or /Library/NDI SDK for Apple/lib/macOS/libndi.dylib (for macOS)
//
//  2. Add Header Search Paths:
//     - Go to Build Settings > Header Search Paths
//     - Add: /Library/NDI SDK for Apple/include
//
//  3. Set the Objective-C Bridging Header:
//     - Go to Build Settings > Swift Compiler - General > Objective-C Bridging Header
//     - Set to: NDI WIRELESS/NDI-WIRELESS-Bridging-Header.h
//
//  4. Add the NDI_ENABLED Swift compiler flag:
//     - Go to Build Settings > Swift Compiler - Custom Flags > Active Compilation Conditions
//     - Add: NDI_ENABLED
//
//  5. Add required frameworks (Link Binary With Libraries):
//     - Accelerate.framework
//     - VideoToolbox.framework
//
//  6. Add Info.plist entries for local network access:
//     - NSLocalNetworkUsageDescription: "NDI WIRELESS needs local network access to discover NDI sources."
//     - NSBonjourServices: ["_ndi._tcp"]
//
//  7. Change NDI_WIRELESSApp.swift to use RealNDIService() instead of MockNDIService()
//

import CoreGraphics
import Foundation

#if NDI_ENABLED

final class RealNDIService: NDIService {
    private var findInstance: NDIlib_find_instance_t?
    private var receivers: [String: ReceiverState] = [:]

    /// Tracks the state of an active NDI receiver for a single source.
    private struct ReceiverState {
        let recvInstance: NDIlib_recv_instance_t
        let framesyncInstance: NDIlib_framesync_instance_t
    }

    init() {
        NDIlib_initialize()
    }

    deinit {
        stopAll()
        NDIlib_destroy()
    }

    // MARK: - Discovery

    func discoverSources() -> AsyncStream<[NDISource]> {
        AsyncStream { [weak self] continuation in
            var findCreate = NDIlib_find_create_t()
            findCreate.show_local_sources = true
            findCreate.p_groups = nil
            findCreate.p_extra_ips = nil

            guard let finder = NDIlib_find_create_v2(&findCreate) else {
                continuation.finish()
                return
            }

            self?.findInstance = finder

            let task = Task.detached {
                while !Task.isCancelled {
                    // Wait up to 1 second for source list changes
                    _ = NDIlib_find_wait_for_sources(finder, 1000)

                    var numSources: UInt32 = 0
                    let sourcesPtr = NDIlib_find_get_current_sources(finder, &numSources)

                    var sources: [NDISource] = []
                    if let sourcesPtr, numSources > 0 {
                        for i in 0..<Int(numSources) {
                            let ndiSource = sourcesPtr[i]
                            let name = ndiSource.p_ndi_name.flatMap { String(cString: $0) } ?? "Unknown"
                            let url = ndiSource.p_url_address.flatMap { String(cString: $0) } ?? ""
                            let ipAddress = Self.extractIPAddress(from: url)

                            sources.append(NDISource(
                                id: name,
                                name: name,
                                ipAddress: ipAddress
                            ))
                        }
                    }

                    continuation.yield(sources)
                }
            }

            continuation.onTermination = { [weak self] _ in
                task.cancel()
                if let finder = self?.findInstance {
                    NDIlib_find_destroy(finder)
                    self?.findInstance = nil
                }
            }
        }
    }

    // MARK: - Receiving

    func startReceiving(from source: NDISource) -> AsyncStream<CGImage> {
        stopReceiving(from: source)

        return AsyncStream { [weak self] continuation in
            // Build an NDIlib_source_t from the source name.
            // The SDK will use its internal finder to locate the source by name.
            guard let ndiNameCStr = strdup(source.id) else {
                continuation.finish()
                return
            }

            var ndiSource = NDIlib_source_t()
            ndiSource.p_ndi_name = UnsafePointer(ndiNameCStr)
            ndiSource.p_url_address = nil

            // Request BGRX/BGRA so we get 32-bit RGBA-like data for easy CGImage conversion
            var recvCreate = NDIlib_recv_create_v3_t()
            recvCreate.source_to_connect_to = ndiSource
            recvCreate.color_format = NDIlib_recv_color_format_BGRX_BGRA
            recvCreate.bandwidth = NDIlib_recv_bandwidth_highest
            recvCreate.allow_video_fields = false
            recvCreate.p_ndi_recv_name = nil

            guard let recvInstance = NDIlib_recv_create_v3(&recvCreate) else {
                free(ndiNameCStr)
                continuation.finish()
                return
            }

            // Frame sync handles clock correction — ideal for a monitor pulling frames at display rate
            guard let framesyncInstance = NDIlib_framesync_create(recvInstance) else {
                NDIlib_recv_destroy(recvInstance)
                free(ndiNameCStr)
                continuation.finish()
                return
            }

            free(ndiNameCStr)

            self?.receivers[source.id] = ReceiverState(
                recvInstance: recvInstance,
                framesyncInstance: framesyncInstance
            )

            let task = Task.detached {
                while !Task.isCancelled {
                    var videoFrame = NDIlib_video_frame_v2_t()

                    // Pull a progressive video frame. This always returns immediately.
                    NDIlib_framesync_capture_video(
                        framesyncInstance,
                        &videoFrame,
                        NDIlib_frame_format_type_progressive
                    )

                    if videoFrame.xres > 0, videoFrame.yres > 0, videoFrame.p_data != nil {
                        // Copy the frame data into a CGImage before freeing
                        if let cgImage = Self.createCGImage(from: &videoFrame) {
                            continuation.yield(cgImage)
                        }
                    }

                    NDIlib_framesync_free_video(framesyncInstance, &videoFrame)

                    // ~30fps capture rate
                    try? await Task.sleep(for: .milliseconds(33))
                }
                continuation.finish()
            }

            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.cleanupReceiver(for: source.id)
            }
        }
    }

    func stopReceiving(from source: NDISource) {
        cleanupReceiver(for: source.id)
    }

    func stopAll() {
        for sourceID in Array(receivers.keys) {
            cleanupReceiver(for: sourceID)
        }

        if let finder = findInstance {
            NDIlib_find_destroy(finder)
            findInstance = nil
        }
    }

    // MARK: - Private Helpers

    private func cleanupReceiver(for sourceID: String) {
        guard let state = receivers.removeValue(forKey: sourceID) else { return }
        NDIlib_framesync_destroy(state.framesyncInstance)
        NDIlib_recv_destroy(state.recvInstance)
    }

    /// Convert an NDI BGRX video frame to a CGImage.
    ///
    /// The frame data is in BGRX format (Blue, Green, Red, X) with 4 bytes per pixel.
    /// We create a CGImage by copying the data so it remains valid after the NDI frame is freed.
    private nonisolated static func createCGImage(from frame: inout NDIlib_video_frame_v2_t) -> CGImage? {
        let width = Int(frame.xres)
        let height = Int(frame.yres)
        let stride = Int(frame.line_stride_in_bytes)

        guard width > 0, height > 0, stride > 0, let srcData = frame.p_data else {
            return nil
        }

        let dataSize = stride * height

        // Copy the pixel data so the CGImage owns it (the NDI frame will be freed after this)
        guard let dataCopy = malloc(dataSize) else { return nil }
        memcpy(dataCopy, srcData, dataSize)

        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: dataCopy,
            size: dataSize,
            releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }
        ) else {
            free(dataCopy)
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // BGRX = 32-bit little-endian with alpha channel skipped (first byte)
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Extract an IP address from an NDI URL/address string.
    private nonisolated static func extractIPAddress(from urlString: String) -> String {
        // NDI address format is typically "IP:PORT" or a more complex URL
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        if let colonRange = trimmed.range(of: ":") {
            return String(trimmed[trimmed.startIndex..<colonRange.lowerBound])
        }
        return trimmed
    }
}

#endif // NDI_ENABLED
