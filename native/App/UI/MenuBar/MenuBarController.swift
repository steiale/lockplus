import AppKit
import Observation
import SwiftUI

/// The status item and its native `NSMenu` (UI-CONCEPT §6.1–§6.2, DESIGN §11.3; validated in spike S15 on 27).
/// - The header `NSHostingView` is created once and reused, with its DEFAULT sizing options (S15: `[]` zeroes
///   `fittingSize`); width `MenuHeaderView.width`, height = `fittingSize.height` re-applied after each update.
/// - It re-renders through Observation alone (`withObservationTracking`, re-armed in a main-actor task) while the
///   menu is open. No state timer. The only `Timer` here is the ~120 ms frame clock of the connecting animation.
/// - Standard items are rebuilt in `menuNeedsUpdate`; every header action also exists as a standard item.
@MainActor final class MenuBarController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let headerItem = NSMenuItem()
    private let header = MenuHeaderModel()
    private let headerHost: NSHostingView<MenuHeaderView>
    private let env: UIEnvironment

    private var headerObserving = false
    private(set) var menuIsOpen = false
    private var frameTimer: Timer?
    private var frameIndex = 0
    private var lastRow: String?
    private var lastAccessibilityLabel = ""
    private var lastAccessibilityUpdate = Date.distantPast
    private var pendingAccessibilityLabel: Task<Void, Never>?
    private var visibilityObservation: NSKeyValueObservation?
    private var displayOptionsObserver: NSObjectProtocol?

    /// Called with `true` in `menuWillOpen` and `false` in `menuDidClose`: the app registers the menu as a stats
    /// consumer (1 Hz polling only while someone looks, §7.4) and records `menuOpenedLaunches` (§6.1).
    var onMenuVisibilityChange: (Bool) -> Void = { _ in }

    private static let menuProfileLimit = 8
    private static let statusPointSize: CGFloat = 15
    private static let menuGlyphPointSize: CGFloat = 13

    init(env: UIEnvironment) {
        self.env = env
        headerHost = NSHostingView(rootView: MenuHeaderView(model: header))
        headerHost.setAccessibilityElement(false)        // VoiceOver uses the duplicated standard items (§6.2)
        super.init()
        item.behavior = .removalAllowed                   // we offer the way back: Settings › Menu Bar
        item.autosaveName = "LockPlusStatusItem"          // stable forever
        item.button?.imagePosition = .imageLeading
        menu.delegate = self
        menu.autoenablesItems = false
        headerItem.view = headerHost
        item.menu = menu
        header.onToggle = { [weak self] on in self?.headerToggled(on) }
        StatusItemLocation.controller = self             // onboarding callout (§6.14)

        // Cmd-drag removal sets isVisible = false (KVO); mirror it into Settings › Menu Bar.
        visibilityObservation = item.observe(\.isVisible, options: [.new]) { [weak self] statusItem, _ in
            let visible = statusItem.isVisible
            MainActor.assumeIsolated {             // SAFETY: NSStatusItem KVO fires on the main thread
                if self?.env.settings.showInMenuBar != visible { self?.env.settings.showInMenuBar = visible }
            }
        }
        // Reduce Motion can change at any time; the frame sequence must stop.
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderStatusItem() }    // SAFETY: queue .main
        }
        header.refresh(from: env)
        resizeHeader()
        observeStatusItem()
        observeConnectGate()
    }

    isolated deinit {
        frameTimer?.invalidate()
        if let displayOptionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver) }
    }

    /// Called from `applicationWillTerminate` (L-MB-1).
    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    // MARK: - Status item

    /// The status item follows the environment all the time (it's always visible), through Observation.
    private func observeStatusItem() {
        withObservationTracking {
            renderStatusItem()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatusItem() }
        }
    }

    /// §4.5: `AppActions.connect` re-reads the old helper and may refuse after the UI's gate let a connect through
    /// (menu, auto-connect). The refuse dialog lives in the main window, so a refusal opens it when it isn't showing.
    private func observeConnectGate() {
        let gate = withObservationTracking { env.connection.connectGate } onChange: { [weak self] in
            Task { @MainActor in self?.observeConnectGate() }
        }
        if gate != nil, !Self.mainWindowVisible { env.actions.openMainWindow() }
    }

    static var mainWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && ($0.identifier?.rawValue.hasPrefix("main") ?? false) }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func renderStatusItem() {
        let condition = env.connection.condition
        let settings = env.settings
        // Both directions (UI-H2): the setting hides and shows the item; Cmd-drag removal flows back through KVO.
        if item.isVisible != settings.showInMenuBar { item.isVisible = settings.showInMenuBar }

        let mode = settings.rateLabel
        let showsLabel = condition.showsRateLabel && mode != .off
        // Glyph, or the 3-frame connecting sequence (§6.1).
        let animate = condition.glyph == .connecting && !reduceMotion && settings.iconStyle == .monochrome
        if animate {
            // Disconnecting runs the sequence backwards: the shackle lifts (UI-L24).
            startFrames(reversed: condition == .disconnecting)
        } else {
            stopFrames()
            item.button?.image = statusImage(condition.glyph, style: settings.iconStyle, withLabel: showsLabel)
        }

        // Rate label: only while connected, hidden while blocked; fixed width so it never jitters.
        if showsLabel {
            let rate = env.stats.current ?? Rate(down: 0, up: 0)
            let text = mode == .both
                ? "↓\(RateFormat.compactFixed(rate.down)) ↑\(RateFormat.compactFixed(rate.up))"
                : "↓\(RateFormat.compactFixed(rate.down))"
            item.button?.attributedTitle = NSAttributedString(string: text, attributes: Self.labelAttributes)
            item.length = fixedLength(for: mode, style: settings.iconStyle)
        } else {
            item.button?.attributedTitle = NSAttributedString(string: "")
            item.length = NSStatusItem.variableLength
        }

        updateAccessibilityLabel(condition.statusItemAccessibilityLabel(for: env.conditionContext,
                                                                         rate: condition.showsRateLabel ? env.stats.current : nil))
        announceIfNeeded(condition)
    }

    /// The button puts about 1.5 pt between its image and the rates; the monochrome canvas has spare room on its right, the
    /// tile has none, so the tile gets 3 pt of transparent space for a 4.5 pt gap. The icon drawing itself is untouched.
    static let tileLabelGap: CGFloat = 3
    /// The button's own space between image and title (measured, about 1.5 pt); the Settings preview copies the gap.
    static let buttonImageTitleGap: CGFloat = 1.5

    private func statusImage(_ glyph: GlyphState, style: IconStyle, withLabel: Bool) -> NSImage? {
        switch style {
        case .monochrome: return LockGlyphImage.statusTemplate(glyph, pointSize: Self.statusPointSize)
        case .color:
            guard let tile = LockGlyphImage.colorTile(glyph, pointSize: Self.statusPointSize - 2) else { return nil }
            guard withLabel else { return tile }
            let padded = NSImage(size: NSSize(width: tile.size.width + Self.tileLabelGap, height: tile.size.height), flipped: false) { _ in
                tile.draw(in: NSRect(origin: .zero, size: tile.size))
                return true
            }
            padded.isTemplate = false
            return padded
        }
    }

    static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: LPTypography.nsFont(size: NSFont.smallSystemFontSize),
        .baselineOffset: 0.5,
    ]
    private var measuredLengths: [String: CGFloat] = [:]

    /// The widest label for this locale, measured once per mode and icon style (§6.1): about 76 pt, out of the notch
    /// zone. The image is the one the style shows with a label (pre-release review LOW: the colour tile, with its gap,
    /// was measured as the monochrome glyph).
    private func fixedLength(for mode: RateLabelMode, style: IconStyle) -> CGFloat {
        let key = "\(mode.rawValue)-\(style.rawValue)"
        if let l = measuredLengths[key] { return l }
        let w = RateFormat.widestCompact()
        let text = mode == .both ? "↓\(w) ↑\(w)" : "↓\(w)"
        let labelWidth = ceil(NSAttributedString(string: text, attributes: Self.labelAttributes).size().width)
        let glyphWidth = statusImage(.protected, style: style, withLabel: true)?.size.width ?? 18
        let length = glyphWidth + labelWidth + 12
        measuredLengths[key] = length
        return length
    }

    private var framesReversed = false
    private func startFrames(reversed: Bool) {
        if frameTimer != nil, framesReversed == reversed { return }
        stopFrames()
        framesReversed = reversed
        frameIndex = 0
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {             // SAFETY: main run loop timer
                guard let self else { return }
                let names = self.framesReversed ? GlyphState.connectingFrames.reversed() : GlyphState.connectingFrames
                self.item.button?.image = LockGlyphImage.statusTemplate(names[self.frameIndex % names.count], pointSize: Self.statusPointSize)
                self.frameIndex += 1
            }
        }
        RunLoop.main.add(t, forMode: .common)           // keeps animating while the menu tracks
        frameTimer = t
    }

    private func stopFrames() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    /// Refreshed at most once a second and only on change (DESIGN §11.6).
    private func updateAccessibilityLabel(_ label: String) {
        guard label != lastAccessibilityLabel else { return }
        let wait = 1 - Date().timeIntervalSince(lastAccessibilityUpdate)
        pendingAccessibilityLabel?.cancel()
        if wait <= 0 {
            applyAccessibilityLabel(label)
        } else {
            pendingAccessibilityLabel = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.applyAccessibilityLabel(label)
            }
        }
    }

    private func applyAccessibilityLabel(_ label: String) {
        item.button?.setAccessibilityLabel(label)
        lastAccessibilityLabel = label
        lastAccessibilityUpdate = Date()
    }

    /// One announcement when a state is entered; high priority for Blocked and auth (§6.6, §8.2).
    private func announceIfNeeded(_ condition: ConnectionCondition) {
        defer { lastRow = condition.row }
        guard let previous = lastRow, previous != condition.row,
              let text = condition.announcement(for: env.conditionContext) else { return }
        let priority: NSAccessibilityPriorityLevel = condition.announcesWithHighPriority ? .high : .medium
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        header.refresh(from: env)
        resizeHeader()
        rebuildStandardItems()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        onMenuVisibilityChange(true)
        observeHeader()
        startCountdownTick()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        onMenuVisibilityChange(false)
        countdownTask?.cancel()
        countdownTask = nil
    }

    /// Rows with a countdown (2 paused, 10 next try) re-render once a second while the menu is open (UI-M6). This is
    /// a display clock for the countdown text, not a state poll; nothing else ticks.
    private var countdownTask: Task<Void, Never>?
    private func startCountdownTick() {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.menuIsOpen else { return }
                switch self.env.connection.condition {
                case .paused, .blockedReconnecting:
                    self.header.refresh(from: self.env)
                    self.resizeHeader()
                    self.rebuildIfStructureChanged()
                default:
                    break
                }
            }
        }
    }

    /// What the standard items depend on; rebuilt while open only when this changes (UI-M5).
    private var menuSignature = ""
    private func currentSignature() -> String {
        let c = env.connection
        var parts = [c.condition.row, "\(c.condition.isActive)", c.profileID?.uuidString ?? "-", c.pendingPromptProfileName ?? "-",
                     "\(env.profiles.profiles.map(\.connectHeld).hashValue)", "\(c.inputs.startHold.map { "\($0)" } ?? "-")",
                     "\(c.anyOnDemandEnabled)", "\(env.settings.updateAvailable)", "\(env.profiles.profiles.map(\.id).hashValue)",
                     "\(env.profiles.profiles.map(\.name).hashValue)", "\(env.profiles.locked != nil)",
                     "\(c.inputs.extensionReadiness == .updateFailed)"]
        if case .paused(let until) = c.condition {
            parts.append(DurationFormat.short(DurationFormat.minutesLeft(until: until, now: Date())))
        }
        return parts.joined(separator: "|")
    }

    private func rebuildIfStructureChanged() {
        let sig = currentSignature()
        guard sig != menuSignature else { return }
        rebuildStandardItems()
    }

    /// No state timer (DESIGN §11.3, S15): re-render when the stores change, re-armed only while the menu is open.
    private func observeHeader() {
        guard !headerObserving else { return }
        headerObserving = true
        withObservationTracking {
            header.refresh(from: env)
            _ = currentSignature()          // also track what the standard items depend on (UI-M5)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.headerObserving = false
                self.header.refresh(from: self.env)
                self.resizeHeader()
                if self.menuIsOpen {
                    self.rebuildIfStructureChanged()
                    self.observeHeader()
                }
            }
        }
    }

    private func resizeHeader() {
        let fit = headerHost.fittingSize
        let size = NSSize(width: MenuHeaderView.width, height: fit.height > 0 ? fit.height : 96)
        if headerHost.frame.size != size { headerHost.frame.size = size }
    }

    private func rebuildStandardItems() {
        menuSignature = currentSignature()
        menu.removeAllItems()
        menu.addItem(headerItem)
        let condition = env.connection.condition
        let profiles = env.profiles.profiles

        // The header switch as a standard item, always present (§6.2).
        if let primary = primaryItem(condition) { menu.addItem(primary) }
        if case .startHeld = condition, condition.actions.contains(.cancel) {
            menu.addItem(action(String(localized: "Cancel", comment: "Button"), #selector(disconnect(_:))))
        }

        // The header's facts in one sentence, only while VoiceOver runs.
        if NSWorkspace.shared.isVoiceOverEnabled {
            menu.addItem(.sectionHeader(title: voiceOverStatusSentence(condition)))
        }

        // Auth waiting for a gesture (§6.5): bold, ↩.
        var enterCodeItem: NSMenuItem?
        if let name = env.connection.pendingPromptProfileName {
            let enter = NSMenuItem(title: String(localized: "Enter Code for \(name)…", comment: "Menu item, auth prompt waiting"),
                                   action: #selector(enterCode(_:)), keyEquivalent: "\r")
            enter.keyEquivalentModifierMask = []
            enter.target = self
            enterCodeItem = enter
            menu.addItem(enter)
        }

        // While blocked, the pause items move up directly under the header (§6.2).
        if condition.isBlocked { addPauseItems(condition) }

        if !profiles.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: String(localized: "Profiles", comment: "Menu section header")))
            let ordered = orderedProfiles(profiles)
            for p in ordered.prefix(Self.menuProfileLimit) { menu.addItem(profileItem(p)) }
            if ordered.count > Self.menuProfileLimit {
                let more = NSMenuItem(title: String(localized: "More Profiles", comment: "Menu submenu"), action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for p in ordered.dropFirst(Self.menuProfileLimit).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                    sub.addItem(profileItem(p))
                }
                more.submenu = sub
                menu.addItem(more)
            }
        }

        if !condition.isBlocked { addPauseItems(condition) }

        if env.settings.updateAvailable {
            let update = NSMenuItem(title: String(localized: "Update Available…", comment: "Menu item, Sparkle gentle reminder"),
                                    action: #selector(checkForUpdates(_:)), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }

        if env.connection.inputs.extensionReadiness == .updateFailed {
            // E2E-4 (U15): profiles still connect through the old tunnel component; the window has the details.
            let i = NSMenuItem(title: String(localized: "Tunnel Component Not Updated", comment: "Menu item, disabled (E2E-4, U15)"), action: nil, keyEquivalent: "")
            i.isEnabled = false
            i.toolTip = env.connection.extensionUpdateFailedMessage
            menu.addItem(i)
        }

        menu.addItem(.separator())
        menu.addItem(action(String(localized: "Open LockPlus", comment: "Menu item"), #selector(openMain(_:))))
        menu.addItem(action(String(localized: "Settings…", comment: "Menu item"), #selector(openSettings(_:)), key: ","))
        menu.addItem(action(String(localized: "Quit LockPlus", comment: "Menu item"), #selector(quit(_:)), key: "q"))
        Self.setMonospaced(menu, bold: enterCodeItem)
    }

    /// SF Mono for every standard item (UI-CONCEPT §2.4) through attributed titles; the "Enter Code" line stays bold (§6.5).
    /// `NSMenuItem.subtitle` has no attributed variant, so profile subtitles keep the system menu font.
    /// The bold item is matched by identity (pre-release review LOW: by title, a profile named like it went bold too).
    static func setMonospaced(_ menu: NSMenu, bold boldItem: NSMenuItem?) {
        for item in menu.items where !item.isSeparatorItem && !item.isSectionHeader && item.view == nil {
            let bold = item === boldItem
            var attributes: [NSAttributedString.Key: Any] = [.font: LPTypography.menuFont(weight: bold ? .bold : .regular)]
            if !item.isEnabled { attributes[.foregroundColor] = NSColor.disabledControlTextColor }
            item.attributedTitle = NSAttributedString(string: item.title, attributes: attributes)
            if let sub = item.submenu { setMonospaced(sub, bold: nil) }
        }
    }

    private func primaryItem(_ condition: ConnectionCondition) -> NSMenuItem? {
        let name = env.conditionContext.name
        switch condition {
        case .blockedAfterFailure, .blockedReconnecting, .blockedBeforeConnected,
             .heldNonRetryable(_, blocked: true), .nonRetryableBeforeConnected(_, blocked: true):
            return action(String(localized: "Disconnect and Restore Internet", comment: "Menu item, blocked rows"), #selector(disconnect(_:)))
        case .paused:
            return nil       // "Resume Protection Now" is in the pause slot
        case .disconnecting:
            let i = NSMenuItem(title: String(localized: "Disconnecting…", comment: "Menu item, disabled"), action: nil, keyEquivalent: "")
            i.isEnabled = false
            return i
        case .startHeld:
            // Row 12a: what the app is doing, disabled (like "Disconnecting…"); Cancel follows as its own item.
            let i = NSMenuItem(title: condition.headerCopy(for: env.conditionContext).title, action: nil, keyEquivalent: "")
            i.isEnabled = false
            return i
        case .extensionNotReady:
            return action(String(localized: "Open System Settings…", comment: "Menu item, row 1"), #selector(openExtensionSettings(_:)))
        default:
            if condition.isActive {
                return action(String(localized: "Disconnect \(name)", comment: "Menu item; the argument is a profile name"), #selector(disconnect(_:)))
            }
            guard env.conditionProfile != nil else {
                if env.profiles.locked != nil { return action(LockedProfilesCopy.menuItem, #selector(openMain(_:))) }
                return action(String(localized: "Import Profile…", comment: "Menu item, empty library"), #selector(openMain(_:)))
            }
            let connect = action(String(localized: "Connect \(name)", comment: "Menu item; the argument is the last-used profile"), #selector(connectLastUsed(_:)))
            if env.conditionProfile?.notYetVerified == true {
                connect.isEnabled = false
                connect.toolTip = ProfileItem.notYetVerifiedExplanation
            } else if let held = env.conditionProfile?.connectHeld {
                connect.isEnabled = false          // review 5 §3: the store would ignore it
                connect.toolTip = held
            }
            return connect
        }
    }

    private func addPauseItems(_ condition: ConnectionCondition) {
        if case .paused(let until) = condition {
            menu.addItem(.separator())
            let left = DurationFormat.short(DurationFormat.minutesLeft(until: until, now: Date()))
            menu.addItem(action(String(localized: "Resume Protection Now (\(left) left)", comment: "Menu item; the argument is like '12 min'"),
                                #selector(resume(_:))))
            return
        }
        guard condition.showsPauseMenu(anyOnDemandEnabled: env.connection.anyOnDemandEnabled) else { return }
        menu.addItem(.separator())
        let pause = NSMenuItem(title: String(localized: "Pause Protection", comment: "Menu submenu"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for minutes in PauseChoice.all {
            let i = NSMenuItem(title: PauseChoice.title(minutes), action: #selector(pause(_:)), keyEquivalent: "")
            i.target = self
            i.tag = minutes
            sub.addItem(i)
        }
        pause.submenu = sub
        menu.addItem(pause)
    }

    private func orderedProfiles(_ profiles: [ProfileItem]) -> [ProfileItem] {
        guard let active = env.connection.profileID, env.connection.condition.isActive,
              let first = profiles.first(where: { $0.id == active }) else { return profiles }
        return [first] + profiles.filter { $0.id != active }
    }

    private func profileItem(_ p: ProfileItem) -> NSMenuItem {
        let i = NSMenuItem(title: p.name, action: #selector(profileClicked(_:)), keyEquivalent: "")
        i.target = self
        i.representedObject = p.id
        i.image = LockGlyphImage.template(env.glyph(for: p), pointSize: Self.menuGlyphPointSize)
        if #available(macOS 27, *) { i.preferredImageVisibility = .visible }   // 27 hides menu images by default (S15)
        let isCurrent = p.id == env.connection.profileID && env.connection.condition.isActive
        i.state = isCurrent ? .on : .off
        i.subtitle = ProfileSubtitle.text(for: p, env: env)
        if p.notYetVerified && !isCurrent { i.isEnabled = false; i.toolTip = ProfileItem.notYetVerifiedExplanation }
        else if let held = p.connectHeld, !isCurrent { i.isEnabled = false; i.toolTip = held }      // review 5 §3
        return i
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        i.target = self
        return i
    }

    private func voiceOverStatusSentence(_ condition: ConnectionCondition) -> String {
        let ctx = env.conditionContext
        let copy = condition.copy(for: ctx)
        guard condition.showsRateLabel, let rate = env.stats.current else {
            return [copy.title, copy.message].compactMap { $0 }.joined(separator: ", ")
        }
        let summary = ThroughputSummary(samples: Array(env.stats.menuSamples))
        return String(localized: "\(copy.title), \(ctx.name), download \(RateFormat.spoken(rate.down)), upload \(RateFormat.spoken(rate.up)); last minute \(summary.spokenSentence)",
                      comment: "VoiceOver-only status item in the menu (§6.2)")
    }

    // MARK: - Actions

    private func headerToggled(_ on: Bool) {
        if on { connectLastUsed(nil) } else { env.actions.disconnect() }
    }

    @objc private func connectLastUsed(_ sender: Any?) {
        guard let id = env.connection.profileID else { env.actions.openMainWindow(); return }
        connectChecked(id)
    }

    /// Menu connects take the same gate as the window (§4.5): `AppActions.connect` re-reads the old helper on every
    /// attempt (E2E-5 F3); a refusal or warning opens the main window, which shows it (`observeConnectGate`).
    private func connectChecked(_ id: ProfileItem.ID) { env.gatedConnect(id) }

    @objc private func disconnect(_ sender: Any?) {
        if env.connection.condition.isBlocked { env.actions.perform(.disconnectAndRestoreInternet) } else { env.actions.disconnect() }
    }

    @objc private func enterCode(_ sender: Any?) { env.actions.perform(.enterCode) }
    @objc private func resume(_ sender: Any?) { env.actions.resume() }
    @objc private func checkForUpdates(_ sender: Any?) { env.actions.checkForUpdates() }
    @objc private func openMain(_ sender: Any?) { env.actions.openMainWindow() }
    @objc private func openSettings(_ sender: Any?) { env.actions.openSettings() }
    @objc private func quit(_ sender: Any?) { env.actions.quitFromMenu() }
    @objc private func openExtensionSettings(_ sender: Any?) { SystemSettingsLink.open(SystemSettingsLink.networkExtensions) }

    @objc private func pause(_ sender: NSMenuItem) {
        let minutes = sender.tag
        let alert = NSAlert()
        alert.messageText = String(localized: "Pause protection?", comment: "Pause confirmation title")
        alert.informativeText = PauseChoice.confirmation(minutes, resumeNeedsApproval: env.connection.resumeAgentNeedsApproval)
        alert.addButton(withTitle: String(localized: "Pause", comment: "Pause confirmation button"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Button"))
        if env.connection.resumeAgentNeedsApproval {
            alert.addButton(withTitle: PauseChoice.openLoginItems)
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn: env.actions.pause(minutes: minutes)
        case .alertThirdButtonReturn: SystemSettingsLink.open(SystemSettingsLink.loginItems)
        default: break
        }
    }

    @objc private func profileClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let target = env.profiles.profile(id) else { return }
        // Clicking the active profile disconnects it; another profile switches directly (§6.2).
        if id == env.connection.profileID, env.connection.condition.isActive {
            env.actions.disconnect()
            return
        }
        if env.switchNeedsConfirmation(to: target) {
            let alert = NSAlert()
            alert.messageText = SwitchCopy.title(target.name)
            alert.informativeText = SwitchCopy.message(target.name)
            alert.addButton(withTitle: String(localized: "Switch", comment: "Switch confirmation button"))
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Button"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        connectChecked(id)
    }
}

/// Pause durations and their copy (§6.6): 5 min / 15 min / 1 hour, then a confirmation.
enum PauseChoice {
    static let all = [5, 15, 60]

    static func title(_ minutes: Int) -> String {
        DurationFormat.short(TimeInterval(minutes * 60))
    }

    static func confirmation(_ minutes: Int, resumeNeedsApproval: Bool = false) -> String {
        let duration = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
        let base = String(localized: "LockPlus will disconnect and allow unprotected internet for \(duration).",
                          comment: "Pause confirmation; the argument is like '15 minutes'")
        guard resumeNeedsApproval else { return base }
        return base + "\n\n" + approvalNote
    }

    /// The resume agent (§10.4) is waiting for login-item approval: the pause can't end while LockPlus is closed.
    static var approvalNote: String {
        String(localized: "LockPlus's background item isn't allowed yet, so if you quit LockPlus, protection resumes the next time it opens instead of on time. Allow LockPlus in System Settings › General › Login Items.",
               comment: "Pause sheet note when the resume agent needs approval (§10.4)")
    }

    static var openLoginItems: String { String(localized: "Open Login Items…", comment: "Button") }
}

/// §4.5 copy for the old LockPlus helper.
enum LegacyHelperCopy {
    static var refuseTitle: String { String(localized: "The old LockPlus is still protecting this Mac", comment: "Legacy helper refuse dialog title (§4.5)") }
    static var warnTitle: String { String(localized: "The old LockPlus left its firewall on", comment: "Legacy helper warning title (§4.5)") }
    static var openOldApp: String { String(localized: "Open the old LockPlus", comment: "Button (§4.5)") }
    static var connectAnyway: String { String(localized: "Connect Anyway", comment: "Button (§4.5)") }
    /// The refusal's message when the notice hasn't caught up with the re-read yet (refused by `AppActions.connect`).
    static var refuseFallback: String { String(localized: "Disconnect in the old LockPlus and turn off its kill switch first.", comment: "§4.5 refuse to connect") }
}

/// Profile switch confirmation (§6.2, F-12).
enum SwitchCopy {
    static func title(_ target: String) -> String {
        String(localized: "Switch to \(target)?", comment: "Switch confirmation title")
    }
    static func message(_ target: String) -> String {
        String(localized: "\(target) has no kill switch, so traffic outside the tunnel won't be blocked.", comment: "Switch confirmation message")
    }
}

/// The sidebar and menu subtitle: the most useful fact about a profile (§6.3). Always contains a state word for
/// the active profile (Differentiate Without Color, §8.2).
enum ProfileSubtitle {
    @MainActor static func text(for p: ProfileItem, env: UIEnvironment, now: Date = Date()) -> String? {
        if p.id == env.connection.profileID {
            let c = env.connection.condition
            switch c {
            case .protected, .protectedDNSWarning:
                if let since = env.connection.connectedSince {
                    let elapsed = Duration.seconds(Int(now.timeIntervalSince(since))).formatted(.time(pattern: .hourMinute))
                    return String(localized: "Protected · \(elapsed)", comment: "Profile subtitle; the argument is like '02:14'")
                }
                return String(localized: "Protected", comment: "State word")
            case .unprotected:
                break
            default:
                if c.glyph != .unprotected { return c.shortStateWord }
            }
        }
        if p.notYetVerified { return String(localized: "Not yet verified", comment: "Profile subtitle (§8.1)") }
        if p.isAutoConnectProfile { return String(localized: "Auto-connect", comment: "Profile subtitle") }
        if p.needsOneTimeCode { return String(localized: "\(p.protocolName) · OTP", comment: "Profile subtitle, e.g. 'OpenVPN · OTP'") }
        return nil
    }
}

extension ConnectionCondition {
    /// One or two words for sidebar subtitles and menu items.
    var shortStateWord: String {
        switch glyph {
        case .unprotected: String(localized: "Not protected", comment: "State word")
        case .connecting:
            switch self {
            case .disconnecting: String(localized: "Disconnecting…", comment: "State word")
            // Row 12a has no NEVPNStatus: never "Connecting…" (review 5 §3).
            case .startHeld(let h) where h.reason == .preparing: String(localized: "Preparing…", comment: "State word, row 12a")
            case .startHeld: String(localized: "Waiting…", comment: "State word, row 12a")
            default: String(localized: "Connecting…", comment: "State word")
            }
        case .reasserting: String(localized: "Reconnecting…", comment: "State word")
        case .protected: String(localized: "Protected", comment: "State word")
        case .blocked: String(localized: "Blocked", comment: "State word")
        case .attention:
            switch self {
            case .authMidStart, .reconnectNeedsCode: String(localized: "Sign-in required", comment: "State word")
            default: String(localized: "Needs attention", comment: "State word")
            }
        case .paused: String(localized: "Paused", comment: "State word")
        case .errorStopped: String(localized: "Stopped", comment: "State word")
        }
    }
}
