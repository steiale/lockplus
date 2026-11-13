import Foundation
import Testing
@testable import LockPlus

/// Item 4 (2.0.2, D-4): the app's Info.plist (Bundle.main in the hosted test).
@MainActor @Suite struct InfoPlistTests {
    private struct DocType { let name: String; let rank: String; let types: [String]; let role: String }

    private var docTypes: [DocType] {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        return raw.map { DocType(name: $0["CFBundleTypeName"] as? String ?? "", rank: $0["LSHandlerRank"] as? String ?? "",
                                 types: $0["LSItemContentTypes"] as? [String] ?? [], role: $0["CFBundleTypeRole"] as? String ?? "") }
    }

    @Test func documentTypesDeclared() throws {
        let types = docTypes
        #expect(types.count == 3)
        let ovpn = try #require(types.first { $0.types == ["net.openvpn.ovpn"] })
        let conf = try #require(types.first { $0.types == ["com.wireguard.config.quick"] })
        let zip = try #require(types.first { $0.types == ["public.zip-archive"] })
        #expect(ovpn.rank == "Default")                      // D-4
        #expect(conf.rank == "Alternate")                    // never the default for nginx configs
        #expect(zip.rank == "Alternate")                     // never the default for zips
        #expect(types.allSatisfy { $0.role == "Viewer" })    // opening never edits or saves in place
    }

    @Test func onlyOVPNIsDefault() {
        #expect(docTypes.filter { $0.rank == "Default" }.flatMap(\.types) == ["net.openvpn.ovpn"])
    }

    @Test func importedTypeDeclarationsAndNoExports() throws {
        let imported = Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]] ?? []
        func ext(_ id: String) -> [String]? {
            let d = imported.first { $0["UTTypeIdentifier"] as? String == id }
            return (d?["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String]
        }
        #expect(imported.count == 2)
        #expect(ext("net.openvpn.ovpn") == ["ovpn"])
        #expect(ext("com.wireguard.config.quick") == ["conf"])
        #expect(Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") == nil)   // we own neither format
    }
}
