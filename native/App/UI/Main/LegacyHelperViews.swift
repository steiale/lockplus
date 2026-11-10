import SwiftUI

/// §4.5 old (Go) LockPlus helper surfaces above the detail (UI-CONCEPT §6.15).

/// A Connect the old-helper rule stopped (refused, or warned about). A strip, not an alert sheet: the sheet blocked
/// Quit, AppleScript `quit` included (E2E-5 F8). Every button ends it; a new Connect replaces it.
struct ConnectGateStrip: View {
    @Environment(UIEnvironment.self) private var env
    let gate: ConnectGateRequest

    var body: some View {
        strip
            // Review LOW: Escape dismisses the strip only while focus is in it (a `.cancelAction` shortcut took Escape
            // for the whole main window).
            .onExitCommand { Self.dismiss(env) }
            // Review LOW: announced on every new gate, not only when the strip appears (`.refused(A)` → `.refused(B)`).
            .onChange(of: gate, initial: true) { announce(Self.announcement(gate)) }
    }

    @ViewBuilder private var strip: some View {
        let notice = env.connection.legacyHelper
        switch gate {
        case .refused:
            // Also set by AppActions.connect after its own re-read, possibly before the notice is updated.
            let message = notice.flatMap { $0.blocksConnect ? $0.message : nil } ?? LegacyHelperCopy.refuseFallback
            InlineStrip(severity: .critical, message: LegacyHelperCopy.titled(LegacyHelperCopy.refuseTitle, message)) {
                if notice?.oldAppInstalled == true {
                    Button(LegacyHelperCopy.openOldApp) { Self.openOldApp(env) }
                }
                Button(String(localized: "OK", comment: "Button")) { Self.dismiss(env) }
            }
        case .warn(let id):
            // The crashed-helper message already says what happened ("… may have left its firewall on …"): no title.
            InlineStrip(severity: .attention, message: notice?.message ?? LegacyHelperCopy.warnTitle) {
                Button(String(localized: "Cancel", comment: "Button")) { Self.dismiss(env) }
                Button(LegacyHelperCopy.connectAnyway) { Self.connectAnyway(id, env) }
            }
        }
    }

    static func announcement(_ gate: ConnectGateRequest) -> String {
        switch gate {
        case .refused: LegacyHelperCopy.refuseTitle
        case .warn: LegacyHelperCopy.warnTitle
        }
    }

    /// "Open the old LockPlus" ends the refusal too (E2E-5 F8: the alert used to stay open).
    static func openOldApp(_ env: UIEnvironment) {
        env.connection.connectGate = nil
        env.actions.openOldLockPlus()
    }

    static func dismiss(_ env: UIEnvironment) { env.connection.connectGate = nil }

    static func connectAnyway(_ id: ProfileItem.ID, _ env: UIEnvironment) {
        env.connection.connectGate = nil
        env.actions.connectAnyway(id)
    }

    /// The strip replaces an alert, so VoiceOver hears it the way it would have heard the alert.
    private func announce(_ text: String) { AccessibilityNotification.Announcement(text).post() }
}

/// The persistent §4.5 banner while the old helper (or its leftovers) is present, and "Remove Old Helper" (E2E-5 F1):
/// removing, removed, cancelled, failed with the reason.
struct LegacyHelperBanner: View {
    @Environment(UIEnvironment.self) private var env

    var body: some View {
        let c = env.connection
        if let removal = c.legacyHelperRemoval {
            removalStrip(removal, helperStillThere: c.legacyHelper?.canRemoveHelper == true)
        } else if let notice = c.legacyHelper {
            InlineStrip(severity: notice.blocksConnect ? .critical : .attention, message: notice.message) {
                if notice.canRemoveHelper {
                    Button(LegacyHelperCopy.removeHelper) { env.actions.removeOldHelper() }
                }
                // E2E-5 F8: only when there is an old app to open (after a Finder Replace there isn't).
                if notice.oldAppInstalled && (notice.blocksConnect || notice.warnsBeforeConnect) {
                    Button(LegacyHelperCopy.openOldApp) { env.actions.openOldLockPlus() }
                }
            }
        }
    }

