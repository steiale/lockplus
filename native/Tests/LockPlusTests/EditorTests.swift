import AppKit
import LPModel
import LPParsing
import SwiftUI
import Testing
@testable import LockPlus

/// Profile editor (UI-CONCEPT §6.9): analysis through LPParsing, issue placement on lines, secret masking data,
/// Save rules, and the TextKit 2 guarantee (no silent fallback to TextKit 1).
@MainActor @Suite("Profile editor (§6.9)")
struct EditorTests {
    @Test("WireGuard: a broken Endpoint is an error on its own line; hooks are dimmed; keys are secret lines")
    func wireGuardAnalysis() {
        let a = EditorAnalyzer.analyzeSync(EditorPreviewText.wireGuard, kind: .wireGuard)
        let errors = a.issues.filter { $0.severity == .error }
        #expect(!errors.isEmpty)
        #expect(errors.contains { $0.line == 9 }, "\(errors)")            // "Endpoint = vpn.example.de" (no port)
        #expect(a.secretLines[1] != nil)                                   // PrivateKey
        #expect(a.secretLines[7] == nil)                                   // PublicKey is not secret
        #expect(a.spans.contains { $0.kind == .ignoredKey })               // PostUp
        #expect(a.spans.contains { $0.kind == .section })
    }

    @Test("WireGuard: a valid config has no errors and yields a summary")
    func wireGuardValid() {
        let fixed = EditorPreviewText.wireGuard.replacingOccurrences(of: "Endpoint = vpn.example.de\n", with: "Endpoint = vpn.example.de:51820\n")
        let a = EditorAnalyzer.analyzeSync(fixed, kind: .wireGuard)
        #expect(a.errorCount == 0, "\(a.issues)")
        #expect(a.summary?.isFullTunnel == true)
    }

    @Test("OpenVPN: BF-CBC blocks with a line; inline <key> is masked")
    func openVPNAnalysis() {
        let a = EditorAnalyzer.analyzeSync(EditorPreviewText.openVPN, kind: .openVPN)
        #expect(a.issues.contains { $0.severity == .error && $0.line == 5 }, "\(a.issues)")   // cipher BF-CBC
        #expect(a.secretLines[11] != nil && a.secretLines[12] != nil)                         // inside <key>
        #expect(a.secretLines[9] == nil)                                                      // the <key> tag itself
    }

    @Test("Line lookup maps UTF-16 offsets to lines")
    func lineLookup() {
        let a = EditorAnalyzer.analyzeSync("a = 1\nbé = 2\nc\n", kind: .wireGuard)
        #expect(a.lineStarts == [0, 6, 13, 15])
        #expect(a.line(forOffset: 0) == 0)
        #expect(a.line(forOffset: 7) == 1)
        #expect(a.line(forOffset: 13) == 2)
    }

    @Test("Save is disabled while errors exist, with a reason; Revert restores")
    func saveRules() async throws {
        let m = EditorModel.preview(kind: .wireGuard, text: EditorPreviewText.wireGuard)
        #expect(!m.canSave)                                      // not dirty
        m.text += "# edit\n"
        #expect(await eventually { !m.errors.isEmpty })         // the debounced (150 ms) analysis ran
        #expect(m.isDirty)
        #expect(!m.canSave)
        #expect(m.saveDisabledReason?.hasPrefix("Fix") == true)
        #expect(m.saveDisabledReason?.contains("^[") == false)          // inflection markup is resolved, not shown
        m.revert()
        #expect(m.pendingReplacement == m.savedText)              // the text view applies it as one undoable edit
    }

    @Test("Saving goes through the backend; the target becomes the saved profile")
    func saveThroughBackend() async throws {
        let backend = FakeEditorBackend()
        let fixed = EditorPreviewText.wireGuard.replacingOccurrences(of: "Endpoint = vpn.example.de\n", with: "Endpoint = vpn.example.de:51820\n")
        let m = EditorModel(target: .new(.wireGuard))
        m.apply(EditorDocument(name: "", kind: .wireGuard, text: fixed))
        m.name = "Lab"
        #expect(m.canSave)
        #expect(await m.save(mode: .saveOnly, using: backend))
        #expect(backend.saved?.name == "Lab")
        #expect(m.target == .existing(backend.newID))
        #expect(!m.isDirty)
    }

