import AppKit
import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @State private var draggedTrayMetric: MenuBarViewModel.TrayMetric?

    private let tableMaxHeight: CGFloat = 360
    private let tableVisibleRowLimit = 120
    private let tableScrollbarReserve: CGFloat = 16
    private let historyColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            systemSummary
            historySummary
            appTableControls
            Divider()
            content
        }
        .padding(14)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MacResourceBar")
                    .font(.headline)
                Text(viewModel.highRefreshEnabled ? "Updating every second" : "Updating every 10 seconds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(viewModel.highRefreshEnabled ? "High 1s" : "Low 10s") {
                viewModel.setHighRefreshEnabled(!viewModel.highRefreshEnabled)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(viewModel.allTrayMetricsSelected ? "Clear" : "All") {
                viewModel.setAllTrayMetricsSelected(!viewModel.allTrayMetricsSelected)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                NotificationCenter.default.post(name: .networkMenuMonitorOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Settings")
        }
    }

    private var systemSummary: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.orderedTrayMetricsForPopover) { metric in
                metricChip(metric)
            }
        }
    }

    private var historySummary: some View {
        LazyVGrid(columns: historyColumns, alignment: .leading, spacing: 8) {
            ForEach(viewModel.orderedTrayMetricsForPopover) { metric in
                HistorySparkline(
                    title: metricTitle(for: metric),
                    value: metricValue(for: metric),
                    samples: historySamples(for: metric),
                    color: historyColor(for: metric)
                )
            }
        }
    }

    private func metricChip(_ metric: MenuBarViewModel.TrayMetric) -> some View {
        HStack(spacing: 6) {
            Image(systemName: metricSymbol(for: metric))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(metricTitle(for: metric))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(metricValue(for: metric))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 0)

            Image(systemName: viewModel.trayMetricEnabled(metric) ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(viewModel.trayMetricEnabled(metric) ? Color.accentColor : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            (draggedTrayMetric == metric ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(draggedTrayMetric == metric ? 0.45 : 0), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            viewModel.toggleTrayMetric(metric)
        }
        .draggable(metric.rawValue) {
            metricChipPreview(metric)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onChanged { _ in
                if draggedTrayMetric == nil {
                    draggedTrayMetric = metric
                }
            }
        )
        .dropDestination(for: String.self) { _, _ in
            draggedTrayMetric = nil
            return true
        } isTargeted: { isTargeted in
            guard isTargeted, let draggedTrayMetric, draggedTrayMetric != metric else { return }
            viewModel.moveTrayMetric(draggedTrayMetric, before: metric)
        }
    }

    private var appTableControls: some View {
        HStack(spacing: 10) {
            TextField("Search apps", text: Binding(
                get: { viewModel.appSearchText },
                set: { viewModel.setAppSearchText($0) }
            ))
            .textFieldStyle(.roundedBorder)

            if let searchMatchCountText = viewModel.searchMatchCountText {
                Text(searchMatchCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 74, alignment: .leading)
            }

            Spacer(minLength: 0)

            thresholdControl

            Toggle("Active only", isOn: Binding(
                get: { viewModel.activeAppsOnly },
                set: { viewModel.setActiveAppsOnly($0) }
            ))
            .toggleStyle(.checkbox)

            Toggle("Show helpers", isOn: Binding(
                get: { viewModel.showHelperProcesses },
                set: { viewModel.setShowHelperProcesses($0) }
            ))
            .toggleStyle(.checkbox)
        }
        .controlSize(.small)
    }

    private var thresholdControl: some View {
        HStack(spacing: 6) {
            Text("Threshold")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Threshold", selection: Binding(
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
            .frame(width: 96)
        }
    }

    private var pausedPerAppState: some View {
        HStack(spacing: 10) {
            Text(viewModel.visiblePerAppStatusMessage ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button("Switch to High 1s") {
                viewModel.setHighRefreshEnabled(true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var content: some View {
        let snapshots = viewModel.filteredAppSnapshots

        perAppHeader
        if let message = viewModel.visiblePerAppStatusMessage {
            if viewModel.highRefreshEnabled {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                pausedPerAppState
            }
        } else if viewModel.appSnapshots.isEmpty {
            Text("Waiting for per-app activity…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if snapshots.isEmpty {
            Text(emptyAppTableMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                appResourceTableHeader
                TopAlignedScrollView(resetID: tableScrollResetID) {
                    appResourceList(snapshots)
                }
                .frame(height: tableMaxHeight)
                .padding(.trailing, tableScrollbarReserve)
            }
        }
    }

    private var perAppHeader: some View {
        HStack(spacing: 8) {
            Text("Apps")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("(\(viewModel.filteredAppCountText))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private var tableScrollResetID: String {
        [
            viewModel.appSearchText,
            viewModel.appResourceFilter.rawValue,
            viewModel.appSortOrder.rawValue,
            viewModel.activeAppsOnly ? "active" : "all",
            viewModel.showHelperProcesses ? "helpers" : "grouped"
        ].joined(separator: "|")
    }

    private var appResourceTableHeader: some View {
        HStack(spacing: 10) {
            metricHeader(
                "Application",
                width: AppResourceRow.columnWidths.application,
                alignment: .leading,
                sortOrder: .name,
                filter: .all
            )
            .layoutPriority(1)

            metricHeader("CPU", width: AppResourceRow.columnWidths.cpu, alignment: .leading, sortOrder: .cpuRate, filter: .cpu)
            metricHeader("RAM", width: AppResourceRow.columnWidths.ram, alignment: .leading, sortOrder: .memoryRate, filter: .memory)
            metricHeader("Disk", width: AppResourceRow.columnWidths.disk, alignment: .leading, sortOrder: .diskRate, filter: .disk)
            metricHeader("Network", width: AppResourceRow.columnWidths.network, alignment: .leading, sortOrder: .networkRate, filter: .network)
            Color.clear
                .frame(width: AppResourceRow.columnWidths.kill)
        }
        .padding(.trailing, tableScrollbarReserve)
    }

    private func appResourceList(_ snapshots: [AppResourceSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(snapshots.prefix(tableVisibleRowLimit))) { snapshot in
                AppResourceRow(snapshot: snapshot) {
                    confirmTermination(of: snapshot)
                }
                .frame(height: 44)

                Divider()
            }

            if snapshots.count > tableVisibleRowLimit {
                Text("\(snapshots.count - tableVisibleRowLimit) more matches hidden. Narrow the search to show them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }
        }
    }

    private var emptyAppTableMessage: String {
        if !viewModel.appSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No apps match the search."
        }
        if viewModel.activeAppsOnly {
            return "No active apps above \(viewModel.thresholdDescription)."
        }
        return "No apps to show."
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
        width: CGFloat,
        alignment: Alignment = .leading,
        sortOrder: MenuBarViewModel.AppSortOrder,
        filter: MenuBarViewModel.AppResourceFilter
    ) -> some View {
        let isActive = viewModel.appSortOrder == sortOrder

        return Button {
            viewModel.setAppResourceFilter(filter)
            viewModel.setAppSortOrder(sortOrder)
        } label: {
            Text(title)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: alignment)
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
        case .memory: "RAM"
        case .disk: "Disk"
        case .externalDisk: "Ext"
        }
    }

    private func metricValue(for metric: MenuBarViewModel.TrayMetric) -> String {
        switch metric {
        case .network:
            viewModel.trayText(for: .network)
        case .cpu:
            viewModel.formattedCPUUsage
        case .cpuTemp:
            viewModel.formattedCPUTemperature
        case .memory:
            viewModel.formattedMemoryUsage
        case .disk:
            viewModel.formattedDiskActivity
        case .externalDisk:
            viewModel.trayExternalDiskText.replacingOccurrences(of: "EXT ", with: "")
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
            .accentColor
        case .cpu:
            .orange
        case .cpuTemp:
            .red
        case .memory:
            .green
        case .disk:
            .purple
        case .externalDisk:
            .blue
        }
    }

    private func confirmTermination(of snapshot: AppResourceSnapshot) {
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

private struct TopAlignedScrollView<Content: View>: NSViewRepresentable {
    let resetID: String
    let content: Content

    init(resetID: String, @ViewBuilder content: () -> Content) {
        self.resetID = resetID
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(resetID: resetID)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let hostingView = NSHostingView(rootView: content)
        hostingView.isFlipped = true
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hostingView
        context.coordinator.hostingView = hostingView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hostingView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        DispatchQueue.main.async {
            scrollToTop(scrollView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.hostingView?.rootView = content
        context.coordinator.hostingView?.invalidateIntrinsicContentSize()

        if context.coordinator.resetID != resetID {
            context.coordinator.resetID = resetID
            DispatchQueue.main.async {
                scrollToTop(scrollView)
            }
        }
    }

    private func scrollToTop(_ scrollView: NSScrollView) {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    final class Coordinator {
        var resetID: String
        var hostingView: NSHostingView<Content>?

        init(resetID: String) {
            self.resetID = resetID
        }
    }
}

private struct AppResourceRow: View {
    let snapshot: AppResourceSnapshot
    let terminate: () -> Void

    struct ColumnWidths {
        let application: CGFloat = 318
        let cpu: CGFloat = 64
        let ram: CGFloat = 76
        let disk: CGFloat = 92
        let network: CGFloat = 92
        let kill: CGFloat = 22
    }
    static let columnWidths = ColumnWidths()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.isAdaptive = true
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: snapshot.icon ?? NSWorkspace.shared.icon(for: .application))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .cornerRadius(5)

                Text(snapshot.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(snapshot.displayName)
                    .layoutPriority(1)

                if snapshot.childProcessCount > 1 {
                    Text("\(snapshot.childProcessCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
            }
            .frame(width: Self.columnWidths.application, alignment: .leading)

            Text(String(format: "%.1f%%", snapshot.cpuUsagePercent))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .frame(width: Self.columnWidths.cpu, alignment: .leading)

            Text(Self.byteFormatter.string(fromByteCount: Int64(snapshot.ramBytes)))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: Self.columnWidths.ram, alignment: .leading)

            Text(Self.rateText(snapshot.diskBytesPerSecond))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            .frame(width: Self.columnWidths.disk, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(Self.rateText(snapshot.downloadBytesPerSecond))↓")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text("\(Self.rateText(snapshot.uploadBytesPerSecond))↑")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(width: Self.columnWidths.network, alignment: .leading)

            Button {
                terminate()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(snapshot.canTerminate ? Color.secondary : Color.secondary.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!snapshot.canTerminate)
            .help(snapshot.canTerminate ? "Terminate \(snapshot.displayName)" : "No process PID available")
            .frame(width: Self.columnWidths.kill, alignment: .leading)
        }
    }

    private static func rateText(_ bytesPerSecond: Double) -> String {
        ByteRateFormatter.stableMenuRate(for: bytesPerSecond, preferredUnitIndex: nil).text
    }
}

private struct HistorySparkline: View {
    let title: String
    let value: String
    let samples: [Double]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text(value)
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Sparkline(samples: samples, color: color)
                .frame(height: 30)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct Sparkline: View {
    let samples: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let values = samples.suffix(90)
            guard values.count > 1 else {
                drawBaseline(in: &context, size: size)
                return
            }

            let maxValue = max(values.max() ?? 0, 1)
            let stepX = size.width / CGFloat(max(values.count - 1, 1))
            var path = Path()

            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * stepX
                let ratio = CGFloat(min(max(value / maxValue, 0), 1))
                let y = size.height - (ratio * size.height)

                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            drawBaseline(in: &context, size: size)
            context.stroke(path, with: .color(color), lineWidth: 1.6)
        }
    }

    private func drawBaseline(in context: inout GraphicsContext, size: CGSize) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        context.stroke(baseline, with: .color(.secondary.opacity(0.22)), lineWidth: 1)
    }
}
