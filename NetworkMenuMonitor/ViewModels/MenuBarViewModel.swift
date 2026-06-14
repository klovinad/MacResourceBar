import Foundation
import Darwin
import IOKit
import IOKit.hidsystem
import IOKit.storage

struct ExternalDiskActivity: Identifiable {
    let bsdName: String
    let displayName: String
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
    let isMemoryCard: Bool
    var id: String { bsdName }
    var systemImageName: String { isMemoryCard ? "sdcard" : "externaldrive" }
}

@MainActor
final class MenuBarViewModel: ObservableObject {
    private enum Preferences {
        static let appResourceThresholdKey = "appResourceDisplayThresholdBytesPerSecond"
        static let appResourceFilterKey = "appResourceFilter"
        static let showAllInfoKey = "showAllInfo"
        static let trayMetricsKey = "trayMetrics"
        static let trayMetricOrderKey = "trayMetricOrder"
        static let highRefreshEnabledKey = "highRefreshEnabled"
        static let appSortOrderKey = "appSortOrder"
        static let appSearchTextKey = "appSearchText"
        static let activeAppsOnlyKey = "activeAppsOnly"
        static let showHelperProcessesKey = "showHelperProcesses"
    }

    private enum RefreshProfile {
        static let highTotalsInterval: TimeInterval = 1
        static let lowTotalsInterval: TimeInterval = 10
        static let highSystemInterval: TimeInterval = 1
        static let lowSystemInterval: TimeInterval = 10
        static let highAppInterval: TimeInterval = 1
        static let lowAppInterval: TimeInterval = 10
    }

    enum AppSortOrder: String, CaseIterable {
        case totalRate, cpuRate, memoryRate, diskRate, networkRate, name

        var label: String {
            switch self {
            case .totalRate:      "Total"
            case .cpuRate:        "CPU"
            case .memoryRate:     "RAM"
            case .diskRate:       "Disk"
            case .networkRate:    "Network"
            case .name:           "Name"
            }
        }
    }

    enum AppResourceFilter: String, CaseIterable {
        case all
        case cpu
        case memory
        case disk
        case network

        var label: String {
            switch self {
            case .all: "All"
            case .cpu: "CPU"
            case .memory: "Memory"
            case .disk: "Disk"
            case .network: "Network"
            }
        }
    }

    enum TrayMetric: String, CaseIterable, Identifiable {
        case network
        case cpu
        case cpuTemp
        case memory
        case disk
        case externalDisk

        var id: String { rawValue }

        var title: String {
            switch self {
            case .network: "Network"
            case .cpu: "CPU"
            case .cpuTemp: "CPU Temp"
            case .memory: "Memory"
            case .disk: "Disk"
            case .externalDisk: "Ext Disk"
            }
        }
    }

    @Published private(set) var totalDownloadBytesPerSecond: Double = 0
    @Published private(set) var totalUploadBytesPerSecond: Double = 0
    @Published private(set) var appSnapshots: [AppResourceSnapshot] = []
    @Published private(set) var perAppStatusMessage: String?
    @Published private(set) var cpuUsagePercent: Double = 0
    @Published private(set) var memoryUsagePercent: Double = 0
    @Published private(set) var diskActivityMBPerSecond: Double = 0
    @Published private(set) var gpuUsagePercent: Double?
    @Published private(set) var cpuTemperatureCelsius: Double?
    @Published private(set) var menuBarTitle = "0.0MB/s↓ 0.0MB/s↑"
    @Published private(set) var menuBarSystemTitle = ""
    @Published private(set) var menuBarNetworkTitle = "0.0MB/s↓ 0.0MB/s↑"
    @Published var launchAtLoginEnabled = LaunchAtLoginService.isEnabled
    @Published var appDisplayThresholdBytesPerSecond: Double
    @Published private(set) var appResourceFilter: AppResourceFilter
    @Published var showAllInfo: Bool
    @Published var highRefreshEnabled: Bool
    @Published var appSearchText: String
    @Published var activeAppsOnly: Bool
    @Published var showHelperProcesses: Bool
    @Published private(set) var appSortOrder: AppSortOrder
    @Published private(set) var selectedTrayMetrics: [TrayMetric]
    @Published private(set) var trayMetricOrder: [TrayMetric]
    @Published private(set) var externalDiskActivities: [ExternalDiskActivity] = []

