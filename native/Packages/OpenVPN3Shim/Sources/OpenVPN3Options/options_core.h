// Plain C++ boundary for the options-only module.
#pragma once
#include <string>
#include <vector>

namespace lpopt {
struct ParseResult {
    bool ok = false;
    std::string error;
    std::vector<std::string> names;
};
ParseResult parse(const std::string &profile);
/// Zeroes a string's buffer (no OpenSSL in this module) before it is released.
void cleanse(std::string &s);
}
