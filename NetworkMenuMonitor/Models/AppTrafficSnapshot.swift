import AppKit
import Foundation

struct AppResourceSnapshot: Identifiable, Equatable {
    let processName: String
    let pid: pid_t?
    let bundleIdentifier: String?
    let icon: NSImage?
    let cpuUsagePercent: Double
    let ramBytes: UInt64
    let diskReadBytesPerSecond: Double
    let diskWriteBytesPerSecond: Double
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let isApproximation: Bool

    var id: String {
        if let pid {
            return "\(pid)"
        }
        return bundleIdentifier.flatMap { "bundle-\($0)" } ?? processName
    }

    var displayName: String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return processName
        }
        return processName
    }

    var networkBytesPerSecond: Double {
        downloadBytesPerSecond + uploadBytesPerSecond
    }

    var diskBytesPerSecond: Double {
        diskReadBytesPerSecond + diskWriteBytesPerSecond
    }

    var totalActivityScore: Double {
        let cpuScore = cpuUsagePercent * 1024 * 1024 / 100
        return networkBytesPerSecond + diskBytesPerSecond + Double(ramBytes) + cpuScore
    }
}