    @ViewBuilder private func removalStrip(_ r: LegacyHelperRemovalState, helperStillThere: Bool) -> some View {
        switch r {
        case .removing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(LegacyHelperCopy.removing).foregroundStyle(StripSeverity.info.textColor)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(StripSeverity.info.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
        case .removed(let left, let stale):
            InlineStrip(severity: left || stale ? .attention : .info, message: LegacyHelperCopy.removed(leftNetworkState: left, staleTunnel: stale)) {
                Button(String(localized: "OK", comment: "Button")) { env.actions.dismissOldHelperRemoval() }
            }
            .onAppear { AccessibilityNotification.Announcement(LegacyHelperCopy.removed(leftNetworkState: left, staleTunnel: stale)).post() }
        case .cancelled, .failed:
            InlineStrip(severity: r == .cancelled ? .attention : .critical,
                        message: LegacyHelperCopy.removalProblem(r, oldAppInstalled: env.connection.legacyHelper?.oldAppInstalled == true)) {
                Button(String(localized: "OK", comment: "Button")) { env.actions.dismissOldHelperRemoval() }
                if helperStillThere {
                    Button(String(localized: "Try Again", comment: "Button")) { env.actions.removeOldHelper() }
                }
            }
        }
    }
}

/// Migration matrix: the update to LockPlus put it next to the old WireGuide+ app, whose login item and helper kept
/// it alive. Offered for the Trash after a confirmation; never while it runs.
struct OldAppTrashBanner: View {
    @Environment(UIEnvironment.self) private var env
    @State private var confirm = false

    var body: some View {
        let c = env.connection
        let running = c.oldWireGuidePlusApp?.running == true
        InlineStrip(severity: .info, message: running ? LegacyHelperCopy.oldAppRunning
                                                      : (c.oldAppTrashFailed ? LegacyHelperCopy.oldAppTrashFailed : LegacyHelperCopy.oldAppInstalled)) {
            Button(String(localized: "Not Now", comment: "Button")) { c.oldAppOfferDismissed = true }
            if !running {
                Button(LegacyHelperCopy.moveOldAppToTrash) { confirm = true }
            }
        }
        .confirmationDialog(Text("Move WireGuide+ to the Trash?", comment: "Confirmation: the old WireGuide+ app (migration matrix)"), isPresented: $confirm) {
            Button(String(localized: "Move to Trash", comment: "Button, confirmation (migration matrix)")) { env.actions.trashOldWireGuidePlusApp() }
        } message: {
            Text("LockPlus replaces it. You can put it back from the Trash.", comment: "Confirmation message (migration matrix)")
        }
    }
}

extension LegacyHelperCopy {
    static var oldAppInstalled: String {
        String(localized: "WireGuide+, the old version of LockPlus, is still installed. LockPlus replaces it.", comment: "Banner: the old WireGuide+ app is still installed (migration matrix)")
    }
    static var oldAppRunning: String {
        String(localized: "WireGuide+, the old version of LockPlus, is still running. Quit it, then you can move it to the Trash.", comment: "Banner: the old WireGuide+ app runs (migration matrix)")
    }
    static var oldAppTrashFailed: String {
        String(localized: "WireGuide+ couldn't be moved to the Trash. Drag it from Applications to the Trash yourself.", comment: "Banner: moving the old app failed (migration matrix)")
    }
    static var moveOldAppToTrash: String { String(localized: "Move to Trash…", comment: "Button, banner: the old WireGuide+ app (migration matrix)") }

    static var removeHelper: String { String(localized: "Remove Old Helper…", comment: "Button, §4.5 banner (E2E-5 F1); macOS asks for an administrator password") }
    static var removing: String { String(localized: "Removing the old LockPlus helper…", comment: "§4.5 banner while the removal runs (E2E-5 F1)") }

    /// `leftNetworkState` wins: its copy already ends with the restart that also clears a crashed tunnel's routes.
    static func removed(leftNetworkState: Bool, staleTunnel: Bool = false) -> String {
        if leftNetworkState {
            String(localized: "The old LockPlus helper was removed, but it left network settings behind. If websites don't load, set DNS back to Automatic in System Settings › Network, then restart your Mac.", comment: "§4.5 removal result (review E2E-5 F1-2: a restart clears pf, not DNS)")
        } else if staleTunnel {
            String(localized: "The old LockPlus helper was removed. Its last connection ended in a crash and left network routes behind: if LockPlus can't connect to a server, restart your Mac.", comment: "§4.5 removal result: the old helper had crashed with a tunnel up, its endpoint routes stay until a restart (E2E-7 F3)")
        } else {
            String(localized: "The old LockPlus helper was removed.", comment: "§4.5 removal result (E2E-5 F1)")
        }
    }

