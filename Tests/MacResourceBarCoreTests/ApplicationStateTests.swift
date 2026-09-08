import XCTest
@testable import MacResourceBarCore

final class ApplicationStateTests: XCTestCase {
    private func snapshot(name: String, pid: Int32, bundle: String?, cpu: Double = 0, ram: UInt64 = 0, disk: Double = 0, network: Double = 0, owner: String? = nil, available: AppResourceSnapshot.Metrics = .all) -> AppResourceSnapshot {
        AppResourceSnapshot(processName: name, pid: pid, pids: [pid], bundleIdentifier: bundle,
            icon: nil, cpuUsagePercent: cpu, ramBytes: ram, diskReadBytesPerSecond: disk,
            diskWriteBytesPerSecond: 0, downloadBytesPerSecond: network, uploadBytesPerSecond: 0,
            isApproximation: false, childProcessCount: 1,
            processIdentities: [pid: .init(pid: pid, startTimeMicroseconds: 1, executablePath: "/test/\(name)")],
            availableMetrics: available, owningAppName: owner)
    }

    @MainActor
    func testGroupingIncludesProvenDescendantsWithoutDoubleCounting() {
        let app = snapshot(name: "Editor", pid: 42, bundle: "test.editor", cpu: 10, ram: 100)
        let helper = snapshot(name: "renderer", pid: 43, bundle: "test.editor", cpu: 25, ram: 200, owner: "Editor")
        let other = snapshot(name: "Editor Helper", pid: 44, bundle: "test.other", cpu: 50)
        let lists = AppSnapshotFilterState(snapshots: [app, helper, other], searchText: "", resourceFilter: .all,
            threshold: 0, sortOrder: .cpuRate, customOrder: [], activeOnly: false, showHelperProcesses: false).snapshotLists
        XCTAssertEqual(lists.table.count, 2)
        let editor = lists.table.first { $0.bundleIdentifier == "test.editor" }
        XCTAssertEqual(editor?.cpuUsagePercent, 35)
        XCTAssertEqual(editor?.ramBytes, 300)
        XCTAssertEqual(editor?.pids, [42, 43])
        XCTAssertEqual(editor?.childProcessCount, 2)
        XCTAssertEqual(lists.table.reduce(0) { $0 + $1.cpuUsagePercent }, 85)
    }

    @MainActor
    func testMinimumWorksWithAllAndActiveIgnoresIdleMemory() {
        let quiet = snapshot(name: "Quiet", pid: 42, bundle: "test.quiet", ram: 4_000_000_000)
        let active = snapshot(name: "Active", pid: 43, bundle: "test.active", cpu: 20, ram: 32_000_000)
        func filter(_ metric: MenuBarViewModel.AppResourceFilter, threshold: Double, activeOnly: Bool) -> [AppResourceSnapshot] {
            AppSnapshotFilterState(snapshots: [quiet, active], searchText: "", resourceFilter: metric,
                threshold: threshold, sortOrder: .cpuRate, customOrder: [], activeOnly: activeOnly, showHelperProcesses: true).filteredSnapshots
        }
        XCTAssertEqual(filter(.cpu, threshold: 10, activeOnly: false).map(\.displayName), ["Active"])
        XCTAssertEqual(filter(.memory, threshold: 0, activeOnly: true).map(\.displayName), ["Active"])
    }

    @MainActor
    func testUnavailableGroupMetricDoesNotBecomeAReportedZero() {
        let app = snapshot(name: "Editor", pid: 42, bundle: "test.editor", available: [.memory, .network])
        let helper = snapshot(name: "Helper", pid: 43, bundle: "test.editor", owner: "Editor")
        let group = AppSnapshotFilterState(snapshots: [app, helper], searchText: "", resourceFilter: .all,
            threshold: 0, sortOrder: .name, customOrder: [], activeOnly: false, showHelperProcesses: false).tableSnapshots.first
        XCTAssertEqual(group?.availableMetrics, [.memory, .network])
    }

    @MainActor
    func testSettingsPersistAcrossModelReloadWithIsolatedDefaults() throws {
        let suite = "MacResourceBar.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MenuBarPreferences(defaults: defaults)
        let first = MenuBarViewModel(preferences: preferences, startMonitoring: false)
        first.setMenuBarLabelStyle(.mini)
        first.setAppResourceFilter(.cpu)
        first.setAppDisplayThreshold(25)
        first.setActiveAppsOnly(false)
        first.moveTrayMetricToEnd(.cpu)
        first.setAppSearchText("temporary search")
        let expectedOrder = first.trayMetricOrder
        let reloaded = MenuBarViewModel(preferences: MenuBarPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))), startMonitoring: false)
        XCTAssertEqual(reloaded.menuBarLabelStyle, .mini)
        XCTAssertEqual(reloaded.appResourceFilter, .cpu)
        XCTAssertEqual(reloaded.appDisplayThresholdBytesPerSecond, 25)
        XCTAssertEqual(reloaded.trayMetricOrder, expectedOrder)
        XCTAssertFalse(reloaded.activeAppsOnly)
        XCTAssertEqual(reloaded.appSearchText, "")
    }

    func testSlowDiskInventoryDoesNotBlockSystemSampling() {
        let sampled = expectation(description: "CPU and memory remain live while inventory waits")
        sampled.assertForOverFulfill = false
        let monitor = SystemMetricsMonitor(diskListReader: { _ in
            Thread.sleep(forTimeInterval: 2)
            return []
        })
        monitor.onSample = { sample in
            if sample.cpuUsagePercent != nil, sample.memoryUsagePercent != nil { sampled.fulfill() }
        }
        monitor.start()
        wait(for: [sampled], timeout: 2.8)
        monitor.stop()
    }
}