    @Test("The buffer stays on TextKit 2 after layout, highlighting and masking")
    func staysOnTextKit2() async throws {
        let m = EditorModel.preview(kind: .wireGuard, text: EditorPreviewText.wireGuard)
        let host = NSHostingView(rootView: ConfigTextView(model: m).frame(width: 600, height: 300))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let tv = try #require(Self.findTextView(in: host))
        #expect(tv.textLayoutManager != nil)
        m.keyRevealed = true
        host.layoutSubtreeIfNeeded()
        #expect(tv.textLayoutManager != nil)
        #expect(tv.writingToolsBehavior == .none)
        #expect(!tv.isAutomaticQuoteSubstitutionEnabled && !tv.isContinuousSpellCheckingEnabled)
    }

    @Test("Forbidden OpenVPN directives get a red dotted underline that actually draws")
    func forbiddenUnderlineDraws() async throws {
        let text = "client\nup /etc/up.sh\nremote vpn.example.com 1194\n"
        let m = EditorModel.preview(kind: .openVPN, text: text)
        #expect(m.analysis.forbiddenRanges[1] == [0..<2], "\(m.analysis.forbiddenRanges)")
        let size = CGSize(width: 500, height: 120)
        let host = NSHostingView(rootView: ConfigTextView(model: m).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        // Strong red pixels right of the gutter (the gutter's own markers are excluded).
        var red = 0
        for y in 0..<rep.pixelsHigh {
            for x in (rep.pixelsWide * 56 / 500)..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.7 && c.greenComponent < 0.4 && c.blueComponent < 0.4 { red += 1 }
            }
        }
        #expect(red >= 4, "red pixels: \(red)")
    }

    @Test("Connect goes through the old-helper rule: refused, warned, or straight through")
    func connectGate() {
        let env = UIEnvironment.preview(row: "15")
        let actions = env.actions as! PreviewUIActions
        env.connection.legacyHelper = LegacyHelperNotice(message: "m", blocksConnect: true, warnsBeforeConnect: false)
        env.gatedConnect(PreviewData.workID)
        #expect(env.connection.connectGate == .refused(PreviewData.workID))
        #expect(!actions.log.contains("connect"))
        env.connection.legacyHelper = LegacyHelperNotice(message: "m", blocksConnect: false, warnsBeforeConnect: true)
        env.gatedConnect(PreviewData.workID)
        #expect(env.connection.connectGate == .warn(PreviewData.workID))
        env.connection.legacyHelper = nil
        env.connection.connectGate = nil
        env.gatedConnect(PreviewData.workID)
        #expect(actions.log.contains("connect"))
    }

    /// Stands in for SwiftUI's `AppKitWindowController`, whose `windowShouldClose` carries out a scene window's close.
    final class ControllerStandIn: NSObject, NSWindowDelegate {
        var asked = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool { asked += 1; return true }
    }

    @Test("Editor close (UI-M13): a rebuilt window hook keeps SwiftUI's delegate; clean closes, dirty asks first")
    func closeSurvivesHookRebuild() async throws {
        let m = EditorModel.preview(kind: .openVPN, text: EditorTemplates.text(for: .openVPN))
        let controller = ControllerStandIn()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = controller
        // Owner test, build 200018: SwiftUI rebuilt the background view, a second hook wrapped the first one's guard,
        // the first hook went away, and the close never reached the controller (close button, ⌘W: nothing).
        weak var firstGone: EditorWindowConfigurator.WindowHook?
        let second = EditorWindowConfigurator.WindowHook()
        second.model = m
        autoreleasepool {
            let first = EditorWindowConfigurator.WindowHook()
            first.model = m
            firstGone = first
            window.contentView?.addSubview(first)
            window.contentView?.addSubview(second)
            first.removeFromSuperview()
        }
        #expect(firstGone == nil)
        #expect(window.sharingType == .none && !window.isRestorable)

        // Unedited: straight through to SwiftUI's controller, and the window closes.
        window.orderFront(nil)
        window.performClose(nil)
        #expect(controller.asked == 1)
        #expect(!window.isVisible)

        // Edited: the save-changes alert, the window stays; Don't Save drops the edits and closes.
        window.orderFront(nil)
        m.text += "# edit\n"
        #expect(m.isDirty)
        let dontSave: NSApplication.ModalResponse = m.canSave ? .alertThirdButtonReturn : .alertSecondButtonReturn
        window.performClose(nil)
        let sheet = try #require(window.attachedSheet)
        #expect(window.isVisible)
        #expect(controller.asked == 1)
        window.endSheet(sheet, returnCode: dontSave)
        let closed = await eventually { !window.isVisible }
        #expect(closed)
        #expect(!m.isDirty)
        // Don't Save closes through windowShouldClose again, so through the controller's own close path.
        #expect(controller.asked == 2)
    }

