import AppKit
import LPModel
import SwiftUI

/// The config buffer (DESIGN §11.4, ref/swiftui-appkit §9): `NSTextView(usingTextLayoutManager: true)` in a
/// representable. Never reads `.layoutManager` (that silently switches to TextKit 1; DEBUG asserts on the switch).
/// Highlighting uses rendering attributes, so the undo stack never sees it.
///
/// Secrets (UI-H3/H4/M15) are masked FAIL-CLOSED:
/// - a synchronous scan of the current text (updated in `didProcessEditing`, before layout) says which lines hold
///   secrets; the debounced parser analysis is only used for colours and underlines;
/// - each layout fragment computes its line from its CURRENT range when it draws, and checks its own text as a last
///   resort, so a stale scan can only over-mask;
/// - VoiceOver/AX and copy see the same bullets as the screen.
struct ConfigTextView: NSViewRepresentable {
    let model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let tv = SecretAwareTextView(usingTextLayoutManager: true)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.writingToolsBehavior = .none                 // the buffer holds a private key
        tv.inlinePredictionType = .no
        tv.font = LPTypography.nsFont(size: 12)
        tv.textColor = NSColor(named: "lp.label")
        tv.backgroundColor = NSColor(named: "lp.sunken") ?? .textBackgroundColor
        tv.drawsBackground = true
        tv.insertionPointColor = NSColor(named: "lp.sage") ?? .textColor
        tv.textContainerInset = NSSize(width: 4, height: 6)
        // No wrapping: config lines read as lines; long values scroll.
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        if let container = tv.textLayoutManager?.textContainer {
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        tv.setAccessibilityLabel(String(localized: "Configuration", comment: "Editor accessibility label"))
        tv.coordinator = c
        c.textView = tv
        // Delegates first, so the very first layout already masks.
        tv.textStorage?.delegate = c
        tv.textLayoutManager?.delegate = c
        c.rescan(model.text)
        tv.string = model.text
        tv.delegate = c

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = tv.backgroundColor
        let gutter = GutterView(scrollView: scroll, coordinator: c)
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        c.gutter = gutter
        c.observeTextKitSwitch(tv)
        c.applyAnalysis(force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let tv = c.textView else { return }
        if let replacement = model.pendingReplacement {
            c.replaceAllUndoably(with: replacement)
            Task { @MainActor in model.pendingReplacement = nil }
        } else if tv.string != model.text {          // a load from the model: not undoable
            tv.string = model.text
            tv.undoManager?.removeAllActions()
        }
        if c.lastRevealed != model.keyRevealed {
            c.lastRevealed = model.keyRevealed
            c.invalidateAll()
        }
        c.applyAnalysis(force: false)
        if let line = model.jumpRequest {
            c.jump(toLine: line)
            Task { @MainActor in model.jumpRequest = nil }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.textView?.undoManager?.removeAllActions()
        coordinator.stopObserving()
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSTextLayoutManagerDelegate, NSTextStorageDelegate {
        let model: EditorModel
        weak var textView: SecretAwareTextView?
        weak var gutter: GutterView?
        var lastRevealed = false
        /// Always matches the text view's current string (UI-H3).
        private(set) var scan = EditorAnalyzer.SecretScan()
        private var appliedGeneration = -1
        private var forbidden: [Int: [Range<Int>]] = [:]
        private var forbiddenLineStarts: [Int] = []
        private var switchObserver: NSObjectProtocol?

        init(model: EditorModel) { self.model = model }

        // MARK: Text changes

        func rescan(_ text: String) {
            let old = scan.secretLines.count
            scan = EditorAnalyzer.scanSecrets(text, kind: model.kind)
            if old != scan.secretLines.count { needsFullInvalidate = true }
        }
        private var needsFullInvalidate = false

        /// Runs inside the edit, before TextKit lays out the changed paragraphs.
        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            let text = textStorage.string
            MainActor.assumeIsolated { rescan(text) }   // SAFETY: NSTextView edits its storage on the main thread
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            model.text = tv.string
            if needsFullInvalidate { needsFullInvalidate = false; invalidateAll() }
            gutter?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let loc = min(tv.selectedRange().location, ns.length)
            let line = scan.line(forOffset: loc)
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let text = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            if model.caretLine != line { model.caretLine = line }
            if model.caretLineText != text { model.caretLineText = text }
        }

        func replaceAllUndoably(with text: String) {
            guard let tv = textView else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            tv.breakUndoCoalescing()                            // keep the typing before it as its own undo step
            tv.insertText(text, replacementRange: full)          // registers the undo like a typed edit
            tv.breakUndoCoalescing()
            tv.undoManager?.setActionName(String(localized: "Revert", comment: "Undo action name"))
        }

        // MARK: Fragments

        func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                               in textElement: NSTextElement) -> NSTextLayoutFragment {
            let fragment = DecoratedLineFragment(textElement: textElement, range: textElement.elementRange)
            fragment.coordinator = self
            fragment.kind = model.kind
            return fragment
        }

        /// Where to start masking a line (nil: not secret). `offset` is the fragment's CURRENT start offset and
        /// `paragraph` its own text.
        func maskStart(lineStartingAt offset: Int, paragraph: Substring) -> Int? {
            guard !model.keyRevealed else { return nil }
            if model.kind == .wireGuard, let from = EditorAnalyzer.wgSecretValueOffset(paragraph) { return from }
            let line = scan.line(forOffset: offset)
            if line < scan.lineStarts.count, scan.lineStarts[line] == offset { return scan.secretLines[line] }
            return EditorAnalyzer.looksSecret(paragraph, kind: model.kind)      // out of sync: fail closed
        }

        /// Forbidden-directive underlines for a line, only while the analysis matches the current text.
        func underlines(lineStartingAt offset: Int) -> [Range<Int>] {
            guard forbiddenLineStarts == scan.lineStarts else { return [] }
            let line = scan.line(forOffset: offset)
            guard line < scan.lineStarts.count, scan.lineStarts[line] == offset else { return [] }
            return forbidden[line] ?? []
        }

        // MARK: Analysis

        func applyAnalysis(force: Bool) {
            guard let tv = textView, let tlm = tv.textLayoutManager,
                  let storage = tlm.textContentManager as? NSTextContentStorage else { return }
            let a = model.analysis
            guard force || a.generation != appliedGeneration else { return }
            // Spans computed for another text would land on the wrong characters.
            guard a.lineStarts == scan.lineStarts else { return }
            appliedGeneration = a.generation
            let newForbidden = a.forbiddenRanges
            let changedLines = Set(forbidden.keys).symmetricDifference(newForbidden.keys)
                .union(newForbidden.keys.filter { forbidden[$0] != newForbidden[$0] })
            forbidden = newForbidden
            forbiddenLineStarts = a.lineStarts
            let length = (tv.string as NSString).length
            tlm.removeRenderingAttribute(.foregroundColor, for: tlm.documentRange)
            for span in a.spans where span.location + span.length <= length {
                guard let start = storage.location(storage.documentRange.location, offsetBy: span.location),
                      let end = storage.location(start, offsetBy: span.length),
                      let range = NSTextRange(location: start, end: end) else { continue }
                tlm.addRenderingAttribute(.foregroundColor, value: Self.color(span.kind), for: range)
            }
            // Re-lay out only the lines whose underline changed (UI-M14), not the whole document.
            for line in changedLines where line < a.lineStarts.count {
                let start = a.lineStarts[line]
                let end = line + 1 < a.lineStarts.count ? a.lineStarts[line + 1] : length
                guard let s = storage.location(storage.documentRange.location, offsetBy: start),
                      let e = storage.location(s, offsetBy: max(end - start, 0)),
                      let r = NSTextRange(location: s, end: e) else { continue }
                tlm.invalidateLayout(for: r)
            }
            tv.needsDisplay = true
            gutter?.needsDisplay = true
        }

        static func color(_ kind: HighlightSpan.Kind) -> NSColor {
            let name = switch kind {
            case .section, .inlineTag: "lp.syntaxSection"
            case .key: "lp.syntaxKey"
            case .forbiddenKey: "lp.criticalText"          // distinct from valid keys (UI-L24), plus the underline
            case .value: "lp.syntaxValue"
            case .number: "lp.syntaxNumber"
            case .comment, .ignoredKey: "lp.syntaxComment"
            }
            return NSColor(named: name) ?? .textColor
        }

        /// Show/Hide toggles every masked line.
        func invalidateAll() {
            guard let tlm = textView?.textLayoutManager else { return }
            tlm.invalidateLayout(for: tlm.documentRange)
            textView?.needsDisplay = true
        }

        /// The buffer with every secret replaced by bullets of the same UTF-16 length (screen, AX and copy agree).
        func maskedString() -> String {
            guard let tv = textView else { return "" }
            guard !model.keyRevealed else { return tv.string }
            let ns = NSMutableString(string: tv.string)
            for (line, from) in scan.secretLines where line < scan.lineStarts.count {
                let start = scan.lineStarts[line] + from
                let end = line + 1 < scan.lineStarts.count ? scan.lineStarts[line + 1] - 1 : ns.length
                guard end > start, end <= ns.length else { continue }
                ns.replaceCharacters(in: NSRange(location: start, length: end - start),
                                     with: String(repeating: "•", count: end - start))
            }
            return ns as String
        }

        func jump(toLine line: Int) {
            guard let tv = textView else { return }
            let starts = scan.lineStarts
            let i = max(0, min(line - 1, starts.count - 1))
            let length = (tv.string as NSString).length
            let start = min(starts[i], length)
            let end = i + 1 < starts.count ? max(start, min(starts[i + 1] - 1, length)) : length
            let range = NSRange(location: start, length: end - start)
            tv.setSelectedRange(range)
            tv.scrollRangeToVisible(range)
            tv.window?.makeFirstResponder(tv)
        }

        /// TextKit 1 fallback trap (DESIGN §11.4): fail loudly in debug builds.
        func observeTextKitSwitch(_ tv: NSTextView) {
            #if DEBUG
            switchObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: tv, queue: .main) { @Sendable _ in
                assertionFailure("ConfigTextView switched to TextKit 1 (something read .layoutManager)")
            }
            #endif
        }

        func stopObserving() {
            if let switchObserver { NotificationCenter.default.removeObserver(switchObserver) }
            switchObserver = nil
        }
    }
}

