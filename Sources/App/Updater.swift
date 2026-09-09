// Updater.swift
// Keeps the app up to date on its own through Sparkle. Silent by design: the
// Info.plist turns automatic checks and installs on, so there is no first-launch
// permission prompt. The outcome of the last check is kept in words so the one
// place a user looks for it can say what actually happened rather than
// Sparkle's generic error.

import Foundation
import Sparkle

/// The self-updater.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// What the last check came to.
    enum Outcome: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case found(String)
        case unreachable
        case failed(String)
        /// This build has no update feed and no key to verify one with, so
        /// Sparkle was never started.
        case notConfigured

        /// The sentence to show for this outcome, or nil while idle.
        var message: String? {
            switch self {
            case .idle: return nil
            case .checking: return "Checking…"
            case .upToDate: return "Notchd is up to date."
            case .found(let version): return "Version \(version) is available and will install shortly."
            case .unreachable:
                return "Couldn't reach the update server. Notchd will try again on its own; nothing is wrong with this copy."
            case .failed(let why): return why
            case .notConfigured:
                return "Automatic updates are not set up for this build. It has no update feed and no signing key, "
                    + "so nothing can be installed and nothing is being checked."
            }
        }
    }

    /// Seeded from the configuration so the unconfigured state is true from the
    /// moment the object exists.
    @Published private(set) var outcome: Outcome = Updater.isConfigured ? .idle : .notConfigured

    /// Whether this build can update itself. Sparkle refuses to start without a
    /// feed URL and a well-formed public key, and starting it anyway shows a
    /// modal the user can do nothing about, so the check happens here first.
    static var isConfigured: Bool {
        func setting(_ key: String) -> String {
            (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return !setting("SUFeedURL").isEmpty && !setting("SUPublicEDKey").isEmpty
    }

    /// Nil when this build has nothing to update from.
    private lazy var controller: SPUStandardUpdaterController? = {
        guard Self.isConfigured else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }()

    /// Whether scheduled checks and installs are on.
    var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// The marketing version of this build.
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// When Sparkle last checked.
    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    /// Starts the scheduled checks. Touching the lazy controller is what starts
    /// Sparkle; the delegate has to exist first, which is why this is a method
    /// rather than part of `init`.
    func start() {
        guard controller != nil else {
            outcome = .notConfigured
            Log.updates.notice("updates disabled: no feed or public key in Info.plist")
            return
        }
    }

    /// A manual check. This one shows Sparkle's UI because it was asked for.
    func checkNow() {
        guard let controller else {
            outcome = .notConfigured
            return
        }
        outcome = .checking
        controller.updater.checkForUpdates()
    }

    /// Records that the feed had nothing newer.
    /// - Parameter updater: The Sparkle updater.
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.outcome = .upToDate(Date()) }
    }

    /// Records the version Sparkle is about to install.
    /// - Parameters:
    ///   - updater: The Sparkle updater.
    ///   - item: The appcast entry found.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.outcome = .found(version) }
    }

    /// Classifies a failed check as unreachable or as itself.
    /// - Parameters:
    ///   - updater: The Sparkle updater.
    ///   - error: What went wrong.
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        let description = error.localizedDescription
        Task { @MainActor in
            self.outcome = Self.isUnreachable(code) ? .unreachable : .failed(description)
        }
    }

    /// Sparkle folds every "could not load the feed" case into one code.
    /// - Parameter code: An `SUError` raw value.
    /// - Returns: True when the feed itself could not be fetched.
    static func isUnreachable(_ code: Int) -> Bool {
        code == Int(SUError.appcastError.rawValue)
    }
}
