import Foundation
import Darwin
@MainActor
final class MenuBarViewModel: ObservableObject {
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
    @Published private(set) var historySamples: [ResourceHistorySample] = []
    @Published private(set) var perAppStatusMessage: String?
    @Published private(set) var cpuUsagePercent: Double = 0
    @Published private(set) var memoryUsagePercent: Double = 0
    @Published private(set) var diskActivityMBPerSecond: Double = 0
    @Published private(set) var cpuTemperatureCelsius: Double?
    @Published private(set) var menuBarTitle = "0.0MB/s↓ 0.0MB/s↑"
    @Published private(set) var menuBarSystemTitle = ""
    @Published private(set) var menuBarNetworkTitle = "0.0MB/s↓ 0.0MB/s↑"
    @Published var launchAtLoginEnabled = LaunchAtLoginService.isEnabled
    @Published var appDisplayThresholdBytesPerSecond: Double
    @Published private(set) var appResourceFilter: AppResourceFilter
    @Published var highRefreshEnabled: Bool
    @Published var appSearchText: String
    @Published var activeAppsOnly: Bool
    @Published var showHelperProcesses: Bool
    @Published var backgroundOpacity: Double
    @Published private(set) var appSortOrder: AppSortOrder
    @Published private(set) var selectedTrayMetrics: [TrayMetric]
    @Published private(set) var trayMetricOrder: [TrayMetric]
    @Published private(set) var externalDiskActivities: [ExternalDiskActivity] = []

    private let preferences = MenuBarPreferences()
    private let totalsMonitor = NetworkTotalsMonitor()
    private let appResourceMonitor = AppResourceMonitor()
    private let systemMetricsMonitor = SystemMetricsMonitor()
    private let smoothingFactor = 0.18
    private let minimumVisibleRate: Double = 16
    private let maximumHistorySampleCount = 300
    private var preferredDownloadUnitIndex = 2
    private var preferredUploadUnitIndex = 2
    private var menuBarDownloadTitle = "0.0MB/s"
    private var menuBarUploadTitle = "0.0MB/s"
    private var isPerAppMonitoringEnabled = false
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
        appDisplayThresholdBytesPerSecond = preferences.appResourceThreshold
        appResourceFilter = AppResourceFilter(rawValue: preferences.appResourceFilterRawValue ?? "") ?? .all
        appSortOrder = AppSortOrder(rawValue: preferences.appSortOrderRawValue ?? "") ?? .totalRate
        highRefreshEnabled = preferences.highRefreshEnabled
        appSearchText = preferences.appSearchText
        activeAppsOnly = preferences.activeAppsOnly
        showHelperProcesses = preferences.showHelperProcesses
        backgroundOpacity = Self.clampedBackgroundOpacity(preferences.backgroundOpacity)

        let storedOrder = preferences.trayMetricOrderRawValues
            .compactMap { TrayMetric(rawValue: $0) }
        let normalizedTrayMetricOrder = Self.normalizedTrayMetricOrder(from: storedOrder)
        trayMetricOrder = normalizedTrayMetricOrder

