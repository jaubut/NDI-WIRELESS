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
//     - Add: NDI_ENABLED (device SDK only — the archive has no arm64 simulator slice)
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
//  OWNERSHIP RULE — read before editing a teardown path:
//  whoever creates a C instance destroys it, on its own exit path, and nobody else.
//  The detached capture loop owns its recv/framesync pair; the discovery loop owns its
//  finder. `stopReceiving`, `stopAll` and stream termination may only *cancel* and clear
//  bookkeeping. There is deliberately no `deinit`: this service lives for the process
//  lifetime, and `NDIlib_destroy()` under live detached loops is a crash, not a cleanup.
//

import CoreGraphics
import Foundation

#if NDI_ENABLED

import Synchronization

/// One receiver's C instances plus its stats.
///
/// The pair is destroyed exactly once, by `close()`, which only the owning capture loop
/// calls when it exits. Readers reach the recv instance through `withRecv`, which takes
/// the same lock `close()` takes, so a stats pull can never overlap the destroy.
/// `nonisolated` on the declaration, not left to inference: the module defaults to
/// MainActor, and this handle is read and closed from the detached capture loop.
private nonisolated final class ReceiverHandle: @unchecked Sendable {
    let stats = FrameStatsAccumulator()

    /// Pulled by the owning loop only, which is why it needs no lock: the loop has
    /// finished by the time `close()` runs.
    let framesync: NDIlib_framesync_instance_t

    private let recv: NDIlib_recv_instance_t
    private let isClosed = Mutex(false)

    /// The capture loop, so a stop path can cancel it. Written and read on the main
    /// actor only — the loop itself never touches it.
    var task: Task<Void, Never>?

    init(recv: NDIlib_recv_instance_t, framesync: NDIlib_framesync_instance_t) {
        self.recv = recv
        self.framesync = framesync
    }

    /// Run `body` against the live receiver, or return nil once it has been destroyed.
    func withRecv<T>(_ body: (NDIlib_recv_instance_t) -> T) -> T? {
        isClosed.withLock { (closed: inout Bool) -> T? in
            closed ? nil : body(recv)
        }
    }

    /// Destroy the pair. Called by the owning loop on its way out, and by nobody else.
    func close() {
        isClosed.withLock { (closed: inout Bool) -> Void in
            guard !closed else { return }
            closed = true
            NDIlib_framesync_destroy(framesync)
            NDIlib_recv_destroy(recv)
        }
    }

    func cancel() {
        task?.cancel()
    }
}

final class RealNDIService: NDIService {
    /// Bookkeeping only — the discovery loop destroys the finder it created.
    private var findInstance: NDIlib_find_instance_t?
    private var discoveryTask: Task<Void, Never>?
    private var receivers: [String: ReceiverHandle] = [:]

    init() {
        NDIlib_initialize()
    }

    // MARK: - Discovery

