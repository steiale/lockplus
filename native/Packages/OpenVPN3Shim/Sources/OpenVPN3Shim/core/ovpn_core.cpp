// The single openvpn3 translation unit. Includes ovpncli.cpp (the whole core) after defining the
// build switches in Package.swift (USE_TUN_BUILDER, USE_OPENSSL, ASIO_STANDALONE, ...).
// Compile-time proof of the build settings (swift build -v no longer prints clang lines).
static_assert(__cplusplus >= 202002L, "C++20 required");
#if !defined(USE_TUN_BUILDER) || !defined(USE_OPENSSL) || !defined(ASIO_STANDALONE)
#error "USE_TUN_BUILDER / USE_OPENSSL / ASIO_STANDALONE must be set by Package.swift"
#endif
#if !__cpp_exceptions || !__cpp_rtti
#error "exceptions and RTTI must be on"
#endif
// DESIGN §8.1 banned defines: none of them may reach the core.
#if defined(OPENVPN_COMMAND_AGENT) || defined(OPENVPN_EXTERNAL_TUN_FACTORY) || defined(OPENVPN_FORCE_TUN_NULL) ||   \
    defined(OPENVPN_DEBUG_VERBOSE_ERRORS) || defined(OPENVPN_SHOW_SESSION_TOKEN) || defined(OPENVPN_PACKET_LOG) ||   \
    defined(OPENVPN_DEBUG_CLIPROTO)
#error "banned openvpn3 define (DESIGN §8.1)"
#endif

#include <client/ovpncli.cpp>
#include <openvpn/auth/cr.hpp>
#include <openvpn/common/stop.hpp>
#include <openssl/opensslv.h>
static_assert(OPENSSL_VERSION_MAJOR == 3 && OPENSSL_VERSION_MINOR == 5, "OpenSSL 3.5 headers from the XCFramework");

#include <openssl/crypto.h>
#include <mutex>
#include <sstream>
#include "ovpn_core.h"

namespace {
using namespace openvpn;

std::once_flag crypto_once;

/// openvpn3 keeps the data-channel algorithm table process-wide; every ClientOptions construction (a session's
/// connect_setup) holds this mutex while it rewrites the table (Vendor/patches/openvpn3/0001). Everything else here
/// that reads the table while another thread may construct ClientOptions (eval_config, ParseClientConfig::parse,
/// the diagnostics read) holds it too. Never held around a ClientOptions construction (not recursive).
std::unique_lock<std::mutex> lock_process_globals()
{
    return std::unique_lock<std::mutex>(ClientOptions::process_globals_mutex());
}

// OpenVPNClient subclass with stub TunBuilder methods (no NE, no connect).
class StubClient final : public ClientAPI::OpenVPNClient {
  public:
    std::vector<std::string> lines;

    // TunBuilderBase stubs: accept everything, never establish.
    bool tun_builder_new() override { return true; }
    bool tun_builder_set_remote_address(const std::string &, bool) override { return true; }
    bool tun_builder_add_address(const std::string &, int, const std::string &, bool, bool) override { return true; }
    bool tun_builder_reroute_gw(bool, bool, unsigned int) override { return true; }
    bool tun_builder_add_route(const std::string &, int, int, bool) override { return true; }
    bool tun_builder_exclude_route(const std::string &, int, int, bool) override { return true; }
    bool tun_builder_set_dns_options(const DnsOptions &) override { return true; }
    bool tun_builder_set_mtu(int) override { return true; }
    bool tun_builder_set_session_name(const std::string &) override { return true; }
    int tun_builder_establish() override { return -1; }
    void tun_builder_teardown(bool) override {}

