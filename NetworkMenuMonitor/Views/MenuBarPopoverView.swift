import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @State private var draggedTrayMetric: MenuBarViewModel.TrayMetric?

    private let maxVisibleRowsWithoutScroll = 6
    private let trayGridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if viewModel.showAllInfo {
                trayOrderEditor
                thresholdRow
                Divider()
            }
            content
        }
        .padding(14)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Apps Resource Table")
                .font(.headline)

            Spacer(minLength: 0)

            Button(viewModel.showAllInfo ? "Hide Info" : "All Info") {
                viewModel.setShowAllInfo(!viewModel.showAllInfo)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var trayOrderEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tray")
                    .font(.callout)

                Spacer(minLength: 0)

                Button(viewModel.allTrayMetricsSelected ? "Clear" : "All") {
                    viewModel.setAllTrayMetricsSelected(!viewModel.allTrayMetricsSelected)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            LazyVGrid(columns: trayGridColumns, spacing: 10) {
                ForEach(viewModel.orderedTrayMetricsForPopover) { metric in
                    trayMetricCard(metric)
                }
            }
        }
    }

    private var thresholdRow: some View {
        HStack(spacing: 10) {
            Text("Filter")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Filter", selection: Binding(
                get: { viewModel.appResourceFilter },
                set: { viewModel.setAppResourceFilter($0) }
            )) {
                ForEach(MenuBarViewModel.AppResourceFilter.allCases, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            .pickerStyle(.menu)

            Spacer(minLength: 0)

            Text("Threshold")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Threshold", selection: Binding(
                get: { viewModel.appDisplayThresholdBytesPerSecond },
                set: { viewModel.setAppDisplayThreshold($0) }
            )) {
                ForEach(viewModel.thresholdOptions, id: \.self) { threshold in
                    Text(viewModel.appResourceFilter == .cpu ? "\(Int(threshold))%" : ByteRateFormatter.thresholdString(for: threshold))
                        .tag(threshold)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var content: some View {
        perAppHeader
        if let message = viewModel.perAppStatusMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if viewModel.appSnapshots.isEmpty {
            Text("Waiting for per-app activity…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if viewModel.filteredAppSnapshots.isEmpty {
            Text("No apps above \(viewModel.thresholdDescription).")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                appResourceTableHeader

                if viewModel.filteredAppSnapshots.count <= maxVisibleRowsWithoutScroll {
                    appResourceList(viewModel.filteredAppSnapshots)
                } else {
                    ScrollView {
                        appResourceList(viewModel.filteredAppSnapshots)
                    }
                }
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

            Picker("Sort", selection: Binding(
                get: { viewModel.appSortOrder },
                set: { viewModel.setAppSortOrder($0) }
            )) {
                ForEach(MenuBarViewModel.AppSortOrder.allCases, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var appResourceTableHeader: some View {
        HStack(spacing: 10) {
            Text("Application")
                .font(.caption)
                .foregroundStyle(.secondary)
                .layoutPriority(1)

            Spacer(minLength: 0)

            Text("CPU")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("RAM")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Disk")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Network")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func appResourceList(_ snapshots: [AppResourceSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshots) { snapshot in
                AppResourceRow(snapshot: snapshot)
                Divider()
            }
        }
    }

    @ViewBuilder
    private func trayMetricValue(_ metric: MenuBarViewModel.TrayMetric) -> some View {
        if metric == .externalDisk {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(viewModel.externalDiskActivities) { activity in
                    HStack(spacing: 5) {
                        Image(systemName: activity.systemImageName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(externalDiskRateText(for: activity))
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }
            }
        } else {
            Text(viewModel.trayText(for: metric))
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private func externalDiskRateText(for activity: ExternalDiskActivity) -> String {
        func compact(_ s: String) -> String {
            s.replacingOccurrences(of: "GB/s", with: "G")
                .replacingOccurrences(of: "MB/s", with: "M")
                .replacingOccurrences(of: "KB/s", with: "K")
                .replacingOccurrences(of: "B/s", with: "B")
        }
        let r = compact(ByteRateFormatter.stableMenuRate(for: activity.readBytesPerSecond, preferredUnitIndex: nil).text)
        let w = compact(ByteRateFormatter.stableMenuRate(for: activity.writeBytesPerSecond, preferredUnitIndex: nil).text)
        return "\(r) D \(w) U"
    }

    private func trayMetricCard(_ metric: MenuBarViewModel.TrayMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(metric.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Image(systemName: viewModel.trayMetricEnabled(metric) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewModel.trayMetricEnabled(metric) ? Color.accentColor : Color.secondary)
            }

            trayMetricValue(metric)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            (draggedTrayMetric == metric ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(draggedTrayMetric == metric ? 0.45 : 0), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            viewModel.toggleTrayMetric(metric)
        }
        .draggable(metric.rawValue) {
            trayMetricCardPreview(metric)
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

    private func trayMetricCardPreview(_ metric: MenuBarViewModel.TrayMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(viewModel.trayText(for: metric))
                .font(.system(size: 16, weight: .medium, design: .monospaced))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AppResourceRow: View {
    let snapshot: AppResourceSnapshot
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.isAdaptive = true
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: snapshot.icon ?? NSWorkspace.shared.icon(for: .application))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .cornerRadius(5)

            Text(snapshot.displayName)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 12)

            Text(String(format: "%.1f%%", snapshot.cpuUsagePercent))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)

            Text(byteFormatter.string(fromByteCount: Int64(snapshot.ramBytes))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(ByteRateFormatter.alignedRate(for: snapshot.diskReadBytesPerSecond, preferredUnitIndex: nil).text) D")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Text("\(ByteRateFormatter.alignedRate(for: snapshot.diskWriteBytesPerSecond, preferredUnitIndex: nil).text) U")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(ByteRateFormatter.alignedRate(for: snapshot.downloadBytesPerSecond, preferredUnitIndex: nil).text) D")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Text("\(ByteRateFormatter.alignedRate(for: snapshot.uploadBytesPerSecond, preferredUnitIndex: nil).text) U")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
        }
    }
}
