import AppKit
import Darwin
import Foundation

struct ProcessIdentity: Equatable {
    let pid: pid_t
    let startTimeMicroseconds: UInt64
    let executablePath: String?

    static func capture(for pid: pid_t) -> ProcessIdentity? {
        guard pid > 1 else { return nil }

        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let readSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
        }
        guard readSize == expectedSize else { return nil }

        let seconds = UInt64(info.pbi_start_tvsec)
        let microseconds = UInt64(info.pbi_start_tvusec)
        let startTime = seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !startTime.overflow else { return nil }

        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let executablePath: String?
        if pathLength > 0 {
            let terminator = pathBuffer.firstIndex(of: 0) ?? pathBuffer.count
            let path = String(
                decoding: pathBuffer.prefix(terminator).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            executablePath = path.isEmpty ? nil : path
        } else {
            executablePath = nil
        }

        return ProcessIdentity(
            pid: pid,
            startTimeMicroseconds: startTime.partialValue + microseconds,
            executablePath: executablePath
        )
    }
}

struct AppResourceSnapshot: Identifiable, Equatable {
    struct Metrics: OptionSet, Sendable {
        let rawValue: Int
        static let cpu = Metrics(rawValue: 1)
        static let memory = Metrics(rawValue: 2)
        static let disk = Metrics(rawValue: 4)
        static let network = Metrics(rawValue: 8)
        static let all: Metrics = [.cpu, .memory, .disk, .network]
    }
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
    let processIdentities: [pid_t: ProcessIdentity]
    var availableMetrics: Metrics = .all
    /// Filled only from a verified process ancestry, never from a name guess.
    var owningAppName: String? = nil

    var id: String {
        if let pid {
            return "pid-\(pid)-\(processIdentities[pid]?.startTimeMicroseconds ?? 0)"
        }
        return "group-\(processName.lowercased())|\(bundleIdentifier ?? "")"
    }

    var canTerminate: Bool {
        pids.contains { pid in
            pid > 1 && pid != getpid() && processIdentities[pid] != nil
        }
    }

    var orderKey: String {
        let baseKey = "name-\(processName.lowercased())|bundle-\(bundleIdentifier ?? "")"
        guard let pid else { return baseKey }
        return "\(baseKey)|pid-\(pid)"
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

        if let helperRange = normalized.range(of: " Helper", options: .caseInsensitive) {
            return String(normalized[..<helperRange.lowerBound])
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
