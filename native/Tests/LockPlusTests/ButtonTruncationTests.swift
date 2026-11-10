import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LockPlus

/// Buttons never truncate (owner review 2026-11-09, German "Trennen und Int…"): action rows use `ActionRow`
/// (one row when everything fits, else stacked). The source rules (no button title carries a line limit or a
/// truncation mode; the hero and the strips use ActionRow / StripActionsLayout) are checked by `Tools/build/lint.sh`:
/// the hosted test app can't read a checkout on an external volume (it blocks in open()).
@Suite("Buttons never truncate")
struct ButtonTruncationTests {
    /// Behaviour, not source text: three long actions sit in one row when they fit and stack (taller, narrower) when not.
    @MainActor @Test("ActionRow stacks three long actions in a narrow container and keeps one row in a wide one")
    func actionRowStacksWhenNarrow() {
        func size(_ width: CGFloat) -> CGSize {
            let v = NSHostingController(rootView: ActionRow {
                Button("Disconnect and Restore Internet") {}
                Button("Pause") {}
                Button("Details…") {}
            })
            return v.sizeThatFits(in: CGSize(width: width, height: 2000))
        }
        let wide = size(900), narrow = size(300)
        #expect(narrow.height > wide.height * 2, "narrow \(narrow) wide \(wide): the row did not stack")
        #expect(narrow.width <= 300.5, "narrow \(narrow): a title overflows its container")
    }
}
