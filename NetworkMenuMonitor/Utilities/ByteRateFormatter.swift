import Foundation

enum ByteRateFormatter {
    private static let minimumDisplayUnitIndex = 2

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
        let unitIndex = resolvedUnitIndex(
            for: value,
            preferredUnitIndex: preferredUnitIndex,
            maxUnitIndex: units.count - 1
        )
        let scaled = value / pow(1024, Double(unitIndex))
        let quantized = (scaled * 10).rounded() / 10

        return StableMenuRate(
            text: String(format: "%.1f%@/s", quantized, units[unitIndex]),
            unitIndex: unitIndex
        )
    }

    static func thresholdString(for bytesPerSecond: Double) -> String {
        bytesPerSecond <= 0 ? "Off" : string(for: bytesPerSecond)
    }

    static func cardRate(for bytesPerSecond: Double) -> String {
        string(for: bytesPerSecond)
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
