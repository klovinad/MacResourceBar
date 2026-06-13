import Foundation
import Darwin
import AppKit

final class CPUProcessMonitor {
    private let queue = DispatchQueue(label: "NetworkMenuMonitor.CPUProcessMonitor")
    private var previousCPUByPid: [pid_t: CPUSamplePoint] = [:]
    private var activePids: Set<pid_t> = []
    private let sampleToPercentMultiplier: Double

    init() {
        sampleToPercentMultiplier = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
    }

    func sample() -> [pid_t: Double] {
        let now = CFAbsoluteTimeGetCurrent()
        var result: [pid_t: Double] = [:]
        activePids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.processIdentifier })

        for pid in activePids {
            guard let taskInfo = readTaskInfo(for: pid) else { continue }

            let totalCPU = taskInfo.totalCPUTime
            if let previous = previousCPUByPid[pid], now > previous.timestamp {
                let elapsed = now - previous.timestamp
                if elapsed > 0 {
                    let delta = totalCPU >= previous.totalCPUTime
                        ? totalCPU - previous.totalCPUTime
                        : 0
                    let percent = (Double(delta) / (elapsed * 1_000_000_000)) * 100
                    let maxPercent = sampleToPercentMultiplier * 100
                    result[pid] = min(max(percent, 0), maxPercent)
                }
            }

            previousCPUByPid[pid] = CPUSamplePoint(
                totalCPUTime: totalCPU,
                timestamp: now
            )
        }

        previousCPUByPid = previousCPUByPid.filter { activePids.contains($0.key) }
        return result
    }

    private func readTaskInfo(for pid: pid_t) -> TaskInfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(
            pid,
            Int32(PROC_PIDTASKINFO),
            0,
            &info,
            size
        )

        guard result == size else { return nil }

        return TaskInfo(
            totalCPUTime: info.pti_total_user + info.pti_total_system
        )
    }

    private struct CPUSamplePoint {
        let totalCPUTime: UInt64
        let timestamp: CFAbsoluteTime
    }

    private struct TaskInfo {
        let totalCPUTime: UInt64
    }
}