    private let totalsMonitor = NetworkTotalsMonitor()
    private let appResourceMonitor = AppResourceMonitor()
    private let systemMetricsMonitor = SystemMetricsMonitor()
    private let smoothingFactor = 0.18
    private let minimumVisibleRate: Double = 16
    private var preferredDownloadUnitIndex = 2
    private var preferredUploadUnitIndex = 2
    private var menuBarDownloadTitle = "0.0MB/s"
    private var menuBarUploadTitle = "0.0MB/s"
    private static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.isAdaptive = true
        return formatter
    }()

    let resourceThresholdOptions: [Double] = [
        0,
        100 * 1024,
        250 * 1024,
        500 * 1024,
        1024 * 1024,
        2 * 1024 * 1024,
        5 * 1024 * 1024
    ]

    let cpuThresholdOptions: [Double] = [
        0,
        1,
        5,
        10,
        25,
        50,
        75,
        100
    ]

    let totalActivityThresholdOptions: [Double] = [
        0,
        1,
        5,
        10,
        25,
        50,
        100
    ]

    let memoryThresholdOptions: [Double] = [
        0,
        16 * 1024 * 1024,
        32 * 1024 * 1024,
        64 * 1024 * 1024,
        128 * 1024 * 1024,
        256 * 1024 * 1024,
        512 * 1024 * 1024
    ]

    init() {
        appDisplayThresholdBytesPerSecond = UserDefaults.standard.double(forKey: Preferences.appResourceThresholdKey)
        appResourceFilter = AppResourceFilter(rawValue: UserDefaults.standard.string(forKey: Preferences.appResourceFilterKey) ?? "") ?? .all
        appSortOrder = AppSortOrder(rawValue: UserDefaults.standard.string(forKey: Preferences.appSortOrderKey) ?? "") ?? .totalRate
        if UserDefaults.standard.object(forKey: Preferences.showAllInfoKey) == nil {
            showAllInfo = false
        } else {
            showAllInfo = UserDefaults.standard.bool(forKey: Preferences.showAllInfoKey)
        }
        if UserDefaults.standard.object(forKey: Preferences.highRefreshEnabledKey) == nil {
            highRefreshEnabled = true
        } else {
            highRefreshEnabled = UserDefaults.standard.bool(forKey: Preferences.highRefreshEnabledKey)
        }
        appSearchText = UserDefaults.standard.string(forKey: Preferences.appSearchTextKey) ?? ""
        if UserDefaults.standard.object(forKey: Preferences.activeAppsOnlyKey) == nil {
            activeAppsOnly = true
        } else {
            activeAppsOnly = UserDefaults.standard.bool(forKey: Preferences.activeAppsOnlyKey)
        }
        if UserDefaults.standard.object(forKey: Preferences.showHelperProcessesKey) == nil {
            showHelperProcesses = false
        } else {
            showHelperProcesses = UserDefaults.standard.bool(forKey: Preferences.showHelperProcessesKey)
        }
        let storedOrder = (UserDefaults.standard.string(forKey: Preferences.trayMetricOrderKey) ?? "")
            .split(separator: ",")
            .compactMap { TrayMetric(rawValue: String($0)) }
        let normalizedTrayMetricOrder = Self.normalizedTrayMetricOrder(from: storedOrder)
        trayMetricOrder = normalizedTrayMetricOrder

        let storedMetrics = (UserDefaults.standard.string(forKey: Preferences.trayMetricsKey) ?? "")
            .split(separator: ",")
            .compactMap { TrayMetric(rawValue: String($0)) }
        selectedTrayMetrics = Self.normalizedSelectedMetrics(
            storedMetrics,
            using: normalizedTrayMetricOrder
        )
        refreshMenuBarTitle()

        totalsMonitor.onSample = { [weak self] sample in
            Task { @MainActor in
                guard let self else { return }
                self.totalDownloadBytesPerSecond = self.smoothedRate(
                    current: self.totalDownloadBytesPerSecond,
                    incoming: sample.downloadBytesPerSecond
                )
                self.totalUploadBytesPerSecond = self.smoothedRate(
                    current: self.totalUploadBytesPerSecond,
                    incoming: sample.uploadBytesPerSecond
                )
                self.refreshMenuBarTitle()
            }
        }

        totalsMonitor.onReset = { [weak self] in
            Task { @MainActor in
                self?.handleNetworkPathReset()
            }
        }

        appResourceMonitor.onUpdate = { [weak self] snapshots in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.appSnapshots = snapshots
            }
        }

        appResourceMonitor.onStatusChange = { [weak self] message in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.perAppStatusMessage = message
            }
        }

        systemMetricsMonitor.onSample = { [weak self] sample in
            Task { @MainActor in
                guard let self else { return }
                self.cpuUsagePercent = sample.cpuUsagePercent
                self.memoryUsagePercent = sample.memoryUsagePercent
                self.diskActivityMBPerSecond = sample.diskActivityMBPerSecond
                self.gpuUsagePercent = sample.gpuUsagePercent
                self.cpuTemperatureCelsius = sample.cpuTemperatureCelsius
                self.refreshMenuBarTitle()
            }
        }

        systemMetricsMonitor.onExternalDiskSample = { [weak self] activities in
            Task { @MainActor in
                guard let self else { return }
                self.externalDiskActivities = activities
                self.refreshMenuBarTitle()
            }
        }

        totalsMonitor.start()
        systemMetricsMonitor.start()
        applyRefreshMode()
    }

    var filteredAppSnapshots: [AppResourceSnapshot] {
        let search = appSearchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return appTableSnapshots
            .filter { snapshot in
                search.isEmpty || snapshot.displayName.localizedCaseInsensitiveContains(search)
            }
            .filter { self.isAppActive($0) }
            .sorted { lhs, rhs in
                switch appSortOrder {
                case .totalRate:
                    return lhs.totalActivityScore != rhs.totalActivityScore
                        ? lhs.totalActivityScore > rhs.totalActivityScore
                        : lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                case .cpuRate:
                    return lhs.cpuUsagePercent != rhs.cpuUsagePercent
                        ? lhs.cpuUsagePercent > rhs.cpuUsagePercent
                        : lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                case .memoryRate:
                    return lhs.ramBytes != rhs.ramBytes
                        ? lhs.ramBytes > rhs.ramBytes
                        : lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                case .diskRate:
                    return lhs.diskBytesPerSecond != rhs.diskBytesPerSecond
                        ? lhs.diskBytesPerSecond > rhs.diskBytesPerSecond
                        : lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                case .networkRate:
                    return lhs.networkBytesPerSecond != rhs.networkBytesPerSecond
                        ? lhs.networkBytesPerSecond > rhs.networkBytesPerSecond
                        : lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                case .name:
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
            }
    }

    func setAppSortOrder(_ order: AppSortOrder) {
        appSortOrder = order
        UserDefaults.standard.set(order.rawValue, forKey: Preferences.appSortOrderKey)
    }

    func setAppResourceFilter(_ filter: AppResourceFilter) {
        appResourceFilter = filter
        UserDefaults.standard.set(filter.rawValue, forKey: Preferences.appResourceFilterKey)

        let options = thresholdOptions(for: filter)
        if !options.contains(appDisplayThresholdBytesPerSecond) {
            appDisplayThresholdBytesPerSecond = options.first ?? 0
            UserDefaults.standard.set(appDisplayThresholdBytesPerSecond, forKey: Preferences.appResourceThresholdKey)
        }
    }

    var thresholdDescription: String {
        switch appResourceFilter {
        case .all:
            if appDisplayThresholdBytesPerSecond <= 0 { return "Off" }
            return String(format: "%.0f activity pts", appDisplayThresholdBytesPerSecond)
        case .disk, .network:
            return ByteRateFormatter.thresholdString(for: appDisplayThresholdBytesPerSecond)
        case .cpu:
            if appDisplayThresholdBytesPerSecond <= 0 { return "Off" }
            return "\(Int(appDisplayThresholdBytesPerSecond)) %"
        case .memory:
            if appDisplayThresholdBytesPerSecond <= 0 { return "Off" }
            return Self.memoryFormatter.string(fromByteCount: Int64(appDisplayThresholdBytesPerSecond))
        }
    }

    var thresholdOptions: [Double] {
        thresholdOptions(for: appResourceFilter)
    }

    var visiblePerAppStatusMessage: String? {
        perAppStatusMessage
    }

    var filteredAppCountText: String {
        let tableSnapshots = appTableSnapshots
        let search = appSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredCount = tableSnapshots
            .lazy
            .filter { snapshot in
                search.isEmpty || snapshot.displayName.localizedCaseInsensitiveContains(search)
            }
            .filter { self.isAppActive($0) }
            .count
        return "\(filteredCount) of \(tableSnapshots.count)"
    }

    var searchMatchCountText: String? {
        let search = appSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return nil }

        let matchCount = appTableSnapshots
            .lazy
            .filter { $0.displayName.localizedCaseInsensitiveContains(search) }
            .count

        return "\(matchCount) matches"
    }

    private func thresholdOptions(for filter: AppResourceFilter) -> [Double] {
        switch filter {
        case .all:
            return totalActivityThresholdOptions
        case .cpu:
            return cpuThresholdOptions
        case .memory:
            return memoryThresholdOptions
        case .disk, .network:
            return resourceThresholdOptions
        }
    }

    private func activityValue(for snapshot: AppResourceSnapshot) -> Double {
        switch appResourceFilter {
        case .all:
            return snapshot.totalActivityScore
        case .cpu:
            return snapshot.cpuUsagePercent
        case .memory:
            return Double(snapshot.ramBytes)
        case .disk:
            return snapshot.diskBytesPerSecond
        case .network:
            return snapshot.networkBytesPerSecond
        }
    }

    private func isAppActive(_ snapshot: AppResourceSnapshot) -> Bool {
        guard activeAppsOnly else { return true }
        let threshold = appDisplayThresholdBytesPerSecond
        return activityValue(for: snapshot) >= threshold
    }

    var appTableSnapshots: [AppResourceSnapshot] {
        showHelperProcesses ? appSnapshots : groupedAppSnapshots()
    }

    private func groupedAppSnapshots() -> [AppResourceSnapshot] {
        var grouped: [String: AppResourceSnapshot] = [:]

        for snapshot in appSnapshots {
            let displayName = snapshot.groupedDisplayName
            let key = snapshot.bundleIdentifier ?? displayName.lowercased()

            guard let current = grouped[key] else {
                grouped[key] = AppResourceSnapshot(
                    processName: displayName,
                    pid: snapshot.isHelperProcess ? nil : snapshot.pid,
                    pids: snapshot.pids,
                    bundleIdentifier: snapshot.bundleIdentifier,
                    icon: snapshot.icon,
                    cpuUsagePercent: snapshot.cpuUsagePercent,
                    ramBytes: snapshot.ramBytes,
                    diskReadBytesPerSecond: snapshot.diskReadBytesPerSecond,
                    diskWriteBytesPerSecond: snapshot.diskWriteBytesPerSecond,
                    downloadBytesPerSecond: snapshot.downloadBytesPerSecond,
                    uploadBytesPerSecond: snapshot.uploadBytesPerSecond,
                    isApproximation: snapshot.isApproximation,
                    childProcessCount: snapshot.childProcessCount
                )
                continue
            }

            grouped[key] = AppResourceSnapshot(
                processName: current.displayName,
                pid: nil,
                pids: Array(Set(current.pids + snapshot.pids)).sorted(),
                bundleIdentifier: current.bundleIdentifier ?? snapshot.bundleIdentifier,
                icon: current.icon ?? snapshot.icon,
                cpuUsagePercent: current.cpuUsagePercent + snapshot.cpuUsagePercent,
                ramBytes: current.ramBytes + snapshot.ramBytes,
                diskReadBytesPerSecond: current.diskReadBytesPerSecond + snapshot.diskReadBytesPerSecond,
                diskWriteBytesPerSecond: current.diskWriteBytesPerSecond + snapshot.diskWriteBytesPerSecond,
                downloadBytesPerSecond: current.downloadBytesPerSecond + snapshot.downloadBytesPerSecond,
                uploadBytesPerSecond: current.uploadBytesPerSecond + snapshot.uploadBytesPerSecond,
                isApproximation: current.isApproximation || snapshot.isApproximation,
                childProcessCount: current.childProcessCount + snapshot.childProcessCount
            )
        }

        return Array(grouped.values)
    }

    func trayMetricEnabled(_ metric: TrayMetric) -> Bool {
        selectedTrayMetrics.contains(metric)
    }

    var orderedTrayMetricsForPopover: [TrayMetric] {
        trayMetricOrder.filter { $0 != .externalDisk || !externalDiskActivities.isEmpty }
    }

    var orderedVisibleTrayMetrics: [TrayMetric] {
        let selectedSet = Set(selectedTrayMetrics)
        let orderedSelected = trayMetricOrder.filter { selectedSet.contains($0) }
        let base = orderedSelected.isEmpty ? [TrayMetric.network] : orderedSelected
        let filtered = base.filter { $0 != .externalDisk || !externalDiskActivities.isEmpty }
        return filtered.isEmpty ? [.network] : filtered
    }

    var trayCPUText: String {
        String(format: "CPU %.0f%%", cpuUsagePercent)
    }

    var trayCPUTempText: String {
        if let cpuTemperatureCelsius {
            return String(format: "TMP %.0fC", cpuTemperatureCelsius)
        }
        return "TMP N/A"
    }

    var trayRAMText: String {
        String(format: "RAM %.0f%%", memoryUsagePercent)
    }

    var trayDiskText: String {
        "DSK \(compactTrayRate(formattedDiskRate(precision: 1, compact: true)))"
    }

    var trayExternalDiskText: String {
        let totalBytesPerSecond = externalDiskActivities.reduce(0.0) {
            $0 + $1.readBytesPerSecond + $1.writeBytesPerSecond
        }
        return "EXT \(compactTrayRate(ByteRateFormatter.stableMenuRate(for: totalBytesPerSecond, preferredUnitIndex: nil).text))"
    }

    var trayDownloadText: String {
        "\(compactTrayRate(menuBarDownloadTitle))↓"
    }

    var trayUploadText: String {
        "\(compactTrayRate(menuBarUploadTitle))↑"
    }

    var formattedCPUUsage: String {
        percentString(cpuUsagePercent)
    }

    var formattedMemoryUsage: String {
        percentString(memoryUsagePercent)
    }

    var formattedDiskActivity: String {
        formattedDiskRate(precision: 2)
    }

    var formattedGPUUsage: String {
        guard let gpuUsagePercent else { return "N/A" }
        return percentString(gpuUsagePercent)
    }

    var formattedCPUTemperature: String {
        guard let cpuTemperatureCelsius else { return "N/A" }
        return String(format: "%.0f C", cpuTemperatureCelsius)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            launchAtLoginEnabled = try LaunchAtLoginService.setEnabled(enabled)
        } catch {
            launchAtLoginEnabled = LaunchAtLoginService.isEnabled
            perAppStatusMessage = "Launch at login could not be updated: \(error.localizedDescription)"
        }
    }

    func setAppDisplayThreshold(_ threshold: Double) {
        appDisplayThresholdBytesPerSecond = threshold
        UserDefaults.standard.set(threshold, forKey: Preferences.appResourceThresholdKey)
    }

    func setShowAllInfo(_ enabled: Bool) {
        showAllInfo = enabled
        UserDefaults.standard.set(enabled, forKey: Preferences.showAllInfoKey)
    }

    func setHighRefreshEnabled(_ enabled: Bool) {
        guard highRefreshEnabled != enabled else { return }
        highRefreshEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Preferences.highRefreshEnabledKey)
        applyRefreshMode()
    }

    func setAppSearchText(_ text: String) {
        appSearchText = text
        UserDefaults.standard.set(text, forKey: Preferences.appSearchTextKey)
    }

    func setActiveAppsOnly(_ enabled: Bool) {
        activeAppsOnly = enabled
        UserDefaults.standard.set(enabled, forKey: Preferences.activeAppsOnlyKey)
    }

    func setShowHelperProcesses(_ enabled: Bool) {
        showHelperProcesses = enabled
        UserDefaults.standard.set(enabled, forKey: Preferences.showHelperProcessesKey)
    }

    func terminateProcess(_ snapshot: AppResourceSnapshot) {
        for pid in snapshot.pids {
            kill(pid, SIGTERM)
        }
    }

    func stopMonitoring() {
        totalsMonitor.stop()
        appResourceMonitor.stop()
        systemMetricsMonitor.stop()
    }

    var selectedTrayMetricsSummary: String {
        if selectedTrayMetrics.isEmpty {
            return "Network"
        }

        if selectedTrayMetrics.count == TrayMetric.allCases.count {
            return "All"
        }

        return selectedTrayMetrics.map(\.title).joined(separator: ", ")
    }

    var allTrayMetricsSelected: Bool {
        Set(selectedTrayMetrics).count == TrayMetric.allCases.count
    }

    func setAllTrayMetricsSelected(_ selected: Bool) {
        if selected {
            trayMetricOrder = Self.normalizedTrayMetricOrder(from: trayMetricOrder)
            selectedTrayMetrics = Self.normalizedSelectedMetrics(trayMetricOrder, using: trayMetricOrder)
        } else {
            selectedTrayMetrics = [.network]
        }
        persistTrayConfiguration()
        refreshMenuBarTitle()
    }

    func toggleTrayMetric(_ metric: TrayMetric) {
        if selectedTrayMetrics.contains(metric) {
            selectedTrayMetrics.removeAll { $0 == metric }
        } else {
            selectedTrayMetrics.append(metric)
        }
        selectedTrayMetrics = Self.normalizedSelectedMetrics(selectedTrayMetrics, using: trayMetricOrder)

        persistTrayConfiguration()
        refreshMenuBarTitle()
    }

    func moveTrayMetrics(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        trayMetricOrder.move(fromOffsets: offsets, toOffset: destination)
        trayMetricOrder = Self.normalizedTrayMetricOrder(from: trayMetricOrder)
        selectedTrayMetrics = Self.normalizedSelectedMetrics(selectedTrayMetrics, using: trayMetricOrder)
        persistTrayConfiguration()
        refreshMenuBarTitle()
    }

    func moveTrayMetric(_ metric: TrayMetric, before target: TrayMetric) {
        guard
            metric != target,
            let sourceIndex = trayMetricOrder.firstIndex(of: metric),
            let targetIndex = trayMetricOrder.firstIndex(of: target)
        else {
            return
        }

        var updatedOrder = trayMetricOrder
        updatedOrder.remove(at: sourceIndex)
        // In the array after removal:
        // - source < target inserts after target
        // - source > target inserts before target
        let destinationIndex = targetIndex
        updatedOrder.insert(metric, at: destinationIndex)

        trayMetricOrder = Self.normalizedTrayMetricOrder(from: updatedOrder)
        selectedTrayMetrics = Self.normalizedSelectedMetrics(selectedTrayMetrics, using: trayMetricOrder)
        persistTrayConfiguration()
        refreshMenuBarTitle()
    }

    func trayText(for metric: TrayMetric) -> String {
        switch metric {
        case .network:
            return "\(trayDownloadText) \(trayUploadText)"
        case .cpu:
            return trayCPUText
        case .cpuTemp:
            return trayCPUTempText
        case .memory:
            return trayRAMText
        case .disk:
            return trayDiskText
        case .externalDisk:
            return trayExternalDiskText
        }
    }

    func compactTrayText(for metric: TrayMetric) -> String {
        switch metric {
        case .network:
            return "\(compactMenuRate(menuBarDownloadTitle))↓ \(compactMenuRate(menuBarUploadTitle))↑"
        case .cpu:
            return String(format: "C%.0f", cpuUsagePercent)
        case .cpuTemp:
            guard let cpuTemperatureCelsius else { return "T--" }
            return String(format: "%.0f°", cpuTemperatureCelsius)
        case .memory:
            return String(format: "R%.0f", memoryUsagePercent)
        case .disk:
            return "D\(compactMenuRate(formattedDiskRate(precision: 1, compact: true)))"
        case .externalDisk:
            let totalBytesPerSecond = externalDiskActivities.reduce(0.0) {
                $0 + $1.readBytesPerSecond + $1.writeBytesPerSecond
            }
            let text = ByteRateFormatter.stableMenuRate(for: totalBytesPerSecond, preferredUnitIndex: nil).text
            return "X\(compactMenuRate(text))"
        }
    }

    private func persistTrayConfiguration() {
        UserDefaults.standard.set(
            selectedTrayMetrics.map(\.rawValue).joined(separator: ","),
            forKey: Preferences.trayMetricsKey
        )
        UserDefaults.standard.set(
            trayMetricOrder.map(\.rawValue).joined(separator: ","),
            forKey: Preferences.trayMetricOrderKey
        )
    }

    private func smoothedRate(current: Double, incoming: Double) -> Double {
        let blended = current == 0
            ? incoming
            : (current * (1 - smoothingFactor)) + (incoming * smoothingFactor)

        return blended < minimumVisibleRate ? 0 : blended
    }

    private func handleNetworkPathReset() {
        totalDownloadBytesPerSecond = 0
        totalUploadBytesPerSecond = 0
        preferredDownloadUnitIndex = 2
        preferredUploadUnitIndex = 2
        appSnapshots = []
        perAppStatusMessage = nil
        refreshMenuBarTitle()
        appResourceMonitor.restart()
    }

    private func applyRefreshMode() {
        totalsMonitor.setPollingInterval(
            highRefreshEnabled ? RefreshProfile.highTotalsInterval : RefreshProfile.lowTotalsInterval
        )
        systemMetricsMonitor.setPollingInterval(
            highRefreshEnabled ? RefreshProfile.highSystemInterval : RefreshProfile.lowSystemInterval
        )
        appResourceMonitor.setPollingInterval(
            highRefreshEnabled ? RefreshProfile.highAppInterval : RefreshProfile.lowAppInterval
        )
        appResourceMonitor.start()
    }

    private func refreshMenuBarTitle() {
        let download = ByteRateFormatter.stableMenuRate(
            for: totalDownloadBytesPerSecond,
            preferredUnitIndex: preferredDownloadUnitIndex
        )
        let upload = ByteRateFormatter.stableMenuRate(
            for: totalUploadBytesPerSecond,
            preferredUnitIndex: preferredUploadUnitIndex
        )

        preferredDownloadUnitIndex = download.unitIndex
        preferredUploadUnitIndex = upload.unitIndex
        menuBarDownloadTitle = download.text
        menuBarUploadTitle = upload.text
        menuBarTitle = resolvedMenuBarTitle()
    }

    private func percentString(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private func compactTrayRate(_ value: String) -> String {
        value
            .replacingOccurrences(of: "GB/s", with: "G")
            .replacingOccurrences(of: "MB/s", with: "M")
            .replacingOccurrences(of: "KB/s", with: "K")
            .replacingOccurrences(of: "B/s", with: "B")
    }

    private func compactMenuRate(_ value: String) -> String {
        compactTrayRate(value)
            .replacingOccurrences(of: "G", with: "")
            .replacingOccurrences(of: "M", with: "")
            .replacingOccurrences(of: "K", with: "")
            .replacingOccurrences(of: "B", with: "")
    }

    private func resolvedMenuBarTitle() -> String {
        let orderedMetrics = orderedVisibleTrayMetrics
        let components = orderedMetrics.map(trayText(for:))

        menuBarSystemTitle = orderedMetrics
            .filter { $0 != .network }
            .map(trayText(for:))
            .joined(separator: "  ")
        menuBarNetworkTitle = trayText(for: .network)

        return components.joined(separator: "  ")
    }

    private static func normalizedTrayMetricOrder(from metrics: [TrayMetric]) -> [TrayMetric] {
        let defaultOrder: [TrayMetric] = [.cpu, .memory, .cpuTemp, .disk, .externalDisk, .network]
        var ordered: [TrayMetric] = []

        for metric in metrics where !ordered.contains(metric) {
            ordered.append(metric)
        }

        for metric in defaultOrder where !ordered.contains(metric) {
            ordered.append(metric)
        }

        return ordered
    }

    private static func normalizedSelectedMetrics(
        _ selected: [TrayMetric],
        using order: [TrayMetric]
    ) -> [TrayMetric] {
        let normalized = order.filter { selected.contains($0) }
        return normalized.isEmpty ? [.network] : normalized
    }

    private func formattedDiskRate(precision: Int, compact: Bool = false) -> String {
        let bytesPerSecond = max(diskActivityMBPerSecond, 0) * 1024 * 1024

        if bytesPerSecond <= 0.0001 {
            return compact ? "0.0MB/s" : "0.00 MB/s"
        }

        let mbPerSecond = bytesPerSecond / (1024 * 1024)
        if mbPerSecond >= 0.1 {
            let format = compact ? "%.\(precision)fMB/s" : "%.\(precision)f MB/s"
            return String(format: format, mbPerSecond)
        }

        let kbPerSecond = bytesPerSecond / 1024
        let format = compact ? "%.\(precision)fKB/s" : "%.\(precision)f KB/s"
        return String(format: format, kbPerSecond)
    }
}

