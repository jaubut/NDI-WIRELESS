//
//  NDISource.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-03-02.
//

import Foundation

nonisolated struct NDISource: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let ipAddress: String
}
