import Foundation
import LPParsing

/// The inputs of the 2.0.1 parity test (PLAN-2.0.2 §1.8): every OpenVPN corpus file and regression under
/// `Tools/fuzz/corpus`, each raw and (when it imports) as its canonical payload, plus crafted cases. This file is also
/// compiled by the one-off generator that ran the 2.0.1 `ExtensionPayloadValidator.evaluate` to write
/// `Golden/engine-check-2.0.1.json`; keep it free of this package's own types.
enum ParityFixtures {
    static let corpusRoot: URL = {
        if let o = ProcessInfo.processInfo.environment["LP_CORPUS_ROOT"] { return URL(fileURLWithPath: o) }
        // …/native/Packages/ProfileValidator/Tests/LPEngineCheckTests/ParityFixtures.swift → …/native/Tools/fuzz/corpus
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("Tools/fuzz/corpus")
    }()

    static let base = """
    client
    dev tun
    proto udp
    remote vpn.example.com 1194
    nobind
    remote-cert-tls server
    cipher AES-256-GCM
    auth SHA256
    auth-user-pass
    <ca>
    -----BEGIN CERTIFICATE-----
    MIIBbDCCARKgAwIBAgIUJ8Y7+O+L3jEhAVLSFYqAj8CM2BQwCgYIKoZIzj0EAwIw
    GzEZMBcGA1UEAwwQTG9ja1BsdXMgdGVzdCBDQTAgFw0yNjExMTEwNjMyMDlaGA8y
    MTI2MTAxODA2MzIwOVowGzEZMBcGA1UEAwwQTG9ja1BsdXMgdGVzdCBDQTBZMBMG
    ByqGSM49AgEGCCqGSM49AwEHA0IABFptPyLKSnCTh5tEfX/yjJaLiCczOPahj5/I
    6roxrxrg1pvXKwdAOuHXHd+ZtKtwihXyso0xVe83EUaRXkv/EU+jMjAwMB0GA1Ud
    DgQWBBTI4kFNVWgGhdSlnxcUEKX3pgfmNTAPBgNVHRMBAf8EBTADAQH/MAoGCCqG
    SM49BAMCA0gAMEUCIQCupO35BGc4t11rAYxoCYu2FQAP1ycjjRnaoRaxQmZKBQIg
    B33dbKTLXCQr3fi/p8/zWqC0qmdFFpmSFIarJZYVy+k=
    -----END CERTIFICATE-----
    </ca>

    """

    static let crafted: [(String, String)] = [
        ("no-iv", "no-iv\n"), ("push", "push \"route 10.0.0.0 255.0.0.0\"\n"), ("log", "log /x\n"),
        ("management", "management 127.0.0.1 7505\n"), ("foo-bar", "foo-bar 1\n"), ("secret", "secret /x\n"),
        ("pkcs12", "<pkcs12>\nMIIBAAAA\n</pkcs12>\n"), ("dh", "<dh>\nx\n</dh>\n"),
        ("dup-cipher", "cipher AES-256-GCM\ncipher AES-128-GCM\n"), ("dup-verb", "verb 3\nverb 4\n"),
        ("dup-persist", "persist-tun\npersist-tun\n"), ("socks", "setenv opt socks-proxy 127.0.0.1 1080\n"),
        ("route-gw", "route 10.0.0.0 255.0.0.0 10.8.0.5\n"), ("cipher-none", "cipher none\n"),
        ("cbc", "cipher AES-256-CBC\n"), ("static-challenge", "auth-user-pass\nstatic-challenge \"Enter OTP\" 1 concat\n"),
        ("autologin", "setenv opt autologin\n"), ("inline-creds", "<auth-user-pass>\nu\np\n</auth-user-pass>\n"),
        ("compress", "compress lz4\ncomp-lzo yes\n"), ("tls-crypt", "<tls-crypt>\nx\n</tls-crypt>\n"),
    ]

    /// (name, raw bytes). Canonical variants are added by the caller (they need the importer).
    static func raw() throws -> [(String, Data)] {
        var out: [(String, Data)] = []
        for dir in ["ovpn", "regressions"] {
            let d = corpusRoot.appendingPathComponent(dir)
            let kids = (FileManager.default.enumerator(atPath: d.path)?.allObjects as? [String] ?? []).sorted()
            for k in kids {
                var isDir: ObjCBool = false
                let p = d.appendingPathComponent(k)
                guard FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                out.append(("\(dir)/\(k)", try Data(contentsOf: p)))
            }
        }
        precondition(out.count > 250, "corpus not found at \(corpusRoot.path)")
        out.append(("base", Data(base.utf8)))
        for (n, t) in crafted { out.append(("crafted/\(n)", Data((base + t).utf8))) }
        out.append(("empty", Data()))
        return out
    }

    /// Raw inputs plus, for every input the importer canonicalises, the canonical text as its own input.
    static func all() throws -> [(String, Data)] {
        var out: [(String, Data)] = []
        for (n, d) in try raw() {
            out.append((n, d))
            if let c = OVPNImporter.importProfile(d).canonicalText { out.append((n + "#canonical", Data(c.utf8))) }
        }
        return out
    }
}
