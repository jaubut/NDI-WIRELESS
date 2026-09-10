//
//  MonitorViewModel.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import CoreGraphics
import Observation

enum LayoutMode: CaseIterable, Hashable {
    case single
    case multi
}

@Observable
final class MonitorViewModel {
    // MARK: - State

    var discoveredSources: [NDISource] = []
    var selectedSources: Set<String> = []
    var frames: [String: CGImage] = [:]
    var layoutMode: LayoutMode = .multi
    var primarySourceID: String?
    var isDiscovering = false
    var activeTools: Set<MonitorTool> = []

    // MARK: - Private

    private let service: NDIService
    private(set) var falseColorProcessor = FalseColorProcessor()
    private(set) var histogramProcessor = HistogramProcessor()
    var histogramData: [String: HistogramData] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var receiveTasks: [String: Task<Void, Never>] = [:]
    private var histogramTask: Task<Void, Never>?

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
        selectedSources.insert(source.id)

        if primarySourceID == nil {
            primarySourceID = source.id
        }

        let stream = service.startReceiving(from: source)
        receiveTasks[source.id] = Task { @MainActor [weak self] in
            for await frame in stream {
                guard let self, self.selectedSources.contains(source.id) else { break }
                self.frames[source.id] = frame
            }
        }
    }

    func stopReceiving(_ source: NDISource) {
        selectedSources.remove(source.id)
        receiveTasks[source.id]?.cancel()
        receiveTasks.removeValue(forKey: source.id)
        frames.removeValue(forKey: source.id)
        service.stopReceiving(from: source)

        if primarySourceID == source.id {
            primarySourceID = selectedSources.first
        }
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
        for sourceID in selectedSources {
            if let source = discoveredSources.first(where: { $0.id == sourceID }) {
                service.stopReceiving(from: source)
            }
        }
        selectedSources.removeAll()
        receiveTasks.values.forEach { $0.cancel() }
        receiveTasks.removeAll()
        frames.removeAll()
        primarySourceID = nil
        stopDiscovery()
        service.stopAll()
    }
}
