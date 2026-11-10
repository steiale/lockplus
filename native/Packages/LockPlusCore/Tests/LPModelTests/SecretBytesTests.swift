import Foundation
import LPModel
import Testing

@Suite struct SecretBytesTests {
    @Test func neverPrints() {
        let s = SecretBytes(copying: Data("hunter2".utf8))
        #expect("\(s)" == "<redacted>")
        #expect(String(reflecting: s) == "<redacted>")
        #expect(Mirror(reflecting: s).children.isEmpty)
        #expect(s.count == 7 && s.copyBytes() == Array("hunter2".utf8))
        #expect(s.constantTimeEquals(SecretBytes(copying: Data("hunter2".utf8))))
        #expect(!s.constantTimeEquals(SecretBytes(copying: Data("hunter3".utf8))))
    }

    private struct Boom: Error {}

    /// The throwing initializer used to free the buffer itself and then again in `deinit`.
    @Test func throwingInitializerFreesOnce() {
        for _ in 0..<64 {
            #expect(throws: Boom.self) {
                _ = try SecretBytes(count: 32) { buf in
                    buf.initializeMemory(as: UInt8.self, repeating: 0xAA)
                    throw Boom()
                }
            }
        }
        let ok = try? SecretBytes(count: 4) { $0.initializeMemory(as: UInt8.self, repeating: 7) }
        #expect(ok?.copyBytes() == [7, 7, 7, 7])
    }
}
