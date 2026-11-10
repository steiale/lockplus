// ObjC++ wrapper. Sees only the plain C++ header core/ovpn_core.h, so AssertMacros and ObjC keywords never meet
// asio/openvpn3 (S14 compile-unit layout, DESIGN §2.2).
#import "OpenVPN3Shim.h"
#include "core/ovpn_core.h"
#include <memory>

static NSString *S(const std::string &s)
{
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}
static NSString *_Nullable SOpt(const std::string &s) { return s.empty() ? nil : S(s); }
static std::string Str(NSString *s) { return s ? std::string(s.UTF8String ?: "") : std::string(); }
static std::string Bytes(const void *b, size_t n) { return (b && n) ? std::string(static_cast<const char *>(b), n) : std::string(); }
static NSArray<NSString *> *Strings(const std::vector<std::string> &v)
{
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:v.size()];
    for (const auto &s : v) [a addObject:S(s)];
    return a;
}

// MARK: - Core

@implementation LPOpenVPN3Core
+ (void)initializeCrypto { lp::init_crypto(); }
+ (NSString *)corePlatform { return S(lp::platform()); }
+ (NSString *)coreCopyright { return S(lp::copyright_first_line()); }
+ (NSString *)opensslVersion { return S(lp::openssl_version()); }
+ (NSArray<NSString *> *)dataChannelCiphers { return Strings(lp::data_channel_ciphers()); }
@end

// MARK: - Evaluation, options, dynamic challenge

@interface LPOpenVPN3Evaluation ()
- (instancetype)initWithProbe:(const lp::ProbeResult &)r;
@end
@implementation LPOpenVPN3Evaluation
- (instancetype)initWithProbe:(const lp::ProbeResult &)r
{
    if ((self = [super init]))
    {
        _evalError = r.evalError; _evalMessage = S(r.evalMessage); _remote = S(r.remote); _externalPki = r.externalPki;
        _autologin = r.autologin; _staticChallenge = S(r.staticChallenge); _staticChallengeEcho = r.staticChallengeEcho;
        _privateKeyPasswordRequired = r.privateKeyPasswordRequired; _optionsOk = r.optionsOk;
        _optionsError = S(r.optionsError); _log = Strings(r.log);
    }
    return self;
}
@end

@interface LPOpenVPN3DynamicChallenge ()
- (instancetype)initWithChallenge:(NSString *)c echo:(BOOL)e responseRequired:(BOOL)r username:(nullable NSString *)u;
@end
@implementation LPOpenVPN3DynamicChallenge
- (instancetype)initWithChallenge:(NSString *)c echo:(BOOL)e responseRequired:(BOOL)r username:(nullable NSString *)u
{
    if ((self = [super init])) { _challenge = [c copy]; _echo = e; _responseRequired = r; _username = [u copy]; }
    return self;
}
@end

@implementation LPOpenVPN3Profile
+ (LPOpenVPN3Evaluation *)evaluateBytes:(const void *)bytes length:(size_t)length disableClientCert:(BOOL)disableClientCert
{
    std::string text = Bytes(bytes, length);
    lp::ProbeResult r = lp::probe(text, disableClientCert);
    lp::cleanse(text);
    return [[LPOpenVPN3Evaluation alloc] initWithProbe:r];
}

+ (nullable NSArray<NSArray<NSString *> *> *)parseOptionsBytes:(const void *)bytes length:(size_t)length
                                                         error:(NSString *_Nullable *_Nullable)error
{
    std::string text = Bytes(bytes, length);
    std::vector<std::vector<std::string>> out;
    std::string err;
    bool ok = lp::parse_options(text, out, err);
    lp::cleanse(text);
    if (!ok)
    {
        if (error) *error = S(err);
        return nil;
    }
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:out.size()];
    for (auto &o : out)
    {
        [a addObject:Strings(o)];
        for (auto &s : o) lp::cleanse(s);
    }
    return a;
}

+ (nullable LPOpenVPN3DynamicChallenge *)parseDynamicChallengeBytes:(const void *)bytes length:(size_t)length
{
    std::string cookie = Bytes(bytes, length), challenge, username;
    bool echo = false, required = false;
    bool ok = lp::parse_dynamic_challenge(cookie, challenge, echo, required, username);
    lp::cleanse(cookie);
    if (!ok) return nil;
    return [[LPOpenVPN3DynamicChallenge alloc] initWithChallenge:S(challenge) echo:echo responseRequired:required
                                                        username:SOpt(username)];
}
@end

// MARK: - Config and credentials (secrets in C++ storage, cleansed)

