import Foundation
import Darwin
import AppKit

final class CPUProcessMonitor {
    private var previousCPUByPid: [pid_t: CPUSamplePoint] = [:]
    private let nanosecondsPerCPUTimeTick: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
            return 1
        }
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    func reset() {
        previousCPUByPid.removeAll(keepingCapacity: false)
    }

    func reset(pid: pid_t) {
        previousCPUByPid.removeValue(forKey: pid)
    }

    func sample(activePids: Set<pid_t>) -> [pid_t: Double] {
        let now = CFAbsoluteTimeGetCurrent()
        var result: [pid_t: Double] = [:]

        for pid in activePids {
            guard let taskInfo = readTaskInfo(for: pid) else { continue }

            let totalCPU = taskInfo.totalCPUTime
            if let previous = previousCPUByPid[pid], now > previous.timestamp {
                let elapsed = now - previous.timestamp
                if elapsed > 0 {
                    let delta = totalCPU >= previous.totalCPUTime
                        ? totalCPU - previous.totalCPUTime
                        : 0
                    // proc_taskinfo reports accumulated CPU time in Mach
                    // absolute-time ticks, not nanoseconds on every Mac.
                    let cpuNanoseconds = Double(delta) * nanosecondsPerCPUTimeTick
                    let processScalePercent = (cpuNanoseconds / (elapsed * 1_000_000_000)) * 100
                    // Match Activity Monitor's process scale: one fully used
                    // logical core is 100%, and multi-threaded apps may exceed it.
                    // Dividing by the machine's core count made normal activity
                    // round down to an apparent zero for almost every process.
                    result[pid] = max(processScalePercent, 0)
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