        let storedMetrics = preferences.trayMetricRawValues
            .compactMap { TrayMetric(rawValue: $0) }
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
                self.cpuTemperatureCelsius = sample.cpuTemperatureCelsius
                self.recordHistorySample()
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
        appResourceMonitor.stop()
    }

    var filteredAppSnapshots: [AppResourceSnapshot] {
        appSnapshotFilterState.filteredSnapshots
    }

    func setAppSortOrder(_ order: AppSortOrder) {
        appSortOrder = order
        preferences.appSortOrderRawValue = order.rawValue
    }

    func setAppResourceFilter(_ filter: AppResourceFilter) {
        appResourceFilter = filter
        preferences.appResourceFilterRawValue = filter.rawValue

        let options = thresholdOptions(for: filter)
        if !options.contains(appDisplayThresholdBytesPerSecond) {
            appDisplayThresholdBytesPerSecond = options.first ?? 0
            preferences.appResourceThreshold = appDisplayThresholdBytesPerSecond
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
        appSnapshotFilterState.filteredCountText
    }

    var searchMatchCountText: String? {
        appSnapshotFilterState.searchMatchCountText
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

    var appTableSnapshots: [AppResourceSnapshot] {
        appSnapshotFilterState.tableSnapshots
    }

    private var appSnapshotFilterState: AppSnapshotFilterState {
        AppSnapshotFilterState(
            snapshots: appSnapshots,
            searchText: appSearchText,
            resourceFilter: appResourceFilter,
            threshold: appDisplayThresholdBytesPerSecond,
            sortOrder: appSortOrder,
            activeOnly: activeAppsOnly,
            showHelperProcesses: showHelperProcesses
        )
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
        preferences.appResourceThreshold = threshold
    }

    func setHighRefreshEnabled(_ enabled: Bool) {
        guard highRefreshEnabled != enabled else { return }
        highRefreshEnabled = enabled
        preferences.highRefreshEnabled = enabled
        applyRefreshMode()
    }

    func setAppSearchText(_ text: String) {
        appSearchText = text
        preferences.appSearchText = text
    }

    func setActiveAppsOnly(_ enabled: Bool) {
        activeAppsOnly = enabled
        preferences.activeAppsOnly = enabled
    }

    func setShowHelperProcesses(_ enabled: Bool) {
        showHelperProcesses = enabled
        preferences.showHelperProcesses = enabled
    }

    func setBackgroundOpacity(_ opacity: Double) {
        backgroundOpacity = Self.clampedBackgroundOpacity(opacity)
        preferences.backgroundOpacity = backgroundOpacity
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
        isPerAppMonitoringEnabled = false
    }

    func setPerAppMonitoringEnabled(_ enabled: Bool) {
        guard isPerAppMonitoringEnabled != enabled else { return }
        isPerAppMonitoringEnabled = enabled

        if enabled {
            appResourceMonitor.setPollingInterval(
                highRefreshEnabled ? RefreshProfile.highAppInterval : RefreshProfile.lowAppInterval
            )
            appResourceMonitor.start()
        } else {
            appResourceMonitor.stop()
            appSnapshots = []
            perAppStatusMessage = nil
        }
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
        preferences.trayMetricRawValues = selectedTrayMetrics.map(\.rawValue)
        preferences.trayMetricOrderRawValues = trayMetricOrder.map(\.rawValue)
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
        historySamples = []
        perAppStatusMessage = nil
        refreshMenuBarTitle()
        if isPerAppMonitoringEnabled {
            appResourceMonitor.restart()
        } else {
            appResourceMonitor.stop()
        }
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
        if isPerAppMonitoringEnabled {
            appResourceMonitor.start()
        }
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

    private func recordHistorySample() {
        let diskBytesPerSecond = max(diskActivityMBPerSecond, 0) * 1024 * 1024
        let externalDiskBytesPerSecond = externalDiskActivities.reduce(0.0) {
            $0 + $1.readBytesPerSecond + $1.writeBytesPerSecond
        }
        historySamples.append(ResourceHistorySample(
            timestamp: Date(),
            downloadBytesPerSecond: totalDownloadBytesPerSecond,
            uploadBytesPerSecond: totalUploadBytesPerSecond,
            cpuUsagePercent: cpuUsagePercent,
            memoryUsagePercent: memoryUsagePercent,
            cpuTemperatureCelsius: cpuTemperatureCelsius,
            diskBytesPerSecond: diskBytesPerSecond,
            externalDiskBytesPerSecond: externalDiskBytesPerSecond
        ))

        if historySamples.count > maximumHistorySampleCount {
            historySamples.removeFirst(historySamples.count - maximumHistorySampleCount)
        }
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

    private static func clampedBackgroundOpacity(_ opacity: Double) -> Double {
        min(max(opacity, 0.2), 1)
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
