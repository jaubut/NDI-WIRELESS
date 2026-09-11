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
    /// Owned here, not by a service: the transport stays transport, and the mock does
    /// not have to reimplement the recovery policy to be useful.
    private let pathMonitor: NetworkPathMonitor
    private(set) var falseColorProcessor = FalseColorProcessor()
    private(set) var histogramProcessor = HistogramProcessor()
    var histogramData: [String: HistogramData] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var receiveTasks: [String: Task<Void, Never>] = [:]
    private var histogramTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var pathMonitorTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?

    /// A feed with no new frame for this long is reported as reconnecting.
    static let starvedAfterMilliseconds: Double = 2000

    /// Escalation ladder timings. Properties rather than constants so the resilience
    /// tests can drive the whole ladder without sleeping through it; nothing in the app
    /// changes them from the defaults.
    var rebuildAfterSeconds: Double = 6
    var rediscoverAfterSeconds: Double = 20

    init(service: NDIService, pathMonitor: NetworkPathMonitor = NetworkPathMonitor()) {
        self.service = service
        self.pathMonitor = pathMonitor
    }

    /// Ids whose receive task is still running and still writing `frames`.
    ///
    /// The resilience tests check the ordering property against this: no stop path may
    /// reach the transport while one of these is live.
    var receivingSourceIDs: Set<String> {
        Set(receiveTasks.compactMap { $0.value.isCancelled ? nil : $0.key })
    }

    // MARK: - Discovery

    func startDiscovery() {
        startPathMonitoring()
        guard !isDiscovering else { return }
        isDiscovering = true
        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await sources in self.service.discoverSources() {
                self.discoveredSources = sources
                for source in sources {
                    self.sourceIndex[source.id] = source
                }
                self.applyScreenshotModeIfNeeded()
            }
        }
    }

    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        isDiscovering = false
    }

    /// A finder bound to the interface that just went away will not find anything on the
    /// new one. Rebuild it — but only if discovery was already running: recovery must
    /// never switch discovery on behind the user's back.
    ///
    /// Tiles are safe across this: they render from `sourceIndex`, which is upserted and
    /// never evicted, so the empty first yield of a fresh finder cannot blank the wall.
    private func restartDiscovery() {
        guard isDiscovering else { return }
        stopDiscovery()
        startDiscovery()
    }

    // MARK: - Screenshot mode

    /// Launch arguments used only when capturing App Store screenshots. Without them
    /// nothing in this section does anything at all.
    static let screenshotModeArgument = "-screenshotMode"
    static let screenshotGridArgument = "-screenshotGrid"

    private let isScreenshotMode = ProcessInfo.processInfo.arguments
        .contains(MonitorViewModel.screenshotModeArgument)
    private let wantsScreenshotGrid = ProcessInfo.processInfo.arguments
        .contains(MonitorViewModel.screenshotGridArgument)

    /// Put the demo feed on screen as soon as discovery offers it, with the chrome up.
    ///
    /// Runs once: the empty-selection guard closes it the moment a source is taken, so a
    /// later discovery yield cannot re-select or reorder anything.
    ///
    /// The fallback to the first discovered source is what makes this usable on the
    /// simulator, which builds Mock-only and therefore has no `demo://` source at all. On
    /// the shipping build the composite yields the demo source in its very first list, so
    /// the fallback is never reached.
    private func applyScreenshotModeIfNeeded() {
        guard isScreenshotMode, selectedSources.isEmpty else { return }
        let demo = discoveredSources.first { CompositeNDIService.isDemo($0.id) }
        guard let source = demo ?? discoveredSources.first else { return }

        isChromeVisible = true
        startReceiving(source)
        layoutMode = wantsScreenshotGrid ? .multi : .single
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

    // MARK: - Network path

    /// Watch the path for as long as the app is monitoring. Idempotent: a recovery pass
    /// restarts discovery through `startDiscovery()` and must not stack a second watcher.
    private func startPathMonitoring() {
        guard pathMonitorTask == nil else { return }
        let monitor = pathMonitor
        pathMonitorTask = Task { @MainActor [weak self] in
            for await change in monitor.changes() {
                guard let self else { return }
                self.handlePathChange(change)
            }
        }
    }

    private func stopPathMonitoring() {
        pathMonitorTask?.cancel()
        pathMonitorTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    /// The network moved under us. Recover in three steps, cheapest first.
    ///
    /// `frames` is never cleared at any step: the last good picture stays on screen under
    /// the chip, because a black tile mid-take reads as a dead camera. `connectionState`
    /// is left to the 1 Hz poll, which decides from evidence — a path change that did not
    /// actually interrupt the feed must not raise a chip.
    ///
    /// Internal rather than private so the resilience tests can drive the ladder without
    /// a real `NWPathMonitor`.
    func handlePathChange(_ change: PathChange) {
        // Cancel before replace. Two path changes 200 ms apart must leave one ladder
        // running, not two racing to rebuild the same receiver.
        recoveryTask?.cancel()
        recoveryTask = nil

        // A path that is down has nothing to reconnect to. The poll raises the chip on
        // its own, and the next change — the path coming back — runs the ladder.
        guard change.isSatisfied else { return }

        // Step 1, now: re-point every live receiver, and put a fresh finder on the new
        // path so `sourceIndex` picks up anything that moved.
        for sourceID in selectedSources {
            guard let source = sourceIndex[sourceID] else { continue }
            service.reconnect(source)
        }
        restartDiscovery()

        guard !selectedSources.isEmpty else { return }

        let baseline = frameCounts()
        let rebuildDelay = rebuildAfterSeconds
        let rediscoverDelay = rediscoverAfterSeconds

        recoveryTask = Task { @MainActor [weak self] in
            // Step 2: the re-point did not take, so rebuild the receiver outright.
            try? await Task.sleep(for: .seconds(rebuildDelay))
            guard !Task.isCancelled else { return }
            let rebuilt = self?.rebuildStarvedReceivers(since: baseline) ?? [:]

            // Step 3: still nothing. A fresh finder, and the chip stays up.
            try? await Task.sleep(for: .seconds(max(0, rediscoverDelay - rebuildDelay)))
            guard !Task.isCancelled else { return }
            self?.restartDiscoveryIfStarved(since: rebuilt)
        }
    }

    /// Frames taken delivery of per selected source, right now.
    ///
    /// Health is pulled from the transport rather than read from `stats`, which only
    /// refreshes while the chrome is up — recovery has to work with the chrome hidden.
    private func frameCounts() -> [String: Int64] {
        var counts: [String: Int64] = [:]
        for sourceID in selectedSources {
            guard let source = sourceIndex[sourceID],
                  let snapshot = service.stats(for: source) else { continue }
            counts[sourceID] = snapshot.received
        }
        return counts
    }

    /// Sources with no *new* frame since `baseline` and nobody on the other end.
    ///
    /// Counting frames rather than watching a clock keeps this exact: `received` only
    /// advances on a timestamp the receiver has not seen before. Both halves are
    /// required, per the plan — a feed that is connected and momentarily quiet is not
    /// worth tearing down mid-take.
    private func starvedSources(since baseline: [String: Int64]) -> [NDISource] {
        selectedSources.compactMap { sourceID in
            guard let source = sourceIndex[sourceID] else { return nil }
            // Nothing is receiving this id at all: that is the worst case, not a healthy one.
            guard let snapshot = service.stats(for: source) else { return source }
            guard snapshot.connections == 0 else { return nil }
            guard let before = baseline[sourceID] else { return source }
            return snapshot.received > before ? nil : source
        }
    }

    /// Step 2. Rebuilds through `resubscribe`, so selection, order and the last frame are
    /// untouched and the old task is cancelled before the new one is stored.
    /// - Returns: the frame counts to judge step 3 against.
    @discardableResult
    private func rebuildStarvedReceivers(since baseline: [String: Int64]) -> [String: Int64] {
        for source in starvedSources(since: baseline) {
            resubscribe(source: source, bandwidth: bandwidth[source.id] ?? .highest)
        }
        return frameCounts()
    }

    /// Step 3. The receiver was rebuilt and still has nothing: the SDK's own finder is
    /// the last thing left that could still be bound to the dead interface.
    private func restartDiscoveryIfStarved(since baseline: [String: Int64]) {
        guard !starvedSources(since: baseline).isEmpty else { return }
        restartDiscovery()
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
        // Cancel first, then stop — the same order as `stopReceiving(_:)`, so no stop
        // ever reaches the transport while a receive task is still writing frames.
        receiveTasks.values.forEach { $0.cancel() }
        receiveTasks.removeAll()
        // Resolved through the session index, not through discovery: a source that
        // dropped off the network still has to be stoppable.
        for sourceID in selectedSources {
            if let source = sourceIndex[sourceID] {
                service.stopReceiving(from: source)
            }
        }
        selectedSources.removeAll()
        frames.removeAll()
        histogramData.removeAll()
        primarySourceID = nil
        stopStatsPolling()
        stopPathMonitoring()
        stopDiscovery()
        service.stopAll()
    }
}
