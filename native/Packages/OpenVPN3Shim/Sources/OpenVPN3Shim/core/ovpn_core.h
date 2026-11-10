// Plain C++ boundary between the openvpn3 TU and the ObjC++ wrapper (keeps AssertMacros/ObjC
// keywords away from asio/openvpn3 headers).
#pragma once
#include <memory>
#include <string>
#include <vector>

namespace lp {

/// OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG), once per process (S13 A3, DESIGN §8.1 [7b]). Every entry point
/// below calls it before touching openvpn3 or OpenSSL; the wrapper also calls it first.
void init_crypto();

struct ProbeResult {
    bool evalError = false;
    std::string evalMessage;
    std::string remote;            // host:port/proto from eval_config
    bool externalPki = false;
    bool autologin = false;        // [7a] EvalConfig fields the import needs (§8.4)
    std::string staticChallenge;
    bool staticChallengeEcho = false;
    bool privateKeyPasswordRequired = false;
    bool optionsOk = false;        // [7b]: ClientOptions constructed without throwing
    std::string optionsError;
    std::vector<std::string> log;  // captured OPENVPN_LOG lines during [7b]
};
/// [7a] + [7b]. `disableClientCert` mirrors the shim rule (cert+key absent ⇒ true, §8.4).
ProbeResult probe(const std::string &profile, bool disableClientCert);

/// [6]: openvpn3's OptionList over the text with the client's profile limits (ParseClientConfig). Each option is
/// [name] + args, or [name, body] for an inline block (body lines each followed by "\n"). false + err on refusal.
bool parse_options(const std::string &text, std::vector<std::vector<std::string>> &out, std::string &err);

/// OpenVPNClientHelper::parse_dynamic_challenge + ChallengeResponse(cookie).get_username().
bool parse_dynamic_challenge(const std::string &cookie, std::string &challenge, bool &echo, bool &responseRequired,
                             std::string &username);

std::string platform();
std::string copyright_first_line();
std::string openssl_version();
/// The data-channel ciphers the process currently allows (what IV_CIPHERS advertises), under ClientOptions'
/// process-globals mutex. The last session's connect_setup sets them; a profile evaluation never does.
std::vector<std::string> data_channel_ciphers();

// ---- connect path (DESIGN §7.3, §8.4) -----------------------------------------------------------------------

struct TunRoute {
    std::string address;
    int prefix = 0;
    bool ipv6 = false;
};
struct TunDnsServer {
    int priority = 0;
    std::vector<std::string> addresses;   // address only; a port is dropped (NE has no per-server port, §8.5)
    std::vector<std::string> resolveDomains;
};
/// What the TunBuilder callbacks of one tun_builder_new … establish sequence delivered (ref/openvpn3 §4.2).
struct TunPlan {
    std::vector<TunRoute> addresses, routes, excludedRoutes;
    bool rerouteIPv4 = false, rerouteIPv6 = false;
    std::vector<TunDnsServer> dnsServers;  // empty: tun_builder_set_dns_options never called
    std::vector<std::string> searchDomains;
    bool allowIPv4 = true, allowIPv6 = true;
    std::string remoteAddress;
    int mtu = 0;                           // 0: not set
};

/// Called on the connect thread, synchronously (§7.3).
class SessionCallbacks {
  public:
    virtual ~SessionCallbacks() = default;
    virtual void on_event(const std::string &name, const std::string &info, bool error, bool fatal) = 0;
    virtual void on_log(const std::string &line) = 0;
    /// Returns an fd openvpn3 will own and close (a dup of NE's utun fd, or a socketpair end), or -1.
    virtual int on_establish(const TunPlan &plan) = 0;
};

/// Per-profile values plus OVPNFixedConfig, applied verbatim (§8.4). enableLegacyAlgorithms has no field: the
/// session always sets it to false (§8.6, D7-1). Secret strings are cleansed by the session after use.
struct SessionConfig {
    std::string content;                   // canonical profile text (secret: keys)
    bool disableClientCert = true;
    bool enableNonPreferredDCAlgorithms = false;
    std::string privateKeyPassword;        // secret
    std::string proxyUsername, proxyPassword;  // secret
    std::string guiVersion;
    std::string platformVersion;
    // OVPNFixedConfig
    std::string ssoMethods;
    bool retryOnAuthFailed = false;
    bool autologinSessions = true;
    bool info = true;
    bool echo = false;
    int connTimeout = 0;
    bool tunPersist = false;
    bool googleDnsFallback = false;
    bool dhcpSearchDomainsAsSplitDomains = false;
    std::string compressionMode = "asym";
    int sslDebugLevel = 0;
};

struct SessionStatus {
    bool error = false;
    std::string status, message;
};
struct SessionStats {
    long long bytesIn = 0, bytesOut = 0;
    int lastPacketReceived = -1;           // binary ms; -1 undefined
};
struct SessionInfo {
    bool defined = false;
    std::string serverIp, vpnIp4, vpnIp6;
};

/// One openvpn3 client for one attempt (single use, ref/openvpn3 §1 item 1). The openvpn::Stop returned by
/// get_async_stop() lives in Session's private Impl, declared BEFORE the client, so it is destroyed after it
/// (D73-3: a Stop member of the client subclass aborts every teardown).
class Session {
  public:
    /// eval_config on a new client. nullptr on an EvalConfig error or exception (err = message, no profile text).
    /// Cleanses cfg's secret strings before returning.
    static Session *create(SessionConfig &cfg, SessionCallbacks *callbacks, std::string &err);
    ~Session();
    Session(const Session &) = delete;
    Session &operator=(const Session &) = delete;

    /// provide_creds. Applies the static-challenge `concat` format (password = pw + response, response = "") when
    /// the profile's static-challenge has a third argument "concat" (§8.4 SC row). Cleanses all four inputs.
    bool provide_creds(std::string &username, std::string &password, std::string &response, std::string &cookie);
    /// Blocks until the session ends; every callback runs on the calling thread.
    SessionStatus connect();
    /// Stop::stop() on the session-owned async stop (sticky: safe before, during and after connect), then
    /// OpenVPNClient::stop().
    void stop();
    void reconnect(int seconds);
    void pause(const std::string &reason);
    void resume();
    SessionStats stats();
    /// Cached inside the CONNECTED event, on the connect thread (§7.7).
    SessionInfo info();

  private:
    struct Impl;
    explicit Session(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

/// OPENSSL_cleanse over a string's buffer, then clear().
void cleanse(std::string &s);

} // namespace lp
