//
//  LocalNetworkAccess.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-10-04.
//
//  iOS has no API that answers "is local network access allowed?". The documented tell is
//  a Bonjour browse: while the user has the app switched off under Settings › Privacy ›
//  Local Network, the browser sits in `.waiting` with a DNS policy-denied error. The NDI
//  SDK's own finder just reports nothing, which looks exactly like an empty network.
//
//  `Network` only, and nonisolated: `NWBrowser` calls back on its own queue and the module
//  defaults to MainActor.
//

import Foundation
import Network

nonisolated enum LocalNetworkAccess {
    /// `kDNSServiceErr_PolicyDenied` from dns_sd.h.
    static let policyDeniedCode: Int32 = -65570

    /// `true` while the OS refuses local network access, `false` once a browse succeeds.
    ///
    /// Browses the same service NDI advertises (`_ndi._tcp`, already declared in
    /// `NSBonjourServices`), so this asks for nothing the app does not already ask for.
    /// The stream finishes if the browser fails and cancels its browser on termination.
    static func deniedUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let browser = NWBrowser(for: .bonjour(type: "_ndi._tcp", domain: nil), using: .tcp)
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error):
                    continuation.yield(isPolicyDenied(error))
                case .failed(let error):
                    // Fatal for this browser: report, then end the stream so the caller
                    // can start a fresh one instead of holding a dead watch.
                    continuation.yield(isPolicyDenied(error))
                    continuation.finish()
                case .ready:
                    continuation.yield(false)
                default:
                    break
                }
            }
            browser.start(queue: DispatchQueue(label: "studio.techlab.ndi-wireless.local-network"))
            continuation.onTermination = { _ in browser.cancel() }
        }
    }

    static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == policyDeniedCode }
        return false
    }
}
