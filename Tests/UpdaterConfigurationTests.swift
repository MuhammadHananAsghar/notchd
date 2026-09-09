// UpdaterConfigurationTests.swift
// This build ships with Sparkle configured: a feed on the project's GitHub
// releases and the public half of the maintainer's EdDSA keypair. These tests
// pin that configuration without starting Sparkle, which is the call that puts
// a modal on screen when something about it is wrong.

import XCTest
@testable import Notchd

@MainActor
final class UpdaterConfigurationTests: XCTestCase {
    /// Reads a trimmed Info.plist string from the app bundle.
    private func setting(_ key: String) -> String {
        (Bundle(for: Updater.self).object(forInfoDictionaryKey: key) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Both halves have to be present, or nothing installed could ever update.
    func testThisBuildHasAnUpdateFeedAndAKey() {
        XCTAssertTrue(Updater.isConfigured, "the feed or the key is missing from Info.plist")
    }

    /// GitHub resolves `releases/latest/download/` to the newest release, so
    /// the URL stays valid for as long as the repo does. Sparkle needs https.
    func testTheFeedIsTheLatestReleaseOnGitHub() throws {
        let url = try XCTUnwrap(URL(string: setting("SUFeedURL")))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasSuffix("/releases/latest/download/appcast.xml"), url.path)
    }

    /// An Ed25519 public key is 32 bytes.
    func testThePublicKeyIsAWellFormedEd25519Key() throws {
        let key = try XCTUnwrap(Data(base64Encoded: setting("SUPublicEDKey")))
        XCTAssertEqual(key.count, 32)
    }

    /// Checks and installs are on, so there is no first-launch prompt.
    func testChecksAndInstallsAreAutomatic() {
        let plist = Bundle(for: Updater.self).infoDictionary ?? [:]
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, true)
    }

    /// A configured build starts idle rather than announcing a problem.
    func testAConfiguredBuildStartsIdle() {
        XCTAssertEqual(Updater().outcome, .idle)
    }

    /// The unconfigured message still says plainly what is missing.
    func testTheUnconfiguredStateStillExplainsItself() throws {
        let message = try XCTUnwrap(Updater.Outcome.notConfigured.message)
        XCTAssertTrue(message.contains("not set up"))
    }

    /// The menu bar item is a menu bar item: no Dock tile.
    func testTheAppIsAMenuBarAgent() {
        let plist = Bundle(for: Updater.self).infoDictionary ?? [:]
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
    }
}
