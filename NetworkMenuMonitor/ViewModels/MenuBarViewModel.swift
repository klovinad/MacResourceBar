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
        case totalRate, cpuRate, memoryRate, diskRate, networkRate, name, custom

        var label: String {
            switch self {
            case .totalRate:      "Activity"
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
            case .all: "Activity"
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
        case full
        case compact
        case mini

        var id: String { rawValue }

        var label: String {
            switch self {
            case .full: "Full"
            case .compact: "Compact"
            case .mini: "Mini"
            }
        }

        var helpText: String {
            switch self {
            case .full: "Readable labels with compact rates."
            case .compact: "Short labels with clear separators."
            case .mini: "Smallest format that keeps values and directions clear."
            }
        }
    }

    struct MenuBarDisplaySlot: Equatable {
        let id: String
        let text: String
        let widthTemplate: String
    }

    @Published private(set) var totalDownloadBytesPerSecond: Double = 0
    @Published private(set) var totalUploadBytesPerSecond: Double = 0
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

    private let preferences = MenuBarPreferences()
    private let totalsMonitor = NetworkTotalsMonitor()
    private let appResourceMonitor = AppResourceMonitor()
    private let systemMetricsMonitor = SystemMetricsMonitor()
    private let smoothingFactor = 0.28
    private let minimumVisibleRate: Double = 16
    private let maximumHistorySampleCount = 300
    private var perAppMonitoringVisible = false
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
                self.availableExternalDiskActivities = activities
                self.refreshExternalDiskSelection()
                self.refreshMenuBarTitle()
            }
        }

        totalsMonitor.start()
        systemMetricsMonitor.start()
        applyRefreshMode()
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
            let availableKeySet = Set(availableKeys)
            customAppOrder = customAppOrder.filter { availableKeySet.contains($0) }
            let storedKeys = Set(customAppOrder)
            customAppOrder.append(contentsOf: availableKeys.filter { !storedKeys.contains($0) })
            preferences.customAppOrder = customAppOrder
        }
        appSortOrder = order
        preferences.appSortOrderRawValue = order.rawValue
    }

    func moveApp(withKey draggedKey: String, relativeTo targetKey: String) {
        guard draggedKey != targetKey else { return }

        let availableKeys = appTableSnapshots.map(\.orderKey)
        let availableKeySet = Set(availableKeys)
        var order = customAppOrder.filter { availableKeySet.contains($0) }
        let knownKeys = Set(order)
        order.append(contentsOf: availableKeys.filter { !knownKeys.contains($0) })

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
        let availableKeySet = Set(availableKeys)
        var order = customAppOrder.filter { availableKeySet.contains($0) }
        let knownKeys = Set(order)
        order.append(contentsOf: availableKeys.filter { !knownKeys.contains($0) })
        order.removeAll { $0 == draggedKey }
        order.append(draggedKey)
        customAppOrder = order
        preferences.customAppOrder = order
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
        orderedVisibleTrayMetrics.flatMap {
            trayDisplaySlots(for: $0, style: style)
        }
    }

    var menuBarMiniDisplaySlots: [MenuBarDisplaySlot] {
        menuBarDisplaySlots(for: .mini)
    }

    var menuBarAccessibilityComponents: [String] {
        orderedVisibleTrayMetrics.flatMap {
            accessibilityTrayComponents(for: $0)
        }
    }

    var menuBarComponentSeparator: String {
        menuBarComponentSeparator(for: menuBarLabelStyle)
    }

    func menuBarComponentSeparator(for style: MenuBarLabelStyle) -> String {
        " "
    }

    var formattedCPUUsage: String {
        percentString(cpuUsagePercent)
    }

    var formattedMemoryUsage: String {
        percentString(memoryUsagePercent)
    }

    var formattedDiskActivity: String {
        ByteRateFormatter.cardRate(
            for: max(diskActivityMBPerSecond, 0) * 1024 * 1024
        )
    }

    var formattedExternalDiskActivity: String {
        ByteRateFormatter.cardRate(
            for: externalDiskActivities.reduce(0.0) {
                $0 + $1.readBytesPerSecond + $1.writeBytesPerSecond
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

    func setPopoverVisible(_ visible: Bool) {
        guard perAppMonitoringVisible != visible else { return }
        perAppMonitoringVisible = visible
        appSnapshotsAreFresh = false

        if visible {
            appResourceMonitor.start()
        } else {
            appResourceMonitor.stop()
        }
    }

    func setExternalDiskSelectionMode(_ mode: ExternalDiskSelectionMode) {
        guard externalDiskSelectionMode != mode else { return }
        externalDiskSelectionMode = mode
        preferences.externalDiskSelectionModeRawValue = mode.rawValue

        if mode == .selected && selectedExternalDiskIDs.isEmpty {
            selectedExternalDiskIDs = availableExternalDiskActivities.map(\.bsdName)
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
        return selectedExternalDiskIDs.contains(disk.bsdName)
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
            selectedExternalDiskIDs = [disk.bsdName]
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
            selectedExternalDiskIDs = availableExternalDiskActivities.map(\.bsdName)
        }

        if selected {
            if !selectedExternalDiskIDs.contains(disk.bsdName) {
                selectedExternalDiskIDs.append(disk.bsdName)
            }
        } else {
            selectedExternalDiskIDs.removeAll { $0 == disk.bsdName }
        }

        preferences.selectedExternalDiskIDs = selectedExternalDiskIDs
        refreshExternalDiskSelection()
        recordHistorySample()
        refreshMenuBarTitle()
    }

    func terminateProcess(_ snapshot: AppResourceSnapshot) {
        // The confirmation alert can close the transient popover, which marks
        // the table stale before the modal returns. The click itself is only
        // enabled for a fresh snapshot, so preserve that already-authorized
        // action instead of silently discarding it after confirmation.
        guard !snapshot.pids.isEmpty else { return }
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
                    text: miniGaugeText(prefix: "C", value: cpuUsagePercent, suffix: "%"),
                    widthTemplate: "C 999%"
                )
            ]
        case .cpuTemp:
            return [
                MenuBarDisplaySlot(
                    id: metric.rawValue,
                    text: cpuTemperatureCelsius.map {
                        miniGaugeText(prefix: "T", value: $0, suffix: "°")
                    } ?? "T —",
                    widthTemplate: "T 999°"
                )
            ]
        case .memory:
            return [
                MenuBarDisplaySlot(
                    id: metric.rawValue,
                    text: miniGaugeText(prefix: "R", value: memoryUsagePercent, suffix: "%"),
                    widthTemplate: "R 999%"
                )
            ]
        case .disk:
            return [
                MenuBarDisplaySlot(
                    id: metric.rawValue,
                    text: "D \(readableMiniTrayRate(for: diskBytesPerSecond))",
                    widthTemplate: "D 999M"
                )
            ]
        case .externalDisk:
            guard !externalDiskActivities.isEmpty else {
                return [
                    MenuBarDisplaySlot(
                        id: "external-disk-unavailable",
                        text: "EXT —",
                        widthTemplate: "EXT 999M"
                    )
                ]
            }

            return externalDiskActivities.map { disk in
                let label = externalDiskShortLabel(disk)
                let bytesPerSecond = disk.readBytesPerSecond + disk.writeBytesPerSecond
                return MenuBarDisplaySlot(
                    id: "external-disk-\(disk.bsdName)",
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
            switch style {
            case .full: return ["Network ↓ 999+ MB/s", "↑ 999+ MB/s"]
            case .compact: return ["↓ 999M", "↑ 999M"]
            case .mini: return miniTraySlots(for: metric).map(\.widthTemplate)
            }
        case .cpu:
            switch style {
            case .full, .compact: return ["CPU 100%"]
            case .mini: return ["C 100%"]
            }
        case .cpuTemp:
            switch style {
            case .full: return ["Temp 100°C"]
            case .compact: return ["T 100°"]
            case .mini: return ["T 100°"]
            }
        case .memory:
            switch style {
            case .full: return ["Memory 100%"]
            case .compact: return ["RAM 100%"]
            case .mini: return ["R 100%"]
            }
        case .disk:
            switch style {
            case .full: return ["Disk 1023.9M"]
            case .compact: return ["D 999M"]
            case .mini: return ["D 999M"]
            }
        case .externalDisk:
            guard !externalDiskActivities.isEmpty else {
                switch style {
                case .full: return ["External disks —"]
                case .compact: return ["EXT —"]
                case .mini: return ["EXT 999M"]
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
            case .mini:
                return [
                    "↓ \(ByteRateFormatter.networkMenuRate(for: totalDownloadBytesPerSecond))",
                    "↑ \(ByteRateFormatter.networkMenuRate(for: totalUploadBytesPerSecond))"
                ]
            }
        case .cpu:
            switch style {
            case .full:
                return [String(format: "CPU %.0f%%", cpuUsagePercent)]
            case .compact:
                return [String(format: "CPU %.0f%%", cpuUsagePercent)]
            case .mini:
                return [String(format: "C%.0f%%", cpuUsagePercent)]
            }
        case .cpuTemp:
            guard let cpuTemperatureCelsius else {
                switch style {
                case .full: return ["Temp —"]
                case .compact, .mini: return ["T—"]
                }
            }
            switch style {
            case .full:
                return [String(format: "Temp %.0f°C", cpuTemperatureCelsius)]
            case .compact:
                return [String(format: "T %.0f°", cpuTemperatureCelsius)]
            case .mini:
                return [String(format: "T%.0f°", cpuTemperatureCelsius)]
            }
        case .memory:
            switch style {
            case .full:
                return [String(format: "Memory %.0f%%", memoryUsagePercent)]
            case .compact:
                return [String(format: "RAM %.0f%%", memoryUsagePercent)]
            case .mini:
                return [String(format: "R%.0f%%", memoryUsagePercent)]
            }
        case .disk:
            switch style {
            case .full:
                return ["Disk \(compactTrayRate(for: diskBytesPerSecond))"]
            case .compact:
                return ["D \(readableMiniTrayRate(for: diskBytesPerSecond))"]
            case .mini:
                return ["D\(miniTrayRate(for: diskBytesPerSecond))"]
            }
        case .externalDisk:
            guard !externalDiskActivities.isEmpty else {
                switch style {
                case .full: return ["External disks —"]
                case .compact: return ["EXT—"]
                case .mini: return ["X—"]
                }
            }

            return externalDiskActivities.map { disk in
                let bytesPerSecond = disk.readBytesPerSecond + disk.writeBytesPerSecond
                switch style {
                case .full:
                    return "\(externalDiskShortLabel(disk)) "
                        + compactTrayRate(for: bytesPerSecond)
                case .compact:
                    return "\(externalDiskShortLabel(disk)) "
                        + readableMiniTrayRate(for: bytesPerSecond)
                case .mini:
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
            return [
                "Network download \(ByteRateFormatter.networkCardRate(for: totalDownloadBytesPerSecond)), "
                    + "upload \(ByteRateFormatter.networkCardRate(for: totalUploadBytesPerSecond))"
            ]
        case .cpu:
            return [String(format: "CPU %.0f percent", cpuUsagePercent)]
        case .cpuTemp:
            guard let cpuTemperatureCelsius else {
                return ["CPU temperature unavailable"]
            }
            return [String(format: "CPU temperature %.0f degrees Celsius", cpuTemperatureCelsius)]
        case .memory:
            return [String(format: "Memory %.0f percent", memoryUsagePercent)]
        case .disk:
            return ["Disk \(ByteRateFormatter.string(for: diskBytesPerSecond))"]
        case .externalDisk:
            guard !externalDiskActivities.isEmpty else {
                return ["External disks unavailable"]
            }
            return externalDiskActivities.map { disk in
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
        ByteRateFormatter.cardRate(
            for: disk.readBytesPerSecond + disk.writeBytesPerSecond
        )
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
        appSnapshotsRevision &+= 1
        appSnapshots = []
        historySamples = []
        perAppStatusMessage = nil
        refreshMenuBarTitle()
        if perAppMonitoringVisible {
            appResourceMonitor.restart()
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
        if perAppMonitoringVisible {
            appResourceMonitor.start()
        }
    }

    private func refreshExternalDiskSelection() {
        let availableIDs = Set(availableExternalDiskActivities.map(\.bsdName))
        let selectedIDs = Set(selectedExternalDiskIDs).intersection(availableIDs)

        switch externalDiskSelectionMode {
        case .all:
            externalDiskActivities = availableExternalDiskActivities
        case .selected:
            externalDiskActivities = availableExternalDiskActivities.filter {
                selectedIDs.contains($0.bsdName)
            }
        }
    }

    private func refreshMenuBarTitle() {
        let title = resolvedMenuBarTitle()
        guard title != menuBarTitle else { return }
        menuBarTitle = title
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

        recordExternalDiskHistory()
    }

    private func recordExternalDiskHistory() {
        let presentIDs = Set(externalDiskActivities.map(\.bsdName))
        externalDiskHistoryByID = externalDiskHistoryByID.filter { presentIDs.contains($0.key) }

        for disk in externalDiskActivities {
            var samples = externalDiskHistoryByID[disk.bsdName] ?? []
            samples.append(disk.readBytesPerSecond + disk.writeBytesPerSecond)
            if samples.count > maximumHistorySampleCount {
                samples.removeFirst(samples.count - maximumHistorySampleCount)
            }
            externalDiskHistoryByID[disk.bsdName] = samples
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
