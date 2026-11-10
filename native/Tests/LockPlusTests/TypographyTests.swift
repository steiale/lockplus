import AppKit
import SwiftUI
import Testing
@testable import LockPlus

/// UI-CONCEPT §2.4: one typography definition, SF Mono everywhere.
@MainActor @Suite("Typography (§2.4)")
struct TypographyTests {
    @Test("The design is the system monospaced one")
    func design() {
        #expect(LPTypography.design == .monospaced)
    }

    @Test("AppKit fonts are fixed-pitch in every weight the UI uses", arguments: [NSFont.Weight.regular, .medium, .semibold, .bold])
    func nsFonts(weight: NSFont.Weight) {
        #expect(LPTypography.nsFont(size: 13, weight: weight).isFixedPitch)
        #expect(LPTypography.menuFont(weight: weight).isFixedPitch)
        #expect(LPTypography.nsFont(textStyle: .caption1, weight: weight).isFixedPitch)
    }
}
