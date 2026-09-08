import Foundation
import Darwin

@_silgen_name("proc_pid_rusage")
func readUsage(_ pid: pid_t, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

// Read-only: pass a verified app PID. Includes reaped helper-process CPU, so
// short-lived nettop/diskutil work is not hidden in the parent-only percentage.
let args = CommandLine.arguments
guard args.count == 3, let pid = Int32(args[1]), pid > 1,
      let duration = Double(args[2]), duration >= 2, duration <= 300 else {
    fputs("usage: swift script/measure_overhead.swift <pid> <seconds 2...300>\n", stderr)
    exit(2)
}
func sample() -> rusage_info_v4 {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
        readUsage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer($0))
    }
    guard result == 0 else { fputs("Process is unavailable.\n", stderr); exit(1) }
    return usage
}
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
let first = sample()
let startedAt = ISO8601DateFormatter().string(from: Date())
let start = ProcessInfo.processInfo.systemUptime
var rows: [[String: Double]] = []
var previous = first
var previousTime = start
while ProcessInfo.processInfo.systemUptime - start < duration {
    Thread.sleep(forTimeInterval: 1)
    let current = sample()
    guard current.ri_proc_start_abstime == first.ri_proc_start_abstime else {
        fputs("PID was reused; measurement discarded.\n", stderr); exit(1)
    }
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = now - previousTime
    let own = current.ri_user_time + current.ri_system_time
    let oldOwn = previous.ri_user_time + previous.ri_system_time
    let children = current.ri_child_user_time + current.ri_child_system_time
    let oldChildren = previous.ri_child_user_time + previous.ri_child_system_time
    guard own >= oldOwn, children >= oldChildren else { exit(1) }
    rows.append([
        "elapsed": now - start,
        "appCPUPercent": Double(own - oldOwn) * secondsPerTick / elapsed * 100,
        "helperCPUPercent": Double(children - oldChildren) * secondsPerTick / elapsed * 100,
        "footprintMiB": Double(current.ri_phys_footprint) / 1_048_576
    ])
    previous = current
    previousTime = now
}
let elapsed = previousTime - start
let appCPU = Double((previous.ri_user_time + previous.ri_system_time) - (first.ri_user_time + first.ri_system_time)) * secondsPerTick / elapsed * 100
let helperCPU = Double((previous.ri_child_user_time + previous.ri_child_system_time) - (first.ri_child_user_time + first.ri_child_system_time)) * secondsPerTick / elapsed * 100
let result: [String: Any] = [
    "startedAt": startedAt, "pid": pid,
    "durationSeconds": elapsed, "appCPUPercent": appCPU,
    "helperCPUPercent": helperCPU, "combinedCPUPercent": appCPU + helperCPU,
    "samples": rows
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