    // ClientAPI pure virtuals
    bool pause_on_connection_timeout() override { return false; }
    void event(const ClientAPI::Event &) override {}
    void acc_event(const ClientAPI::AppCustomControlMessageEvent &) override {}
    void log(const ClientAPI::LogInfo &li) override { lines.push_back(li.text); }
    void external_pki_cert_request(ClientAPI::ExternalPKICertRequest &r) override { r.error = true; r.errorText = "no EPKI"; }
    void external_pki_sign_request(ClientAPI::ExternalPKISignRequest &r) override { r.error = true; r.errorText = "no EPKI"; }
};

class NullEvents : public ClientEvent::Queue {
  public:
    void add_event(ClientEvent::Base::Ptr) override {}
};

/// openvpn3's client profile limits (ParseClientConfig::parse), for [6] and the concat lookup.
OptionList::Limits profile_limits()
{
    return OptionList::Limits("profile is too large", ProfileParseLimits::MAX_PROFILE_SIZE, ProfileParseLimits::OPT_OVERHEAD,
                              ProfileParseLimits::TERM_OVERHEAD, ProfileParseLimits::MAX_LINE_SIZE,
                              ProfileParseLimits::MAX_DIRECTIVE_SIZE);
}

/// The connect-path client: TunBuilder callbacks collect an lp::TunPlan; establish hands it to the callbacks.
class LPClient final : public ClientAPI::OpenVPNClient {
  public:
    // `stop` is owned by Session::Impl and declared before this client there (D73-3); only a pointer here.
    LPClient(lp::SessionCallbacks *cb, Stop *stop) : cb_(cb), stop_(stop) {}

    Stop *get_async_stop() override { return stop_; }

    // §8.4: NE exempts provider sockets from the tunnel; nothing to bind here.
    bool socket_protect(openvpn_io::detail::socket_type, std::string, bool) override { return true; }
    bool pause_on_connection_timeout() override { return false; }
    bool remote_override_enabled() override { return false; }

    // ---- TunBuilder ----
    bool tun_builder_new() override
    {
        plan_ = lp::TunPlan();
        return true;
    }
    bool tun_builder_set_layer(int layer) override { return layer == 3; }
    bool tun_builder_set_remote_address(const std::string &a, bool) override
    {
        plan_.remoteAddress = a;
        return true;
    }
    bool tun_builder_add_address(const std::string &a, int pl, const std::string &, bool v6, bool) override
    {
        plan_.addresses.push_back({a, pl, v6});
        return true;
    }
    bool tun_builder_set_route_metric_default(int) override { return true; }
    // The redirect-gateway flags (block-local, bypass-dhcp, …) are not applied: NE and the §10 policy own LAN access
    // and the server route (review M4: the unused flags were deleted rather than half-applied).
    bool tun_builder_reroute_gw(bool v4, bool v6, unsigned int) override
    {
        plan_.rerouteIPv4 = v4;
        plan_.rerouteIPv6 = v6;
        return true;
    }
    bool tun_builder_add_route(const std::string &a, int pl, int, bool v6) override
    {
        plan_.routes.push_back({a, pl, v6});
        return true;
    }
    bool tun_builder_exclude_route(const std::string &a, int pl, int, bool v6) override
    {
        plan_.excludedRoutes.push_back({a, pl, v6});
        return true;
    }
    bool tun_builder_set_dns_options(const DnsOptions &d) override
    {
        plan_.dnsServers.clear();
        for (const auto &kv : d.servers)
        {
            lp::TunDnsServer s;
            s.priority = kv.first;
            for (const auto &a : kv.second.addresses)
                if (!a.address.empty())
                    s.addresses.push_back(a.address);
            for (const auto &dom : kv.second.domains)
                s.resolveDomains.push_back(dom.domain);
            plan_.dnsServers.push_back(std::move(s));
        }
        plan_.searchDomains.clear();
        for (const auto &dom : d.search_domains)
            plan_.searchDomains.push_back(dom.domain);
        return true;
    }
    bool tun_builder_set_mtu(int mtu) override
    {
        plan_.mtu = mtu;
        return true;
    }
    bool tun_builder_set_session_name(const std::string &) override { return true; }
    // §8.5: proxy settings and WINS are not applied in v2.0 (connect note in the log).
    bool tun_builder_add_proxy_bypass(const std::string &) override { return true; }
    bool tun_builder_set_proxy_auto_config_url(const std::string &) override { return note("proxy auto-config"); }
    bool tun_builder_set_proxy_http(const std::string &, int) override { return note("HTTP proxy"); }
    bool tun_builder_set_proxy_https(const std::string &, int) override { return note("HTTPS proxy"); }
    bool tun_builder_add_wins_server(const std::string &) override { return true; }
    bool tun_builder_set_allow_local_dns(bool) override { return true; }
    bool tun_builder_set_allow_family(int af, bool allow) override
    {
        if (af == AF_INET)
            plan_.allowIPv4 = allow;
        else if (af == AF_INET6)
            plan_.allowIPv6 = allow;
        return true;
    }
    int tun_builder_establish() override { return cb_ ? cb_->on_establish(plan_) : -1; }
    // tun_builder_teardown: openvpn3's default (no-op). NE owns the utun; nothing to undo here.

