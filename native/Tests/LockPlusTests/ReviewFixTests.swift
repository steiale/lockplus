import AppKit
import LPModel
import SwiftUI
import Testing
@testable import LockPlus

/// Tests for the Sonnet UI review (docs/native/reviews/2026-10-26-sonnet-ui.md) and Fable app review L2/L8.
@MainActor @Suite("UI review fixes")
struct ReviewFixTests {

    // MARK: UI-H1 delete confirmation

    @Test("Delete… only asks; nothing is deleted until the confirmation")
    func deleteAsksFirst() {
        let env = UIEnvironment.preview(row: "15")
        let actions = env.actions as! PreviewUIActions
        env.presentation.requestDelete(PreviewData.workID)
        #expect(env.presentation.pendingDelete == PreviewData.workID)
        #expect(!actions.log.contains("delete"))
    }

    // MARK: UI-M9 sheet coordinator

    @Test("One sheet at a time, auth first; dismissing clears only the shown one")
    func sheetPriority() {
        let env = UIEnvironment.preview(row: "15")
        env.importer.preview = PreviewData.importPreview
        #expect(MainSheet.active(in: env)?.id.hasPrefix("import-") == true)
        env.auth.prompt = AuthPromptState(id: UUID(), profileName: "Acme", kind: .password(oneTimeCode: false))
        guard case .auth = MainSheet.active(in: env) else { Issue.record("auth must win"); return }
        MainSheet.active(in: env)?.clear(in: env)
        #expect(env.auth.prompt == nil)
        #expect(env.importer.preview != nil)                    // queued behind, presented next
        #expect(MainSheet.active(in: env)?.id.hasPrefix("import-") == true)
    }

    // MARK: UI-H2 show in menu bar

    @Test("Show in menu bar off hides the status item; on shows it again")
    func showInMenuBar() {
        let env = UIEnvironment.preview(row: "6")
        let controller = MenuBarController(env: env)
        defer { controller.remove() }
        env.settings.showInMenuBar = false
        controller.renderStatusItem()
        #expect(!controller.item.isVisible)
        env.settings.showInMenuBar = true
        controller.renderStatusItem()
        #expect(controller.item.isVisible)
    }

    // MARK: UI-M5 menu liveness

    @Test("Standard items are rebuilt when the state changes while the menu is open")
    func menuRebuildsWhileOpen() async throws {
        let env = UIEnvironment.preview(row: "6")
        let controller = MenuBarController(env: env)
        defer { controller.remove() }
        let menu = try #require(controller.item.menu)
        controller.menuNeedsUpdate(menu)
        controller.menuWillOpen(menu)
        #expect(menu.items.contains { $0.title == "Disconnect Work" })
        env.connection.inputs.status = .disconnected
        try await Task.sleep(for: .milliseconds(200))
        #expect(menu.items.contains { $0.title == "Connect Work" }, "\(menu.items.map(\.title))")
        controller.menuDidClose(menu)
    }

    // MARK: UI-H3 masking fail-closed (pixel test with an insert above a key line)

    /// Renders the text view and returns the pixels of one line band.
    static func renderBand(_ model: EditorModel, insertAbove: String?, line: Int) async throws -> [UInt32] {
        let size = CGSize(width: 600, height: 200)
        let host = NSHostingView(rootView: ConfigTextView(model: model).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let tv = try #require(EditorTests.findTextView(in: host))
        if let insertAbove {
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.insertText(insertAbove, replacementRange: NSRange(location: 0, length: 0))
        }
        // Render immediately: the debounced analysis (150 ms) hasn't run, so it is stale.
        host.layoutSubtreeIfNeeded()
        tv.display()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if ProcessInfo.processInfo.environment["LP_DEBUG_BANDS"] == "1" {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LockPlusUIScreenshots")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("band-\(UUID().uuidString.prefix(4)).png"))
        }
        // The band of the requested line, from its layout fragment (not a guessed line height).
        let tlm = try #require(tv.textLayoutManager)
        var frames: [CGRect] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            frames.append(f.layoutFragmentFrame); return frames.count <= line
        }
        let frame = try #require(frames.count > line ? frames[line] : nil)
        let origin = tv.textContainerOrigin
        var r = tv.convert(CGRect(x: frame.minX + origin.x, y: frame.minY + origin.y, width: 400, height: frame.height), to: host)
        if !host.isFlipped { r.origin.y = host.bounds.height - r.maxY }
        let scale = CGFloat(rep.pixelsHigh) / size.height
        let lineText = (tv.string as NSString).components(separatedBy: "\n")[line]
        let eq = (lineText as NSString).range(of: "=").location
        try #require(eq != NSNotFound, "line \(line) is not a key line: \(lineText.debugDescription)")
        let valueX = r.minX + CGFloat(eq + 2) * 7.2                 // skip "PrivateKey = "
        var out: [UInt32] = []
        for y in Int(r.minY * scale)..<min(Int(r.maxY * scale), rep.pixelsHigh) {
            for x in Int(valueX * scale)..<min(Int(r.maxX * scale), rep.pixelsWide) {
                let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                out.append(UInt32((c?.redComponent ?? 0) * 255) << 16 | UInt32((c?.greenComponent ?? 0) * 255) << 8 | UInt32((c?.blueComponent ?? 0) * 255))
            }
        }
        return out
    }

