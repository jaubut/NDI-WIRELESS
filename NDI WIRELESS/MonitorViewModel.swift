//
//  MonitorViewModel.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import CoreGraphics
import Foundation
import Observation

enum LayoutMode: CaseIterable, Hashable {
    case single
    case multi
}

@Observable
final class MonitorViewModel {
    // MARK: - State

    /// Picker-only: whatever the network reported on the last discovery yield.
    /// Nothing that is on screen may be derived from this — a flap empties it.
    var discoveredSources: [NDISource] = []

    /// The session's frame of reference. Upserted on every discovery yield and never
    /// evicted, so a source that drops off the network keeps its tile, its title and
    /// its place in the grid.
    var sourceIndex: [String: NDISource] = [:]

    /// Ordered: selection order is tile order. The no-duplicate invariant rests solely
    /// on the guard in `startReceiving(_:)` — any new write site must re-check it.
    var selectedSources: [String] = []

    var frames: [String: CGImage] = [:]
    var bandwidth: [String: NDIBandwidthMode] = [:]
    var stats: [String: FrameStats] = [:]
    var connectionState: [String: SourceConnectionState] = [:]
    var layoutMode: LayoutMode = .multi
    var primarySourceID: String?
    var isDiscovering = false
    var isChromeVisible = true
    var activeTools: Set<MonitorTool> = []

    // MARK: - Private

    private let service: NDIService
    private(set) var falseColorProcessor = FalseColorProcessor()
    private(set) var histogramProcessor = HistogramProcessor()
    var histogramData: [String: HistogramData] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var receiveTasks: [String: Task<Void, Never>] = [:]
    private var histogramTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?

    /// A feed with no new frame for this long is reported as reconnecting.
    static let starvedAfterMilliseconds: Double = 2000

    init(service: NDIService) {
        self.service = service
    }

    // MARK: - Discovery

