import Foundation
import Testing
@testable import RamLume

@Suite("Memory units")
struct MemoryUnitsTests {
    @Test func convertsPagesToBytes() {
        #expect(MemoryUnits.bytes(fromPages: 1_048_576, pageSize: 16_384) == 17_179_869_184)
        #expect(MemoryUnits.bytes(fromPages: 0, pageSize: 16_384) == 0)
        #expect(MemoryUnits.bytes(fromPages: 3, pageSize: 4_096) == 12_288)
    }

    @Test func saturatesInsteadOfOverflowing() {
        #expect(MemoryUnits.bytes(fromPages: .max, pageSize: 16_384) == .max)
        #expect(MemoryUnits.saturatingAdd(.max, 1) == .max)
        #expect(MemoryUnits.saturatingSum([.max, .max, 5]) == .max)
    }

    @Test func counterDeltaRejectsResets() {
        #expect(MemoryUnits.counterDelta(from: 10, to: 25) == 15)
        #expect(MemoryUnits.counterDelta(from: 25, to: 25) == 0)
        #expect(MemoryUnits.counterDelta(from: 25, to: 10) == nil)
        // A wrapped 64-bit counter looks like a reset and is rejected, not turned into a huge delta.
        #expect(MemoryUnits.counterDelta(from: .max - 2, to: 3) == nil)
    }

    @Test func fractions() {
        #expect(MemoryUnits.fraction(1, of: 4) == 0.25)
        #expect(MemoryUnits.fraction(1, of: 0) == nil)
        #expect(MemoryUnits.fraction(5, of: 4) == 1.25)
        #expect(MemoryUnits.clampedFraction(5, of: 4) == 1)
        #expect(MemoryUnits.clampedFraction(5, of: 0) == 0)
    }

    @Test func signedDifferenceHandlesExtremes() {
        #expect(MemoryUnits.signedDifference(10, 4) == 6)
        #expect(MemoryUnits.signedDifference(4, 10) == -6)
        #expect(MemoryUnits.signedDifference(.max, 0) == .max)
        #expect(MemoryUnits.signedDifference(0, .max) == .min)
    }
}

@Suite("Formatting")
struct MemoryFormatterTests {
    let posix = Locale(identifier: "en_US_POSIX")

    @Test func formatsBinaryUnits() {
        #expect(MemoryFormatter.string(fromBytes: UInt64(0), locale: posix) == "0 KB")
        #expect(MemoryFormatter.string(fromBytes: 512 * MemoryUnits.kibibyte, locale: posix) == "512 KB")
        #expect(MemoryFormatter.string(fromBytes: 340 * MemoryUnits.mebibyte, locale: posix) == "340 MB")
        #expect(MemoryFormatter.string(fromBytes: 52 * MemoryUnits.mebibyte + MemoryUnits.mebibyte / 2, locale: posix) == "52.5 MB")
        #expect(MemoryFormatter.string(fromBytes: UInt64(12_691_659_489), locale: posix) == "11.8 GB")
        #expect(MemoryFormatter.string(fromBytes: UInt64(5.74 * Double(MemoryUnits.gibibyte)), locale: posix) == "5.74 GB")
        #expect(MemoryFormatter.string(fromBytes: 16 * MemoryUnits.gibibyte, locale: posix) == "16.0 GB")
    }

    @Test func switchesToGigabytesAtOneThousandMegabytes() {
        #expect(MemoryFormatter.string(fromBytes: 999 * MemoryUnits.mebibyte, locale: posix) == "999 MB")
        #expect(MemoryFormatter.string(fromBytes: 1_014 * MemoryUnits.mebibyte, locale: posix) == "0.99 GB")
    }

    /// The unit follows the rounded value, so 999.7 MB doesn't read "1,000 MB".
    @Test func unitsSwitchOnTheRoundedValue() {
        let justUnderAThousandMegabytes = UInt64(999.7 * Double(MemoryUnits.mebibyte))
        #expect(MemoryFormatter.string(fromBytes: justUnderAThousandMegabytes, locale: posix) == "0.98 GB")
        #expect(MemoryFormatter.string(fromBytes: justUnderAThousandMegabytes, style: .compact, locale: posix) == "1 GB")
        let justUnderAMegabyte = UInt64(1_023.7 * Double(MemoryUnits.kibibyte))
        #expect(MemoryFormatter.string(fromBytes: justUnderAMegabyte, locale: posix) == "1.0 MB")
        #expect(MemoryFormatter.string(fromBytes: justUnderAMegabyte, style: .compact, locale: posix) == "1 MB")
    }

    @Test func processCountsArePluralizedCorrectly() {
        #expect(MemoryFormatter.processCount(1) == "1 process")
        #expect(MemoryFormatter.processCount(0) == "0 processes")
        #expect(MemoryFormatter.processCount(12) == "12 processes")
    }

    @Test func compactStyleDropsTrailingZero() {
        #expect(MemoryFormatter.string(fromBytes: 2 * MemoryUnits.gibibyte, style: .compact, locale: posix) == "2 GB")
        #expect(MemoryFormatter.string(fromBytes: 16 * MemoryUnits.gibibyte, style: .compact, locale: posix) == "16 GB")
        #expect(MemoryFormatter.string(fromBytes: UInt64(3_650_722_201), style: .compact, locale: posix) == "3.4 GB")
        #expect(MemoryFormatter.string(fromBytes: 340 * MemoryUnits.mebibyte, style: .compact, locale: posix) == "340 MB")
    }

    @Test func usedOfTotal() {
        #expect(MemoryFormatter.usedOfTotal(used: 12_691_659_489, total: 16 * MemoryUnits.gibibyte, locale: posix) == "11.8/16 GB")
        #expect(MemoryFormatter.usedOfTotal(used: 6 * MemoryUnits.gibibyte, total: 8 * MemoryUnits.gibibyte, locale: posix) == "6.0/8 GB")
    }

    @Test func percentagesAreClamped() {
        #expect(MemoryFormatter.percent(0.738, locale: posix) == "74%")
        #expect(MemoryFormatter.percent(1.4, locale: posix) == "100%")
        #expect(MemoryFormatter.percent(-1, locale: posix) == "0%")
        #expect(MemoryFormatter.percent(.nan, locale: posix) == "0%")
    }

    @Test func sharesNeverRoundToNoneOrAll() {
        #expect(MemoryFormatter.share(0, locale: posix) == "0%")
        #expect(MemoryFormatter.share(0.004, locale: posix) == "<1%")
        #expect(MemoryFormatter.share(0.25, locale: posix) == "25%")
        #expect(MemoryFormatter.share(0.996, locale: posix) == ">99%")
        #expect(MemoryFormatter.share(1, locale: posix) == "100%")
    }

    @Test func signedChangesAndDurations() {
        #expect(MemoryFormatter.signedChange(bytes: 0, locale: posix) == "No change")
        #expect(MemoryFormatter.signedChange(bytes: Int64(MemoryUnits.gibibyte + MemoryUnits.gibibyte / 5), locale: posix) == "+1.2 GB")
        #expect(MemoryFormatter.signedChange(bytes: -Int64(300 * MemoryUnits.mebibyte), locale: posix) == "−300 MB")
        #expect(MemoryFormatter.duration(42) == "42 s")
        #expect(MemoryFormatter.duration(600) == "10 min")
        #expect(MemoryFormatter.duration(3_900) == "1 h 5 min")
        #expect(MemoryFormatter.duration(7_200) == "2 h")
    }
}