private struct SystemMetricsSample: Sendable {
    let cpuUsagePercent: Double
    let memoryUsagePercent: Double
    let diskActivityMBPerSecond: Double
    let gpuUsagePercent: Double?
    let cpuTemperatureCelsius: Double?
}

private typealias IOHIDEventRef = OpaquePointer

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreatePrivate(_ allocator: CFAllocator?) -> IOHIDEventSystemClient

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEventPrivate(
    _ service: IOHIDServiceClient,
    _ eventType: Int64,
    _ options: Int32,
    _ timestamp: Int64
) -> IOHIDEventRef?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValuePrivate(_ event: IOHIDEventRef, _ field: Int32) -> Double

private final class SystemMetricsMonitor: @unchecked Sendable {
    private struct DiskCounters {
        let readBytes: UInt64
        let writeBytes: UInt64
        let timestamp: CFAbsoluteTime
    }

    private enum CPUState {
        static let user = 0
        static let system = 1
        static let idle = 2
        static let nice = 3
        static let max = 4
    }

    var onSample: ((SystemMetricsSample) -> Void)?
    var onExternalDiskSample: (([ExternalDiskActivity]) -> Void)?

    private let queue = DispatchQueue(label: "NetworkMenuMonitor.SystemMetricsMonitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var previousCPUInfo: processor_info_array_t?
    private var previousCPUInfoCount: mach_msg_type_number_t = 0
    private var diskNames: [String] = []
    private var previousDiskCounters: [String: DiskCounters] = [:]
    private var pollingInterval: TimeInterval = 1
    private var didResolveDiskNames = false
    private struct ExternalDiskInfo {
        let displayName: String
        let isMemoryCard: Bool
    }

    private var cachedExternalDiskInfo: [String: ExternalDiskInfo] = [:]
    private var lastKnownDiskSet: Set<String> = []
    private var previousExternalDiskCounters: [String: DiskCounters] = [:]

    func start() {
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: pollingInterval)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
        if let previousCPUInfo {
            let previousSize = vm_size_t(previousCPUInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: previousCPUInfo), previousSize)
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        // previousCPUInfo is intentionally preserved across stop/start so the first
        // sample after a mode-switch returns a real value rather than 0.
        // readCPUUsage() frees the old pointer on every normal sample cycle.
        // deinit handles cleanup if the object is destroyed before the next sample.
    }