    func startDiscovery() {
        guard !isDiscovering else { return }
        isDiscovering = true
        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await sources in self.service.discoverSources() {
                self.discoveredSources = sources
                for source in sources {
                    self.sourceIndex[source.id] = source
                }
            }
        }
    }

    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        isDiscovering = false
    }

    // MARK: - Receiving

    func toggleSource(_ source: NDISource) {
        if selectedSources.contains(source.id) {
            stopReceiving(source)
        } else {
            startReceiving(source)
        }
    }

    func startReceiving(_ source: NDISource) {
        guard !selectedSources.contains(source.id) else { return }
        selectedSources.append(source.id)
        sourceIndex[source.id] = source

        if primarySourceID == nil {
            primarySourceID = source.id
        }

        let mode = bandwidth[source.id] ?? .highest
        bandwidth[source.id] = mode
        connectionState[source.id] = .live

        resubscribe(source: source, bandwidth: mode)
        startStatsPolling()
    }

    func stopReceiving(_ source: NDISource) {
        selectedSources.removeAll { $0 == source.id }
        receiveTasks[source.id]?.cancel()
        receiveTasks.removeValue(forKey: source.id)
        frames.removeValue(forKey: source.id)
        stats.removeValue(forKey: source.id)
        connectionState.removeValue(forKey: source.id)
        histogramData.removeValue(forKey: source.id)

        // Cancels the transport's loop and drops its bookkeeping; the loop destroys its
        // own C instances as it unwinds. Nothing here destroys anything.
        service.stopReceiving(from: source)

        if primarySourceID == source.id {
            primarySourceID = selectedSources.first
        }
        if selectedSources.isEmpty {
            stopStatsPolling()
        }
    }

    // MARK: - Bandwidth

    /// Switch a source between full resolution and the low-bandwidth proxy.
    ///
    /// Frames are deliberately *not* cleared: the receiver is rebuilt underneath, and a
    /// black flash mid-take reads as a dropped feed.
    func setBandwidth(_ mode: NDIBandwidthMode, for sourceID: String) {
        guard bandwidth[sourceID] != mode else { return }
        bandwidth[sourceID] = mode

        guard selectedSources.contains(sourceID), let source = sourceIndex[sourceID] else { return }
        resubscribe(source: source, bandwidth: mode)
    }

    /// Replace the subscription for an already-selected source.
    ///
    /// The old task is cancelled before the new one is stored, so two live tasks can
    /// never write `frames[id]`. Selection is untouched: this is not a start or a stop.
    private func resubscribe(source: NDISource, bandwidth mode: NDIBandwidthMode) {
        receiveTasks[source.id]?.cancel()

        let stream = service.startReceiving(from: source, bandwidth: mode)
        receiveTasks[source.id] = Task { @MainActor [weak self] in
            for await frame in stream {
                guard let self, self.selectedSources.contains(source.id) else { break }
                self.frames[source.id] = frame
            }
        }
    }

    // MARK: - Stats

    /// Pull health at 1 Hz. Never push: writing ms-since-last-frame into `@Observable`
    /// at frame rate invalidates the same view tree that draws the video.
    private func startStatsPolling() {
        guard statsTask == nil else { return }
        statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.pollStats()
            }
        }
    }

    private func stopStatsPolling() {
        statsTask?.cancel()
        statsTask = nil
        stats.removeAll()
        connectionState.removeAll()
    }

    /// The readout is chrome and only runs when chrome is up; connection state is video
    /// status, so it is refreshed either way.
    private func pollStats() {
        for sourceID in selectedSources {
            guard let source = sourceIndex[sourceID] else { continue }
            let snapshot = service.stats(for: source)

            if isChromeVisible {
                if let snapshot {
                    stats[sourceID] = snapshot
                } else {
                    stats.removeValue(forKey: sourceID)
                }
            }

            connectionState[sourceID] = Self.connectionState(
                from: snapshot,
                previous: connectionState[sourceID]
            )
        }
    }

    /// Live unless the receiver reports no connections, or no new frame has landed
    /// within the starvation window. An existing gap keeps its original start time.
    static func connectionState(
        from stats: FrameStats?,
        previous: SourceConnectionState?,
        now: Date = Date()
    ) -> SourceConnectionState {
        let isStalled: Bool
        if let stats {
            let starved = (stats.msSinceLastFrame ?? .greatestFiniteMagnitude) > starvedAfterMilliseconds
            isStalled = starved || stats.connections == 0
        } else {
            // Nothing is receiving this id — that is a gap, not a healthy feed.
            isStalled = true
        }

        guard isStalled else { return .live }
        if case .reconnecting(let since) = previous {
            return .reconnecting(since: since)
        }
        return .reconnecting(since: now)
    }

    // MARK: - Tools

    func toggleTool(_ tool: MonitorTool) {
        if activeTools.contains(tool) {
            activeTools.remove(tool)
        } else {
            activeTools.insert(tool)
        }
    }

    var isFalseColorActive: Bool {
        activeTools.contains(.falseColor)
    }

    var isHistogramActive: Bool {
        activeTools.contains(.histogram)
    }

    /// Compute histogram for a given source's current frame on a background thread.
    func updateHistogram(for sourceID: String) {
        guard isHistogramActive, let frame = frames[sourceID] else {
            histogramData.removeValue(forKey: sourceID)
            return
        }
        let processor = histogramProcessor
        histogramTask?.cancel()
        histogramTask = Task.detached { [weak self] in
            let result = processor.compute(frame)
            guard let result else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isHistogramActive else { return }
                self.histogramData[sourceID] = result
            }
        }
    }

    func selectPrimary(_ source: NDISource) {
        primarySourceID = source.id
        layoutMode = .single
    }

    func stopAll() {
        // Resolved through the session index, not through discovery: a source that
        // dropped off the network still has to be stoppable.
        for sourceID in selectedSources {
            if let source = sourceIndex[sourceID] {
                service.stopReceiving(from: source)
            }
        }
        selectedSources.removeAll()
        receiveTasks.values.forEach { $0.cancel() }
        receiveTasks.removeAll()
        frames.removeAll()
        histogramData.removeAll()
        primarySourceID = nil
        stopStatsPolling()
        stopDiscovery()
        service.stopAll()
    }
}