    // ---- ClientAPI ----
    void event(const ClientAPI::Event &ev) override
    {
        if (ev.name == "CONNECTED")
        {
            // connection_info() is gated to the connect thread in openvpn3 (§7.7): cache it here.
            ClientAPI::ConnectionInfo ci = connection_info();
            std::lock_guard<std::mutex> g(info_mu_);
            info_.defined = ci.defined;
            info_.serverIp = ci.serverIp;
            info_.vpnIp4 = ci.vpnIp4;
            info_.vpnIp6 = ci.vpnIp6;
        }
        if (cb_)
            cb_->on_event(ev.name, ev.info, ev.error, ev.fatal);
    }
    void acc_event(const ClientAPI::AppCustomControlMessageEvent &) override {}
    void log(const ClientAPI::LogInfo &li) override
    {
        if (!cb_)
            return;
        std::istringstream is(li.text);
        std::string line;
        while (std::getline(is, line))
            if (!line.empty())
                cb_->on_log(line);
    }
    void external_pki_cert_request(ClientAPI::ExternalPKICertRequest &r) override
    {
        r.error = true;
        r.errorText = "external PKI not supported";
    }
    void external_pki_sign_request(ClientAPI::ExternalPKISignRequest &r) override
    {
        r.error = true;
        r.errorText = "external PKI not supported";
    }

    lp::SessionInfo cached_info()
    {
        std::lock_guard<std::mutex> g(info_mu_);
        return info_;
    }

  private:
    bool note(const char *what)
    {
        if (cb_)
            cb_->on_log(std::string("note: the server's ") + what + " setting is not applied");
        return true;
    }

    lp::SessionCallbacks *cb_;
    Stop *stop_;
    lp::TunPlan plan_;
    std::mutex info_mu_;
    lp::SessionInfo info_;
};

/// The profile's static-challenge format: true when its third argument is "concat" (§8.4; openvpn3 never reads it).
bool static_challenge_concat(const std::string &content)
{
    try
    {
        OptionList::Limits lim = profile_limits();
        OptionList opts;
        opts.parse_from_config(content, &lim);
        for (const auto &o : opts)
            if (o.size() >= 4 && o.ref(0) == "static-challenge")
                return o.ref(3) == "concat";
    }
    catch (const std::exception &)
    {
    }
    return false;
}

} // namespace

namespace lp {

void init_crypto()
{
    // S13 A3: never auto-load openssl.cnf (I/O, and a sandbox read). Must precede any other OpenSSL call.
    std::call_once(crypto_once, [] { OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG, nullptr); });
}

void cleanse(std::string &s)
{
    if (!s.empty())
        OPENSSL_cleanse(s.data(), s.size());
    s.clear();
}

