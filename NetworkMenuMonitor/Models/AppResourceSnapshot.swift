import AppKit
import Foundation

struct AppResourceSnapshot: Identifiable, Equatable {
    let processName: String
    let pid: pid_t?
    let pids: [pid_t]
    let bundleIdentifier: String?
    let icon: NSImage?
    let cpuUsagePercent: Double
    let ramBytes: UInt64
    let diskReadBytesPerSecond: Double
    let diskWriteBytesPerSecond: Double
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let isApproximation: Bool
    let childProcessCount: Int

    var id: String {
        if let pid {
            return "\(pid)"
        }
        return bundleIdentifier.flatMap { "bundle-\($0)" } ?? processName
    }

    var canTerminate: Bool {
        !pids.isEmpty
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
        let cpuPoints = min(max(cpuUsagePercent, 0), 100)
        let memoryPoints = min(Double(ramBytes) / (512 * 1024 * 1024), 100)
        let diskPoints = min(diskBytesPerSecond / (1024 * 1024), 100)
        let networkPoints = min(networkBytesPerSecond / (1024 * 1024), 100)
        return cpuPoints + memoryPoints + diskPoints + networkPoints
    }

    var isHelperProcess: Bool {
        Self.parentAppName(for: processName) != nil
    }

    var groupedDisplayName: String {
        Self.parentAppName(for: processName) ?? displayName
    }

    static func parentAppName(for processName: String) -> String? {
        let normalized = processName.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.localizedCaseInsensitiveContains("Google Chrome Helper") ||
            normalized.localizedCaseInsensitiveContains("Chrome Helper") {
            return "Google Chrome"
        }

        if normalized.localizedCaseInsensitiveContains("Safari Web Content") ||
            normalized.localizedCaseInsensitiveContains("com.apple.WebKit") ||
            normalized.localizedCaseInsensitiveContains("WebKit") {
            return "Safari"
        }

        if normalized.localizedCaseInsensitiveContains("Electron Helper") {
            return normalized
                .replacingOccurrences(of: " Helper", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "Electron", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }

        if normalized.localizedCaseInsensitiveContains(" Helper") {
            return normalized
                .replacingOccurrences(of: " Helper", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }

        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
