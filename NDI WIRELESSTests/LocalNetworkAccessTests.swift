//
//  LocalNetworkAccessTests.swift
//  NDI WIRELESSTests
//
//  Created by Jeremie Aubut on 2026-10-04.
//

import Network
import Testing
@testable import NDI_WIRELESS

struct LocalNetworkAccessTests {
    @Test func onlyThePolicyDeniedDNSErrorCountsAsDenied() {
        #expect(LocalNetworkAccess.isPolicyDenied(.dns(LocalNetworkAccess.policyDeniedCode)))
        // kDNSServiceErr_NoSuchRecord: a real DNS failure, not a permission one.
        #expect(!LocalNetworkAccess.isPolicyDenied(.dns(-65554)))
        #expect(!LocalNetworkAccess.isPolicyDenied(.posix(.ECONNREFUSED)))
    }
}
