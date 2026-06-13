import Foundation
import AppKit
import Darwin

final class MemoryProcessMonitor {
    func sample() -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        let activePids = NSWorkspace.shared.runningApplications.compactMap { $0.processIdentifier }

        for pid in activePids {
            if let taskInfo = readTaskInfo(for: pid) {
                result[pid] = taskInfo.residentBytes
            }
        }

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
            residentBytes: info.pti_resident_size
        )
    }

    private struct TaskInfo {
        let residentBytes: UInt64
    }
}
