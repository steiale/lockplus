import AppKit
import Foundation
import LPModel
import os
import UserNotifications

/// What the app tells the user about while no LockPlus window is key (DESIGN §11.7, UI-CONCEPT §6.5, §6.13).
enum ConnectionNotice: Sendable, Equatable {
    case connected(UUID)
    case disconnectedByUser(UUID)
    /// Protection stopped without the user asking (an observed disconnect with an error, or a session that ended).
    case stoppedUnexpectedly(UUID)
    /// A sign-in the user must give (inside a connect, AUTH_PENDING, a reconnect code).
    case needsSignIn(UUID, reconnect: Bool)
    /// PF 53: protected again after the tunnel process crashed and was restarted (by macOS or by LockPlus).
    case reconnectedAfterRestart(UUID)

    var profileID: UUID {
        switch self {
        case .connected(let id), .disconnectedByUser(let id), .stoppedUnexpectedly(let id), .needsSignIn(let id, _),
             .reconnectedAfterRestart(let id): id
        }
    }

    var isProblem: Bool {
        switch self {
        case .stoppedUnexpectedly, .needsSignIn: true
        case .connected, .disconnectedByUser, .reconnectedAfterRestart: false
        }
    }
}

/// A notification as posted: the profile name only, never a challenge, server text or user name (§8.4, F-9), and no
/// text-input action.
struct UserNotice: Sendable, Equatable {
    var id: String
    var title: String
    var body: String
}

enum NotificationAuthorization: Sendable, Equatable { case notDetermined, authorized, denied }

/// Pure rules (tested): which notice is posted in which mode, and its wording.
enum NotificationPolicy {
    static func shouldPost(_ n: ConnectionNotice, mode: AppSettings.Notifications, anyWindowKey: Bool) -> Bool {
        guard !anyWindowKey else { return false }
        switch mode {
        case .off: return false
        case .problemsOnly: return n.isProblem
        case .connectDisconnect: return true
        }
    }

    static func notice(_ n: ConnectionNotice, profileName name: String) -> UserNotice {
        let id = "lp.\(n.profileID.uuidString)"
        return switch n {
        case .connected:
            UserNotice(id: id, title: String(localized: "Protected", comment: "Notification title"),
                       body: String(localized: "Connected to \(name).", comment: "Notification body; profile name"))
        case .disconnectedByUser:
            UserNotice(id: id, title: String(localized: "Not protected", comment: "Notification title"),
                       body: String(localized: "Disconnected from \(name).", comment: "Notification body; profile name"))
        case .reconnectedAfterRestart:
            UserNotice(id: id, title: String(localized: "Protected", comment: "Notification title"),
                       body: String(localized: "Reconnected to \(name) after a tunnel process restart.", comment: "Notification body (PF 53); profile name"))
        case .stoppedUnexpectedly:
            UserNotice(id: id, title: String(localized: "Protection stopped", comment: "Notification title"),
                       body: String(localized: "\(name) disconnected unexpectedly.", comment: "Notification body; profile name"))
        case .needsSignIn(_, let reconnect):
            UserNotice(id: id + ".auth",
                       title: reconnect ? String(localized: "\(name) needs a new one-time code", comment: "Notification title; profile name")
                                        : String(localized: "\(name) needs sign-in", comment: "Notification title; profile name"),
                       body: String(localized: "Click to open LockPlus.", comment: "Notification body"))
        }
    }
}

/// `UNUserNotificationCenter` (live). Clicking a notification is a user gesture: it opens the main window, whose
/// sheet shows a pending prompt (§8.4: credential UI never appears without a gesture).
@MainActor final class UserNotificationCenterBridge: NSObject, UNUserNotificationCenterDelegate {
    var onActivate: (@MainActor () -> Void)?
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "ui")

    func install() { UNUserNotificationCenter.current().delegate = self }

    func authorization() async -> NotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .authorized
        }
    }

    func requestAuthorization() async {
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) } catch {
            log.notice("notification authorization: \((error as NSError).code, privacy: .public)")
        }
    }

    func post(_ n: UserNotice) {
        let c = UNMutableNotificationContent()
        c.title = n.title
        c.body = n.body
        c.sound = nil
        let request = UNNotificationRequest(identifier: n.id, content: c, trigger: nil)   // same id replaces
        UNUserNotificationCenter.current().add(request) { @Sendable error in
            if let error { Logger(subsystem: "io.github.steiale.lockplus.mac", category: "ui").notice("notification: \((error as NSError).code, privacy: .public)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { onActivate?() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list] }
}
