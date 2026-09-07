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
    private let readUsage: (pid_t) -> DiskUsage?
    private let clock: () -> TimeInterval

    init(
        readUsage: @escaping (pid_t) -> DiskUsage? = DiskProcessMonitor.readUsage,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.readUsage = readUsage
        self.clock = clock
    }

    func reset() {
        previousRUsageByPid.removeAll(keepingCapacity: false)
    }

    func sample(activePids: Set<pid_t>, maximumAge: TimeInterval = 15) -> [pid_t: DiskProcessSample] {
        var result: [pid_t: DiskProcessSample] = [:]
        let now = clock()
        var nextBaselines: [pid_t: DiskSamplePoint] = [:]

        for pid in activePids {
            guard let usage = readUsage(pid) else { continue }
            let totalRead = usage.readBytes
            let totalWrite = usage.writeBytes

            if let previous = previousRUsageByPid[pid], previous.startTime == usage.startTime {
                let elapsed = now - previous.timestamp
                if let readRate = CounterRatePolicy.rate(current: totalRead, previous: previous.totalRead, elapsed: elapsed, maximumAge: maximumAge),
                   let writeRate = CounterRatePolicy.rate(current: totalWrite, previous: previous.totalWrite, elapsed: elapsed, maximumAge: maximumAge) {
                    result[pid] = DiskProcessSample(
                        pid: pid,
                        readBytesPerSecond: readRate,
                        writeBytesPerSecond: writeRate
                    )
                }
            }

            nextBaselines[pid] = DiskSamplePoint(
                totalRead: totalRead,
                totalWrite: totalWrite,
                timestamp: now,
                startTime: usage.startTime
            )
        }

        previousRUsageByPid = nextBaselines
        return result
    }

    static func readUsage(for pid: pid_t) -> DiskUsage? {
        var usage = rusage_info_v4()

        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            procPIDRUsage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer(pointer))
        }
        guard result == 0 else { return nil }

        return DiskUsage(
            readBytes: usage.ri_diskio_bytesread,
            writeBytes: usage.ri_diskio_byteswritten,
            startTime: usage.ri_proc_start_abstime
        )
    }

    private struct DiskSamplePoint {
        let totalRead: UInt64
        let totalWrite: UInt64
        let timestamp: CFAbsoluteTime
        let startTime: UInt64
    }

    struct DiskUsage {
        let readBytes: UInt64
        let writeBytes: UInt64
        let startTime: UInt64
    }
}
