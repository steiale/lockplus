import Foundation
import Testing
@testable import LockPlus

@Suite struct AppServicesTests {
    @Test func payloadDigestIsHexSHA256() {
        #expect(PayloadDigest.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