/// Masks a secret line's value with bullets and draws the red dotted underline under forbidden directives.
/// Its line is computed from its CURRENT range when it draws (fragments survive edits above them).
final class DecoratedLineFragment: NSTextLayoutFragment {
    weak var coordinator: ConfigTextView.Coordinator?
    var kind: VPNProtocolKind = .wireGuard

    override func draw(at point: CGPoint, in context: CGContext) {
        guard let line = textLineFragments.first,
              let storage = textLayoutManager?.textContentManager as? NSTextContentStorage else {
            return super.draw(at: point, in: context)
        }
        let offset = storage.offset(from: storage.documentRange.location, to: rangeInElement.location)
        let paragraph = Substring((textElement as? NSTextParagraph)?.attributedString.string ?? "")
        let c = coordinator, k = kind
        // SAFETY: NSTextView draws its layout fragments on the main thread.
        let deco: (mask: Int?, underlines: [Range<Int>]) = MainActor.assumeIsolated {
            guard let c else {
                // No coordinator: still never show a key.
                return (EditorAnalyzer.wgSecretValueOffset(paragraph) ?? EditorAnalyzer.looksSecret(paragraph, kind: k), [])
            }
            return (c.maskStart(lineStartingAt: offset, paragraph: paragraph), c.underlines(lineStartingAt: offset))
        }
        if let maskFrom = deco.mask {
            let x = line.locationForCharacter(at: maskFrom).x + line.typographicBounds.minX
            context.saveGState()
            // 1.5 pt short of the secret: wide glyphs (W) overhang to the left of their advance (the pixel test caught it).
            context.clip(to: CGRect(x: point.x, y: point.y, width: max(x - 1.5, 0), height: layoutFragmentFrame.height))
            super.draw(at: point, in: context)
            context.restoreGState()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: LPTypography.nsFont(size: 12),
                .foregroundColor: NSColor(named: "lp.syntaxComment") ?? .secondaryLabelColor,
            ]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            NSAttributedString(string: String(repeating: "•", count: 20), attributes: attributes)
                .draw(at: CGPoint(x: point.x + x, y: point.y + line.typographicBounds.minY))
            NSGraphicsContext.restoreGraphicsState()
        } else {
            super.draw(at: point, in: context)
        }
        guard !deco.underlines.isEmpty else { return }
        context.saveGState()
        context.setFillColor((NSColor(named: "lp.critical") ?? .systemRed).cgColor)
        let y = point.y + line.typographicBounds.maxY - 1.5
        for r in deco.underlines {
            let x0 = point.x + line.locationForCharacter(at: r.lowerBound).x
            let x1 = point.x + line.locationForCharacter(at: r.upperBound).x
            var x = x0
            while x + 1.6 <= x1 + 0.5 {
                context.fillEllipse(in: CGRect(x: x, y: y, width: 1.6, height: 1.6))
                x += 3
            }
        }
        context.restoreGState()
    }

    /// Room for the underline below the text.
    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.insetBy(dx: 0, dy: -2) }
}

