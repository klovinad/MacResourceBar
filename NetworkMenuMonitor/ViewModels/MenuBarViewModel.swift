import Foundation
import Darwin
import SwiftUI
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
        case totalRate, cpuRate, memoryRate, diskRate, networkRate, name, custom

        var label: String {
            switch self {
            case .totalRate:      "Overall"
            case .cpuRate:        "CPU"
            case .memoryRate:     "Memory"
            case .diskRate:       "Disk"
            case .networkRate:    "Network"
            case .name:           "Name"
            case .custom:         "Custom"
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
            case .externalDisk: "External Disk"
            }
        }
    }

    enum ExternalDiskSelectionMode: String, CaseIterable {
        case all
        case selected

        var label: String {
            switch self {
            case .all: "All"
            case .selected: "Selected"
            }
        }
    }

    enum MenuBarLabelStyle: String, CaseIterable, Identifiable {
        case twoLines
        case icons
        case full
        case compact
        case mini

        var id: String { rawValue }

        var label: String {
            switch self {
            case .twoLines: "Two lines"
            case .icons: "Icons"
            case .full: "Full"
            case .compact: "Compact"
            case .mini: "Mini"
            }
        }

        var helpText: String {
            switch self {
            case .twoLines: "Two rows in each column. Network download and upload stay together."
            case .icons: "One row with resource icons and larger values."
            case .full: "Readable labels with compact rates."
            case .compact: "Short labels with clear separators."
            case .mini: "Smallest format that keeps values and directions clear."
            }
        }

        var graphicStyle: MenuBarGraphicRenderer.Style? {
            switch self {
            case .twoLines: .twoLines
            case .icons: .icons
            case .full, .compact, .mini: nil
            }
        }
    }

    struct MenuBarDisplaySlot: Equatable {
        let id: String
        let text: String
        let widthTemplate: String
        var pairID: String? = nil
    }

    @Published private(set) var totalDownloadBytesPerSecond: Double = 0
    @Published private(set) var totalUploadBytesPerSecond: Double = 0
    @Published private(set) var networkTotalsLastUpdatedAt: Date?
    @Published private(set) var networkTotalsStatusMessage: String?
    @Published private(set) var networkSourceDescription = "Primary interface"
    @Published private(set) var appSnapshots: [AppResourceSnapshot] = []
    @Published private(set) var appSnapshotsAreFresh = false
    @Published private(set) var historySamples: [ResourceHistorySample] = []
    @Published private(set) var externalDiskHistoryByID: [String: [Double]] = [:]
    @Published private(set) var perAppStatusMessage: String?
    @Published private(set) var settingsErrorMessage: String?
    @Published private(set) var cpuUsagePercent: Double = 0
    @Published private(set) var memoryUsagePercent: Double = 0
    @Published private(set) var diskActivityMBPerSecond: Double = 0
    @Published private(set) var cpuTemperatureCelsius: Double?
    @Published private(set) var cpuMetricIsAvailable = false
    @Published private(set) var memoryMetricIsAvailable = false
    @Published private(set) var diskMetricIsAvailable = false
    @Published private(set) var systemMetricsLastUpdatedAt: Date?
    @Published private(set) var compressedMemoryBytes: UInt64?
    @Published private(set) var swapUsedBytes: UInt64?
    @Published private(set) var memoryPressure: SystemMetricsSample.MemoryPressure = .normal
    @Published private(set) var menuBarTitle = "↓ 0M ↑ 0M"
    @Published var launchAtLoginEnabled = LaunchAtLoginService.isEnabled
    @Published var appDisplayThresholdBytesPerSecond: Double
    @Published private(set) var appResourceFilter: AppResourceFilter
    @Published var highRefreshEnabled: Bool
    @Published var appSearchText: String
    @Published var activeAppsOnly: Bool
    @Published var showHelperProcesses: Bool
    @Published var backgroundOpacity: Double
    @Published private(set) var appSortOrder: AppSortOrder
    @Published private(set) var customAppOrder: [String]
    @Published private(set) var selectedTrayMetrics: [TrayMetric]
    @Published private(set) var trayMetricOrder: [TrayMetric]
    @Published private(set) var menuBarLabelStyle: MenuBarLabelStyle
    @Published private(set) var externalDiskActivities: [ExternalDiskActivity] = []
    @Published private(set) var availableExternalDiskActivities: [ExternalDiskActivity] = []
    @Published private(set) var externalDiskSelectionMode: ExternalDiskSelectionMode
    @Published private(set) var selectedExternalDiskIDs: [String]
    @Published private(set) var networkSource: NetworkTotalsMonitor.Source

    private let preferences: MenuBarPreferences
    private let totalsMonitor = NetworkTotalsMonitor()
    private let appResourceMonitor = AppResourceMonitor()
    private let systemMetricsMonitor = SystemMetricsMonitor()
    private let smoothingFactor = 0.28
    private let minimumVisibleRate: Double = 16
    private let maximumHistorySampleCount = 300
    private var perAppMonitoringVisible = false
    private var settingsVisible = false
    private var appSnapshotsRevision = 0
    private var cachedAppSnapshotLists: (
        key: AppSnapshotListsCacheKey,
        lists: AppSnapshotFilterState.SnapshotLists
    )?

    private struct AppSnapshotListsCacheKey: Equatable {
        let snapshotsRevision: Int
        let searchText: String
        let resourceFilter: String
        let threshold: Double
        let sortOrder: String
        let customOrder: [String]
        let activeOnly: Bool
        let showHelperProcesses: Bool
    }
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

    let totalActivityThresholdOptions: [Double] = [0]

    let memoryThresholdOptions: [Double] = [
        0,
        16 * 1024 * 1024,
        32 * 1024 * 1024,
        64 * 1024 * 1024,
        128 * 1024 * 1024,
        256 * 1024 * 1024,
        512 * 1024 * 1024
    ]

    init(preferences: MenuBarPreferences = MenuBarPreferences(), startMonitoring: Bool = true) {
        self.preferences = preferences
        appDisplayThresholdBytesPerSecond = preferences.appResourceThreshold
        appResourceFilter = AppResourceFilter(rawValue: preferences.appResourceFilterRawValue ?? "") ?? .all
        appSortOrder = AppSortOrder(rawValue: preferences.appSortOrderRawValue ?? "") ?? .totalRate
        customAppOrder = preferences.customAppOrder
        highRefreshEnabled = preferences.highRefreshEnabled
        // Search is intentionally session-only. Restoring a hidden query made
        // the list appear inexplicably empty on the next launch.
        appSearchText = ""
        preferences.appSearchText = ""
        activeAppsOnly = preferences.activeAppsOnly
        showHelperProcesses = preferences.showHelperProcesses
        backgroundOpacity = Self.clampedBackgroundOpacity(preferences.backgroundOpacity)
        externalDiskSelectionMode = ExternalDiskSelectionMode(
            rawValue: preferences.externalDiskSelectionModeRawValue ?? ""
        ) ?? .all
        selectedExternalDiskIDs = preferences.selectedExternalDiskIDs
        networkSource = NetworkTotalsMonitor.Source(
            rawValue: preferences.networkSourceRawValue ?? ""
        ) ?? .primary
        menuBarLabelStyle = MenuBarLabelStyle(
            rawValue: preferences.menuBarLabelStyleRawValue ?? ""
        ) ?? .compact

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
                self.networkTotalsLastUpdatedAt = sample.timestamp
                self.networkTotalsStatusMessage = nil
                self.networkSourceDescription = sample.sourceDescription
                self.refreshMenuBarTitle()
            }
        }

        totalsMonitor.onReset = { [weak self] in
            Task { @MainActor in
                self?.handleNetworkPathReset()
            }
        }

        totalsMonitor.onStatusChange = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.networkTotalsStatusMessage = message
                if message != nil {
                    self.totalDownloadBytesPerSecond = 0
                    self.totalUploadBytesPerSecond = 0
                    self.networkTotalsLastUpdatedAt = nil
                    self.refreshMenuBarTitle()
                }
            }
        }

        appResourceMonitor.onUpdate = { [weak self] snapshots in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.perAppMonitoringVisible else { return }
                self.appSnapshotsRevision &+= 1
                self.appSnapshots = snapshots
                self.appSnapshotsAreFresh = true
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
                if let value = sample.cpuUsagePercent {
                    self.cpuUsagePercent = value
                    self.cpuMetricIsAvailable = true
                } else {
                    self.cpuMetricIsAvailable = false
                }
                if let value = sample.memoryUsagePercent {
                    self.memoryUsagePercent = value
                    self.memoryMetricIsAvailable = true
                } else {
                    self.memoryMetricIsAvailable = false
                }
                if let value = sample.diskActivityMBPerSecond {
                    self.diskActivityMBPerSecond = value
                    self.diskMetricIsAvailable = true
                } else {
                    self.diskMetricIsAvailable = false
                }
                self.cpuTemperatureCelsius = sample.cpuTemperatureCelsius
                self.compressedMemoryBytes = sample.compressedMemoryBytes
                self.swapUsedBytes = sample.swapUsedBytes
                self.memoryPressure = sample.memoryPressure
                self.systemMetricsLastUpdatedAt = sample.timestamp
                self.recordHistorySample()
                self.refreshMenuBarTitle()
            }
        }

        systemMetricsMonitor.onExternalDiskSample = { [weak self] activities in
            Task { @MainActor in
                guard let self else { return }
                self.availableExternalDiskActivities = activities
                self.migrateExternalDiskSelectionIfNeeded(using: activities)
                self.refreshExternalDiskSelection()
                self.refreshMenuBarTitle()
            }
        }

        if startMonitoring {
            totalsMonitor.setSource(networkSource)
            totalsMonitor.start()
            systemMetricsMonitor.start()
            applyRefreshMode()
        }
    }

    var filteredAppSnapshots: [AppResourceSnapshot] {
        appSnapshotLists.filtered
    }

    var appSnapshotLists: AppSnapshotFilterState.SnapshotLists {
        let key = AppSnapshotListsCacheKey(
            snapshotsRevision: appSnapshotsRevision,
            searchText: appSearchText,
            resourceFilter: appResourceFilter.rawValue,
            threshold: appDisplayThresholdBytesPerSecond,
            sortOrder: appSortOrder.rawValue,
            customOrder: customAppOrder,
            activeOnly: activeAppsOnly,
            showHelperProcesses: showHelperProcesses
        )
        if let cachedAppSnapshotLists, cachedAppSnapshotLists.key == key {
            return cachedAppSnapshotLists.lists
        }

        let lists = appSnapshotFilterState.snapshotLists
        cachedAppSnapshotLists = (key, lists)
        return lists
    }

    func setAppSortOrder(_ order: AppSortOrder) {
        // A helper process is a short-lived PID, so a persisted manual order
        // would become meaningless after it relaunches.
        guard !(showHelperProcesses && order == .custom) else { return }

        if order == .custom {
            let snapshotLists = appSnapshotLists
            let visibleKeys = snapshotLists.filtered.map(\.orderKey)
            let visibleKeySet = Set(visibleKeys)
            let availableKeys = visibleKeys
                + snapshotLists.table.map(\.orderKey).filter { !visibleKeySet.contains($0) }
            customAppOrder = customOrderIncludingAvailableKeys(availableKeys)
            preferences.customAppOrder = customAppOrder
        }
        appSortOrder = order
        preferences.appSortOrderRawValue = order.rawValue
    }

    func moveApp(withKey draggedKey: String, relativeTo targetKey: String) {
        guard draggedKey != targetKey else { return }

        let availableKeys = appTableSnapshots.map(\.orderKey)
        var order = customOrderIncludingAvailableKeys(availableKeys)

        guard
            let sourceIndex = order.firstIndex(of: draggedKey),
            let targetIndex = order.firstIndex(of: targetKey)
        else {
            return
        }

        order.remove(at: sourceIndex)
        guard let destinationIndex = order.firstIndex(of: targetKey) else { return }
        let insertionIndex = sourceIndex < targetIndex
            ? min(destinationIndex + 1, order.endIndex)
            : destinationIndex
        order.insert(draggedKey, at: insertionIndex)

        customAppOrder = order
        preferences.customAppOrder = order
    }

    func moveAppToEnd(withKey draggedKey: String) {
        let availableKeys = appTableSnapshots.map(\.orderKey)
        var order = customOrderIncludingAvailableKeys(availableKeys)
        order.removeAll { $0 == draggedKey }
        order.append(draggedKey)
        customAppOrder = order
        preferences.customAppOrder = order
    }

    private func customOrderIncludingAvailableKeys(_ availableKeys: [String]) -> [String] {
        StableOrderPolicy.merging(stored: customAppOrder, available: availableKeys)
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
            return "Off"
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

    var monitoringHasIssue: Bool {
        visiblePerAppStatusMessage != nil
            || networkTotalsStatusMessage != nil
            || networkTotalsLastUpdatedAt == nil
            || !cpuMetricIsAvailable
            || !memoryMetricIsAvailable
            || !diskMetricIsAvailable
    }

    var monitoringStatusSummary: String {
        monitoringHasIssue ? "Some data unavailable" : "Monitoring active"
    }

    var monitoringIssueDetails: String {
        var messages: [String] = []
        if let networkTotalsStatusMessage { messages.append(networkTotalsStatusMessage) }
        else if networkTotalsLastUpdatedAt == nil { messages.append("Network traffic is warming up") }
        if !cpuMetricIsAvailable { messages.append("CPU is warming up or unavailable") }
        if !memoryMetricIsAvailable { messages.append("Memory is unavailable") }
        if !diskMetricIsAvailable { messages.append("Internal disk activity is warming up or unavailable") }
        if let visiblePerAppStatusMessage { messages.append(visiblePerAppStatusMessage) }
        return messages.isEmpty ? "All selected monitors are reporting" : messages.joined(separator: ". ")
    }

    var memoryPressureLabel: String {
        switch memoryPressure {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
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
        appSnapshotLists.table
    }

    private var appSnapshotFilterState: AppSnapshotFilterState {
        AppSnapshotFilterState(
            snapshots: appSnapshots,
            searchText: appSearchText,
            resourceFilter: appResourceFilter,
            threshold: appDisplayThresholdBytesPerSecond,
            sortOrder: appSortOrder,
            customOrder: customAppOrder,
            activeOnly: activeAppsOnly,
            showHelperProcesses: showHelperProcesses
        )
    }

    func trayMetricEnabled(_ metric: TrayMetric) -> Bool {
        selectedTrayMetrics.contains(metric)
    }

    var orderedTrayMetricsForPopover: [TrayMetric] {
        trayMetricOrder
    }

    var orderedVisibleTrayMetrics: [TrayMetric] {
        let selectedSet = Set(selectedTrayMetrics)
        let orderedSelected = trayMetricOrder.filter { selectedSet.contains($0) }
        let base = orderedSelected.isEmpty ? [TrayMetric.network] : orderedSelected
        return base
    }

    var menuBarDisplayComponents: [String] {
        menuBarDisplayComponents(for: menuBarLabelStyle)
    }

    func menuBarDisplayComponents(for style: MenuBarLabelStyle) -> [String] {
        menuBarDisplaySlots(for: style).map(\.text)
    }

    func menuBarWidthTemplateComponents(for style: MenuBarLabelStyle) -> [String] {
        menuBarDisplaySlots(for: style).map(\.widthTemplate)
    }

    func menuBarDisplaySlots(for style: MenuBarLabelStyle) -> [MenuBarDisplaySlot] {
        if style.graphicStyle != nil {
            return menuBarGraphicEntries(for: style).map {
                MenuBarDisplaySlot(id: $0.id, text: "\($0.label) \($0.value)",
                                   widthTemplate: "\($0.label) \($0.widthTemplate)")
            }
        }
        let slots = orderedVisibleTrayMetrics.flatMap { metric in
            trayDisplaySlots(for: metric, style: style).map { slot in
                var result = slot
                result.pairID = metric == .network ? "network" : nil
                return result
            }
        }
        guard slots.isEmpty else { return slots }

        // An explicitly empty external-disk selection is valid, but the last
        // visible metric must never collapse into an invisible click target.
        return [MenuBarDisplaySlot(
            id: "status-item-fallback",
            text: "MRB",
            widthTemplate: "MRB"
        )]
    }

    var menuBarMiniDisplaySlots: [MenuBarDisplaySlot] {
        menuBarDisplaySlots(for: .mini)
    }

    func menuBarGraphicEntries(for style: MenuBarLabelStyle) -> [MenuBarGraphicEntry] {
        let detailed = style == .twoLines
        func rate(_ bytes: Double) -> String {
            detailed ? ByteRateFormatter.stableMenuRate(for: bytes, preferredUnitIndex: nil).text
                : readableMiniTrayRate(for: bytes)
        }
        let rateTemplate = detailed ? "1023.9MB/s" : "999M"
        let entries = orderedVisibleTrayMetrics.flatMap { metric -> [MenuBarGraphicEntry] in
            switch metric {
            case .network:
                return [
                    MenuBarGraphicEntry(id: "network-download", label: "↓",
                        value: networkTotalsLastUpdatedAt == nil ? "N/A" : (detailed
                            ? ByteRateFormatter.networkFullMenuRate(for: totalDownloadBytesPerSecond)
                            : ByteRateFormatter.networkMenuRate(for: totalDownloadBytesPerSecond)),
                        widthTemplate: detailed ? "999+ MB/s" : "999M", symbolName: "arrow.down", pairID: "network"),
                    MenuBarGraphicEntry(id: "network-upload", label: "↑",
                        value: networkTotalsLastUpdatedAt == nil ? "N/A" : (detailed
                            ? ByteRateFormatter.networkFullMenuRate(for: totalUploadBytesPerSecond)
                            : ByteRateFormatter.networkMenuRate(for: totalUploadBytesPerSecond)),
                        widthTemplate: detailed ? "999+ MB/s" : "999M", symbolName: "arrow.up", pairID: "network")
                ]
            case .cpu:
                return [MenuBarGraphicEntry(id: metric.rawValue, label: "CPU", value: formattedCPUUsage,
                    widthTemplate: "100%", symbolName: "cpu")]
            case .memory:
                return [MenuBarGraphicEntry(id: metric.rawValue, label: "RAM", value: formattedMemoryUsage,
                    widthTemplate: "100%", symbolName: "memorychip")]
            case .cpuTemp:
                return [MenuBarGraphicEntry(id: metric.rawValue, label: "Temp",
                    value: cpuTemperatureCelsius.map { String(format: "%.0f°", $0) } ?? "N/A",
                    widthTemplate: "100°", symbolName: "thermometer.medium")]
            case .disk:
                return [MenuBarGraphicEntry(id: metric.rawValue, label: "Disk",
                    value: diskMetricIsAvailable ? rate(max(diskActivityMBPerSecond, 0) * 1024 * 1024) : "N/A",
                    widthTemplate: rateTemplate, symbolName: "internaldrive")]
            case .externalDisk:
                guard !externalDiskActivities.isEmpty else {
                    return externalDiskSelectionIsExplicitlyEmpty ? [] : [MenuBarGraphicEntry(
                        id: "external-disk-unavailable", label: "EXT", value: "N/A",
                        widthTemplate: rateTemplate, symbolName: "externaldrive")]
                }
                return externalDiskActivities.map { disk in
                    MenuBarGraphicEntry(id: "external-disk-\(disk.persistentID)", label: externalDiskShortLabel(disk),
                        value: disk.activityIsAvailable ? rate(disk.readBytesPerSecond + disk.writeBytesPerSecond) : "N/A",
                        widthTemplate: rateTemplate, symbolName: "externaldrive", showsLabelWithIcon: true)
                }
            }
        }
        return entries.isEmpty ? [MenuBarGraphicEntry(
            id: "status-item-fallback", label: "", value: "MRB", widthTemplate: "MRB", symbolName: nil
        )] : entries
    }

    var menuBarAccessibilityComponents: [String] {
        let components = orderedVisibleTrayMetrics.flatMap {
            accessibilityTrayComponents(for: $0)
        }
        return components.isEmpty
            ? ["MacResourceBar, no external disks selected"]
            : components
    }

    private var externalDiskSelectionIsExplicitlyEmpty: Bool {
        externalDiskSelectionMode == .selected
            && !availableExternalDiskActivities.isEmpty
            && externalDiskActivities.isEmpty
    }

    var menuBarComponentSeparator: String {
        menuBarComponentSeparator(for: menuBarLabelStyle)
    }

    func menuBarComponentSeparator(for style: MenuBarLabelStyle) -> String {
        " "
    }

    var formattedCPUUsage: String {
        cpuMetricIsAvailable ? percentString(cpuUsagePercent) : "N/A"
    }

    var formattedMemoryUsage: String {
        memoryMetricIsAvailable ? percentString(memoryUsagePercent) : "N/A"
    }

    var formattedDiskActivity: String {
        guard diskMetricIsAvailable else { return "N/A" }
        return ByteRateFormatter.cardRate(
            for: max(diskActivityMBPerSecond, 0) * 1024 * 1024
        )
    }

    var formattedCompressedMemory: String {
        guard let compressedMemoryBytes else { return "N/A" }
        return Self.memoryFormatter.string(fromByteCount: Int64(clamping: compressedMemoryBytes))
    }

    var formattedSwapUsed: String {
        guard let swapUsedBytes else { return "N/A" }
        return Self.memoryFormatter.string(fromByteCount: Int64(clamping: swapUsedBytes))
    }

    var systemMetricsFreshnessText: String {
        guard let systemMetricsLastUpdatedAt else { return "Waiting for system metrics" }
        let age = max(Int(Date().timeIntervalSince(systemMetricsLastUpdatedAt).rounded()), 0)
        return age <= 1 ? "Updated now" : "Updated \(age) seconds ago"
    }

    var networkFreshnessText: String {
        if let networkTotalsStatusMessage {
            return networkTotalsStatusMessage
        }
        guard let networkTotalsLastUpdatedAt else { return "Waiting for network traffic" }
        let age = max(Int(Date().timeIntervalSince(networkTotalsLastUpdatedAt).rounded()), 0)
        let freshness = age <= 1 ? "updated now" : "updated \(age) seconds ago"
        return "\(networkSourceDescription), \(freshness)"
    }

    var processMonitoringStateText: String {
        if let visiblePerAppStatusMessage {
            return visiblePerAppStatusMessage
        }
        guard perAppMonitoringVisible else { return "Runs only while the popover is open" }
        return appSnapshotsAreFresh
            ? "Current, \(appSnapshots.count) application rows"
            : "Collecting application activity"
    }

    var formattedExternalDiskActivity: String {
        guard externalDiskActivities.contains(where: \.activityIsAvailable) else {
            return "N/A"
        }
        return ByteRateFormatter.cardRate(
            for: externalDiskActivities.reduce(0.0) { result, disk in
                guard disk.activityIsAvailable else { return result }
                return result + disk.readBytesPerSecond + disk.writeBytesPerSecond
            }
        )
    }

    var formattedCPUTemperature: String {
        guard let cpuTemperatureCelsius else { return "N/A" }
        return String(format: "%.0f°C", cpuTemperatureCelsius)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            launchAtLoginEnabled = try LaunchAtLoginService.setEnabled(enabled)
            settingsErrorMessage = nil
        } catch {
            launchAtLoginEnabled = LaunchAtLoginService.isEnabled
            settingsErrorMessage = "Launch at login could not be updated: \(error.localizedDescription)"
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

    func setNetworkSource(_ source: NetworkTotalsMonitor.Source) {
        guard networkSource != source else { return }
        networkSource = source
        preferences.networkSourceRawValue = source.rawValue
        networkTotalsLastUpdatedAt = nil
        networkTotalsStatusMessage = "Waiting for \(source.label.lowercased()) traffic"
        totalsMonitor.setSource(source)
        refreshMenuBarTitle()
    }

    func setAppSearchText(_ text: String) {
        appSearchText = text
    }

    func setActiveAppsOnly(_ enabled: Bool) {
        activeAppsOnly = enabled
        preferences.activeAppsOnly = enabled
    }

    func setShowHelperProcesses(_ enabled: Bool) {
        guard showHelperProcesses != enabled else { return }
        if enabled, appSortOrder == .custom {
            setAppSortOrder(.totalRate)
        }
        showHelperProcesses = enabled
        preferences.showHelperProcesses = enabled
    }

    func resetAppFilters() {
        setAppSearchText("")
        setAppResourceFilter(.all)
        setAppDisplayThreshold(0)
        setActiveAppsOnly(false)
        setShowHelperProcesses(false)
    }

    func setBackgroundOpacity(_ opacity: Double) {
        backgroundOpacity = Self.clampedBackgroundOpacity(opacity)
        preferences.backgroundOpacity = backgroundOpacity
    }

    func setMenuBarLabelStyle(_ style: MenuBarLabelStyle) {
        guard menuBarLabelStyle != style else { return }
        menuBarLabelStyle = style
        preferences.menuBarLabelStyleRawValue = style.rawValue
        refreshMenuBarTitle()
    }

    func moveMenuBarLabelStyle(_ direction: MoveCommandDirection) {
        guard direction == .left || direction == .right,
              let current = MenuBarLabelStyle.allCases.firstIndex(of: menuBarLabelStyle) else { return }
        let next = current + (direction == .left ? -1 : 1)
        guard MenuBarLabelStyle.allCases.indices.contains(next) else { return }
        setMenuBarLabelStyle(MenuBarLabelStyle.allCases[next])
    }

    func setPopoverVisible(_ visible: Bool) {
        guard perAppMonitoringVisible != visible else { return }
        perAppMonitoringVisible = visible
        appSnapshotsAreFresh = false

        if visible {
            appResourceMonitor.start()
        } else {
            appResourceMonitor.stop()
        }
        updateSystemCollectionOptions()
    }

    func setSettingsVisible(_ visible: Bool) {
        guard settingsVisible != visible else { return }
        settingsVisible = visible
        updateSystemCollectionOptions()
    }

    func setExternalDiskSelectionMode(_ mode: ExternalDiskSelectionMode) {
        guard externalDiskSelectionMode != mode else { return }
        externalDiskSelectionMode = mode
        preferences.externalDiskSelectionModeRawValue = mode.rawValue

        if mode == .selected && selectedExternalDiskIDs.isEmpty {
            selectedExternalDiskIDs = availableExternalDiskActivities.map(\.persistentID)
            preferences.selectedExternalDiskIDs = selectedExternalDiskIDs
        }

        refreshExternalDiskSelection()
        recordHistorySample()
        refreshMenuBarTitle()
    }

    func externalDiskSelected(_ disk: ExternalDiskActivity) -> Bool {
        if externalDiskSelectionMode == .all {
            return true
        }
        return selectedExternalDiskIDs.contains(disk.persistentID)
    }

    func externalDiskShownInMenuBar(_ disk: ExternalDiskActivity) -> Bool {
        trayMetricEnabled(.externalDisk) && externalDiskSelected(disk)
    }

    func setExternalDiskShownInMenuBar(_ disk: ExternalDiskActivity, shown: Bool) {
        if shown, !trayMetricEnabled(.externalDisk) {
            // A disk row is a direct menu-bar control. When the whole group is
            // hidden, clicking one row starts a focused selection instead of
            // unexpectedly restoring every connected disk.
            externalDiskSelectionMode = .selected
            preferences.externalDiskSelectionModeRawValue = ExternalDiskSelectionMode.selected.rawValue
            selectedExternalDiskIDs = [disk.persistentID]
            preferences.selectedExternalDiskIDs = selectedExternalDiskIDs
            refreshExternalDiskSelection()
            toggleTrayMetric(.externalDisk)
            recordHistorySample()
            refreshMenuBarTitle()
            return
        }

        setExternalDisk(disk, selected: shown)
    }

    func setExternalDisk(_ disk: ExternalDiskActivity, selected: Bool) {
        // "All" is the backwards-compatible default. The first attempt to
        // hide one disk turns it into an explicit selection containing every
        // other currently connected disk. This makes the per-disk controls
        // useful without forcing the user through the Settings picker first.
        if externalDiskSelectionMode == .all {
            guard !selected else { return }
            externalDiskSelectionMode = .selected
            preferences.externalDiskSelectionModeRawValue = ExternalDiskSelectionMode.selected.rawValue
            selectedExternalDiskIDs = availableExternalDiskActivities.map(\.persistentID)
        }

        if selected {
            if !selectedExternalDiskIDs.contains(disk.persistentID) {
                selectedExternalDiskIDs.append(disk.persistentID)
            }
        } else {
            selectedExternalDiskIDs.removeAll { $0 == disk.persistentID }
        }

        preferences.selectedExternalDiskIDs = selectedExternalDiskIDs
        refreshExternalDiskSelection()
        recordHistorySample()
        refreshMenuBarTitle()
    }

    func terminateProcess(_ snapshot: AppResourceSnapshot) {
        let candidates = snapshot.pids.filter { pid in
            pid > 1 && pid != getpid() && snapshot.processIdentities[pid] != nil
        }
        guard !candidates.isEmpty else {
            perAppStatusMessage = "This process can no longer be terminated safely. Refresh the list and try again."
            return
        }

        var terminated = 0
        var skipped = 0
        var failures: [String] = []

        for pid in candidates {
            guard
                let expected = snapshot.processIdentities[pid],
                let current = ProcessIdentity.capture(for: pid),
                current.startTimeMicroseconds == expected.startTimeMicroseconds,
                expected.executablePath == nil || current.executablePath == expected.executablePath
            else {
                skipped += 1
                continue
            }

            if kill(pid, SIGTERM) == 0 {
                terminated += 1
            } else {
                let reason = String(cString: strerror(errno))
                failures.append("PID \(pid): \(reason)")
            }
        }

        if failures.isEmpty, skipped == 0 {
            perAppStatusMessage = terminated == 1
                ? "Termination request sent to \(snapshot.displayName)."
                : "Termination requests sent to \(terminated) processes in \(snapshot.displayName)."
        } else {
            var parts: [String] = []
            if terminated > 0 { parts.append("sent: \(terminated)") }
            if skipped > 0 { parts.append("changed or already closed: \(skipped)") }
            if !failures.isEmpty { parts.append(failures.joined(separator: "; ")) }
            perAppStatusMessage = "Termination result for \(snapshot.displayName): " + parts.joined(separator: ", ")
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
        updateSystemCollectionOptions()
        refreshMenuBarTitle()
    }

    func toggleTrayMetric(_ metric: TrayMetric) {
        guard selectedTrayMetrics.count > 1 || !selectedTrayMetrics.contains(metric) else {
            return
        }
        if selectedTrayMetrics.contains(metric) {
            selectedTrayMetrics.removeAll { $0 == metric }
        } else {
            selectedTrayMetrics.append(metric)
        }
        selectedTrayMetrics = Self.normalizedSelectedMetrics(selectedTrayMetrics, using: trayMetricOrder)

        persistTrayConfiguration()
        updateSystemCollectionOptions()
        refreshMenuBarTitle()
    }

    func moveTrayMetricToEnd(_ metric: TrayMetric) {
        var updatedOrder = trayMetricOrder
        updatedOrder.removeAll { $0 == metric }
        updatedOrder.append(metric)
        trayMetricOrder = Self.normalizedTrayMetricOrder(from: updatedOrder)
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

    func moveTrayMetric(
        _ metric: TrayMetric,
        relativeTo target: TrayMetric,
        insertAfter: Bool
    ) {
        guard
            metric != target,
            trayMetricOrder.contains(metric),
            trayMetricOrder.contains(target)
        else {
            return
        }

        var updatedOrder = trayMetricOrder
        updatedOrder.removeAll { $0 == metric }
        guard let destinationIndex = updatedOrder.firstIndex(of: target) else { return }
        let insertionIndex = insertAfter
            ? min(destinationIndex + 1, updatedOrder.endIndex)
            : destinationIndex
        updatedOrder.insert(metric, at: insertionIndex)
        updatedOrder = Self.normalizedTrayMetricOrder(from: updatedOrder)
        guard updatedOrder != trayMetricOrder else { return }

        trayMetricOrder = updatedOrder
        selectedTrayMetrics = Self.normalizedSelectedMetrics(selectedTrayMetrics, using: trayMetricOrder)
        persistTrayConfiguration()
        refreshMenuBarTitle()
    }

    private func miniTraySlots(for metric: TrayMetric) -> [MenuBarDisplaySlot] {
        let diskBytesPerSecond = max(diskActivityMBPerSecond, 0) * 1024 * 1024

        switch metric {
        case .network:
            guard networkTotalsLastUpdatedAt != nil else {
                return [MenuBarDisplaySlot(id: metric.rawValue, text: "NET N/A", widthTemplate: "NET 999M")]
            }
            return [
                MenuBarDisplaySlot(
                    id: "network-download",
                    text: "↓ \(ByteRateFormatter.networkMenuRate(for: totalDownloadBytesPerSecond))",
                    widthTemplate: "↓ 999M"
                ),
                MenuBarDisplaySlot(
                    id: "network-upload",
                    text: "↑ \(ByteRateFormatter.networkMenuRate(for: totalUploadBytesPerSecond))",
                    widthTemplate: "↑ 999M"
                )
            ]
        case .cpu:
            return [
                MenuBarDisplaySlot(
                    id: metric.rawValue,
                    text: cpuMetricIsAvailable
                        ? miniGaugeText(prefix: "C", value: cpuUsagePercent, suffix: "%")
                        : "C N/A",
                    widthTemplate: "C 999%"
                )
            ]
        case .cpuTemp:
            return [
                MenuBarDisplaySlot(
                    id: metric.rawValue,
                    text: cpuTemperatureCelsius.map {
                        miniGaugeText(prefix: "T", value: $0, suffix: "°")
                    } ?? "T N/A",
                    widthTemplate: "T 999°"
                )
            ]
        case .memory:
            return [
                MenuBarDisplaySlot(
                    id: metric.rawValue,
                    text: memoryMetricIsAvailable
                        ? miniGaugeText(prefix: "R", value: memoryUsagePercent, suffix: "%")
                        : "R N/A",
                    widthTemplate: "R 999%"
                )
            ]
        case .disk:
            return [
                MenuBarDisplaySlot(
                    id: metric.rawValue,
                    text: diskMetricIsAvailable
                        ? "D \(readableMiniTrayRate(for: diskBytesPerSecond))"
                        : "D N/A",
                    widthTemplate: "D 999M"
                )
            ]
        case .externalDisk:
            guard !externalDiskActivities.isEmpty else {
                if externalDiskSelectionIsExplicitlyEmpty {
                    return []
                }
                return [
                    MenuBarDisplaySlot(
                        id: "external-disk-unavailable",
                        text: "EXT N/A",
                        widthTemplate: "EXT 999M"
                    )
                ]
            }

            return externalDiskActivities.map { disk in
                let label = externalDiskShortLabel(disk)
                guard disk.activityIsAvailable else {
                    return MenuBarDisplaySlot(
                        id: "external-disk-\(disk.persistentID)",
                        text: "\(label) N/A",
                        widthTemplate: "\(label) 999M"
                    )
                }
                let bytesPerSecond = disk.readBytesPerSecond + disk.writeBytesPerSecond
                return MenuBarDisplaySlot(
                    id: "external-disk-\(disk.persistentID)",
                    text: "\(label) \(readableMiniTrayRate(for: bytesPerSecond))",
                    widthTemplate: "\(label) 999M"
                )
            }
        }
    }

    private func trayDisplaySlots(
        for metric: TrayMetric,
        style: MenuBarLabelStyle
    ) -> [MenuBarDisplaySlot] {
        if style == .mini {
            return miniTraySlots(for: metric)
        }

        let components = trayComponents(for: metric, style: style)
        let templates = trayWidthTemplates(for: metric, style: style)
        return zip(components, templates).enumerated().map { index, pair in
            MenuBarDisplaySlot(
                id: "\(style.rawValue)-\(metric.rawValue)-\(index)",
                text: pair.0,
                widthTemplate: pair.1
            )
        }
    }

    private func trayWidthTemplates(
        for metric: TrayMetric,
        style: MenuBarLabelStyle
    ) -> [String] {
        switch metric {
        case .network:
            guard networkTotalsLastUpdatedAt != nil else {
                switch style {
                case .full: return ["Network N/A"]
                case .compact, .mini, .twoLines, .icons: return ["NET N/A"]
                }
            }
            switch style {
            case .full: return ["Network ↓ 999+ MB/s", "↑ 999+ MB/s"]
            case .compact: return ["↓ 999M", "↑ 999M"]
            case .mini, .twoLines, .icons: return miniTraySlots(for: metric).map(\.widthTemplate)
            }
        case .cpu:
            guard cpuMetricIsAvailable else {
                switch style {
                case .full, .compact: return ["CPU N/A"]
                case .mini, .twoLines, .icons: return ["C N/A"]
                }
            }
            switch style {
            case .full, .compact: return ["CPU 100%"]
            case .mini, .twoLines, .icons: return ["C 100%"]
            }
        case .cpuTemp:
            switch style {
            case .full: return ["Temp 100°C"]
            case .compact: return ["T 100°"]
            case .mini, .twoLines, .icons: return ["T 100°"]
            }
        case .memory:
            guard memoryMetricIsAvailable else {
                switch style {
                case .full: return ["Memory N/A"]
                case .compact: return ["RAM N/A"]
                case .mini, .twoLines, .icons: return ["R N/A"]
                }
            }
            switch style {
            case .full: return ["Memory 100%"]
            case .compact: return ["RAM 100%"]
            case .mini, .twoLines, .icons: return ["R 100%"]
            }
        case .disk:
            guard diskMetricIsAvailable else {
                return [style == .full ? "Disk N/A" : "D N/A"]
            }
            switch style {
            case .full: return ["Disk 1023.9M"]
            case .compact: return ["D 999M"]
            case .mini, .twoLines, .icons: return ["D 999M"]
            }
        case .externalDisk:
            guard !externalDiskActivities.isEmpty else {
                if externalDiskSelectionIsExplicitlyEmpty {
                    return []
                }
                switch style {
                case .full: return ["External disks N/A"]
                case .compact: return ["EXT N/A"]
                case .mini, .twoLines, .icons: return ["EXT 999M"]
                }
            }

            return externalDiskActivities.map { disk in
                let maximumRate = style == .full ? "1023.9M" : "999M"
                return "\(externalDiskShortLabel(disk)) \(maximumRate)"
            }
        }
    }

    private func trayComponents(
        for metric: TrayMetric,
        style: MenuBarLabelStyle
    ) -> [String] {
        if style == .mini {
            return miniTraySlots(for: metric).map(\.text)
        }

        let diskBytesPerSecond = max(diskActivityMBPerSecond, 0) * 1024 * 1024

        switch metric {
        case .network:
            guard networkTotalsLastUpdatedAt != nil else {
                return [style == .full ? "Network N/A" : "NET N/A"]
            }
            switch style {
            case .full:
                return [
                    "Network ↓ \(ByteRateFormatter.networkFullMenuRate(for: totalDownloadBytesPerSecond))",
                    "↑ \(ByteRateFormatter.networkFullMenuRate(for: totalUploadBytesPerSecond))"
                ]
            case .compact:
                return [
                    "↓ \(ByteRateFormatter.networkMenuRate(for: totalDownloadBytesPerSecond))",
                    "↑ \(ByteRateFormatter.networkMenuRate(for: totalUploadBytesPerSecond))"
                ]
            case .mini, .twoLines, .icons:
                return [
                    "↓ \(ByteRateFormatter.networkMenuRate(for: totalDownloadBytesPerSecond))",
                    "↑ \(ByteRateFormatter.networkMenuRate(for: totalUploadBytesPerSecond))"
                ]
            }
        case .cpu:
            guard cpuMetricIsAvailable else {
                switch style {
                case .full, .compact: return ["CPU N/A"]
                case .mini, .twoLines, .icons: return ["C N/A"]
                }
            }
            switch style {
            case .full:
                return [String(format: "CPU %.0f%%", cpuUsagePercent)]
            case .compact:
                return [String(format: "CPU %.0f%%", cpuUsagePercent)]
            case .mini, .twoLines, .icons:
                return [String(format: "C%.0f%%", cpuUsagePercent)]
            }
        case .cpuTemp:
            guard let cpuTemperatureCelsius else {
                switch style {
                case .full: return ["Temp N/A"]
                case .compact, .mini, .twoLines, .icons: return ["T N/A"]
                }
            }
            switch style {
            case .full:
                return [String(format: "Temp %.0f°C", cpuTemperatureCelsius)]
            case .compact:
                return [String(format: "T %.0f°", cpuTemperatureCelsius)]
            case .mini, .twoLines, .icons:
                return [String(format: "T%.0f°", cpuTemperatureCelsius)]
            }
        case .memory:
            guard memoryMetricIsAvailable else {
                switch style {
                case .full: return ["Memory N/A"]
                case .compact: return ["RAM N/A"]
                case .mini, .twoLines, .icons: return ["R N/A"]
                }
            }
            switch style {
            case .full:
                return [String(format: "Memory %.0f%%", memoryUsagePercent)]
            case .compact:
                return [String(format: "RAM %.0f%%", memoryUsagePercent)]
            case .mini, .twoLines, .icons:
                return [String(format: "R%.0f%%", memoryUsagePercent)]
            }
        case .disk:
            guard diskMetricIsAvailable else {
                switch style {
                case .full: return ["Disk N/A"]
                case .compact, .mini, .twoLines, .icons: return ["D N/A"]
                }
            }
            switch style {
            case .full:
                return ["Disk \(compactTrayRate(for: diskBytesPerSecond))"]
            case .compact:
                return ["D \(readableMiniTrayRate(for: diskBytesPerSecond))"]
            case .mini, .twoLines, .icons:
                return ["D\(miniTrayRate(for: diskBytesPerSecond))"]
            }
        case .externalDisk:
            guard !externalDiskActivities.isEmpty else {
                if externalDiskSelectionIsExplicitlyEmpty {
                    return []
                }
                switch style {
                case .full: return ["External disks N/A"]
                case .compact: return ["EXT N/A"]
                case .mini, .twoLines, .icons: return ["X N/A"]
                }
            }

            return externalDiskActivities.map { disk in
                guard disk.activityIsAvailable else {
                    let label = externalDiskShortLabel(disk)
                    return "\(label) N/A"
                }
                let bytesPerSecond = disk.readBytesPerSecond + disk.writeBytesPerSecond
                switch style {
                case .full:
                    return "\(externalDiskShortLabel(disk)) "
                        + compactTrayRate(for: bytesPerSecond)
                case .compact:
                    return "\(externalDiskShortLabel(disk)) "
                        + readableMiniTrayRate(for: bytesPerSecond)
                case .mini, .twoLines, .icons:
                    return "\(externalDiskShortLabel(disk)):"
                        + miniTrayRate(for: bytesPerSecond)
                }
            }
        }
    }

    private func compactTrayRate(for bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 0.5 else { return "0M" }

        let compact = ByteRateFormatter.stableMenuRate(
            for: bytesPerSecond,
            preferredUnitIndex: nil
        ).text
            .replacingOccurrences(of: "TB/s", with: "T")
            .replacingOccurrences(of: "GB/s", with: "G")
            .replacingOccurrences(of: "MB/s", with: "M")
            .replacingOccurrences(of: "KB/s", with: "K")
            .replacingOccurrences(of: "B/s", with: "B")

        for unit in ["B", "K", "M", "G", "T"] where compact.hasSuffix(".0\(unit)") {
            return String(compact.dropLast(3)) + unit
        }
        return compact
    }

    private func miniTrayRate(for bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        guard value >= 0.5 else { return "0B" }

        let units = ["B", "K", "M", "G", "T", "P", "E"]
        var scaled = value
        var unitIndex = 0
        while scaled >= 1024, unitIndex < units.count - 1 {
            scaled /= 1024
            unitIndex += 1
        }

        let roundingFactor = scaled >= 10 ? 1.0 : 10.0
        scaled = (scaled * roundingFactor).rounded() / roundingFactor
        // Mini is a glanceable four-character rate. Promote slightly
        // before the binary boundary instead of emitting values such as
        // "1023M", which would widen every field in the status item.
        if scaled >= 1000, unitIndex < units.count - 1 {
            scaled /= 1024
            unitIndex += 1
        }
        if scaled >= 1000 {
            scaled = 999
        }

        let number: String
        if scaled >= 10 {
            number = String(format: "%.0f", scaled)
        } else {
            number = String(format: "%.1f", scaled)
                .replacingOccurrences(of: ".0", with: "")
        }
        return number + units[unitIndex]
    }

    private func readableMiniTrayRate(for bytesPerSecond: Double) -> String {
        let rate = miniTrayRate(for: bytesPerSecond)
        if rate == "0B" {
            return "0.0M"
        }

        guard
            rate.count == 2,
            let unit = rate.last,
            ["B", "K", "M", "G", "T", "P", "E"].contains(String(unit))
        else {
            return rate
        }
        return "\(rate.dropLast()).0\(unit)"
    }

    /// Keep the label/value boundary explicit at every magnitude. The slot
    /// template reserves the possible third digit, so following metrics stay
    /// fixed when a value crosses 100.
    private func miniGaugeText(prefix: String, value: Double, suffix: String) -> String {
        let rounded = min(max(Int(value.rounded()), 0), 999)
        return "\(prefix) \(rounded)\(suffix)"
    }

    private func accessibilityTrayComponents(for metric: TrayMetric) -> [String] {
        let diskBytesPerSecond = max(diskActivityMBPerSecond, 0) * 1024 * 1024

        switch metric {
        case .network:
            guard networkTotalsLastUpdatedAt != nil else {
                return ["Network unavailable"]
            }
            return [
                "Network download \(ByteRateFormatter.networkCardRate(for: totalDownloadBytesPerSecond)), "
                    + "upload \(ByteRateFormatter.networkCardRate(for: totalUploadBytesPerSecond))"
            ]
        case .cpu:
            guard cpuMetricIsAvailable else { return ["CPU unavailable"] }
            return [String(format: "CPU %.0f percent", cpuUsagePercent)]
        case .cpuTemp:
            guard let cpuTemperatureCelsius else {
                return ["CPU temperature unavailable"]
            }
            return [String(format: "CPU temperature %.0f degrees Celsius", cpuTemperatureCelsius)]
        case .memory:
            guard memoryMetricIsAvailable else { return ["Memory unavailable"] }
            return [String(format: "Memory %.0f percent", memoryUsagePercent)]
        case .disk:
            guard diskMetricIsAvailable else { return ["Disk unavailable"] }
            return ["Disk \(ByteRateFormatter.string(for: diskBytesPerSecond))"]
        case .externalDisk:
            guard !externalDiskActivities.isEmpty else {
                if externalDiskSelectionIsExplicitlyEmpty {
                    return []
                }
                return ["External disks unavailable"]
            }
            return externalDiskActivities.map { disk in
                guard disk.activityIsAvailable else {
                    return "\(externalDiskDisplayLabel(for: disk)) unavailable"
                }
                let bytesPerSecond = disk.readBytesPerSecond + disk.writeBytesPerSecond
                return "\(externalDiskDisplayLabel(for: disk)) "
                    + ByteRateFormatter.string(for: bytesPerSecond)
            }
        }
    }

    private func externalDiskDisplayName(_ disk: ExternalDiskActivity) -> String {
        let displayName = disk.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? disk.bsdName : displayName
    }

    func externalDiskDisplayLabel(for disk: ExternalDiskActivity) -> String {
        let baseLabel = externalDiskDisplayName(disk)
        // The picker also renders hidden disks, so disambiguate against every
        // connected device rather than only the currently selected subset.
        let matchingDisks = availableExternalDiskActivities.filter { candidate in
            externalDiskDisplayName(candidate)
                .localizedCaseInsensitiveCompare(baseLabel) == .orderedSame
        }
        return matchingDisks.count > 1
            ? "\(baseLabel) (\(disk.bsdName))"
            : baseLabel
    }

    private func externalDiskShortLabel(_ disk: ExternalDiskActivity) -> String {
        let firstWord = externalDiskDisplayName(disk)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .first(where: { !$0.isEmpty }) ?? "EXT"
        let baseLabel = String(firstWord.prefix(3)).uppercased()
        let collidingDisks = externalDiskActivities.filter { candidate in
            let candidateWord = externalDiskDisplayName(candidate)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .first(where: { !$0.isEmpty }) ?? "EXT"
            return String(candidateWord.prefix(3)).uppercased() == baseLabel
        }
        guard collidingDisks.count > 1 else { return baseLabel }

        let numericSuffix = disk.bsdName.filter(\.isNumber)
        return numericSuffix.isEmpty
            ? "\(baseLabel)-\(disk.bsdName.uppercased())"
            : "\(baseLabel)\(numericSuffix)"
    }

    func externalDiskRateText(for disk: ExternalDiskActivity) -> String {
        guard disk.activityIsAvailable else { return "N/A" }
        return ByteRateFormatter.cardRate(
            for: disk.readBytesPerSecond + disk.writeBytesPerSecond
        )
    }

    func externalDiskCapacityText(for disk: ExternalDiskActivity) -> String? {
        guard let capacity = disk.capacityBytes else { return nil }
        let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: capacity), countStyle: .file)
        guard let available = disk.availableBytes else { return total }
        let free = ByteCountFormatter.string(fromByteCount: Int64(clamping: available), countStyle: .file)
        return "\(free) free of \(total)"
    }

    private func persistTrayConfiguration() {
        preferences.trayMetricRawValues = selectedTrayMetrics.map(\.rawValue)
        preferences.trayMetricOrderRawValues = trayMetricOrder.map(\.rawValue)
    }

    private func smoothedRate(current: Double, incoming: Double) -> Double {
        if !highRefreshEnabled {
            return incoming < minimumVisibleRate ? 0 : incoming
        }

        let blended = current == 0
            ? incoming
            : (current * (1 - smoothingFactor)) + (incoming * smoothingFactor)

        return blended < minimumVisibleRate ? 0 : blended
    }

    private func handleNetworkPathReset() {
        totalDownloadBytesPerSecond = 0
        totalUploadBytesPerSecond = 0
        networkTotalsLastUpdatedAt = nil
        historySamples = []
        networkTotalsStatusMessage = "Waiting for network traffic sample"
        refreshMenuBarTitle()
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
        if perAppMonitoringVisible {
            appResourceMonitor.start()
        }
        updateSystemCollectionOptions()
    }

    private func updateSystemCollectionOptions() {
        if perAppMonitoringVisible || settingsVisible {
            systemMetricsMonitor.setCollectionOptions(.all)
            return
        }

        var options: SystemMetricsMonitor.CollectionOptions = []
        let selected = Set(selectedTrayMetrics)
        if selected.contains(.cpu) { options.insert(.cpu) }
        if selected.contains(.memory) { options.insert(.memory) }
        if selected.contains(.disk) { options.insert(.disk) }
        if selected.contains(.cpuTemp) { options.insert(.temperature) }
        if selected.contains(.externalDisk) { options.insert(.externalDisks) }
        systemMetricsMonitor.setCollectionOptions(options)
    }

    private func refreshExternalDiskSelection() {
        let availableIDs = Set(availableExternalDiskActivities.map(\.persistentID))
        let selectedIDs = Set(selectedExternalDiskIDs).intersection(availableIDs)

        switch externalDiskSelectionMode {
        case .all:
            externalDiskActivities = availableExternalDiskActivities
        case .selected:
            externalDiskActivities = availableExternalDiskActivities.filter {
                selectedIDs.contains($0.persistentID)
            }
        }
    }

    private func migrateExternalDiskSelectionIfNeeded(using disks: [ExternalDiskActivity]) {
        var migrated = selectedExternalDiskIDs
        var changed = false
        for disk in disks where migrated.contains(disk.bsdName) {
            migrated.removeAll { $0 == disk.bsdName }
            if !migrated.contains(disk.persistentID) {
                migrated.append(disk.persistentID)
            }
            changed = true
        }
        guard changed else { return }
        selectedExternalDiskIDs = migrated
        preferences.selectedExternalDiskIDs = migrated
    }

    private func refreshMenuBarTitle() {
        let title = resolvedMenuBarTitle()
        guard title != menuBarTitle else { return }
        menuBarTitle = title
    }

    private func recordHistorySample() {
        guard cpuMetricIsAvailable, memoryMetricIsAvailable, diskMetricIsAvailable else {
            return
        }
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

        recordExternalDiskHistory()
    }

    private func recordExternalDiskHistory() {
        let presentIDs = Set(externalDiskActivities.map(\.persistentID))
        externalDiskHistoryByID = externalDiskHistoryByID.filter { presentIDs.contains($0.key) }

        for disk in externalDiskActivities {
            guard disk.activityIsAvailable else { continue }
            var samples = externalDiskHistoryByID[disk.persistentID] ?? []
            samples.append(disk.readBytesPerSecond + disk.writeBytesPerSecond)
            if samples.count > maximumHistorySampleCount {
                samples.removeFirst(samples.count - maximumHistorySampleCount)
            }
            externalDiskHistoryByID[disk.persistentID] = samples
        }
    }

    private func percentString(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private func resolvedMenuBarTitle() -> String {
        menuBarDisplayComponents.joined(separator: menuBarComponentSeparator)
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
        min(max(opacity, 0.55), 1)
    }

}