    @Test("A key line stays masked right after an insert above it (stale analysis): two different keys draw the same")
    func maskingFailsClosedAfterInsert() async throws {
        func text(_ key: String) -> String { "[Interface]\nPrivateKey = \(key)\nAddress = 10.0.0.2/32\n" }
        let a = EditorModel.preview(kind: .wireGuard, text: text("yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="))
        let b = EditorModel.preview(kind: .wireGuard, text: text("WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW="))
        // After inserting two lines at the top, the key is on line 3 (0-based).
        let bandA = try await Self.renderBand(a, insertAbove: "# one\n# two\n", line: 3)
        let bandB = try await Self.renderBand(b, insertAbove: "# one\n# two\n", line: 3)
        #expect(!bandA.isEmpty)
        #expect(bandA == bandB, "the key's pixels depend on the key: it is drawn unmasked")
        // Control: revealed, the two keys draw differently (the band is really the key line). The models kept the
        // inserted lines, so the key is still on line 3.
        a.keyRevealed = true; b.keyRevealed = true
        let revealedA = try await Self.renderBand(a, insertAbove: nil, line: 3)
        let revealedB = try await Self.renderBand(b, insertAbove: nil, line: 3)
        #expect(revealedA != revealedB)
    }

    // MARK: UI-H4 / UI-M15 / Fable L2: AX, copy, Services, Find

    /// The hosting windows stay alive for the test run: `host.window` is weak, and a window freed early took the text
    /// view's undo manager with it (flaked under a loaded full run).
    static var windows: [NSWindow] = []

    static func textView(for model: EditorModel) async throws -> (SecretAwareTextView, NSHostingView<some View>) {
        let host = NSHostingView(rootView: ConfigTextView(model: model).frame(width: 600, height: 200))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let tv = try #require(EditorTests.findTextView(in: host) as? SecretAwareTextView)
        return (tv, host)
    }

    static let key = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
    static let wg = "[Interface]\nPrivateKey = \(key)\nAddress = 10.0.0.2/32\n"

    @Test("VoiceOver / AX read bullets while masked, the key once revealed")
    func accessibilityMasked() async throws {
        let m = EditorModel.preview(kind: .wireGuard, text: Self.wg)
        let (tv, _) = try await Self.textView(for: m)
        #expect(tv.accessibilityValue()?.contains(Self.key) == false)
        #expect(tv.accessibilityString(for: NSRange(location: 0, length: (Self.wg as NSString).length))?.contains(Self.key) == false)
        m.keyRevealed = true
        #expect(tv.accessibilityValue()?.contains(Self.key) == true)
    }