/// Clipboard and accessibility hygiene (§6.9, F-7; UI-H4, UI-M15).
/// - While masked, copy puts the masked text on the pasteboard (secrets as bullets) instead of beeping.
/// - Once revealed, a copy that touches a secret is concealed + transient and cleared after 60 s.
/// - VoiceOver and the AX API get the masked text while masked.
final class SecretAwareTextView: NSTextView {
    weak var coordinator: ConfigTextView.Coordinator?

    private var selectionTouchesSecret: Bool {
        guard let c = coordinator else { return true }
        let r = selectedRange()
        let first = c.scan.line(forOffset: r.location), last = c.scan.line(forOffset: r.location + max(r.length - 1, 0))
        return (first...last).contains { c.scan.secretLines[$0] != nil }
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard selectionTouchesSecret, let c = coordinator else { return super.writeSelection(to: pboard, types: types) }
        let r = selectedRange()
        if !c.model.keyRevealed {
            let masked = (c.maskedString() as NSString).substring(with: r)
            pboard.clearContents()
            return pboard.setString(masked, forType: .string)
        }
        let text = (string as NSString).substring(with: r)
        pboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pboard.writeObjects([item])
        let count = pboard.changeCount
        let board = pboard
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if board.changeCount == count { board.clearContents() }
        }
        return true
    }

    // MARK: Other ways out of the buffer while masked (Fable L2)

    private var maskedAndTouchingSecret: Bool {
        guard let c = coordinator else { return true }
        return !c.model.keyRevealed && selectionTouchesSecret
    }

    private var maskedWithSecrets: Bool {
        guard let c = coordinator else { return true }
        return !c.model.keyRevealed && !c.scan.secretLines.isEmpty
    }

    /// Services menu: no requestor for a masked secret selection.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType != nil, maskedAndTouchingSecret { return nil }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Share menu.
    override func orderFrontSharingServicePicker(_ sender: Any?) {
        if maskedAndTouchingSecret { NSSound.beep(); return }
        super.orderFrontSharingServicePicker(sender)
    }

    /// Look Up (force click, ⌃⌘D) on a masked secret.
    override func quickLook(with event: NSEvent) {
        if let c = coordinator, !c.model.keyRevealed {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if c.scan.secretLines[c.scan.line(forOffset: index)] != nil { NSSound.beep(); return }
        }
        super.quickLook(with: event)
    }

    override func showDefinition(for attrString: NSAttributedString?, at textBaseline: NSPoint) {
        if maskedAndTouchingSecret { NSSound.beep(); return }
        super.showDefinition(for: attrString, at: textBaseline)
    }

    /// Find would confirm a key's characters by matching them: off while keys are masked.
    override func performTextFinderAction(_ sender: Any?) {
        if maskedWithSecrets { NSSound.beep(); return }
        super.performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) || item.action == #selector(performFindPanelAction(_:)) {
            if maskedWithSecrets { return false }
        }
        return super.validateUserInterfaceItem(item)
    }

    override func performFindPanelAction(_ sender: Any?) {
        if maskedWithSecrets { NSSound.beep(); return }
        super.performFindPanelAction(sender)
    }

    // MARK: Accessibility (masked while hidden)

    private var axText: String { coordinator?.maskedString() ?? String(repeating: "•", count: (string as NSString).length) }

    override func accessibilityValue() -> String? { axText }

    override func accessibilityString(for range: NSRange) -> String? {
        let ns = axText as NSString
        guard range.location + range.length <= ns.length else { return nil }
        return ns.substring(with: range)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }

    override func accessibilitySelectedText() -> String? { accessibilityString(for: selectedRange()) }

}

