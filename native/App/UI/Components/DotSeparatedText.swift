import SwiftUI

/// Text made of facts joined by " · " ("Protected · 0:01", "Home NAS · 203.0.113.20 · WireGuard"). A plain wrap
/// breaks after a dot and leaves it dangling ("Protected ·" / "0:01"); this view picks the first layout that fits:
/// one line; the last fact on its own line; one fact per line; else the ordinary wrap (`wrapLimit` lines, nil =
/// unlimited) for text without separators or with one fact too long for a line (owner review 2026-11-10).
struct DotSeparatedText: View {
    let text: String
    var wrapLimit: Int?

    var body: some View {
        let parts = text.components(separatedBy: " · ")
        ViewThatFits(in: .horizontal) {
            line(text)
            if parts.count > 2 {
                VStack(alignment: .leading, spacing: 1) {
                    line(parts.dropLast().joined(separator: " · "))
                    line(parts[parts.count - 1])
                }
            }
            if parts.count > 1 {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(parts.indices, id: \.self) { line(parts[$0]) }
                }
            }
            Text(text).lineLimit(wrapLimit).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(_ s: String) -> some View {
        Text(s).lineLimit(1).fixedSize()
    }
}
