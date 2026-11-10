#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// openvpn3's OptionList parser only: no crypto, no network, no OpenSSL (DESIGN §2.2, §8.1). Linked by the app for
/// the import-time differential check against our own tokenizer.
@interface LPOpenVPN3Options : NSObject
/// Parses profile text (raw bytes; copied into C++ storage and cleansed after use — key-bearing text never crosses as
/// an NSString, review simplification 6) with openvpn3's `OptionList::parse_from_config`. Keys: ok (NSNumber BOOL),
/// error (NSString, empty on success), names (NSArray<NSString *> of directive names in order).
+ (NSDictionary<NSString *, id> *)parseProfileBytes:(const void *)bytes length:(size_t)length;
@end

NS_ASSUME_NONNULL_END
