import Foundation
import Testing
@testable import LPParsing
import LPModel

/// DESIGN §15.1 "Differential (L-OVPN-1)" 3: the Go 2.7 tokenizer vs the Swift port on the shared vectors.
/// Vectors: GoVectors.generated.swift (native/Tools/fuzz/govectors/export.sh). Equality is required.
struct GoVectorFile: Decodable {
    struct Directive: Decodable, Equatable {
        var n: String
        var a: [String]
        var l: Int
        var i: Bool
        var b: String
        var c: [Directive]
    }
    struct Config: Decodable {
        var name: String
        var input: String
        var parseErr: String?
        var ds: [Directive]?
        var validate: String?
    }
    struct Line: Decodable {
        var input: String
        var tokens: [String]?
        var err: String?
    }
    var lines: [Line]
    var configs: [Config]

    static let shared: GoVectorFile = {
        let data = Data(base64Encoded: GoVectors.base64JSON)!
        return try! JSONDecoder().decode(GoVectorFile.self, from: data)
    }()
}

extension GoVectorFile.Directive {
    init(_ d: OVPNDirective) {
        self.init(n: d.name, a: d.args, l: d.line, i: d.isInline, b: d.body, c: d.children.map(Self.init))
    }
}

@Suite("Go tokenizer differential")
struct GoDifferentialTests {
    static let configNames = GoVectorFile.shared.configs.map(\.name)

    @Test func vectorCounts() {
        #expect(GoVectorFile.shared.lines.count >= 50)
        #expect(GoVectorFile.shared.configs.count >= 250)
    }

    @Test(arguments: 0..<GoVectorFile.shared.lines.count)
    func parseLineMatchesGo(_ index: Int) throws {
        let v = GoVectorFile.shared.lines[index]
        let input = String(decoding: Data(base64Encoded: v.input)!, as: UTF8.self)
        switch OVPNTokenizer.parseLine(input) {
        case .success(let toks):
            #expect(v.err == nil, "Go errors (\(v.err ?? "")) but Swift accepts \(input.debugDescription)")
            #expect(toks == (v.tokens ?? []), "tokens differ for \(input.debugDescription)")
        case .failure(let e):
            #expect(v.err == e.message, "error differs for \(input.debugDescription)")
        }
    }

    @Test(arguments: configNames)
    func parseConfigMatchesGo(_ name: String) throws {
        let v = try #require(GoVectorFile.shared.configs.first { $0.name == name })
        let bytes = Data(base64Encoded: v.input)!
        switch OVPNTokenizer.parse(bytes) {
        case .success(let ds):
            #expect(v.parseErr == nil, "Go fails (\(v.parseErr ?? "")) but Swift parses")
            #expect(ds.map(GoVectorFile.Directive.init) == (v.ds ?? []))
        case .failure(let e):
            #expect(v.parseErr == e.message)
        }
    }

    @Test(arguments: configNames)
    func validateMatchesGo(_ name: String) throws {
        let v = try #require(GoVectorFile.shared.configs.first { $0.name == name })
        let bytes = Data(base64Encoded: v.input)!
        #expect(OVPNAllowlist.goValidate(bytes) == v.validate)
    }
}