    func setPollingInterval(_ interval: TimeInterval) {
        let normalizedInterval = max(interval, 1)
        guard abs(normalizedInterval - pollingInterval) > 0.01 else { return }
        pollingInterval = normalizedInterval

        if timer != nil {
            stop()
            start()
        }
    }

    private func poll() {
        if !didResolveDiskNames || previousDiskCounters.isEmpty {
            diskNames = resolveTrackedDiskNames()
            didResolveDiskNames = true
        }

        let externalActivities = readExternalDiskActivities()

        let sample = SystemMetricsSample(
            cpuUsagePercent: readCPUUsage(),
            memoryUsagePercent: readMemoryUsage(),
            diskActivityMBPerSecond: readDiskActivity(),
            gpuUsagePercent: nil,
            cpuTemperatureCelsius: readCPUTemperature()
        )

        Task { @MainActor in
            onSample?(sample)
            onExternalDiskSample?(externalActivities)
        }
    }

    private func readCPUUsage() -> Double {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &cpuInfoCount
        )

        guard result == KERN_SUCCESS, let cpuInfo else {
            return 0
        }

        guard let previousCPUInfo else {
            self.previousCPUInfo = cpuInfo
            self.previousCPUInfoCount = cpuInfoCount
            return 0
        }

        var totalTicksUsed: UInt32 = 0
        var totalTicks: UInt32 = 0