    /// Cancelled or failed, with what happened and what to do.
    /// `oldAppInstalled`: "Open the old LockPlus" is offered only when there is one to open (E2E-6 N1).
    static func removalProblem(_ r: LegacyHelperRemovalState, oldAppInstalled: Bool = false) -> String {
        switch r {
        case .cancelled:
            String(localized: "The old helper wasn't removed because the administrator password was cancelled. It is still installed.", comment: "§4.5 removal cancelled (E2E-5 F1)")
        case .failed(.busy):
            String(localized: "The old LockPlus is still connected or its kill switch is on, so its helper wasn't removed. Disconnect in the old LockPlus first, or restart your Mac, then try again. If you also use WireGuide, its kill switch counts too: turn it off for the removal.", comment: "§4.5 removal refused (E2E-5 F1; migration matrix: the pf anchor is shared with upstream WireGuide)")
        case .failed(.busyWhileConnected):
            String(localized: "The old LockPlus still seems to be connected, so its helper wasn't removed. Disconnect LockPlus and try again: its connection can look like one of the old LockPlus. If that doesn't help, disconnect in the old LockPlus or restart your Mac.", comment: "§4.5 removal refused by root while LockPlus itself is connected (E2E-7 F3: its utun can reuse a crashed old tunnel's number)")
        case .failed(.oldAppRunning):
            String(localized: "Quit the old LockPlus first, then remove its helper. While it runs, it would install the helper again.", comment: "§4.5 removal refused while the Go app runs (review E2E-5 F1-1)")
        case .failed(.dnsNotRestored) where oldAppInstalled:
            String(localized: "The old LockPlus helper isn't running, and the DNS settings it changed may still be active. Open the old LockPlus once so its helper restores DNS, or set DNS back to Automatic in System Settings › Network and try again, or restart your Mac.", comment: "§4.5 removal refused: un-replayed DNS journal, the old app is installed (E2E-6 N1)")
        case .failed(.dnsNotRestored):
            String(localized: "The old LockPlus helper isn't running, and the DNS settings it changed may still be active. Set DNS back to Automatic in System Settings › Network and try again, or restart your Mac.", comment: "§4.5 removal refused: un-replayed DNS journal, no old app to open (E2E-6 N1)")
        case .failed(.dnsRestartRestores):
            String(localized: "Restart your Mac — the old helper then restores your DNS settings — then remove it.", comment: "§4.5 removal refused: the journal holds the user's own DNS servers (review 650b251)")
        case .failed(.notResponding):
            String(localized: "The old helper isn't responding. Restart your Mac, then remove it.", comment: "§4.5 removal refused: the helper's socket doesn't answer (Fable follow-up LOW-3)")
        case .failed(.dnsProtectionLeft):
            String(localized: "The old LockPlus left its DNS protection on. Restart your Mac to clear it, then remove the helper.", comment: "§4.5 removal refused: only 1.0.x's port-53 pf rules are left (E2E-6 N2)")
        case .failed(.notTheOldHelper):
            String(localized: "The installed helper doesn't match the old LockPlus helper, so LockPlus didn't change anything.", comment: "§4.5 removal refused: unexpected files (E2E-5 F1)")
        case .failed(.incomplete):
            String(localized: "The old helper couldn't be removed completely. Restart your Mac and try again.", comment: "§4.5 removal incomplete (E2E-5 F1)")
        case .failed(.couldNotRun(let detail)):
            String(localized: "The old helper couldn't be removed: \(detail)", comment: "§4.5 removal failed; the argument is the system's message (E2E-5 F1)")
        case .removing, .removed:
            ""
        }
    }

    /// Title and message in one strip line ("The old LockPlus is still protecting this Mac. Disconnect in …").
    static func titled(_ title: String, _ message: String) -> String {
        message.isEmpty ? title : String(localized: "\(title). \(message)", comment: "§4.5 strip: a title, then its message")
    }
}

#Preview("Gate — refused") {
    let env = UIEnvironment.preview(row: "15")
    env.connection.legacyHelper = PreviewData.legacyRefuse
    env.connection.connectGate = .refused(PreviewData.workID)
    return VStack { WindowBanners(); Spacer() }.environment(env).frame(width: 680, height: 140)
}