    @Test("Copy while masked puts bullets, not the key; revealed copies are concealed")
    func copyMasked() async throws {
        let m = EditorModel.preview(kind: .wireGuard, text: Self.wg)
        let (tv, _) = try await Self.textView(for: m)
        let pb = NSPasteboard(name: NSPasteboard.Name("io.github.steiale.lockplus.tests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        tv.selectAll(nil)
        #expect(tv.writeSelection(to: pb, types: [.string]))
        let copied = try #require(pb.string(forType: .string))
        #expect(!copied.contains(Self.key))
        #expect(copied.contains("Address = 10.0.0.2/32"))          // the rest copies normally
        m.keyRevealed = true
        #expect(tv.writeSelection(to: pb, types: [.string]))
        #expect(pb.string(forType: .string)?.contains(Self.key) == true)
        #expect(pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
    }

    @Test("Services and Find are refused while a masked secret is involved")
    func servicesAndFindRefused() async throws {
        let m = EditorModel.preview(kind: .wireGuard, text: Self.wg)
        let (tv, _) = try await Self.textView(for: m)
        tv.setSelectedRange(NSRange(location: 14, length: 10))      // inside the key line
        #expect(tv.validRequestor(forSendType: .string, returnType: nil) == nil)
        let find = NSMenuItem(title: "Find", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "")
        #expect(!tv.validateUserInterfaceItem(find))
    }

    // MARK: UI-M12 revert is undoable

    @Test("Revert is one undoable edit")
    func revertUndoable() async throws {
        let m = EditorModel.preview(kind: .wireGuard, text: Self.wg)
        let (tv, host) = try await Self.textView(for: m)
        tv.setSelectedRange(NSRange(location: (Self.wg as NSString).length, length: 0))
        // A test has no event cycle to close NSUndoManager's automatic groups, so each user action gets an explicit
        // group, the way AppKit wraps each key event and menu command.
        let um = try #require(tv.undoManager)
        um.groupsByEvent = false
        defer { um.groupsByEvent = true }
        um.beginUndoGrouping()
        tv.insertText("# edit\n", replacementRange: tv.selectedRange())
        um.endUndoGrouping()
        #expect(m.isDirty)
        um.beginUndoGrouping()
        m.revert()
        host.rootView = host.rootView                             // trigger updateNSView
        host.layoutSubtreeIfNeeded()
        um.endUndoGrouping()
        #expect(tv.string == Self.wg)
        #expect(um.canUndo)
        #expect(um.undoActionName == String(localized: "Revert", comment: "Undo action name"))
        um.undo()
        #expect(tv.string.hasSuffix("# edit\n"), "after undo: \(tv.string.debugDescription)")
        #expect(um.canUndo, "the typing stays its own undo step")
    }

    // MARK: Performance

    @Test("Large profiles analyse and scan quickly")
    func largeProfilePerformance() {
        var ovpn = "client\ndev tun\nremote vpn.example.com 1194\n<ca>\n"
        for _ in 0..<4_000 { ovpn += "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7aaaaaaaa\n" }
        ovpn += "</ca>\n"
        let clock = ContinuousClock()
        let scan = clock.measure { _ = EditorAnalyzer.scanSecrets(ovpn, kind: .openVPN) }
        let analysis = clock.measure { _ = EditorAnalyzer.analyzeSync(ovpn, kind: .openVPN) }
        #expect(scan < .milliseconds(150), "scan \(scan)")
        #expect(analysis < .seconds(2), "analysis \(analysis)")
    }

    // MARK: Fable L8 server text

    @Test("Server text loses controls and bidi overrides, collapses newlines, and is capped")
    func serverTextSanitized() {
        #expect(ServerText.sanitize("Enter\ncode\r\nnow") == "Enter code now")
        #expect(ServerText.sanitize("abc\u{202E}lmth.exe\u{2066}x\u{2069}") == "abclmth.exex")
        #expect(ServerText.sanitize("a\u{0007}b\u{009B}c") == "abc")
        let long = String(repeating: "x", count: 1_000)
        #expect(ServerText.sanitize(long).count == ServerText.maxLength)
        #expect(ServerText.sanitize(long).hasSuffix("…"))
    }

    // MARK: UI-M17 German

    @Test("German ships: the catalog compiles a de.lproj with real translations")
    func germanTranslationsExist() throws {
        let path = try #require(Bundle.main.path(forResource: "de", ofType: "lproj"), "no de.lproj in the app")
        let de = try #require(Bundle(path: path))
        for key in ["Protected", "Not protected", "Connect", "Disconnect and Restore Internet", "Show the Switch Again"] {
            let value = de.localizedString(forKey: key, value: "§missing§", table: "Localizable")
            #expect(value != "§missing§" && value != key, "\(key) → \(value)")
        }
        #expect(!Bundle.main.localizations.contains("ko") && !Bundle.main.localizations.contains("ja"))
    }

    // MARK: UI-M10 / UI-L19

    @Test("Held non-retryable rows get their own status-item label and a restore-internet menu action")
    func heldNonRetryableCopy() {
        let ctx = ProfileContext(name: "Work", protocolName: "WireGuard")
        let blocked = ConnectionCondition.heldNonRetryable(.authFailed, blocked: true)
        #expect(blocked.statusItemAccessibilityLabel(for: ctx, rate: nil).hasPrefix("LockPlus, blocked, Work stopped:"))
        let open = ConnectionCondition.heldNonRetryable(.authFailed, blocked: false)
        #expect(open.statusItemAccessibilityLabel(for: ctx, rate: nil).contains("Auto-connect is paused"))
        #expect(ConnectionCondition.extensionNotReady(.rebootRequired).isExtensionNotReady)
        #expect(!ConnectionCondition.protected.isExtensionNotReady)
    }
}
