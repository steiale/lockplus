import Foundation
import SwiftUI

/// `main.swift`'s only call. Keeps top-level code free of closures (D73-11).
enum AppEntry {
    @MainActor static func run() {
        if CommandLine.arguments.contains(HeadlessResume.argument) { HeadlessResume.main() }
        LockPlusApp.main()
    }
}
