import SwiftUI

/// The one form layout (UI-CONCEPT §6.5 form rule): labels in one left-aligned column, every field starting on the
/// same leading edge and filling the rest of the width. Used by the sign-in sheets and any label-plus-field group
/// that isn't a system `Form`. A row that spans both columns (server text, hints) uses `.gridCellColumns(2)`.
struct LPFormGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) { content }
    }
}

/// A label cell and a field cell in an `LPFormGrid`.
struct LPFormRow<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field
    var body: some View {
        GridRow {
            Text(label).gridColumnAlignment(.leading)
            field.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The one text field look outside system `Form`s (UI-CONCEPT §2.2, draft 8.3, review S-4.04): a fill close to the
/// window background (`lp.field`) with a soft 1 pt border (`lp.fieldBorder`) instead of the bezel's grey block. The
/// focus ring is the accent colour, 2 pt; Increase Contrast uses the ≥ 3:1 `lp.stroke` border. Works for `TextField`
/// and `SecureField`; apply it after the caller's own `.focused`.
struct LPField: ViewModifier {
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        content
            .textFieldStyle(.plain)
            // Pre-release review M6: `.plain` still draws the system focus ring tight around the text; ours is the
            // only ring. The caller's `.focused($focus, equals:)` keeps moving focus (FocusRingTests).
            .focusEffectDisabled()
            .focused($focused)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.lp.field, in: shape)
            .overlay {
                shape.strokeBorder(focused ? Color.lp.accentText : (contrast == .increased ? Color.lp.stroke : Color.lp.fieldBorder),
                                   lineWidth: focused ? 2 : 1)
            }
    }
}

extension View {
    func lpField() -> some View { modifier(LPField()) }
}