    func discoverSources() -> AsyncStream<[NDISource]> {
        AsyncStream { [weak self] continuation in
            var findCreate = NDIlib_find_create_t()
            findCreate.show_local_sources = true
            findCreate.p_groups = nil
            findCreate.p_extra_ips = nil

            guard let created = NDIlib_find_create_v2(&findCreate) else {
                continuation.finish()
                return
            }

            // Owned by the loop below; the property is a bookkeeping copy that nothing
            // destroys.
            nonisolated(unsafe) let finder = created
            self?.findInstance = finder

            let task = Task.detached {
                while !Task.isCancelled {
                    // Short wait: a path change should surface in the picker in well
                    // under a second, and the call returns early when the list changes.
                    _ = NDIlib_find_wait_for_sources(finder, 250)

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

                // Exit path of the loop that created it: the only destroy.
                NDIlib_find_destroy(finder)
                continuation.finish()
            }

            self?.discoveryTask = task

            continuation.onTermination = { @Sendable [weak self] _ in
                task.cancel()
                Task { @MainActor [weak self] in
                    self?.findInstance = nil
                    self?.discoveryTask = nil
                }
            }
        }
    }

    // MARK: - Receiving

    func startReceiving(from source: NDISource, bandwidth: NDIBandwidthMode) -> AsyncStream<CGImage> {
        // Cancels any previous receiver for this id and drops its bookkeeping; that
        // loop destroys its own pair as it unwinds.
        stopReceiving(from: source)

        let sourceID = source.id

        return AsyncStream { [weak self] continuation in
            // Build an NDIlib_source_t from the source name.
            // The SDK will use its internal finder to locate the source by name.
            guard let ndiNameCStr = strdup(sourceID) else {
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
            recvCreate.bandwidth = bandwidth == .lowest
                ? NDIlib_recv_bandwidth_lowest
                : NDIlib_recv_bandwidth_highest
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

            let handle = ReceiverHandle(recv: recvInstance, framesync: framesyncInstance)
            self?.receivers[sourceID] = handle

            let task = Task.detached {
                let framesync = handle.framesync
                while !Task.isCancelled {
                    var videoFrame = NDIlib_video_frame_v2_t()

                    // Pull a progressive video frame. This always returns immediately.
                    NDIlib_framesync_capture_video(
                        framesync,
                        &videoFrame,
                        NDIlib_frame_format_type_progressive
                    )

                    if videoFrame.xres > 0, videoFrame.yres > 0, videoFrame.p_data != nil {
                        // Frame sync repeats the last frame between arrivals, so identity
                        // is decided *before* the malloc+memcpy: a repeat costs nothing
                        // and never reaches the view, which is what keeps the histogram
                        // and false colour from re-grading a frozen picture.
                        let isNewFrame = handle.stats.record(
                            timestamp: videoFrame.timestamp,
                            timecode: videoFrame.timecode,
                            frameRateN: Int32(videoFrame.frame_rate_N),
                            frameRateD: Int32(videoFrame.frame_rate_D)
                        )

                        if isNewFrame, let cgImage = Self.createCGImage(from: &videoFrame) {
                            continuation.yield(cgImage)
                        }
                    }

                    NDIlib_framesync_free_video(framesync, &videoFrame)

                    // ~30fps capture rate
                    try? await Task.sleep(for: .milliseconds(33))
                }

                // Exit path of the loop that created the pair: the only destroy.
                handle.close()
                continuation.finish()
            }

            handle.task = task

            continuation.onTermination = { @Sendable [weak self] _ in
                task.cancel()
                Task { @MainActor [weak self] in
                    self?.forgetReceiver(sourceID, ifSame: handle)
                }
            }
        }
    }

    func stopReceiving(from source: NDISource) {
        guard let handle = receivers.removeValue(forKey: source.id) else { return }
        handle.cancel()
    }

    func stopAll() {
        for handle in receivers.values {
            handle.cancel()
        }
        receivers.removeAll()

        discoveryTask?.cancel()
        discoveryTask = nil
        findInstance = nil
    }

    /// Re-point the existing receiver at its source. Never destroys anything: the
    /// ownership rule at the top of this file says only the capture loop may do that,
    /// and this call is exactly the SDK's way of keeping the loop's instance alive
    /// across a network change (`Recv.h:187`).
    ///
    /// `withRecv` takes the same lock `close()` takes, so a re-point can never overlap
    /// the destroy; on a receiver that has already gone it does nothing.
    func reconnect(_ source: NDISource) {
        guard let handle = receivers[source.id] else { return }
        let sourceID = source.id

        _ = handle.withRecv { recv -> Void in
            guard let ndiNameCStr = strdup(sourceID) else { return }
            defer { free(ndiNameCStr) }

            var ndiSource = NDIlib_source_t()
            ndiSource.p_ndi_name = UnsafePointer(ndiNameCStr)
            ndiSource.p_url_address = nil
            NDIlib_recv_connect(recv, &ndiSource)
        }
    }

    // MARK: - Stats

    func stats(for source: NDISource) -> FrameStats? {
        guard let handle = receivers[source.id] else { return nil }
        let local = handle.stats.snapshot()

        // Received and dropped come from two out-structs, not one: dropped frames are
        // `dropped.video_frames`. "Late" has no SDK equivalent and stays local.
        let merged = handle.withRecv { recv -> FrameStats in
            var total = NDIlib_recv_performance_t()
            var dropped = NDIlib_recv_performance_t()
            NDIlib_recv_get_performance(recv, &total, &dropped)
            let connections = Int(NDIlib_recv_get_no_connections(recv))
            return local.withTransportCounters(
                received: total.video_frames,
                dropped: dropped.video_frames,
                connections: connections
            )
        }
        return merged ?? local
    }

    // MARK: - Private Helpers

    /// Drop bookkeeping for a receiver, but only if a newer one has not taken its slot
    /// (a bandwidth swap replaces the handle while the old stream is still terminating).
    private func forgetReceiver(_ sourceID: String, ifSame handle: ReceiverHandle) {
        guard receivers[sourceID] === handle else { return }
        receivers.removeValue(forKey: sourceID)
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
