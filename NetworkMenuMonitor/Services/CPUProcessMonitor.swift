import Foundation
import Darwin
import AppKit

final class CPUProcessMonitor {
    private var previousCPUByPid: [pid_t: CPUSamplePoint] = [:]
    private let readTaskInfo: (pid_t) -> TaskInfo?
    private let clock: () -> TimeInterval
    private let nanosecondsPerCPUTimeTick: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
            return 1
        }
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    init(
        readTaskInfo: @escaping (pid_t) -> TaskInfo? = CPUProcessMonitor.readTaskInfo,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.readTaskInfo = readTaskInfo
        self.clock = clock
    }

    func reset() {
        previousCPUByPid.removeAll(keepingCapacity: false)
    }

    func sample(activePids: Set<pid_t>, maximumAge: TimeInterval = 15) -> [pid_t: Double] {
        let now = clock()
        var result: [pid_t: Double] = [:]
        var nextBaselines: [pid_t: CPUSamplePoint] = [:]

        for pid in activePids {
            guard let taskInfo = readTaskInfo(pid) else { continue }

            let totalCPU = taskInfo.totalCPUTime
            if let previous = previousCPUByPid[pid],
               previous.startTime == taskInfo.startTime,
               let ticksPerSecond = CounterRatePolicy.rate(
                    current: totalCPU,
                    previous: previous.totalCPUTime,
                    elapsed: now - previous.timestamp,
                    maximumAge: maximumAge
               ) {
                // rusage CPU time is in Mach ticks (including on Apple silicon).
                let processScalePercent = ticksPerSecond * nanosecondsPerCPUTimeTick / 1_000_000_000 * 100
                // One fully used core is 100%; multi-threaded apps may exceed it.
                result[pid] = max(processScalePercent, 0)
            }

            nextBaselines[pid] = CPUSamplePoint(
                totalCPUTime: totalCPU,
                timestamp: now,
                startTime: taskInfo.startTime
            )
        }

        previousCPUByPid = nextBaselines
        return result
    }

    static func readTaskInfo(for pid: pid_t) -> TaskInfo? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            procPIDRUsageForCPU(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer(pointer))
        }
        guard result == 0 else { return nil }
        // Read identity and counters atomically from the same kernel snapshot.
        return TaskInfo(
            totalCPUTime: info.ri_user_time + info.ri_system_time,
            startTime: info.ri_proc_start_abstime
        )
    }

    private struct CPUSamplePoint {
        let totalCPUTime: UInt64
        let timestamp: CFAbsoluteTime
        let startTime: UInt64
    }

    struct TaskInfo {
        let totalCPUTime: UInt64
        let startTime: UInt64
    }
}

@_silgen_name("proc_pid_rusage")
private func procPIDRUsageForCPU(_ pid: pid_t, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32