@implementation LPOpenVPN3SessionConfig {
  @public
    std::string _content, _privateKeyPassword, _proxyUsername, _proxyPassword;
}
- (instancetype)init
{
    if ((self = [super init]))
    {
        _guiVersion = @"LockPlus"; _platformVersion = @""; _ssoMethods = @""; _compressionMode = @"asym";
        _disableClientCert = YES; _autologinSessions = YES; _info = YES;
    }
    return self;
}
- (void)setSecret:(LPOpenVPN3Secret)slot bytes:(const void *)bytes length:(size_t)length
{
    std::string *dst = nullptr;
    switch (slot)
    {
    case LPOpenVPN3SecretProfile: dst = &_content; break;
    case LPOpenVPN3SecretPrivateKeyPassword: dst = &_privateKeyPassword; break;
    case LPOpenVPN3SecretProxyUsername: dst = &_proxyUsername; break;
    case LPOpenVPN3SecretProxyPassword: dst = &_proxyPassword; break;
    default: return;
    }
    lp::cleanse(*dst);
    *dst = Bytes(bytes, length);
}
- (void)dealloc
{
    lp::cleanse(_content); lp::cleanse(_privateKeyPassword); lp::cleanse(_proxyUsername); lp::cleanse(_proxyPassword);
}
@end

@implementation LPOpenVPN3Credentials {
  @public
    std::string _username, _password, _response, _cookie;
}
- (void)setSecret:(LPOpenVPN3Secret)slot bytes:(const void *)bytes length:(size_t)length
{
    std::string *dst = nullptr;
    switch (slot)
    {
    case LPOpenVPN3SecretUsername: dst = &_username; break;
    case LPOpenVPN3SecretPassword: dst = &_password; break;
    case LPOpenVPN3SecretResponse: dst = &_response; break;
    case LPOpenVPN3SecretDynamicChallengeCookie: dst = &_cookie; break;
    default: return;
    }
    lp::cleanse(*dst);
    *dst = Bytes(bytes, length);
}
- (void)dealloc { lp::cleanse(_username); lp::cleanse(_password); lp::cleanse(_response); lp::cleanse(_cookie); }
@end

// MARK: - Plan objects

@interface LPOpenVPN3Route ()
- (instancetype)initWithRoute:(const lp::TunRoute &)r;
@end
@implementation LPOpenVPN3Route
- (instancetype)initWithRoute:(const lp::TunRoute &)r
{
    if ((self = [super init])) { _address = S(r.address); _prefix = r.prefix; _ipv6 = r.ipv6; }
    return self;
}
@end

@interface LPOpenVPN3DNSServer ()
- (instancetype)initWithServer:(const lp::TunDnsServer &)s;
@end
@implementation LPOpenVPN3DNSServer
- (instancetype)initWithServer:(const lp::TunDnsServer &)s
{
    if ((self = [super init])) { _priority = s.priority; _addresses = Strings(s.addresses); _resolveDomains = Strings(s.resolveDomains); }
    return self;
}
@end

static NSArray<LPOpenVPN3Route *> *Routes(const std::vector<lp::TunRoute> &v)
{
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:v.size()];
    for (const auto &r : v) [a addObject:[[LPOpenVPN3Route alloc] initWithRoute:r]];
    return a;
}

@interface LPOpenVPN3TunPlan ()
- (instancetype)initWithPlan:(const lp::TunPlan &)p;
@end
@implementation LPOpenVPN3TunPlan
- (instancetype)initWithPlan:(const lp::TunPlan &)p
{
    if ((self = [super init]))
    {
        _addresses = Routes(p.addresses); _routes = Routes(p.routes); _excludedRoutes = Routes(p.excludedRoutes);
        _rerouteIPv4 = p.rerouteIPv4; _rerouteIPv6 = p.rerouteIPv6;
        NSMutableArray *dns = [NSMutableArray arrayWithCapacity:p.dnsServers.size()];
        for (const auto &s : p.dnsServers) [dns addObject:[[LPOpenVPN3DNSServer alloc] initWithServer:s]];
        _dnsServers = dns; _searchDomains = Strings(p.searchDomains);
        _allowIPv4 = p.allowIPv4; _allowIPv6 = p.allowIPv6; _remoteAddress = S(p.remoteAddress); _mtu = p.mtu;
    }
    return self;
}
@end

@interface LPOpenVPN3ConnectionInfo ()
- (instancetype)initWithInfo:(const lp::SessionInfo &)i;
@end
@implementation LPOpenVPN3ConnectionInfo
- (instancetype)initWithInfo:(const lp::SessionInfo &)i
{
    if ((self = [super init])) { _serverIP = S(i.serverIp); _vpnIPv4 = SOpt(i.vpnIp4); _vpnIPv6 = SOpt(i.vpnIp6); }
    return self;
}
@end

