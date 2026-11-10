// LockPlusTunnel entry point (DESIGN §5.1). Top-level code here is MainActor-isolated in Swift 6 (D73-11), so this
// file contains NO closure literals (SwiftLint `lp_main_swift_closure`): everything runs in nonisolated functions in
// TunnelProcess.swift; C-level hooks live in ASanSupport.c.
import Foundation

// "first light" before startSystemExtensionMode, so a debugger attached by name as root sees the process (forum 725805).
TunnelProcess.logFirstLight()
// autoreleasepool { NEProvider.startSystemExtensionMode(); listener.start() }
TunnelProcess.startSystemExtensionMode()
dispatchMain()