/// Line numbers and issue markers (✕ error, ⚠ warning) from the TextKit 2 layout fragments in view
/// (not NSLayoutManager, not from the top of the document; UI-M14).
final class GutterView: NSRulerView {
    weak var coordinator: ConfigTextView.Coordinator?

    init(scrollView: NSScrollView, coordinator: ConfigTextView.Coordinator) {
        self.coordinator = coordinator
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let c = coordinator, let tv = c.textView, let tlm = tv.textLayoutManager,
              let storage = tlm.textContentManager as? NSTextContentStorage else { return }
        (NSColor(named: "lp.sunken") ?? .textBackgroundColor).setFill()
        bounds.fill()
        let a = c.model.analysis
        let inSync = a.lineStarts == c.scan.lineStarts
        var worst: [Int: EditorIssue.Severity] = [:]
        if inSync {
            for issue in a.issues {
                guard let l = issue.line, issue.severity >= .warning else { continue }
                worst[l - 1] = max(worst[l - 1] ?? .info, issue.severity)
            }
        }
        let font = LPTypography.nsFont(size: 10)
        let numberColor = NSColor(named: "lp.syntaxComment") ?? .secondaryLabelColor
        let visible = tv.visibleRect
        let origin = tv.textContainerOrigin
        // Start at the first fragment in view.
        let startPoint = CGPoint(x: 0, y: max(visible.minY - origin.y, 0))
        let start = tlm.textLayoutFragment(for: startPoint)?.rangeInElement.location ?? tlm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > visible.maxY { return false }
            let offset = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            let line = c.scan.line(forOffset: offset)
            let y = self.convert(NSPoint(x: 0, y: frame.minY + origin.y), from: tv).y
            if let sev = worst[line] {
                // Shape differs per severity: octagon for errors, triangle for warnings.
                let name = sev == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
                let tint = NSColor(named: sev == .error ? "lp.critical" : "lp.attention") ?? .systemRed
                if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .bold).applying(.init(paletteColors: [tint]))) {
                    img.draw(in: NSRect(x: self.ruleThickness - img.size.width - 6, y: y + 2, width: img.size.width, height: img.size.height))
                }
            } else {
                let s = NSAttributedString(string: "\(line + 1)", attributes: [.font: font, .foregroundColor: numberColor])
                s.draw(at: NSPoint(x: self.ruleThickness - s.size().width - 6, y: y + 1))
            }
            return true
        }
    }
}