@interface LPOpenVPN3Status ()
- (instancetype)initWithStatus:(const lp::SessionStatus &)s;
@end
@implementation LPOpenVPN3Status
- (instancetype)initWithStatus:(const lp::SessionStatus &)s
{
    if ((self = [super init])) { _error = s.error; _status = S(s.status); _message = S(s.message); }
    return self;
}
@end

// MARK: - Session

namespace {
/// C++ callbacks → the ObjC delegate (strong; the Swift side holds its adapter weakly). Connect thread only.
struct DelegateCallbacks final : lp::SessionCallbacks {
    id<LPOpenVPN3SessionDelegate> delegate;
    void on_event(const std::string &name, const std::string &info, bool error, bool fatal) override
    {
        @autoreleasepool { [delegate sessionEvent:S(name) info:S(info) error:error fatal:fatal]; }
    }
    void on_log(const std::string &line) override
    {
        @autoreleasepool { [delegate sessionLog:S(line)]; }
    }
    int on_establish(const lp::TunPlan &plan) override
    {
        @autoreleasepool { return [delegate sessionEstablish:[[LPOpenVPN3TunPlan alloc] initWithPlan:plan]]; }
    }
};
} // namespace

@implementation LPOpenVPN3Session {
    // Declaration order matters for destruction: the session (client + its Stop) goes before the callbacks object
    // it points to. C++ ivars are destroyed in reverse declaration order.
    std::unique_ptr<DelegateCallbacks> _callbacks;
    std::unique_ptr<lp::Session> _session;
}

- (nullable instancetype)initWithConfig:(LPOpenVPN3SessionConfig *)config
                               delegate:(id<LPOpenVPN3SessionDelegate>)delegate
                                  error:(NSString *_Nullable *_Nullable)error
{
    if (!(self = [super init])) return nil;
    lp::init_crypto();
    _callbacks = std::make_unique<DelegateCallbacks>();
    _callbacks->delegate = delegate;
    lp::SessionConfig c;
    c.content = config->_content; lp::cleanse(config->_content);
    c.privateKeyPassword = config->_privateKeyPassword; lp::cleanse(config->_privateKeyPassword);
    c.proxyUsername = config->_proxyUsername; lp::cleanse(config->_proxyUsername);
    c.proxyPassword = config->_proxyPassword; lp::cleanse(config->_proxyPassword);
    c.disableClientCert = config.disableClientCert;
    c.enableNonPreferredDCAlgorithms = config.enableNonPreferredDCAlgorithms;
    c.guiVersion = Str(config.guiVersion);
    c.platformVersion = Str(config.platformVersion);
    c.ssoMethods = Str(config.ssoMethods);
    c.retryOnAuthFailed = config.retryOnAuthFailed;
    c.autologinSessions = config.autologinSessions;
    c.info = config.info;
    c.echo = config.echo;
    c.connTimeout = (int)config.connTimeout;
    c.tunPersist = config.tunPersist;
    c.googleDnsFallback = config.googleDnsFallback;
    c.dhcpSearchDomainsAsSplitDomains = config.dhcpSearchDomainsAsSplitDomains;
    c.compressionMode = Str(config.compressionMode);
    c.sslDebugLevel = (int)config.sslDebugLevel;
    std::string err;
    lp::Session *s = lp::Session::create(c, _callbacks.get(), err);
    if (!s)
    {
        if (error) *error = S(err);
        return nil;
    }
    _session.reset(s);
    return self;
}

- (BOOL)provideCredentials:(LPOpenVPN3Credentials *)credentials
{
    return _session->provide_creds(credentials->_username, credentials->_password, credentials->_response, credentials->_cookie);
}

- (LPOpenVPN3Status *)connect { return [[LPOpenVPN3Status alloc] initWithStatus:_session->connect()]; }
- (void)stop { _session->stop(); }
- (void)reconnect:(NSInteger)seconds { _session->reconnect((int)seconds); }
- (void)pause:(NSString *)reason { _session->pause(Str(reason)); }
- (void)resume { _session->resume(); }

- (LPOpenVPN3TransportStats)transportStats
{
    lp::SessionStats s = _session->stats();
    return LPOpenVPN3TransportStats{s.bytesIn, s.bytesOut, s.lastPacketReceived};
}

- (nullable LPOpenVPN3ConnectionInfo *)connectionInfo
{
    lp::SessionInfo i = _session->info();
    return i.defined ? [[LPOpenVPN3ConnectionInfo alloc] initWithInfo:i] : nil;
}
@end
