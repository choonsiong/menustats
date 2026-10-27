import Foundation

// MARK: - sysctl helpers

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func integer(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

// MARK: - Formatting

enum Fmt {
    private static let byteUnits = ["B", "KB", "MB", "GB", "TB"]
    private static let byteUnitsShort = ["B", "K", "M", "G", "T"]
    private static let bitUnits = ["bps", "Kbps", "Mbps", "Gbps"]
    private static let bitUnitsShort = ["b", "K", "M", "G"]

    private static func scale(_ value: Double, units: [String], divisor: Double, suffix: String = "") -> String {
        var v = max(0, value)
        var index = 0
        // Thresholds are the rounding boundaries, not the divisor, so the
        // number never prints as "1023" or "100.0". The menu bar sizes its
        // slots on that three-digit guarantee.
        while v >= min(divisor, 999.5) && index < units.count - 1 {
            v /= divisor
            index += 1
        }
        let decimals = (index == 0 || v >= 99.95) ? 0 : 1
        return String(format: "%.\(decimals)f%@%@%@", v, units[index].isEmpty ? "" : " ", units[index], suffix)
    }

    /// "9.82 GB"
    static func bytes(_ value: Double) -> String {
        scale(value, units: byteUnits, divisor: 1024)
    }

    /// Transfer rate. `short` is the compact menu-bar form ("1.4M").
    static func rate(_ bytesPerSecond: Double, bits: Bool, short: Bool) -> String {
        if bits {
            let value = bytesPerSecond * 8
            return short
                ? scale(value, units: bitUnitsShort, divisor: 1000).replacingOccurrences(of: " ", with: "")
                : scale(value, units: bitUnits, divisor: 1000)
        }
        return short
            ? scale(bytesPerSecond, units: byteUnitsShort, divisor: 1024).replacingOccurrences(of: " ", with: "")
            : scale(bytesPerSecond, units: byteUnits, divisor: 1024, suffix: "/s")
    }

    /// The widest strings the compact rate can produce. With tabular digits
    /// every number of the same shape is the same width, so measuring these
    /// is enough to size a slot that never has to grow.
    static func widestShortRates(bits: Bool) -> [String] {
        (bits ? bitUnitsShort : byteUnitsShort).flatMap { ["999" + $0, "99.9" + $0] }
    }

    static func percent(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", max(0, min(100, value)))
    }

    static func temperature(_ celsius: Double, fahrenheit: Bool) -> String {
        fahrenheit
            ? String(format: "%.0f°F", celsius * 9 / 5 + 32)
            : String(format: "%.0f°C", celsius)
    }
}
