//
//  AboutView.swift
//  NDI WIRELESS
//
//  Created by Jeremie Aubut on 2026-09-10.
//
//  What the App Store requires the app itself to state: who made it, which version this
//  is, where the privacy policy and the licence agreement live, and the trademark and
//  third-party notices the NDI SDK licence obliges us to ship (§3g).
//

import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    /// Verbatim, and not to be reworded: Vizrt's licence specifies this sentence.
    private static let trademarkNotice = "NDI® is a registered trademark of Vizrt NDI AB."
    private static let copyrightNotice = "© 2026 Tech Lab Studio, Montréal"

    private static let summary = """
        Wireless NDI® monitor for on-set video village. Discovers NDI senders on your \
        local network, single view or multi-view grid, histogram, false colour, live \
        link stats.
        """

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Version", value: Self.versionAndBuild)
                } header: {
                    Text(Self.displayName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }

                Section {
                    Text(Self.summary)
                }

                Section {
                    Link("Privacy Policy", destination: Self.privacyPolicyURL)
                    Link("EULA", destination: Self.eulaURL)
                    Link("Support", destination: Self.supportURL)
                    NavigationLink("Third-party licences") {
                        ThirdPartyLicensesView()
                    }
                }

                Section {
                    Text(Self.trademarkNotice)
                    Text(Self.copyrightNotice)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("About")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Bundle

    /// The name on the Home screen, not the target name: the target is still called
    /// "NDI WIRELESS" and the app is called TLS Viewer.
    private static var displayName: String {
        let info = Bundle.main.infoDictionary
        let display = info?["CFBundleDisplayName"] as? String
        let name = info?["CFBundleName"] as? String
        return display ?? name ?? "TLS Viewer"
    }

    private static var versionAndBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    // MARK: - Links

    // Force-unwrapped deliberately: these are compile-time constants, and a typo should
    // fail on the first launch of a debug build rather than ship as a dead row.
    private static let privacyPolicyURL = URL(string: "https://tech-lab.studio/privacy-policy")!
    private static let eulaURL = URL(string: "https://tech-lab.studio/eula")!
    private static let supportURL = URL(string: "https://tech-lab.studio")!
}

/// The NDI SDK's own third-party notices, shipped verbatim.
///
/// Loaded from the bundle rather than pasted into source so the file stays byte-identical
/// to the one Vizrt distributes, and re-copying it on an SDK update is the whole change.
struct ThirdPartyLicensesView: View {
    private static let resourceName = "ThirdPartyLicenses"

    var body: some View {
        ScrollView {
            Text(Self.licenseText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Third-party licences")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private static var licenseText: String {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Never expected: the file is a bundle resource. Saying so beats an empty
            // screen where a legal notice is supposed to be.
            return "Third-party licence notices are missing from this build."
        }
        return text
    }
}

#Preview {
    AboutView()
}
