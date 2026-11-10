#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The openvpn3 client core (DESIGN §2.2, §7.3, §8.1, §8.4), built with USE_TUN_BUILDER only.
/// Every entry point runs OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG) first.
@interface LPOpenVPN3Core : NSObject
@property (class, readonly) NSString *corePlatform;
@property (class, readonly) NSString *coreCopyright;
@property (class, readonly) NSString *opensslVersion;
/// The data-channel ciphers this process allows and advertises (IV_CIPHERS), as the last session's settings left
/// them (openvpn3 keeps them process-wide). A profile evaluation never changes them (Vendor/patches/openvpn3/0001).
@property (class, readonly) NSArray<NSString *> *dataChannelCiphers;
/// OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG), once per process. Call before anything else (the extension
/// does so at first light); every other entry point calls it too.
+ (void)initializeCrypto;
@end
// No NSString entry point takes profile text (review simplification 6): key-bearing text crosses only as raw bytes
// (LPOpenVPN3Profile, -setSecret:bytes:length:) and is cleansed in C++.

/// [7a]/[7b] result (§8.1). `log` holds openvpn3's captured log lines (categories, no profile text beyond what
/// openvpn3 prints).
@interface LPOpenVPN3Evaluation : NSObject
@property (readonly) BOOL evalError;
@property (readonly, copy) NSString *evalMessage;
/// host:port/proto from eval_config (not secret).
@property (readonly, copy) NSString *remote;
@property (readonly) BOOL externalPki;
@property (readonly) BOOL autologin;
@property (readonly, copy) NSString *staticChallenge;
@property (readonly) BOOL staticChallengeEcho;
@property (readonly) BOOL privateKeyPasswordRequired;
@property (readonly) BOOL optionsOk;
@property (readonly, copy) NSString *optionsError;
@property (readonly, copy) NSArray<NSString *> *log;
@end

/// A dynamic (CRV1) challenge parsed from its cookie.
@interface LPOpenVPN3DynamicChallenge : NSObject
@property (readonly, copy) NSString *challenge;
@property (readonly) BOOL echo;
@property (readonly) BOOL responseRequired;
@property (readonly, copy, nullable) NSString *username;
@end

/// Profile-level helpers that take secret text as raw bytes (copied into C++ storage, cleansed after use).
@interface LPOpenVPN3Profile : NSObject
/// [7a] + [7b] with Config.disableClientCert as given.
+ (LPOpenVPN3Evaluation *)evaluateBytes:(const void *)bytes length:(size_t)length disableClientCert:(BOOL)disableClientCert;
/// [6] openvpn3 OptionList with the client's profile limits: [name] + args per option, [name, body] for an inline
/// block (body lines each followed by "\n"). nil + *error on refusal.
+ (nullable NSArray<NSArray<NSString *> *> *)parseOptionsBytes:(const void *)bytes length:(size_t)length
                                                         error:(NSString *_Nullable *_Nullable)error;
/// OpenVPNClientHelper::parse_dynamic_challenge + ChallengeResponse(cookie).get_username(); nil if not CRV1.
+ (nullable LPOpenVPN3DynamicChallenge *)parseDynamicChallengeBytes:(const void *)bytes length:(size_t)length;
@end

/// Secret slots set with -setSecret:bytes:length: (copied into C++ std::string, cleansed when consumed or freed).
typedef NS_ENUM(NSInteger, LPOpenVPN3Secret) {
    LPOpenVPN3SecretProfile = 0,
    LPOpenVPN3SecretPrivateKeyPassword,
    LPOpenVPN3SecretProxyUsername,
    LPOpenVPN3SecretProxyPassword,
    LPOpenVPN3SecretUsername,
    LPOpenVPN3SecretPassword,
    LPOpenVPN3SecretResponse,
    LPOpenVPN3SecretDynamicChallengeCookie,
};

/// Session configuration: per-profile values plus OVPNFixedConfig, applied verbatim. There is no
/// enableLegacyAlgorithms: the shim always sets it to false (§8.6).
@interface LPOpenVPN3SessionConfig : NSObject
@property BOOL disableClientCert;
@property BOOL enableNonPreferredDCAlgorithms;
@property (copy) NSString *guiVersion;
@property (copy) NSString *platformVersion;
@property (copy) NSString *ssoMethods;
@property BOOL retryOnAuthFailed;
@property BOOL autologinSessions;
@property BOOL info;
@property BOOL echo;
@property NSInteger connTimeout;
@property BOOL tunPersist;
@property BOOL googleDnsFallback;
@property BOOL dhcpSearchDomainsAsSplitDomains;
@property (copy) NSString *compressionMode;
@property NSInteger sslDebugLevel;
/// Profile, PrivateKeyPassword, ProxyUsername, ProxyPassword.
- (void)setSecret:(LPOpenVPN3Secret)slot bytes:(const void *)bytes length:(size_t)length;
@end

