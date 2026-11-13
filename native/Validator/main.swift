// LockPlusValidator entry point (PLAN-2.0.2 §1.6). Top-level code here is MainActor-isolated in Swift 6, so this file
// contains NO closure literals (lint `lp_main_swift_closure`): everything runs in ValidatorProcess.swift.
ValidatorProcess.run()
