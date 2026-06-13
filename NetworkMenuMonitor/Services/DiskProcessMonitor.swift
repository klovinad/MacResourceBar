import Foundation
import AppKit
import Darwin

@_silgen_name("proc_pid_rusage")
private func procPIDRUsage(
    _ pid: pid_t,
    _ flavor: Int32,
    _ buffer: UnsafeMutableRawPointer
) -> Int32

struct DiskProcessSample {
    let pid: pid_t
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
}

final class DiskProcessMonitor {
    private var previousRUsageByPid: [pid_t: DiskSamplePoint] = [:]
    private var activePids: Set<pid_t> = []

    func sample() -> [pid_t: DiskProcessSample] {
        var result: [pid_t: DiskProcessSample] = [:]
        let now = CFAbsoluteTimeGetCurrent()
        activePids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.processIdentifier })

        for pid in activePids {
            guard let usage = readUsage(for: pid) else { continue }
            let totalRead = usage.readBytes
            let totalWrite = usage.writeBytes

            if let previous = previousRUsageByPid[pid], now > previous.timestamp {
                let elapsed = now - previous.timestamp
                if elapsed > 0 {
                    let deltaRead = totalRead >= previous.totalRead
                        ? Double(totalRead - previous.totalRead)
                        : 0
                    let deltaWrite = totalWrite >= previous.totalWrite
                        ? Double(totalWrite - previous.totalWrite)
                        : 0

                    result[pid] = DiskProcessSample(
                        pid: pid,
                        readBytesPerSecond: deltaRead / elapsed,
                        writeBytesPerSecond: deltaWrite / elapsed
                    )
                }
            }

            previousRUsageByPid[pid] = DiskSamplePoint(
                totalRead: totalRead,
                totalWrite: totalWrite,
                timestamp: now
            )
        }

        previousRUsageByPid = previousRUsageByPid.filter { activePids.contains($0.key) }
        return result
    }

    private func readUsage(for pid: pid_t) -> DiskUsage? {
        var usage = rusage_info_current()

        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            procPIDRUsage(pid, RUSAGE_INFO_CURRENT, UnsafeMutableRawPointer(pointer))
        }
        guard result == 0 else { return nil }

        return DiskUsage(
            readBytes: usage.ri_diskio_bytesread,
            writeBytes: usage.ri_diskio_byteswritten
        )
    }

    private struct DiskSamplePoint {
        let totalRead: UInt64
        let totalWrite: UInt64
        let timestamp: CFAbsoluteTime
    }

    private struct DiskUsage {
        let readBytes: UInt64
        let writeBytes: UInt64
    }
}
