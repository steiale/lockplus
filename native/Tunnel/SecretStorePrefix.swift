import TunnelEngine

/// The extension's secret store (DESIGN §6.3): the System keychain, with the service prefix chosen here because
/// package code can't see target conditions (§2.2). Apple Development-signed builds (Debug, FaultInjection:
/// LP_DEV_SIGNING) use `…tunnel.dev.`: their designated requirement differs from Release, so the items could not be
/// shared anyway, and the prefixes keep the two from colliding.
enum TunnelSecretStore {
    #if LP_DEV_SIGNING
    static let servicePrefix = SystemKeychainSecretStore.devPrefix
    #else
    static let servicePrefix = SystemKeychainSecretStore.releasePrefix
    #endif

    /// `backend`: `SecItemBackend()` in production, a fake in tests (no default, round 6 Fable r6 N3).
    static func make(backend: any GenericPasswordBackend) -> SystemKeychainSecretStore {
        SystemKeychainSecretStore(backend: backend, servicePrefix: servicePrefix)
    }
}
