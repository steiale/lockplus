// openvpn3 OptionList parser (header-only), compiled without OpenSSL or asio.
static_assert(__cplusplus >= 202002L, "C++20 required");
// The options module never logs: show_unused_options() is not called here, so the log macros it references are
// defined as no-ops (openvpn3 expects the including TU to choose a log backend).
#define OPENVPN_LOG(args)
#define OPENVPN_LOG_NTNL(args)
#define OPENVPN_LOG_STRING(str)
#include <openvpn/io/io.hpp>
#include <openvpn/common/options.hpp>
#include "options_core.h"

namespace lpopt {
ParseResult parse(const std::string &profile)
{
    ParseResult r;
    try
    {
        openvpn::OptionList list = openvpn::OptionList::parse_from_config_static(profile, nullptr);
        for (const auto &o : list)
            if (!o.empty())
                r.names.push_back(o.ref(0));
        r.ok = true;
    }
    catch (const std::exception &e)
    {
        r.error = e.what();
    }
    return r;
}

void cleanse(std::string &s)
{
    volatile char *p = s.data();
    for (size_t i = 0; i < s.size(); ++i)
        p[i] = 0;
    s.clear();
}
}
