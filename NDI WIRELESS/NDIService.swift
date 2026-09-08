//
//  NDIService.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import CoreGraphics
import Foundation

protocol NDIService: AnyObject {
    /// Discover sources on the network. Yields updated source lists over time.
    func discoverSources() -> AsyncStream<[NDISource]>

    /// Start receiving video frames from a source.
    func startReceiving(from source: NDISource) -> AsyncStream<CGImage>

    /// Stop receiving from a source.
    func stopReceiving(from source: NDISource)

    /// Stop all receivers and discovery.
    func stopAll()
}
