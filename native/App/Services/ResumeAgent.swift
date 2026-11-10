import Foundation
import os
import ServiceManagement

/// The resume agent's registration state (`SMAppService.Status`, Sendable copy).
enum ResumeAgentStatus: Sendable, Equatable { case notRegistered, enabled, requiresApproval, notFound }

/// DESIGN §10.4 (N3): `Contents/Library/LaunchAgents/io.github.steiale.lockplus.mac.resume.plist`, registered with
/// `SMAppService.agent(plistName:)` for the duration of each pause, so a pause never outlives a crashed app. The agent
/// runs `LockPlus --resume-protection` (`HeadlessResume`) every minute (`StartCalendarInterval {}`) and at load.
/// `SMResumeAgent` is the real one; preview mode and tests use `InertResumeAgent`.
@MainActor protocol ResumeAgentControlling: AnyObject {
    var status: ResumeAgentStatus { get }
    /// Registers; `.requiresApproval` when Login Items needs the user's approval (code 1), the previous launch-time
    /// behaviour then applies ("If LockPlus quits unexpectedly, protection resumes the next time it opens").
    @discardableResult func register() -> ResumeAgentStatus
    /// `unregister(completionHandler:)`; job-not-found counts as done. From inside the agent this KILLS the process.
    func unregister() async
}

enum ResumeAgentPlist {
    static let label = "io.github.steiale.lockplus.mac.resume"
    static let name = label + ".plist"
}

@MainActor final class SMResumeAgent: ResumeAgentControlling {
    private let service = SMAppService.agent(plistName: ResumeAgentPlist.name)
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "lifecycle")

    var status: ResumeAgentStatus { Self.map(service.status) }

    static func map(_ s: SMAppService.Status) -> ResumeAgentStatus {
        switch s {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }

    @discardableResult func register() -> ResumeAgentStatus {
        do { try service.register() } catch {
            let code = (error as NSError).code
            // kSMErrorAlreadyRegistered = success; code 1 ("Operation not permitted") = approval pending (§10.4).
            if code == kSMErrorAlreadyRegistered { return .enabled }
            log.notice("resume agent register: \(code, privacy: .public)")
            if code == 1 { return .requiresApproval }
        }
        return status
    }

    func unregister() async {
        let service = self.service
        let code: Int? = await withCheckedContinuation { (k: CheckedContinuation<Int?, Never>) in
            service.unregister { @Sendable error in k.resume(returning: error.map { ($0 as NSError).code }) }
        }
        if let code, code != kSMErrorJobNotFound { log.notice("resume agent unregister: \(code, privacy: .public)") }
    }
}

/// Preview mode and tests: records, registers nothing.
@MainActor final class InertResumeAgent: ResumeAgentControlling {
    private(set) var calls: [String] = []
    var status: ResumeAgentStatus = .notRegistered
    var registerResult: ResumeAgentStatus = .enabled

    @discardableResult func register() -> ResumeAgentStatus {
        calls.append("register")
        status = registerResult
        return status
    }

    func unregister() async {
        calls.append("unregister")
        status = .notRegistered
    }
}

/// §10.4 launch rule (C12), pure: SMAppService requires re-registering an agent whose executable changed, and our
/// `BundleProgram` is the main binary every update replaces.
enum ResumeAgentLaunchPolicy {
    enum Action: Sendable, Equatable { case none, unregister, reregister }

    static func action(pausedUntil: Date?, agentBuild: String?, currentBuild: String, status: ResumeAgentStatus, now: Date) -> Action {
        guard let pausedUntil, pausedUntil > now else {
            // Not paused (an expired pause resumes and unregisters on its own path): drop a stale registration.
            return pausedUntil == nil && status != .notRegistered ? .unregister : .none
        }
        // `.notFound` (the user switched it off in Login Items) is respected, never undone.
        return agentBuild != currentBuild || status == .notRegistered ? .reregister : .none
    }
}