/// ProvideCreds (§8.4). Username, Password, Response, DynamicChallengeCookie slots.
@interface LPOpenVPN3Credentials : NSObject
- (void)setSecret:(LPOpenVPN3Secret)slot bytes:(const void *)bytes length:(size_t)length;
@end

@interface LPOpenVPN3Route : NSObject
@property (readonly, copy) NSString *address;
@property (readonly) NSInteger prefix;
@property (readonly) BOOL ipv6;
@end

@interface LPOpenVPN3DNSServer : NSObject
@property (readonly) NSInteger priority;
@property (readonly, copy) NSArray<NSString *> *addresses;
@property (readonly, copy) NSArray<NSString *> *resolveDomains;
@end

/// One TunBuilder sequence (tun_builder_new … establish), raw.
@interface LPOpenVPN3TunPlan : NSObject
@property (readonly, copy) NSArray<LPOpenVPN3Route *> *addresses;
@property (readonly, copy) NSArray<LPOpenVPN3Route *> *routes;
@property (readonly, copy) NSArray<LPOpenVPN3Route *> *excludedRoutes;
@property (readonly) BOOL rerouteIPv4;
@property (readonly) BOOL rerouteIPv6;
@property (readonly, copy) NSArray<LPOpenVPN3DNSServer *> *dnsServers;
@property (readonly, copy) NSArray<NSString *> *searchDomains;
@property (readonly) BOOL allowIPv4;
@property (readonly) BOOL allowIPv6;
@property (readonly, copy) NSString *remoteAddress;
/// 0 = not set.
@property (readonly) NSInteger mtu;
@end

/// Called on the connect thread, synchronously. The session holds its delegate strongly.
@protocol LPOpenVPN3SessionDelegate <NSObject>
- (void)sessionEvent:(NSString *)name info:(NSString *)info error:(BOOL)error fatal:(BOOL)fatal;
- (void)sessionLog:(NSString *)line;
/// tun_builder_establish(): an fd openvpn3 will own and close (a dup or a socketpair end), or -1.
- (int32_t)sessionEstablish:(LPOpenVPN3TunPlan *)plan;
@end

typedef struct {
    int64_t bytesIn;
    int64_t bytesOut;
    /// Binary milliseconds since the last received packet; -1 undefined.
    int32_t lastPacketReceived;
} LPOpenVPN3TransportStats;

@interface LPOpenVPN3ConnectionInfo : NSObject
@property (readonly, copy) NSString *serverIP;
@property (readonly, copy, nullable) NSString *vpnIPv4;
@property (readonly, copy, nullable) NSString *vpnIPv6;
@end

@interface LPOpenVPN3Status : NSObject
@property (readonly) BOOL error;
@property (readonly, copy) NSString *status;
@property (readonly, copy) NSString *message;
@end

/// One openvpn3 OpenVPNClient for one attempt (single use). Owns the openvpn::Stop returned by get_async_stop(),
/// which outlives the client (D73-3). -stop is safe before, during and after -connect, from any thread.
/// The object must not be deallocated while -connect runs (the adapter releases it after its thread ended).
@interface LPOpenVPN3Session : NSObject
/// eval_config on a new client; nil + *error on an EvalConfig error. Consumes (cleanses) the config's secrets.
- (nullable instancetype)initWithConfig:(LPOpenVPN3SessionConfig *)config
                               delegate:(id<LPOpenVPN3SessionDelegate>)delegate
                                  error:(NSString *_Nullable *_Nullable)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// provide_creds (static-challenge `concat` applied); consumes (cleanses) the credentials' secrets.
- (BOOL)provideCredentials:(LPOpenVPN3Credentials *)credentials NS_SWIFT_NAME(provideCredentials(_:));
/// Blocks until the session ends; every delegate call runs on the calling thread.
- (LPOpenVPN3Status *)connect;
- (void)stop;
- (void)reconnect:(NSInteger)seconds;
- (void)pause:(NSString *)reason;
- (void)resume;
- (LPOpenVPN3TransportStats)transportStats;
/// Cached in the CONNECTED event; nil before.
- (nullable LPOpenVPN3ConnectionInfo *)connectionInfo;
@end

NS_ASSUME_NONNULL_END
