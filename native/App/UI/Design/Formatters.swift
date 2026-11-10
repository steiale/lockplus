import Foundation

/// Number formatting for every live value (UI-CONCEPT §8.3, ref/swiftui-appkit §8: static styles, never a
/// `Formatter` inside `body`). Units are decimal (1 KB = 1000 B), matching Activity Monitor.
enum RateFormat {
    /// "1.2 MB/s", "30 kB/s" with the system's byte-count formatting for the locale (UI-M17/L24: no hand-made units,
    /// no "10.0 KB/s"). Decimal units, as Activity Monitor.
    static func text(_ bytesPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let amount = Int64(max(bytesPerSecond, 0).rounded())
            .formatted(.byteCount(style: .decimal, spellsOutZero: false).locale(locale))
        return String(localized: "\(amount)/s", locale: locale, comment: "Data rate, e.g. '1.2 MB/s'; the argument is a byte count")
    }

    /// VoiceOver form: "1.2 megabytes per second".
    static func spoken(_ bytesPerSecond: Double) -> String {
        let v = max(bytesPerSecond, 0)
        let unit: UnitInformationStorage
        let value: Double
        switch v {
        case ..<1_000: unit = .bytes; value = v
        case ..<1_000_000: unit = .kilobytes; value = v / 1_000
        case ..<1_000_000_000: unit = .megabytes; value = v / 1_000_000
        default: unit = .gigabytes; value = v / 1_000_000_000
        }
        let rounded = (value < 10 ? (value * 10).rounded() / 10 : value.rounded())
        let amount = Measurement(value: rounded, unit: unit).formatted(.measurement(width: .wide, usage: .asProvided))
        return String(localized: "\(amount) per second", comment: "Spoken data rate, e.g. '1.2 megabytes per second'")
    }

    /// Menu bar label piece (§6.1): 3 significant characters plus K/M/G, locale decimal separator, never words.
    /// "1.2M", "30K", "999K", "0K".
    static func compact(_ bytesPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let kb = max(bytesPerSecond, 0) / 1_000
        let letters = ["K", "M", "G", "T"]
        var value = kb, unit = 0
        while value >= 999.5, unit < letters.count - 1 { value /= 1_000; unit += 1 }
        if value < 0.05 { return "0\(letters[unit])" }
        let digits = value < 9.95 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + letters[unit]
    }

    /// `compact`, left-padded with plain spaces to the width of `widestCompact` (4 characters). The status item draws
    /// it in SF Mono, where a space is exactly one digit wide (U+2007 figure space isn't in SF Mono: it fell back to
    /// another font and shifted the label ~0.18 pt per pad), so every value has the same width and the label stays put as rates change (owner test
    /// 2026-11-10: "6,5K" → "658K" moved the centred text sideways in the fixed-width item).
    static func compactFixed(_ bytesPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let s = compact(bytesPerSecond, locale: locale)
        return String(repeating: " ", count: max(0, widestCompact().count - s.count)) + s
    }

    /// The widest possible compact string for this locale, used to fix `NSStatusItem.length` once (§6.1).
    static func widestCompact() -> String {
        // Three digits beat "digit, separator, digit"; M is the widest unit letter in SF.
        "888M"
    }

}

enum ByteFormat {
    /// "1.4 GB", "92 MB".
    static func text(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .decimal))
    }
}

enum DurationFormat {
    /// Session clock "02:14:07" (monospaced digits at the call site).
    static func clock(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(Int(seconds), 0)).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2)))
    }

    /// "21 sec" (localized unit).
    static func seconds(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(Int(seconds), 0)).formatted(.units(allowed: [.seconds], width: .abbreviated))
    }

    /// "1 hr, 29 min" style used for summaries.
    static func short(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds), 0)
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = s >= 3_600 ? [.hours, .minutes] : (s >= 60 ? [.minutes] : [.seconds])
        return Duration.seconds(s).formatted(.units(allowed: allowed, width: .abbreviated))
    }

    /// Spoken: "12 minutes".
    static func spoken(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds), 0)
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = s >= 3_600 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(max(s, 60)).formatted(.units(allowed: allowed, width: .wide))
    }

    /// Minutes left, rounded up: a pause with 11 min 10 s left reads "12 min".
    static func minutesLeft(until date: Date, now: Date) -> TimeInterval {
        let left = date.timeIntervalSince(now)
        return (left / 60).rounded(.up) * 60
    }
}
