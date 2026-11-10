import AppKit

/// "Restart…" for a tunnel component that finishes installing at the next restart (row 1 `.rebootRequired`).
/// LockPlus doesn't restart the Mac itself (that needs Apple-event automation rights); it says how.
enum SystemRestart {
    @MainActor static func request() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart to finish installing", comment: "Restart alert title")
        alert.informativeText = String(localized: "Save your work, then choose Apple menu  › Restart. LockPlus can connect after the restart.", comment: "Restart alert message; the Apple logo character is the Apple menu")
        alert.addButton(withTitle: String(localized: "OK", comment: "Button"))
        alert.runModal()
    }
}
