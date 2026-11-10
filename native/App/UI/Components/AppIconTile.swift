import SwiftUI

/// The app icon inside the UI (welcome, empty library, no selection, About). Same composition as `AppIcon.icon`:
/// the padlock layer (`AppMark`, scale 1.2) and its shadow (`AppMarkShadow`) over `lp.iconTile`, off-white in light
/// and navy in dark, so the tile follows the window's appearance like the Dock icon follows the system's.
/// `landed: false` lifts the padlock off the tile and hides its shadow; animating it to `true` sets the lock down
/// (welcome, §7.1). Decorative: hidden from VoiceOver.
struct AppIconTile: View {
    var size: CGFloat = 96
    var landed = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        let layer = size * 1.2
        ZStack {
            ZStack {
                shape.fill(Color.lp.iconTile)
                // Icon Composer's automatic gradient: a touch lighter at the top.
                shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                Image("AppMarkShadow").resizable().interpolation(.high)   // the original's soft drop shadow
                    .frame(width: layer, height: layer)
                    .scaleEffect(landed ? 1 : 0.9)
                    .opacity(landed ? 1 : 0)
            }
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.lp.hairline, lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.18), radius: size * 0.04, y: size * 0.02)
            // Not clipped: while it is lifted the padlock may rise above the tile's edge.
            Image("AppMark").resizable().interpolation(.high)
                .frame(width: layer, height: layer)
                .scaleEffect(landed ? 1 : 1.08)
                .offset(y: landed ? 0 : -size * 0.1)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview("App icon tile") {
    HStack(spacing: 24) {
        AppIconTile(size: 64)
        AppIconTile(size: 96)
        AppIconTile(size: 128, landed: false)
    }
    .padding(32)
}