    @Test("The invisible bridge window can't be closed or minimised by the user (L9)")
    func bridgeWindowNotClosable() {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.lpMakeInvisible()
        #expect(!w.styleMask.contains(.closable) && !w.styleMask.contains(.miniaturizable) && !w.styleMask.contains(.titled))
        #expect(w.alphaValue == 0 && w.ignoresMouseEvents)
    }

    private static func makeEditorWindow(_ delegate: NSWindowDelegate) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        return window
    }

    @Test("Editor close (L8): when SwiftUI replaces the delegate, updateNSView's install re-wraps it and the controller still decides")
    func closeSurvivesDelegateReplacement() async throws {
        let m = EditorModel.preview(kind: .openVPN, text: EditorTemplates.text(for: .openVPN))
        let first = ControllerStandIn(), replacement = ControllerStandIn()
        let window = Self.makeEditorWindow(first)
        let hook = EditorWindowConfigurator.WindowHook()
        hook.model = m
        window.contentView?.addSubview(hook)
        let guardObject = try #require(window.delegate as? EditorWindowConfigurator.CloseGuard)
        #expect(guardObject.original === first)
        window.delegate = replacement                                  // SwiftUI sets its delegate again
        EditorWindowConfigurator.CloseGuard.install(on: window, hook: hook)          // what updateNSView does
        #expect(window.delegate === guardObject)                       // the same guard, not a second wrapper
        #expect(guardObject.original === replacement)
        window.orderFront(nil)
        window.performClose(nil)
        #expect(replacement.asked == 1 && first.asked == 0)
        let closed = await eventually { !window.isVisible }
        #expect(closed)
    }

    @Test("Editor close (L8): a released hook never lets a dirty editor close silently; a clean one still closes")
    func closeFailsSafeWithoutHook() async throws {
        let m = EditorModel.preview(kind: .openVPN, text: EditorTemplates.text(for: .openVPN))
        let controller = ControllerStandIn()
        let window = Self.makeEditorWindow(controller)
        weak var gone: EditorWindowConfigurator.WindowHook?
        autoreleasepool {
            let hook = EditorWindowConfigurator.WindowHook()
            hook.model = m
            gone = hook
            window.contentView?.addSubview(hook)
            hook.removeFromSuperview()
        }
        #expect(gone == nil)
        window.orderFront(nil)
        m.text += "# edit\n"
        window.performClose(nil)
        let sheet = try #require(window.attachedSheet)                 // asked, did not close
        #expect(window.isVisible && controller.asked == 0)
        window.endSheet(sheet, returnCode: .cancel)                    // neither Save nor Don't Save
        _ = await eventually { window.attachedSheet == nil }
        m.discardChanges()
        window.performClose(nil)                                       // clean: provably nothing to lose
        #expect(controller.asked >= 1)
        let closed = await eventually { !window.isVisible }
        #expect(closed)
    }

    static func findTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
        return nil
    }
}

@MainActor final class FakeEditorBackend: ProfileEditorBackend {
    let newID = UUID()
    var saved: (name: String, text: String, mode: EditorSaveMode)?
    var openVPNValidator: (any OpenVPN3ProfileValidating)? { nil }
    func load(_ target: EditorTarget) async throws -> EditorDocument {
        EditorDocument(name: "Work", kind: target.newKind ?? .wireGuard, text: EditorTemplates.text(for: target.newKind ?? .wireGuard))
    }
    func save(_ target: EditorTarget, name: String, text: String, mode: EditorSaveMode) async throws -> UUID {
        saved = (name, text, mode)
        return target.profileID ?? newID
    }
}
