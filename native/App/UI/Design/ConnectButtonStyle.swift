import SwiftUI

/// The signature Connect button (UI-CONCEPT §2.2, DESIGN §11.8): a `ButtonStyle` on a real `Button`, so its
/// accessibility traits come for free. One sage per appearance, the same as the sidebar selection (owner 2026-11-10):
/// light is `lp.connectFill` `#a9d9c6` with ink `#001e28`, dark is `#4a6e62` with `#eaf4ee`. Native bezel radius, not a pill.
struct ConnectButtonStyle: ButtonStyle {
    var prominence: Prominence = .large
    enum Prominence { case regular, large }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(prominence == .large ? .body.weight(.semibold) : .body)
            .foregroundStyle(Color.lp.connectLabel)
            .padding(.horizontal, prominence == .large ? 18 : 12)
            .padding(.vertical, prominence == .large ? 7 : 4)
            .frame(minHeight: 24)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.lp.connectFill)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.lp.stroke, lineWidth: contrast == .increased ? 1 : 0)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

extension ButtonStyle where Self == ConnectButtonStyle {
    static var lpConnect: ConnectButtonStyle { ConnectButtonStyle() }
    static var lpConnectRegular: ConnectButtonStyle { ConnectButtonStyle(prominence: .regular) }
}
