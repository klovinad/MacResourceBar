import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let macResourceBarAppOrder = UTType(
        exportedAs: "com.klovinad.MacResourceBar.app-order"
    )
}

private struct AppOrderDragItem: Codable, Transferable {
    let key: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .macResourceBarAppOrder)
    }
}

private enum TrayMetricDropEdge: Equatable {
    case before
    case after
}

private struct TrayMetricDropPlacement: Equatable {
    let targetMetric: MenuBarViewModel.TrayMetric
    let edge: TrayMetricDropEdge
}

private struct TrayMetricDropDelegate: DropDelegate {
    typealias TrayMetric = MenuBarViewModel.TrayMetric

    let targetMetric: TrayMetric
    let targetHeight: CGFloat
    @Binding var draggedMetric: TrayMetric?
    @Binding var dropPlacement: TrayMetricDropPlacement?
    let animation: Animation?
    let moveMetric: (TrayMetric, TrayMetric, TrayMetricDropEdge) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggedMetric != nil
            && info.hasItemsConforming(to: [UTType.utf8PlainText.identifier])
    }

    func dropEntered(info: DropInfo) {
        updateDropPlacement(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        updateDropPlacement(info: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropPlacement?.targetMetric == targetMetric {
            dropPlacement = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let sourceMetric = draggedMetric else {
            clearDragState()
            return false
        }

        let placement = placement(for: info)
        withAnimation(animation) {
            moveMetric(sourceMetric, placement.targetMetric, placement.edge)
        }

        clearDragState()
        return true
    }

    private func updateDropPlacement(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        let proposedPlacement = placement(for: info)
        guard proposedPlacement != dropPlacement else { return }
        dropPlacement = proposedPlacement
    }

    private func placement(for info: DropInfo) -> TrayMetricDropPlacement {
        TrayMetricDropPlacement(
            targetMetric: targetMetric,
            edge: info.location.y < targetHeight / 2 ? .before : .after
        )
    }

    private func clearDragState() {
        draggedMetric = nil
        dropPlacement = nil
    }
}

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var draggedTrayMetric: MenuBarViewModel.TrayMetric?
    @State private var trayMetricDropPlacement: TrayMetricDropPlacement?
    @State private var draggedAppKey: String?
    @State private var hoveredTrayMetric: MenuBarViewModel.TrayMetric?
    @State private var lockedAppOrder: [String]?
    @State private var isAppTableHovered = false

    private let tableScrollbarReserve: CGFloat = 14
    private let sidebarWidth: CGFloat = 200

    var body: some View {
        ZStack(alignment: .top) {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            } else {
                Rectangle()
                    .fill(.regularMaterial)
                    .ignoresSafeArea()

                Color(nsColor: .windowBackgroundColor)
                    .opacity(viewModel.backgroundOpacity)
                    .ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 10) {
                header

                HStack(alignment: .top, spacing: 12) {
                    sidebar
                        .frame(width: sidebarWidth, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 8) {
                        appTableControls
                        Divider()
                        content
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onDisappear {
            resetTrayMetricDragState()
            hoveredTrayMetric = nil
            isAppTableHovered = false
            lockedAppOrder = nil
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.gradient)
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("MacResourceBar")
                    .font(.headline)

                HStack(spacing: 5) {
                    Circle()
                        .fill(viewModel.visiblePerAppStatusMessage == nil ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(viewModel.visiblePerAppStatusMessage == nil ? "Monitoring active" : "Some data unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text("Labels")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Menu bar label style", selection: Binding(
                    get: { viewModel.menuBarLabelStyle },
                    set: { viewModel.setMenuBarLabelStyle($0) }
                )) {
                    ForEach(MenuBarViewModel.MenuBarLabelStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Text("Update")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Update interval", selection: Binding(
                    get: { viewModel.highRefreshEnabled },
                    set: { viewModel.setHighRefreshEnabled($0) }
                )) {
                    Text("1s").tag(true)
                    Text("10s").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 94)
                .controlSize(.small)
            }

            Button {
                NotificationCenter.default.post(name: .networkMenuMonitorOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Settings")
            .accessibilityLabel("Open settings")
        }
    }

    private enum SummaryItem: Identifiable {
        case metric(MenuBarViewModel.TrayMetric)
        case externalDisks

        var id: String {
            switch self {
            case .metric(let metric): "metric-\(metric.rawValue)"
            case .externalDisks: "metric-external-disks"
            }
        }
    }

    private var summaryItems: [SummaryItem] {
        viewModel.orderedTrayMetricsForPopover.flatMap { metric -> [SummaryItem] in
            guard metric == .externalDisk else { return [.metric(metric)] }
            return [.externalDisks]
        }
    }

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("MENU BAR METRICS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)

                ForEach(summaryItems) { item in
                    switch item {
                    case .metric(let metric):
                        sidebarMetricRow(
                            color: historyColor(for: metric),
                            label: metricTitle(for: metric),
                            value: metricValue(for: metric),
                            samples: historySamples(for: metric),
                            trayMetric: metric
                        )
                    case .externalDisks:
                        externalDisksSection
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var externalDisksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarMetricRow(
                color: .blue,
                label: "External",
                value: metricValue(for: .externalDisk),
                samples: historySamples(for: .externalDisk),
                trayMetric: .externalDisk
            )

            Group {
                if viewModel.availableExternalDiskActivities.isEmpty {
                    Text("No external disks connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 26)
                        .padding(.trailing, 10)
                        .padding(.bottom, 7)
                } else {
                    ForEach(viewModel.availableExternalDiskActivities) { disk in
                        externalDiskCompactRow(disk)
                    }
                }
            }
            .opacity(viewModel.trayMetricEnabled(.externalDisk) ? 1 : 0.42)

            Divider()
                .padding(.leading, 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sidebarMetricRow(
        color: Color,
        label: String,
        value: String,
        samples: [Double],
        trayMetric: MenuBarViewModel.TrayMetric,
        handlesReordering: Bool = true
    ) -> some View {
        let isEnabled = viewModel.trayMetricEnabled(trayMetric)
        let isHovered = hoveredTrayMetric == trayMetric

        let row = HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .stroke(
                                isEnabled ? color.opacity(0.24) : Color.secondary.opacity(0.55),
                                lineWidth: 1
                            )
                            .frame(width: 11, height: 11)
                        Circle()
                            .fill(isEnabled ? color : Color.clear)
                            .frame(width: 7, height: 7)
                    }
                    .frame(width: 13, height: 24)

                    Text(label)
                        .font(.callout)
                        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(value)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Group {
                    if samples.count > 1 {
                        Sparkline(
                            samples: samples,
                            color: color,
                            range: sparklineRange(for: trayMetric)
                        )
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 10)
                .padding(.leading, 7)
                .accessibilityHidden(true)
            }
            .padding(.leading, 9)
            .padding(.trailing, 4)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 43, alignment: .leading)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 43)
                .opacity(
                    isHovered || trayMetricDropPlacement?.targetMetric == trayMetric
                        ? 0.78
                        : 0.28
                )
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 43, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            trayMetricDropPlacement?.targetMetric == trayMetric
                ? Color.accentColor.opacity(0.13)
                : (isHovered ? Color.primary.opacity(0.045) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 22)
        }
        .overlay(alignment: .top) {
            if trayMetricDropPlacement == TrayMetricDropPlacement(
                targetMetric: trayMetric,
                edge: .before
            ) {
                trayMetricDropIndicator
            }
        }
        .overlay(alignment: .bottom) {
            if trayMetricDropPlacement == TrayMetricDropPlacement(
                targetMetric: trayMetric,
                edge: .after
            ) {
                trayMetricDropIndicator
            }
        }
        .onTapGesture {
            viewModel.toggleTrayMetric(trayMetric)
        }
        .help(
            isEnabled && viewModel.selectedTrayMetrics.count == 1
                ? "At least one metric must remain shown; drag to reorder"
                : "Click to show or hide \(trayMetric.title); drag to reorder"
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(trayMetric.title) in menu bar")
        .accessibilityValue("\(value), \(isEnabled ? "shown" : "hidden")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            viewModel.toggleTrayMetric(trayMetric)
        }

        return trayMetricReorderable(
            row,
            metric: trayMetric,
            enabled: handlesReordering
        )
    }

    @ViewBuilder
    private func trayMetricReorderable<Content: View>(
        _ content: Content,
        metric: MenuBarViewModel.TrayMetric,
        enabled: Bool
    ) -> some View {
        if enabled {
            content
                .onHover { hovering in
                    updateTrayMetricHover(metric, hovering: hovering)
                }
                .onDrag {
                    beginTrayMetricDrag(metric)
                } preview: {
                    metricChipPreview(metric)
                }
                .onDrop(
                    of: [.utf8PlainText],
                    delegate: trayMetricDropDelegate(for: metric)
                )
        } else {
            content
        }
    }

    private func updateTrayMetricHover(
        _ metric: MenuBarViewModel.TrayMetric,
        hovering: Bool
    ) {
        if hovering {
            hoveredTrayMetric = metric
        } else if hoveredTrayMetric == metric {
            hoveredTrayMetric = nil
        }
    }

    private func beginTrayMetricDrag(
        _ metric: MenuBarViewModel.TrayMetric
    ) -> NSItemProvider {
        draggedTrayMetric = metric
        trayMetricDropPlacement = nil

        return NSItemProvider(object: metric.rawValue as NSString)
    }

    private func trayMetricDropDelegate(
        for targetMetric: MenuBarViewModel.TrayMetric
    ) -> TrayMetricDropDelegate {
        TrayMetricDropDelegate(
            targetMetric: targetMetric,
            targetHeight: 43,
            draggedMetric: $draggedTrayMetric,
            dropPlacement: $trayMetricDropPlacement,
            animation: reduceMotion ? nil : .easeOut(duration: 0.12)
        ) { sourceMetric, destinationMetric, edge in
            viewModel.moveTrayMetric(
                sourceMetric,
                relativeTo: destinationMetric,
                insertAfter: edge == .after
            )
        }
    }

    private func resetTrayMetricDragState() {
        draggedTrayMetric = nil
        trayMetricDropPlacement = nil
    }

    private var trayMetricDropIndicator: some View {
        Capsule(style: .continuous)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 8)
            .shadow(color: Color.accentColor.opacity(0.3), radius: 1)
            .accessibilityHidden(true)
    }

    private func externalDiskCompactRow(_ disk: ExternalDiskActivity) -> some View {
        let isSelected = viewModel.externalDiskShownInMenuBar(disk)

        return Button {
            viewModel.setExternalDiskShownInMenuBar(disk, shown: !isSelected)
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .stroke(
                            isSelected ? Color.blue.opacity(0.28) : Color.secondary.opacity(0.55),
                            lineWidth: 1
                        )
                        .frame(width: 11, height: 11)
                    Circle()
                        .fill(isSelected ? Color.blue : Color.clear)
                        .frame(width: 7, height: 7)
                }
                .frame(width: 13, height: 24)

                Text(externalDiskChipTitle(disk))
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.secondary : Color.secondary.opacity(0.62))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(viewModel.externalDiskRateText(for: disk))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 25)
        .padding(.trailing, 30)
        .frame(maxWidth: .infinity, minHeight: 27)
        .help("Click to \(isSelected ? "hide" : "show") \(externalDiskChipTitle(disk)) in the menu bar")
        .accessibilityLabel("\(externalDiskChipTitle(disk)) in menu bar")
        .accessibilityValue("\(viewModel.externalDiskRateText(for: disk)), \(isSelected ? "shown" : "hidden")")
    }

    private func externalDiskChipTitle(_ disk: ExternalDiskActivity) -> String {
        viewModel.externalDiskDisplayLabel(for: disk)
    }

    private var appTableControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                TextField("Search applications", text: Binding(
                    get: { viewModel.appSearchText },
                    set: { viewModel.setAppSearchText($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)

                HStack(spacing: 5) {
                    Text("Show")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Applications", selection: Binding(
                        get: { viewModel.activeAppsOnly },
                        set: { viewModel.setActiveAppsOnly($0) }
                    )) {
                        Text("All").tag(false)
                        Text("Active").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 112)
                    .help("Show all applications or only applications with current activity")
                }

                Menu {
                    Toggle("List helper processes separately", isOn: Binding(
                        get: { viewModel.showHelperProcesses },
                        set: { viewModel.setShowHelperProcesses($0) }
                    ))

                    Divider()

                    Button("Reset filters") {
                        viewModel.resetAppFilters()
                    }
                    .disabled(!hasActiveAppFilters)
                } label: {
                    Image(systemName: viewModel.showHelperProcesses ? "slider.horizontal.3.circle.fill" : "slider.horizontal.3")
                        .foregroundStyle(viewModel.showHelperProcesses ? Color.accentColor : Color.primary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
                .help("Table options")
                .accessibilityLabel("Table options")
                .accessibilityValue(viewModel.showHelperProcesses ? "Helper processes listed separately" : "Related processes grouped")
            }

            HStack(spacing: 12) {
                resourceFilterControl
                sortControl
                thresholdControl
                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
    }

    private var resourceFilterControl: some View {
        HStack(spacing: 5) {
            Text("Metric")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Metric", selection: Binding(
                get: { viewModel.appResourceFilter },
                set: { viewModel.setAppResourceFilter($0) }
            )) {
                ForEach(MenuBarViewModel.AppResourceFilter.allCases, id: \.self) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .labelsHidden()
            .frame(width: 86)
            .help("Choose which resource the minimum filter uses")
        }
    }

    private var sortControl: some View {
        HStack(spacing: 5) {
            Text("Sort")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Sort", selection: Binding(
                get: { viewModel.appSortOrder },
                set: { viewModel.setAppSortOrder($0) }
            )) {
                ForEach(MenuBarViewModel.AppSortOrder.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                        .disabled(viewModel.showHelperProcesses && order == .custom)
                }
            }
            .labelsHidden()
            .frame(width: 94)
            .help("Sort applications")
        }
    }

    private var thresholdControl: some View {
        HStack(spacing: 5) {
            Text("Minimum")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Minimum", selection: Binding(
                get: { viewModel.appDisplayThresholdBytesPerSecond },
                set: { viewModel.setAppDisplayThreshold($0) }
            )) {
                ForEach(viewModel.thresholdOptions, id: \.self) { threshold in
                    Text(thresholdLabel(for: threshold))
                        .tag(threshold)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 90)
            .help("Minimum activity to show")
        }
    }

    private var hasActiveAppFilters: Bool {
        !viewModel.appSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.appResourceFilter != .all
            || viewModel.appDisplayThresholdBytesPerSecond > 0
            || viewModel.activeAppsOnly
            || viewModel.showHelperProcesses
    }

    @ViewBuilder
    private var content: some View {
        let snapshotLists = viewModel.appSnapshotLists
        let liveSnapshots = snapshotLists.filtered
        let snapshots = interactionOrderedSnapshots(
            liveSnapshots: liveSnapshots,
            allSnapshots: snapshotLists.table
        )
        let totalCount = snapshotLists.table.count

        VStack(alignment: .leading, spacing: 8) {
            appResourceTableHeader(visibleCount: snapshots.count, totalCount: totalCount)

            if let message = viewModel.visiblePerAppStatusMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            }

            if !viewModel.appSnapshots.isEmpty, !viewModel.appSnapshotsAreFresh {
                Label("Refreshing process data…", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }

            if viewModel.appSnapshots.isEmpty {
                emptyState(
                    title: "Collecting application activity…",
                    systemImage: "clock.arrow.circlepath"
                )
            } else if snapshots.isEmpty {
                emptyState(
                    title: emptyAppTableMessage,
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Color.clear
                                .frame(height: 1)
                                .id(appListTopAnchorID)

                            appResourceList(snapshots)
                                .padding(.trailing, tableScrollbarReserve)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo(appListTopAnchorID, anchor: .top)
                        }
                    }
                    .onChange(of: tableScrollResetID) { _ in
                        lockedAppOrder = isAppTableHovered && viewModel.appSortOrder != .custom
                            ? liveSnapshots.map(\.orderKey)
                            : nil
                        DispatchQueue.main.async {
                            proxy.scrollTo(appListTopAnchorID, anchor: .top)
                        }
                    }
                    .onHover { hovering in
                        isAppTableHovered = hovering
                        if hovering, viewModel.appSortOrder != .custom {
                            lockedAppOrder = lockedAppOrder ?? liveSnapshots.map(\.orderKey)
                        } else {
                            lockedAppOrder = nil
                        }
                    }
                    .transaction { transaction in
                        if viewModel.appSortOrder != .custom {
                            transaction.animation = nil
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func interactionOrderedSnapshots(
        liveSnapshots: [AppResourceSnapshot],
        allSnapshots: [AppResourceSnapshot]
    ) -> [AppResourceSnapshot] {
        guard
            viewModel.appSortOrder != .custom,
            let lockedAppOrder
        else {
            return liveSnapshots
        }

        var byKey: [String: AppResourceSnapshot] = [:]
        for snapshot in allSnapshots {
            byKey[snapshot.orderKey] = snapshot
        }

        // Keep both order and membership stable while the pointer is inside
        // the table. Values still come from the freshest snapshot, and a
        // process that actually ended disappears because it is no longer in
        // the unfiltered table source.
        return lockedAppOrder.compactMap { byKey[$0] }
    }

    private var appListTopAnchorID: String {
        "app-list-top"
    }

    private var tableScrollResetID: String {
        [
            viewModel.appSearchText,
            viewModel.appResourceFilter.rawValue,
            viewModel.appSortOrder.rawValue,
            String(viewModel.appDisplayThresholdBytesPerSecond),
            viewModel.activeAppsOnly ? "active" : "all",
            viewModel.showHelperProcesses ? "helpers" : "grouped"
        ].joined(separator: "|")
    }

    private func appResourceTableHeader(visibleCount: Int, totalCount: Int) -> some View {
        let countText = visibleCount == totalCount
            ? "\(totalCount)"
            : "\(visibleCount) of \(totalCount)"

        return HStack(spacing: 8) {
            metricHeader(
                "Applications · \(countText)",
                width: AppResourceRow.columnWidths.application,
                alignment: .leading,
                sortOrder: .name
            )

            metricHeader("CPU", width: AppResourceRow.columnWidths.cpu, alignment: .trailing, sortOrder: .cpuRate)
            metricHeader("Memory", width: AppResourceRow.columnWidths.ram, alignment: .trailing, sortOrder: .memoryRate)
            metricHeader("Disk", width: AppResourceRow.columnWidths.disk, alignment: .trailing, sortOrder: .diskRate)
            metricHeader("Network", width: AppResourceRow.columnWidths.network, alignment: .trailing, sortOrder: .networkRate)
            Color.clear
                .frame(width: AppResourceRow.columnWidths.kill, height: 1)
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 18)
        .padding(.trailing, tableScrollbarReserve)
    }

    private func appResourceList(_ snapshots: [AppResourceSnapshot]) -> some View {
        let isReordering = viewModel.appSortOrder == .custom

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(snapshots) { snapshot in
                AppResourceRow(
                    snapshot: snapshot,
                    showsDragHandle: isReordering,
                    allowsTermination: viewModel.appSnapshotsAreFresh
                ) {
                    confirmTermination(of: snapshot)
                }
                .frame(minHeight: 42)
                .background(
                    draggedAppKey == snapshot.orderKey ? Color.accentColor.opacity(0.12) : Color.clear
                )
                .contentShape(Rectangle())
                .dropDestination(for: AppOrderDragItem.self) { items, _ in
                    guard
                        isReordering,
                        let draggedKey = items.first?.key,
                        draggedKey != snapshot.orderKey
                    else {
                        draggedAppKey = nil
                        return false
                    }

                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                        viewModel.moveApp(withKey: draggedKey, relativeTo: snapshot.orderKey)
                    }
                    draggedAppKey = nil
                    return true
                } isTargeted: { isTargeted in
                    if isTargeted, isReordering {
                        draggedAppKey = snapshot.orderKey
                    } else if draggedAppKey == snapshot.orderKey {
                        draggedAppKey = nil
                    }
                }

                Divider()
            }

            if isReordering {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line")
                    Text("Drop here to move to the end")
                }
                .font(.caption)
                .foregroundStyle(draggedAppKey == appListEndTargetID ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(
                    draggedAppKey == appListEndTargetID
                        ? Color.accentColor.opacity(0.08)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
                .dropDestination(for: AppOrderDragItem.self) { items, _ in
                    guard let draggedKey = items.first?.key else {
                        draggedAppKey = nil
                        return false
                    }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                        viewModel.moveAppToEnd(withKey: draggedKey)
                    }
                    draggedAppKey = nil
                    return true
                } isTargeted: { isTargeted in
                    if isTargeted {
                        draggedAppKey = appListEndTargetID
                    } else if draggedAppKey == appListEndTargetID {
                        draggedAppKey = nil
                    }
                }
            }
        }
    }

    private var appListEndTargetID: String {
        "app-list-end-drop-target"
    }

    private var emptyAppTableMessage: String {
        hasActiveAppFilters
            ? "No applications match the current filters."
            : "No applications to show."
    }

    private func emptyState(title: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if hasActiveAppFilters, !viewModel.appSnapshots.isEmpty {
                Button("Reset filters") {
                    viewModel.resetAppFilters()
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func thresholdLabel(for threshold: Double) -> String {
        switch viewModel.appResourceFilter {
        case .all:
            return threshold <= 0 ? "Off" : "\(Int(threshold)) pts"
        case .cpu:
            return threshold <= 0 ? "Off" : "\(Int(threshold))%"
        case .memory:
            let formatter = ByteCountFormatter()
            formatter.countStyle = .memory
            formatter.isAdaptive = true
            return threshold <= 0 ? "Off" : formatter.string(fromByteCount: Int64(threshold))
        case .disk, .network:
            return ByteRateFormatter.thresholdString(for: threshold)
        }
    }

    private func metricHeader(
        _ title: String,
        width: CGFloat?,
        alignment: Alignment = .leading,
        sortOrder: MenuBarViewModel.AppSortOrder
    ) -> some View {
        let isActive = viewModel.appSortOrder == sortOrder

        return Button {
            viewModel.setAppSortOrder(sortOrder)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if isActive {
                    Image(systemName: sortOrder == .name ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.caption.weight(isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: alignment)
        .accessibilityLabel("Sort by \(title)")
        .accessibilityValue(
            isActive
                ? (sortOrder == .name ? "Selected, ascending" : "Selected, descending")
                : "Not selected"
        )
    }

    private func metricChipPreview(_ metric: MenuBarViewModel.TrayMetric) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(metric.title)
                .font(.caption)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func metricTitle(for metric: MenuBarViewModel.TrayMetric) -> String {
        switch metric {
        case .network: "Net"
        case .cpu: "CPU"
        case .cpuTemp: "Temp"
        case .memory: "Memory"
        case .disk: "Disk"
        case .externalDisk: "External Disk"
        }
    }

    private func metricValue(for metric: MenuBarViewModel.TrayMetric) -> String {
        switch metric {
        case .network:
            ByteRateFormatter.networkCardRate(
                for: viewModel.totalDownloadBytesPerSecond + viewModel.totalUploadBytesPerSecond
            )
        case .cpu:
            viewModel.formattedCPUUsage
        case .cpuTemp:
            viewModel.formattedCPUTemperature
        case .memory:
            viewModel.formattedMemoryUsage
        case .disk:
            viewModel.formattedDiskActivity
        case .externalDisk:
            viewModel.formattedExternalDiskActivity
        }
    }

    private func metricSymbol(for metric: MenuBarViewModel.TrayMetric) -> String {
        switch metric {
        case .network: "arrow.up.arrow.down"
        case .cpu: "cpu"
        case .cpuTemp: "thermometer.medium"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .externalDisk: "externaldrive"
        }
    }

    private func historySamples(for metric: MenuBarViewModel.TrayMetric) -> [Double] {
        switch metric {
        case .network:
            viewModel.historySamples.map(\.networkBytesPerSecond)
        case .cpu:
            viewModel.historySamples.map(\.cpuUsagePercent)
        case .cpuTemp:
            viewModel.historySamples.compactMap(\.cpuTemperatureCelsius)
        case .memory:
            viewModel.historySamples.map(\.memoryUsagePercent)
        case .disk:
            viewModel.historySamples.map(\.diskBytesPerSecond)
        case .externalDisk:
            viewModel.historySamples.map(\.externalDiskBytesPerSecond)
        }
    }

    private func historyColor(for metric: MenuBarViewModel.TrayMetric) -> Color {
        switch metric {
        case .network:
            .cyan
        case .cpu:
            viewModel.cpuUsagePercent >= 85 ? .red : (viewModel.cpuUsagePercent >= 65 ? .orange : .blue)
        case .cpuTemp:
            (viewModel.cpuTemperatureCelsius ?? 0) >= 90 ? .red : ((viewModel.cpuTemperatureCelsius ?? 0) >= 75 ? .orange : .pink)
        case .memory:
            viewModel.memoryUsagePercent >= 90 ? .red : (viewModel.memoryUsagePercent >= 75 ? .orange : .green)
        case .disk:
            .purple
        case .externalDisk:
            .blue
        }
    }

    private func sparklineRange(for metric: MenuBarViewModel.TrayMetric) -> ClosedRange<Double>? {
        switch metric {
        case .cpu, .memory:
            0 ... 100
        case .cpuTemp:
            30 ... 110
        case .network, .disk, .externalDisk:
            nil
        }
    }

    private func confirmTermination(of snapshot: AppResourceSnapshot) {
        guard viewModel.appSnapshotsAreFresh else { return }
        let alert = NSAlert()
        alert.messageText = "Terminate \(snapshot.displayName)?"
        alert.informativeText = snapshot.pids.count == 1
            ? "This sends SIGTERM to PID \(snapshot.pids[0])."
            : "This sends SIGTERM to \(snapshot.pids.count) related processes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        viewModel.terminateProcess(snapshot)
    }
}

private struct AppResourceRow: View {
    let snapshot: AppResourceSnapshot
    let showsDragHandle: Bool
    let allowsTermination: Bool
    let terminate: () -> Void
    @State private var isHovered = false
    @FocusState private var isTerminateFocused: Bool

    struct ColumnWidths {
        // The table content is 606 pt wide after the popover sidebar and
        // scrollbar reserve. Keeping every column explicit makes the header
        // and rows share one grid even though the rows live in a ScrollView.
        let application: CGFloat = 238
        let cpu: CGFloat = 58
        let ram: CGFloat = 72
        let disk: CGFloat = 80
        let network: CGFloat = 86
        let kill: CGFloat = 32
    }
    static let columnWidths = ColumnWidths()

    private var canTerminate: Bool {
        snapshot.canTerminate && allowsTermination
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.isAdaptive = true
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if showsDragHandle {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 28)
                        .contentShape(Rectangle())
                        .draggable(AppOrderDragItem(key: snapshot.orderKey)) {
                            Label(snapshot.displayName, systemImage: "line.3.horizontal")
                                .font(.caption)
                                .padding(.vertical, 7)
                                .padding(.horizontal, 10)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .help("Drag to reorder")
                        .accessibilityLabel("Reorder \(snapshot.displayName)")
                }

                Image(nsImage: snapshot.icon ?? NSWorkspace.shared.icon(for: .application))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .cornerRadius(5)
                    .accessibilityHidden(true)

                Text(snapshot.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(snapshot.displayName)
                    .layoutPriority(1)
                    .accessibilityLabel("Application")
                    .accessibilityValue(snapshot.displayName)

                if snapshot.childProcessCount > 1 {
                    Text("\(snapshot.childProcessCount)")
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                        .accessibilityLabel("\(snapshot.childProcessCount) related processes")
                }
            }
            .frame(width: Self.columnWidths.application, alignment: .leading)

            Text(cpuText)
                .font(.caption.weight(.medium).monospacedDigit())
                .lineLimit(1)
                .frame(width: Self.columnWidths.cpu, alignment: .trailing)
                .accessibilityLabel("CPU")
                .accessibilityValue(cpuText == "—" ? "No activity" : cpuText)

            Text(memoryText)
                .font(.caption.weight(.medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: Self.columnWidths.ram, alignment: .trailing)
                .accessibilityLabel("Memory")
                .accessibilityValue(memoryText == "—" ? "No memory reported" : memoryText)

            Text(Self.rateText(snapshot.diskBytesPerSecond))
                .font(.caption.weight(.medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(width: Self.columnWidths.disk, alignment: .trailing)
                .accessibilityLabel("Disk")
                .accessibilityValue(
                    snapshot.diskBytesPerSecond < 0.5
                        ? "No activity"
                        : ByteRateFormatter.string(for: snapshot.diskBytesPerSecond)
                )

            networkCell
                .frame(width: Self.columnWidths.network, alignment: .trailing)

            Button {
                terminate()
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        canTerminate && (isHovered || isTerminateFocused)
                            ? Color.red
                            : Color.secondary
                    )
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canTerminate)
            .focused($isTerminateFocused)
            .opacity(
                canTerminate
                    ? ((isHovered || isTerminateFocused) ? 1 : 0.36)
                    : 0
            )
            .help(
                !allowsTermination
                    ? "Process data is refreshing"
                    : (snapshot.canTerminate ? "Terminate \(snapshot.displayName)" : "No process PID available")
            )
            .frame(width: Self.columnWidths.kill, alignment: .trailing)
            .accessibilityLabel("Terminate \(snapshot.displayName)")
        }
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Terminate \(snapshot.displayName)…", role: .destructive) {
                terminate()
            }
            .disabled(!canTerminate)
        }
    }

    private var cpuText: String {
        snapshot.cpuUsagePercent < 0.05
            ? "—"
            : String(format: "%.1f%%", snapshot.cpuUsagePercent)
    }

    private var memoryText: String {
        snapshot.ramBytes == 0
            ? "—"
            : Self.byteFormatter.string(fromByteCount: Int64(snapshot.ramBytes))
    }

    @ViewBuilder
    private var networkCell: some View {
        if snapshot.networkBytesPerSecond < 0.5 {
            Text("—")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Network")
                .accessibilityValue("No activity")
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text("↓ \(Self.rateText(snapshot.downloadBytesPerSecond))")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("↑ \(Self.rateText(snapshot.uploadBytesPerSecond))")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Network")
            .accessibilityValue(
                "Download \(ByteRateFormatter.string(for: snapshot.downloadBytesPerSecond)), "
                    + "upload \(ByteRateFormatter.string(for: snapshot.uploadBytesPerSecond))"
            )
        }
    }

    private static func rateText(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 0.5 ? "—" : ByteRateFormatter.string(for: bytesPerSecond)
    }
}

private struct Sparkline: View {
    let samples: [Double]
    let color: Color
    let range: ClosedRange<Double>?

    var body: some View {
        Canvas { context, size in
            let values = samples.suffix(90)
            guard values.count > 1 else {
                drawBaseline(in: &context, size: size)
                return
            }

            let lowerBound = range?.lowerBound ?? 0
            // Dynamic rate charts keep the peak for the full retained history
            // instead of rescaling every second as the visible window moves.
            let upperBound = range?.upperBound ?? max(samples.max() ?? 0, 1)
            let span = max(upperBound - lowerBound, 1)
            let stepX = size.width / CGFloat(max(values.count - 1, 1))
            var path = Path()

            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * stepX
                let ratio = CGFloat(min(max((value - lowerBound) / span, 0), 1))
                let y = size.height - (ratio * size.height)

                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            drawBaseline(in: &context, size: size)
            var area = path
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.1)))
            context.stroke(path, with: .color(color), lineWidth: 1.6)
        }
        .accessibilityHidden(true)
    }

    private func drawBaseline(in context: inout GraphicsContext, size: CGSize) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        context.stroke(baseline, with: .color(.secondary.opacity(0.22)), lineWidth: 1)
    }
}
