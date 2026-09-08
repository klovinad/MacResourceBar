import Foundation

enum ByteRateFormatter {
    private static let minimumDisplayUnitIndex = 0

    struct StableMenuRate {
        let text: String
        let unitIndex: Int
    }

    struct AlignedRate {
        let text: String
        let unitIndex: Int
    }

    static func string(for bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        if value < 0.5 {
            return "0 B/s"
        }
        var scaled = value
        var unitIndex = 0

        while scaled >= 1024, unitIndex < units.count - 1 {
            scaled /= 1024
            unitIndex += 1
        }

        while unitIndex < minimumDisplayUnitIndex {
            scaled /= 1024
            unitIndex += 1
        }

        let precision = scaled >= 100 ? 0 : (scaled >= 10 ? 1 : 2)
        return "\(scaled.formatted(.number.precision(.fractionLength(precision)))) \(units[unitIndex])"
    }

    static func stableMenuRate(for bytesPerSecond: Double, preferredUnitIndex: Int?) -> StableMenuRate {
        let value = max(bytesPerSecond, 0)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var unitIndex = resolvedUnitIndex(
            for: value,
            preferredUnitIndex: preferredUnitIndex,
            maxUnitIndex: units.count - 1
        )
        var scaled = value / pow(1024, Double(unitIndex))
        var quantized = (scaled * 10).rounded() / 10
        if quantized >= 1024, unitIndex < units.count - 1 {
            unitIndex += 1
            scaled = value / pow(1024, Double(unitIndex))
            quantized = (scaled * 10).rounded() / 10
        }

        return StableMenuRate(
            text: String(format: "%.1f%@/s", quantized, units[unitIndex]),
            unitIndex: unitIndex
        )
    }

    static func thresholdString(for bytesPerSecond: Double) -> String {
        bytesPerSecond <= 0 ? "Off" : string(for: bytesPerSecond)
    }

    /// The three two-line layouts reserve the widest unit and four integer
    /// digits. Keep a tenth of a unit, including across rounding boundaries.
    static func twoLineMenuRate(for bytesPerSecond: Double, shortUnits: Bool) -> String {
        guard bytesPerSecond.isFinite else { return "N/A" }
        if bytesPerSecond >= 1023.95 * pow(1024, 4) {
            return shortUnits ? "1024+T" : "1024+TB/s"
        }
        let rate = stableMenuRate(for: bytesPerSecond, preferredUnitIndex: nil)
        guard shortUnits else { return rate.text }
        let units = ["B", "K", "M", "G", "T"]
        let suffix = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"][rate.unitIndex]
        var number = String(rate.text.dropLast(suffix.count))
        if number.hasSuffix(".0") { number.removeLast(2) }
        return number + units[rate.unitIndex]
    }

    static func cardRate(for bytesPerSecond: Double) -> String {
        string(for: bytesPerSecond)
    }

    /// Aggregate network throughput is easier to scan when its unit does not
    /// change around the 1 MB boundary. Keep it in MB/s even for sub-megabyte
    /// traffic (for example, 521 KB/s becomes 0.51 MB/s).
    static func networkCardRate(for bytesPerSecond: Double) -> String {
        let megabytes = max(bytesPerSecond, 0) / (1024 * 1024)
        guard megabytes >= 0.005 else { return "0 MB/s" }

        let precision = megabytes >= 100 ? 0 : (megabytes >= 10 ? 1 : 2)
        let number = megabytes.formatted(
            .number.precision(.fractionLength(precision))
        )
        return "\(number) MB/s"
    }

    /// Compact menu-bar form of the same fixed MB/s representation. Values
    /// are deliberately capped so the status item keeps a permanent width.
    static func networkMenuRate(for bytesPerSecond: Double) -> String {
        let megabytes = max(bytesPerSecond, 0) / (1024 * 1024)
        guard megabytes >= 0.05 else { return "0.0M" }
        guard megabytes < 999.5 else { return "999M" }

        if megabytes < 10 {
            return String(format: "%.1fM", megabytes)
        }
        return String(format: "%.0fM", megabytes)
    }

    static func networkFullMenuRate(for bytesPerSecond: Double) -> String {
        let megabytes = max(bytesPerSecond, 0) / (1024 * 1024)
        guard megabytes < 999.5 else { return "999+ MB/s" }

        let compact = networkMenuRate(for: bytesPerSecond)
        return "\(compact.dropLast()) MB/s"
    }

    static func alignedRate(for bytesPerSecond: Double, preferredUnitIndex: Int?) -> AlignedRate {
        let value = max(bytesPerSecond, 0)
        let units = [" B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        let unitIndex = resolvedUnitIndex(
            for: value,
            preferredUnitIndex: preferredUnitIndex,
            maxUnitIndex: units.count - 1
        )
        let scaled = value / pow(1024, Double(unitIndex))
        let quantized = (scaled * 10).rounded() / 10

        return AlignedRate(
            text: String(format: "%6.1f %@", quantized, units[unitIndex]),
            unitIndex: unitIndex
        )
    }

    private static func resolvedUnitIndex(for bytesPerSecond: Double, preferredUnitIndex: Int?, maxUnitIndex: Int) -> Int {
        var targetUnitIndex = 0
        var scaled = bytesPerSecond

        while scaled >= 1024, targetUnitIndex < maxUnitIndex {
            scaled /= 1024
            targetUnitIndex += 1
        }

        targetUnitIndex = max(targetUnitIndex, minimumDisplayUnitIndex)

        guard let preferredUnitIndex else {
            return targetUnitIndex
        }

        let preferredScale = bytesPerSecond / pow(1024, Double(preferredUnitIndex))
        if preferredScale >= 0.75, preferredScale < 1400 {
            return preferredUnitIndex
        }

        return targetUnitIndex
    }
}
