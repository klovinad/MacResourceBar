import XCTest
import Darwin
@testable import MacResourceBarCore

final class ProcessSamplingTests: XCTestCase {
    func testCPUUsesOneCoreScaleAndDiscardsReusedPID() {
        var time: TimeInterval = 10
        var info: CPUProcessMonitor.TaskInfo? = .init(totalCPUTime: 0, startTime: 1)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let second = UInt64(1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
        let monitor = CPUProcessMonitor(readTaskInfo: { _ in info }, clock: { time })
        XCTAssertNil(monitor.sample(activePids: [42])[42])
        time += 1
        info = .init(totalCPUTime: 2 * second, startTime: 1)
        XCTAssertEqual(monitor.sample(activePids: [42])[42] ?? -1, 200, accuracy: 0.001)
        // Same PID and larger counters must still be treated as a new process.
        time += 1
        info = .init(totalCPUTime: 3 * second, startTime: 2)
        XCTAssertNil(monitor.sample(activePids: [42])[42])
        time += 1
        info = .init(totalCPUTime: 4 * second, startTime: 2)
        XCTAssertEqual(monitor.sample(activePids: [42])[42] ?? -1, 100, accuracy: 0.001)
    }

    func testCPUPermissionLossExitAndLongGapRequireNewBaseline() {
        var time: TimeInterval = 10
        var info: CPUProcessMonitor.TaskInfo? = .init(totalCPUTime: 100, startTime: 1)
        let monitor = CPUProcessMonitor(readTaskInfo: { _ in info }, clock: { time })
        _ = monitor.sample(activePids: [42])
        info = nil
        time += 1
        XCTAssertNil(monitor.sample(activePids: [42])[42])
        info = .init(totalCPUTime: 200, startTime: 1)
        time += 1
        XCTAssertNil(monitor.sample(activePids: [42])[42])
        time += 60
        XCTAssertNil(monitor.sample(activePids: [42])[42])
        _ = monitor.sample(activePids: [])
        time += 1
        XCTAssertNil(monitor.sample(activePids: [42])[42])
    }

    func testDiskDistinguishesIdleResetAndPIDReuse() {
        var time: TimeInterval = 10
        var info: DiskProcessMonitor.DiskUsage? = .init(readBytes: 100, writeBytes: 100, startTime: 1)
        let monitor = DiskProcessMonitor(readUsage: { _ in info }, clock: { time })
        XCTAssertNil(monitor.sample(activePids: [42])[42])
        time += 2
        info = .init(readBytes: 1100, writeBytes: 2100, startTime: 1)
        let active = monitor.sample(activePids: [42])[42]
        XCTAssertEqual(active?.readBytesPerSecond, 500)
        XCTAssertEqual(active?.writeBytesPerSecond, 1000)
        time += 1
        XCTAssertEqual(monitor.sample(activePids: [42])[42]?.readBytesPerSecond, 0)
        time += 1
        info = .init(readBytes: 1, writeBytes: 2, startTime: 1)
        XCTAssertNil(monitor.sample(activePids: [42])[42])
        time += 1
        info = .init(readBytes: 9000, writeBytes: 9000, startTime: 2)
        XCTAssertNil(monitor.sample(activePids: [42])[42])
        time += 60
        XCTAssertNil(monitor.sample(activePids: [42])[42])
        info = nil
        time += 1
        XCTAssertNil(monitor.sample(activePids: [42])[42])
        info = .init(readBytes: 9000, writeBytes: 9000, startTime: 2)
        time += 1
        XCTAssertNil(monitor.sample(activePids: [42])[42])
    }

    func testNativeCPUSampleMatchesIndependentGetrusage() throws {
        let monitor = CPUProcessMonitor()
        let pid = getpid()
        var before = rusage(), after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        let start = ProcessInfo.processInfo.systemUptime
        _ = monitor.sample(activePids: [pid])
        // Bounded work in the test process; never signal another application.
        var accumulator = 0.0
        while ProcessInfo.processInfo.systemUptime - start < 0.2 {
            accumulator += sqrt(Double.random(in: 1...100))
        }
        XCTAssertGreaterThan(accumulator, 0)
        let measured = try XCTUnwrap(monitor.sample(activePids: [pid])[pid])
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        let expected = (seconds(after.ru_utime) + seconds(after.ru_stime)
            - seconds(before.ru_utime) - seconds(before.ru_stime)) / elapsed * 100
        XCTAssertEqual(measured, expected, accuracy: 8)
    }

    func testMemoryAndProcessIdentityReadTheActualTestProcess() throws {
        let pid = getpid()
        XCTAssertGreaterThan(try XCTUnwrap(MemoryProcessMonitor().sample(activePids: [pid])[pid]), 0)
        let identity = try XCTUnwrap(ProcessIdentity.capture(for: pid))
        XCTAssertEqual(identity.pid, pid)
        XCTAssertEqual(ProcessIdentity.capture(for: pid), identity)
        XCTAssertNil(ProcessIdentity.capture(for: -1))
        XCTAssertNil(MemoryProcessMonitor().sample(activePids: [-1])[-1])
    }
}
