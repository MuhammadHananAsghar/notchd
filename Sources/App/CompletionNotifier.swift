// CompletionNotifier.swift
// Tells the user when an agent finishes a turn: a macOS notification with no
// sound, a moment of life in the notch showing the agent's mark, and one
// tap on the trackpad. A bare chat reply with no tool calls counts only
// while the plain-replies switch is on. Clicking the notification opens the
// session in the timeline.

import AppKit
import UserNotifications

/// Posts notifications and notch celebrations for finished turns.
@MainActor
final class CompletionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let ledger: Ledger
    private let preferences: Preferences
    private let notch: NotchViewModel
    private let openSession: (Int64) -> Void
    private var lastNoticed: [Int64: Date] = [:]
    private var authorised = false

    /// Two done markers within this span for one session count as one.
    static let debounce: TimeInterval = 5

    /// Creates the notifier.
    /// - Parameters:
    ///   - ledger: The ledger to summarise from.
    ///   - preferences: The switches.
    ///   - notch: The notch to animate.
    ///   - openSession: Opens a session's page, for a clicked notification.
    init(ledger: Ledger, preferences: Preferences, notch: NotchViewModel, openSession: @escaping (Int64) -> Void) {
        self.ledger = ledger
        self.preferences = preferences
        self.notch = notch
        self.openSession = openSession
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks for permission once, quietly.
    func prepare() {
        guard preferences.notifyOnDone else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorised = granted }
        }
    }

    /// Looks at newly recorded rows for finished turns.
    /// - Parameter rows: The rows just written.
    func handle(_ rows: [EventRow]) {
        for row in rows where TurnCompletion.isDone(row) {
            notice(row)
        }
    }

    /// Notifies about one finished turn, if it is worth it and not a repeat.
    private func notice(_ done: EventRow) {
        if let last = lastNoticed[done.sessionId], done.ts.timeIntervalSince(last) < Self.debounce { return }
        guard let summary = try? TurnCompletion.summary(for: done, in: ledger) else { return }
        guard summary.isWorthNoticing || preferences.noticeChatReplies else { return }
        lastNoticed[done.sessionId] = done.ts
        if preferences.celebrateInNotch {
            notch.celebrate(NotchCelebration(sessionId: summary.sessionId, vendor: summary.vendor, title: summary.title, detail: summary.marks))
        }
        if preferences.hapticOnDone { Haptics.tap() }
        if preferences.notifyOnDone { post(summary) }
    }

    /// Posts the notification.
    private func post(_ summary: TurnSummary) {
        let content = UNMutableNotificationContent()
        content.title = "\(VendorNames.display(summary.vendor)) finished in \(summary.project)"
        content.body = summary.sentence
        content.sound = nil
        content.userInfo = ["sessionId": summary.sessionId]
        let request = UNNotificationRequest(identifier: "turn-\(summary.sessionId)-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.app.error("notification failed: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Shows the banner even while Notchd is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    /// Opens the session a clicked notification names.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["sessionId"] as? Int64
            ?? (response.notification.request.content.userInfo["sessionId"] as? Int).map(Int64.init)
        Task { @MainActor in
            if let id { self.openSession(id) }
            completionHandler()
        }
    }
}