ProbeResult probe(const std::string &profile, bool disableClientCert)
{
    init_crypto();
    ProbeResult r;
    ClientAPI::Config cfg;
    cfg.content = profile;
    cfg.info = true;
    cfg.compressionMode = "asym";
    cfg.dhcpSearchDomainsAsSplitDomains = false;
    cfg.disableClientCert = disableClientCert;
    cfg.enableLegacyAlgorithms = false; // never (§8.6)

    // [7a] eval_config on a real OpenVPNClient subclass (parse only).
    StubClient client;
    ClientAPI::EvalConfig eval;
    {
        auto g = lock_process_globals();
        eval = client.eval_config(cfg);
    }
    r.evalError = eval.error;
    r.evalMessage = eval.message;
    r.externalPki = eval.externalPki;
    r.autologin = eval.autologin;
    r.staticChallenge = eval.staticChallenge;
    r.staticChallengeEcho = eval.staticChallengeEcho;
    r.privateKeyPasswordRequired = eval.privateKeyPasswordRequired;
    r.remote = eval.remoteHost + ":" + eval.remotePort + "/" + eval.remoteProto;
    if (eval.error)
    {
        cleanse(cfg.content);
        return r;
    }

    // [7b] Construct ClientOptions (runs handle_unused_options) without connect(): same steps as
    // OpenVPNClient::connect_setup up to `new ClientOptions`, with a log context on this thread.
    Log::Context logctx(&client);
    try
    {
        OptionList options;
        OptionList::KeyValueList kvl;
        {
            auto g = lock_process_globals();
            ParseClientConfig::parse(cfg.content, &kvl, options);
        }

        ClientOptions::Config cc;
        cc.clientconf.import_client_settings(cfg);
        cc.clientconf.disableClientCert = disableClientCert;
        cc.cli_stats.reset(new openvpn::SessionStats());
        cc.cli_events.reset(new NullEvents());
        cc.proto_context_options.reset(new ProtoContextCompressionOptions());
        cc.proto_context_options->parse_compression_mode(cfg.compressionMode);
        cc.builder = &client;
        // Vendor/patches/openvpn3/0001: the extension evaluates profiles while a session runs in the same process.
        // An evaluation must not rewrite openvpn3's process-wide data-channel algorithm table or SSL log level: it
        // would race the session's reads, and its defaults (AEAD only) would drop a live Acme-style session's CBC
        // cipher from IV_CIPHERS and legal_dc_cipher on its next handshake.
        cc.apply_process_globals = false;
        ClientOptions::Ptr co = new ClientOptions(options, cc);
        r.optionsOk = true;
    }
    catch (const std::exception &e)
    {
        r.optionsError = e.what();
    }
    cleanse(cfg.content);
    r.log = client.lines;
    return r;
}

bool parse_options(const std::string &text, std::vector<std::vector<std::string>> &out, std::string &err)
{
    init_crypto();
    out.clear();
    try
    {
        OptionList::Limits lim = profile_limits();
        OptionList opts;
        opts.parse_from_config(text, &lim);
        for (const auto &o : opts)
        {
            std::vector<std::string> v;
            v.reserve(o.size());
            for (size_t i = 0; i < o.size(); ++i)
                v.push_back(o.ref(i));
            out.push_back(std::move(v));
        }
        return true;
    }
    catch (const std::exception &e)
    {
        err = e.what();
        out.clear();
        return false;
    }
}

bool parse_dynamic_challenge(const std::string &cookie, std::string &challenge, bool &echo, bool &responseRequired,
                             std::string &username)
{
    init_crypto();
    // ChallengeResponse decodes the username with openvpn3's global base64 object, which exists only while an
    // InitProcess::Init is alive (every OpenVPNClient holds one; this static helper may run without a client).
    InitProcess::Init init;
    ClientAPI::DynamicChallenge dc;
    if (!ClientAPI::OpenVPNClientHelper::parse_dynamic_challenge(cookie, dc))
        return false;
    challenge = dc.challenge;
    echo = dc.echo;
    responseRequired = dc.responseRequired;
    try
    {
        ChallengeResponse cr(cookie);
        username = cr.get_username();
    }
    catch (const std::exception &)
    {
        username.clear();
    }
    cleanse(dc.stateID);
    return true;
}

std::string platform()
{
    init_crypto();
    return ClientAPI::OpenVPNClientHelper::platform();
}
std::string copyright_first_line()
{
    init_crypto();
    std::string c = ClientAPI::OpenVPNClientHelper::copyright();
    return c.substr(0, c.find('\n'));
}
std::string openssl_version()
{
    init_crypto();
    return OpenSSL_version(OPENSSL_VERSION);
}

std::vector<std::string> data_channel_ciphers()
{
    init_crypto();
    std::vector<std::string> out;
    auto g = lock_process_globals();
    CryptoAlgs::for_each([&out](CryptoAlgs::Type, const CryptoAlgs::Alg &alg) -> bool {
        if (!alg.dc_cipher())
            return false;
        out.emplace_back(alg.name());
        return true;
    });
    return out;
}

// ---- Session ----------------------------------------------------------------------------------------------------

struct Session::Impl {
    Stop stop;       // declared FIRST: destroyed after `client` (D73-3, Conflicts as)
    LPClient client;
    bool concat = false;
    explicit Impl(SessionCallbacks *cb) : client(cb, &stop) {}
};

Session::Session(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}
Session::~Session() = default;

