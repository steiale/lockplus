#import "OpenVPN3Options.h"
#include "options_core.h"

static NSString *S(const std::string &s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @""; }

@implementation LPOpenVPN3Options
+ (NSDictionary<NSString *, id> *)parseProfileBytes:(const void *)bytes length:(size_t)length
{
    std::string text = (bytes && length) ? std::string(static_cast<const char *>(bytes), length) : std::string();
    lpopt::ParseResult r = lpopt::parse(text);
    lpopt::cleanse(text);
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:r.names.size()];
    for (const auto &n : r.names) [names addObject:S(n)];
    return @{ @"ok": @(r.ok), @"error": S(r.error), @"names": names };
}
@end