        for cpu in 0 ..< Int(cpuCount) {
            let offset = CPUState.max * cpu

            let user = UInt32(cpuInfo[offset + CPUState.user] - previousCPUInfo[offset + CPUState.user])
            let system = UInt32(cpuInfo[offset + CPUState.system] - previousCPUInfo[offset + CPUState.system])
            let nice = UInt32(cpuInfo[offset + CPUState.nice] - previousCPUInfo[offset + CPUState.nice])
            let idle = UInt32(cpuInfo[offset + CPUState.idle] - previousCPUInfo[offset + CPUState.idle])

            totalTicksUsed += user + system + nice
            totalTicks += user + system + nice + idle
        }

        let previousSize = vm_size_t(previousCPUInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: previousCPUInfo), previousSize)

        self.previousCPUInfo = cpuInfo
        self.previousCPUInfoCount = cpuInfoCount

        guard totalTicks > 0 else { return 0 }
        return min(max((Double(totalTicksUsed) / Double(totalTicks)) * 100, 0), 100)
    }

    private func readMemoryUsage() -> Double {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }

        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let usedPages =
            UInt64(stats.active_count) +
            UInt64(stats.wire_count) +
            UInt64(stats.compressor_page_count)
        let usedMemory = usedPages * UInt64(pageSize)

        guard totalMemory > 0 else { return 0 }
        return min(max((Double(usedMemory) / Double(totalMemory)) * 100, 0), 100)
    }

    private func readDiskActivity() -> Double {
        guard !diskNames.isEmpty else { return 0 }
        let now = CFAbsoluteTimeGetCurrent()
        var currentCounters: [String: DiskCounters] = [:]
        var totalBytesPerSecond = 0.0

        for diskName in diskNames {
            guard let counters = diskCounters(for: diskName, timestamp: now) else { continue }
            currentCounters[diskName] = counters

            guard let previous = previousDiskCounters[diskName] else { continue }
            let elapsed = counters.timestamp - previous.timestamp
            guard elapsed > 0 else { continue }

            let previousTotal = previous.readBytes + previous.writeBytes
            let currentTotal = counters.readBytes + counters.writeBytes
            guard currentTotal >= previousTotal else { continue }

            totalBytesPerSecond += Double(currentTotal - previousTotal) / elapsed
        }

        previousDiskCounters = currentCounters
        return totalBytesPerSecond / (1024 * 1024)
    }

    private func detectExternalDisks(among names: [String]) -> [String: ExternalDiskInfo] {
        var result: [String: ExternalDiskInfo] = [:]
        for name in names {
            guard let media = serviceForBSDName(name) else { continue }
            defer { IOObjectRelease(media) }

            guard
                let protocolChars = IORegistryEntrySearchCFProperty(
                    media,
                    kIOServicePlane,
                    "Protocol Characteristics" as CFString,
                    kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
                ) as? [String: Any],
                let location = protocolChars["Physical Interconnect Location"] as? String,
                location == "External"
            else { continue }

            let interconnect = (protocolChars["Physical Interconnect"] as? String) ?? ""

            let displayName: String
            let productName: String
            if let deviceChars = IORegistryEntrySearchCFProperty(
                media,
                kIOServicePlane,
                "Device Characteristics" as CFString,
                kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
            ) as? [String: Any],
            let product = deviceChars["Product Name"] as? String,
            !product.trimmingCharacters(in: .whitespaces).isEmpty {
                productName = product.trimmingCharacters(in: .whitespaces)
                displayName = productName
            } else {
                productName = ""
                displayName = name
            }

            let isMemoryCard = interconnect.localizedCaseInsensitiveContains("SD") ||
                               productName.localizedCaseInsensitiveContains("SD")

            result[name] = ExternalDiskInfo(displayName: displayName, isMemoryCard: isMemoryCard)
        }
        return result
    }

    private func readExternalDiskActivities() -> [ExternalDiskActivity] {
        let currentDiskSet = Set(diskNames)
        if currentDiskSet != lastKnownDiskSet {
            cachedExternalDiskInfo = detectExternalDisks(among: diskNames)
            lastKnownDiskSet = currentDiskSet
        }

        guard !cachedExternalDiskInfo.isEmpty else { return [] }

        let now = CFAbsoluteTimeGetCurrent()
        var freshCounters: [String: DiskCounters] = [:]
        var activities: [ExternalDiskActivity] = []

        for (bsdName, info) in cachedExternalDiskInfo {
            guard let counters = diskCounters(for: bsdName, timestamp: now) else { continue }
            freshCounters[bsdName] = counters

            guard let prev = previousExternalDiskCounters[bsdName] else { continue }
            let elapsed = counters.timestamp - prev.timestamp
            guard elapsed > 0 else { continue }

            let readRate  = counters.readBytes  >= prev.readBytes  ? Double(counters.readBytes  - prev.readBytes)  / elapsed : 0
            let writeRate = counters.writeBytes >= prev.writeBytes ? Double(counters.writeBytes - prev.writeBytes) / elapsed : 0

            activities.append(ExternalDiskActivity(
                bsdName: bsdName,
                displayName: info.displayName,
                readBytesPerSecond: readRate,
                writeBytesPerSecond: writeRate,
                isMemoryCard: info.isMemoryCard
            ))
        }

        previousExternalDiskCounters = freshCounters
        return activities.sorted { $0.bsdName < $1.bsdName }
    }

    private func diskCounters(for diskName: String, timestamp: CFAbsoluteTime) -> DiskCounters? {
        guard let media = serviceForBSDName(diskName) else { return nil }
        defer { IOObjectRelease(media) }
        guard let driver = parentBlockStorageDriver(of: media) else { return nil }
        defer {
            if driver != media {
                IOObjectRelease(driver)
            }
        }

        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(driver, &properties, kCFAllocatorDefault, 0)
        guard
            result == KERN_SUCCESS,
            let dictionary = properties?.takeRetainedValue() as? [String: Any],
            let statistics = dictionary["Statistics"] as? [String: Any]
        else {
            return nil
        }

        let readBytes = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
        let writeBytes = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        return DiskCounters(readBytes: readBytes, writeBytes: writeBytes, timestamp: timestamp)
    }

    private func serviceForBSDName(_ bsdName: String) -> io_service_t? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        return service == 0 ? nil : service
    }

    private func parentBlockStorageDriver(of service: io_service_t) -> io_service_t? {
        var current = service

        while current != 0 {
            if let className = IOObjectCopyClass(current)?.takeRetainedValue() as String?,
               className == kIOBlockStorageDriverClass {
                return current
            }

            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if current != service {
                IOObjectRelease(current)
            }
            guard result == KERN_SUCCESS, parent != 0 else { return nil }
            current = parent
        }

        return nil
    }

    private func readCPUTemperature() -> Double? {
        let client = IOHIDEventSystemClientCreatePrivate(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        let temperatureEventType: Int64 = 15
        let temperatureField = Int32(temperatureEventType) << 16

        let dieValues = services.compactMap { service -> Double? in
            let usagePage = (IOHIDServiceClientCopyProperty(service, "PrimaryUsagePage" as CFString) as? NSNumber)?.intValue
            let usage = (IOHIDServiceClientCopyProperty(service, "PrimaryUsage" as CFString) as? NSNumber)?.intValue
            let product = (IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String) ?? ""

            guard usagePage == 0xff00, usage == 5 else { return nil }
            guard product.hasPrefix("PMU tdie") else { return nil }
            guard let event = IOHIDServiceClientCopyEventPrivate(service, temperatureEventType, 0, 0) else {
                return nil
            }

            let value = IOHIDEventGetFloatValuePrivate(event, temperatureField)
            guard value.isFinite, value > 0, value < 150 else { return nil }
            return value
        }

        return dieValues.max()
    }

    private func resolveTrackedDiskNames() -> [String] {
        let mountedIdentifiers = mountedDiskIdentifiers()
        var resolved = Set<String>()

        for identifier in mountedIdentifiers {
            resolved.formUnion(physicalDiskIdentifiers(for: identifier))
        }

        return resolved.sorted()
    }

    private func mountedDiskIdentifiers() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "df -l | tail -n +2 | awk '{print $1}' | sed 's#^/dev/##' | sort -u"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func physicalDiskIdentifiers(for identifier: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/dev/\(identifier)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [wholeDiskIdentifier(from: identifier)]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = plist as? [String: Any]
        else {
            return [wholeDiskIdentifier(from: identifier)]
        }

        if let stores = dictionary["APFSPhysicalStores"] as? [[String: Any]] {
            let physicalStores = stores.compactMap { $0["APFSPhysicalStore"] as? String }
            if !physicalStores.isEmpty {
                return physicalStores.map(wholeDiskIdentifier(from:))
            }
        }

        if let parentWholeDisk = dictionary["ParentWholeDisk"] as? String, !parentWholeDisk.isEmpty {
            return [wholeDiskIdentifier(from: parentWholeDisk)]
        }

        if let deviceIdentifier = dictionary["DeviceIdentifier"] as? String, !deviceIdentifier.isEmpty {
            return [wholeDiskIdentifier(from: deviceIdentifier)]
        }

        return [wholeDiskIdentifier(from: identifier)]
    }

    private func wholeDiskIdentifier(from identifier: String) -> String {
        identifier.replacingOccurrences(
            of: #"s\d+$"#,
            with: "",
            options: .regularExpression
        )
    }
}
