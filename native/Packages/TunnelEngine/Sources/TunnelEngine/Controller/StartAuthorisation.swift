import Foundation
import LPWire

/// 2.0.2 item 3 (PLAN-2.0.2 §3): who may start a profile. Pure value logic, no I/O, no clock of its own: the controller
/// passes `now` and persists `authorised`.

/// The record of a start the controller admitted, tied to the profile's session rather than to its revision or its
/// current rules (round 1, Fable H1): NE replays a session's start options when it restarts it, and that restart must be
/// honoured for as long as the session may still be restarted. Persisted in `state.plist`; the nonce is not secret from
/// the extension, and only NE and the owner's app ever hold it.
///
/// Round 2 (Fable L4): both facts are kept side by side. `nonce`: the last armed start's (NE replays it in the options of
/// a restart of that start); `unattended`: an unattended (on-demand) admission happened since, whose restart arrives
/// with no options. Neither overwrites the other. The nonce goes only with the user's stop, a removed configuration,
/// the profile's removal or a wipe (and with the end of a session NE never restarts: one without a kill switch, round 1
/// L5); `unattended` also with the owner's revoke.
/// Round 2 (Codex r2 #2): `killSwitch` says the session it belongs to had a kill switch (at admission, or by its live
/// flags when it ended). NE restarts such a session by itself after a crash, `noNetwork` or `providerFailed`, so its
/// record is never revoked: only the user's stop, a removal, a wipe or a reboot end it.
/// Round 2 (Fable L2): `boot` is the boot session (`kern.bootsessionuuid`) the record was made in. NE never replays a
/// session across a reboot, so a record of another boot admits nothing and is dropped when the controller loads.
public struct AuthorisedStart: Codable, Sendable, Equatable {
    public var nonce: UUID?
    public var at: Date
    public var unattended: Bool
    public var boot: String?
    public var killSwitch: Bool
    public init(nonce: UUID?, at: Date, unattended: Bool? = nil, boot: String? = BootSession.current(), killSwitch: Bool = false) {
        self.nonce = nonce; self.at = at; self.unattended = unattended ?? (nonce == nil); self.boot = boot; self.killSwitch = killSwitch
    }
    private enum CodingKeys: String, CodingKey { case nonce, at, unattended, boot, killSwitch }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        nonce = try c.decodeIfPresent(UUID.self, forKey: .nonce)
        at = try c.decode(Date.self, forKey: .at)
        unattended = try c.decodeIfPresent(Bool.self, forKey: .unattended) ?? (nonce == nil)
        boot = try c.decodeIfPresent(String.self, forKey: .boot)
        killSwitch = try c.decodeIfPresent(Bool.self, forKey: .killSwitch) ?? true      // unknown: never revocable
    }
    /// An unattended admission stands: honours a non-manual restart of the same profile.
    public var isUnattended: Bool { unattended }
}

public enum StartAuthorisationDecision: Sendable, Equatable {
    /// A live arm with this start's nonce was consumed; the controller records the authorisation once it admits the start.
    case armed(UUID)
    /// NE restarting the session the persisted authorisation names: the same nonce, or (a non-manual start) an unattended
    /// admission of the same profile that no user stop has ended since. Carries the record it matched (round 2, L1: put
    /// back at admission if a revoke removed it while the start waited in the guard).
    case replay(AuthorisedStart)
    /// No `lp.manual`, and the owner turned on Auto-Connect for the profile. The controller records it (nil nonce) once
    /// it admits the start.
    case unattended
    case refused
}

/// Arms made over XPC by the profile owner's own connection (kernel-reported uid). In memory only: an arm older than
/// `ttl` is worthless, and an extension restart between arm and start just makes the app's start fail once.
struct StartArms: Sendable, Equatable {
    static let ttl: TimeInterval = ArmLifetime.seconds
    static let maxPerOwner = 8

    private struct Arm: Sendable, Equatable { var key: ProfileKey; var nonce: UUID; var at: Date }
    private var arms: [Arm] = []          // oldest first

    var count: Int { arms.count }
    func count(forOwner uid: uid_t) -> Int { arms.lazy.filter { $0.key.ownerUID == uid }.count }

    /// A live arm is younger than `ttl` and not from the future (a wall clock set back invalidates it).
    private static func live(_ a: Arm, _ now: Date) -> Bool {
        let age = now.timeIntervalSince(a.at)
        return age >= 0 && age < ttl
    }

    /// Records the arm; returns when it expires. A second arm of the same profile replaces the first (one pending start
    /// per profile); the owner's oldest arm goes past `maxPerOwner`.
    mutating func arm(_ key: ProfileKey, nonce: UUID, now: Date) -> Date {
        arms.removeAll { !Self.live($0, now) || $0.key == key }
        arms.append(Arm(key: key, nonce: nonce, at: now))
        while arms.lazy.filter({ $0.key.ownerUID == key.ownerUID }).count > Self.maxPerOwner,
              let i = arms.firstIndex(where: { $0.key.ownerUID == key.ownerUID }) {
            arms.remove(at: i)
        }
        return now.addingTimeInterval(Self.ttl)
    }

    /// The table of PLAN-2.0.2 §3.1. Consumes the arm of an armed start (one use). A manual start whose nonce matches
    /// neither an arm nor the persisted authorisation leaves every arm alone (a wrong guess must not burn the owner's).
    mutating func decide(_ key: ProfileKey, options: StartOptions, hasOnDemandRules: Bool,
                         authorised: [ProfileKey: AuthorisedStart], now: Date) -> StartAuthorisationDecision {
        arms.removeAll { !Self.live($0, now) }
        guard options.isManual else {
            if hasOnDemandRules { return .unattended }
            // Round 1 (Fable H1b): the on-demand rules went away while the unattended session ran (another Auto-Connect
            // profile, Stay Connected off); NE's restart of THAT session arrives with no options and is still honoured.
            // An armed session's record never admits a non-manual start (round 1 L8: `scutil --nc start` stays refused).
            if let rec = authorised[key], rec.isUnattended { return .replay(rec) }
            return .refused
        }
        guard let nonce = options.nonce else { return .refused }
        if let i = arms.firstIndex(where: { $0.key == key && $0.nonce == nonce }) {
            arms.remove(at: i)
            return .armed(nonce)
        }
        if let rec = authorised[key], rec.nonce == nonce { return .replay(rec) }
        return .refused
    }

    mutating func drop(_ key: ProfileKey) { arms.removeAll { $0.key == key } }
    mutating func drop(ownerUID: uid_t) { arms.removeAll { $0.key.ownerUID == ownerUID } }
}

/// Round 2 (Fable L2): the boot session the controller runs in (`kern.bootsessionuuid`). nil if it can't be read; records
/// then carry nil and compare equal among themselves (the pre-round-2 behaviour).
public enum BootSession {
    public static func current() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size <= 128 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return s.isEmpty ? nil : s
    }
}