Session *Session::create(SessionConfig &in, SessionCallbacks *callbacks, std::string &err)
{
    init_crypto();
    ClientAPI::Config cc;
    std::unique_ptr<Impl> impl;
    try
    {
        impl = std::make_unique<Impl>(callbacks);
        impl->concat = static_challenge_concat(in.content);
        cc.content = in.content;
        cc.guiVersion = in.guiVersion;
        cc.platformVersion = in.platformVersion;
        cc.disableClientCert = in.disableClientCert;
        cc.enableNonPreferredDCAlgorithms = in.enableNonPreferredDCAlgorithms;
        cc.enableLegacyAlgorithms = false; // never: §8.6, D7-1
        cc.privateKeyPassword = in.privateKeyPassword;
        cc.proxyUsername = in.proxyUsername;
        cc.proxyPassword = in.proxyPassword;
        // OVPNFixedConfig, verbatim
        cc.ssoMethods = in.ssoMethods;
        cc.retryOnAuthFailed = in.retryOnAuthFailed;
        cc.autologinSessions = in.autologinSessions;
        cc.info = in.info;
        cc.echo = in.echo;
        cc.connTimeout = in.connTimeout;
        cc.tunPersist = in.tunPersist;
        cc.googleDnsFallback = in.googleDnsFallback;
        cc.dhcpSearchDomainsAsSplitDomains = in.dhcpSearchDomainsAsSplitDomains;
        cc.compressionMode = in.compressionMode;
        cc.sslDebugLevel = in.sslDebugLevel;

        ClientAPI::EvalConfig ev;
        {
            auto g = lock_process_globals();
            ev = impl->client.eval_config(cc);
        }
        if (ev.error)
        {
            err = "eval_config: " + ev.message;
            impl.reset();
        }
    }
    catch (const std::exception &e)
    {
        err = std::string("exception: ") + e.what();
        impl.reset();
    }
    cleanse(cc.content);
    cleanse(cc.privateKeyPassword);
    cleanse(cc.proxyUsername);
    cleanse(cc.proxyPassword);
    cleanse(in.content);
    cleanse(in.privateKeyPassword);
    cleanse(in.proxyUsername);
    cleanse(in.proxyPassword);
    if (!impl)
        return nullptr;
    return new Session(std::move(impl));
}

bool Session::provide_creds(std::string &username, std::string &password, std::string &response, std::string &cookie)
{
    ClientAPI::ProvideCreds pc;
    bool ok = false;
    try
    {
        pc.username = username;
        pc.password = password;
        pc.response = response;
        pc.dynamicChallengeCookie = cookie;
        if (impl_->concat && !pc.response.empty() && pc.dynamicChallengeCookie.empty())
        {
            pc.password += pc.response; // Go combineStaticChallenge semantics (§8.4 SC row)
            cleanse(pc.response);
        }
        ok = !impl_->client.provide_creds(pc).error;
    }
    catch (const std::exception &)
    {
        ok = false;
    }
    cleanse(pc.username);
    cleanse(pc.password);
    cleanse(pc.response);
    cleanse(pc.dynamicChallengeCookie);
    cleanse(username);
    cleanse(password);
    cleanse(response);
    cleanse(cookie);
    return ok;
}

SessionStatus Session::connect()
{
    SessionStatus out;
    try
    {
        ClientAPI::Status st = impl_->client.connect();
        out.error = st.error;
        out.status = st.status;
        out.message = st.message;
    }
    catch (const std::exception &e)
    {
        out.error = true;
        out.status = "exception";
        out.message = e.what();
    }
    return out;
}

void Session::stop()
{
    impl_->stop.stop();   // sticky: honoured even before connect() finished its setup (ref/openvpn3 §1 item 2)
    impl_->client.stop();
}

void Session::reconnect(int seconds) { impl_->client.reconnect(seconds); }
void Session::pause(const std::string &reason) { impl_->client.pause(reason); }
void Session::resume() { impl_->client.resume(); }

SessionStats Session::stats()
{
    ClientAPI::TransportStats ts = impl_->client.transport_stats();
    SessionStats s;
    s.bytesIn = ts.bytesIn;
    s.bytesOut = ts.bytesOut;
    s.lastPacketReceived = ts.lastPacketReceived;
    return s;
}

SessionInfo Session::info() { return impl_->client.cached_info(); }

} // namespace lp
