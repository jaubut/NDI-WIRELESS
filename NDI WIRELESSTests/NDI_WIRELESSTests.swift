//
//  NDI_WIRELESSTests.swift
//  NDI WIRELESSTests
//
//  Created by Jeremie Aubut on 2026-03-02.
//
//  The unit target is hosted by the app, so `Bundle.main` here is the app bundle: these
//  assert what actually shipped inside it, not what is sitting in the source tree.
//

import Foundation
import Testing

struct NDI_WIRELESSTests {

    /// Vizrt's licence (§3g) requires these notices to ship with anything built on the
    /// NDI SDK, and the About screen loads them by this exact name. A resource that
    /// quietly stops being copied would leave a legal notice reading as an empty screen.
    @Test func theThirdPartyNoticesAreInTheBundleAndReadable() throws {
        let url = try #require(
            Bundle.main.url(forResource: "ThirdPartyLicenses", withExtension: "txt")
        )
        let text = try String(contentsOf: url, encoding: .utf8)

        #expect(text.contains("Vizrt NDI AB"))
        #expect(text.count > 1_000)
    }

    /// App Store Connect rejects an upload whose manifest is missing or malformed, and
    /// the file only reaches the bundle by way of the synchronized folder — nothing in
    /// the project file names it, so nothing would complain if it stopped arriving.
    @Test func thePrivacyManifestIsInTheBundleAndDeclaresNoTrackingOrCollection() throws {
        let url = try #require(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let data = try Data(contentsOf: url)
        let manifest = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)

        // One declared reason: the uptime clock the frame-stats accumulator measures with.
        let accessed = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        #expect(accessed?.count == 1)
        #expect(
            accessed?.first?["NSPrivacyAccessedAPIType"] as? String
                == "NSPrivacyAccessedAPICategorySystemBootTime"
        )
        #expect(accessed?.first?["NSPrivacyAccessedAPITypeReasons"] as? [String] == ["35F9.1"])
    }

    /// Version and build are read straight out of the bundle by the About screen; these
    /// are the numbers App Store Connect matches an upload against.
    ///
    /// 1.0 (1) is already on the store, so neither number can be reused — an upload that
    /// repeats them is rejected. Pinning both here means a forgotten bump fails on the
    /// simulator rather than at the end of an archive-and-upload.
    @Test func theBundleCarriesTheShippingIdentityAndVersion() {
        let info = Bundle.main.infoDictionary
        #expect(info?["CFBundleDisplayName"] as? String == "TLS Viewer")
        #expect(info?["CFBundleIdentifier"] as? String == "TechLabStudio.NDI-WIRELESS")
        #expect(info?["CFBundleShortVersionString"] as? String == "1.1")
        #expect(info?["CFBundleVersion"] as? String == "2")
    }
}
