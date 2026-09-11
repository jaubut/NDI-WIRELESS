//
//  NetworkPathMonitor.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-09-11.
//
//  What the OS knows about the network path, coalesced into something a view model can
//  act on. `Network` only: no NDI here, so the transport stays transport and the mock
//  does not have to reimplement the recovery policy.
//
//  Isolation is declared, not inferred: `NWPathMonitor` calls back on its own queue and
//  the module defaults to MainActor.
//

import Foundation
import Network
import Synchronization

/// A network path that is not the one we were last on.
///
/// `interfaceFingerprint` is a cheap identity for "which network is this": the interfaces
/// the path runs over plus the gateways behind them. Walking to a different access point
/// usually changes the gateway; losing Wi-Fi changes both.
nonisolated struct PathChange: Sendable, Equatable {
    let isSatisfied: Bool
    let interfaceFingerprint: String
}

/// Emits a path change once a burst has settled.
///
/// `NWPathMonitor` fires several times on a single Wi-Fi transition — interface down,
/// interface up, address assigned — and each one would otherwise cost a full recovery
/// pass. Updates are held for `debounceSeconds` and only the settled state is emitted.
nonisolated final class NetworkPathMonitor: Sendable {
    /// Long enough to swallow a transition's burst, short enough that a viewer on set
    /// does not sit in front of a frozen frame wondering.
    static let debounceSeconds: Double = 1.5

    private struct State {
        var generation: UInt64 = 0
        /// The path we consider ourselves to be on. The first one observed is the
        /// launch state, not a change, so it is recorded and not emitted.
        var baseline: PathChange?
        var pending: PathChange?
        /// Set by any update inside the window that differs from the baseline, so a
        /// Wi-Fi toggle that lands back on the same access point still counts: the
        /// receivers died in the middle of it even though the fingerprint matches.
        var sawDifference = false
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "studio.techlab.ndi-wireless.path-monitor")
    private let debounce: Double

    init(debounceSeconds: Double = NetworkPathMonitor.debounceSeconds) {
        self.debounce = debounceSeconds
    }

    /// Departures from the path we are on, one per settled transition.
    ///
    /// The stream cancels its monitor on termination, so the caller only has to drop the
    /// task that is iterating it.
    func changes() -> AsyncStream<PathChange> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                // Everything that leaves the handler is a value: the path itself never
                // crosses an isolation boundary.
                self?.observe(
                    PathChange(
                        isSatisfied: path.status == .satisfied,
                        interfaceFingerprint: Self.fingerprint(of: path)
                    ),
                    into: continuation
                )
            }
            monitor.start(queue: queue)
            continuation.onTermination = { _ in monitor.cancel() }
        }
    }

    private func observe(
        _ change: PathChange,
        into continuation: AsyncStream<PathChange>.Continuation
    ) {
        let generation = state.withLock { (s: inout State) -> UInt64 in
            s.generation &+= 1
            s.pending = change
            if s.baseline == nil {
                s.baseline = change
            } else if change != s.baseline {
                s.sawDifference = true
            }
            return s.generation
        }

        // Only the last update of a burst survives: an older timer finds its generation
        // superseded and drops out.
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self else { return }
            let settled = self.state.withLock { (s: inout State) -> PathChange? in
                guard s.generation == generation, s.sawDifference, let pending = s.pending else {
                    return nil
                }
                s.sawDifference = false
                s.baseline = pending
                s.pending = nil
                return pending
            }
            if let settled {
                continuation.yield(settled)
            }
        }
    }

    /// Sorted, so the same network always reads the same way.
    private static func fingerprint(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { "\($0.type):\($0.name)" }
            .sorted()
        let gateways = path.gateways
            .map { String(describing: $0) }
            .sorted()
        return (interfaces + gateways).joined(separator: "|")
    }
}
