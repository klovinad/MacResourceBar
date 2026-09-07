import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            menuBarSettings
                .tabItem {
                    Label("Menu Bar", systemImage: "menubar.rectangle")
                }

            processSettings
                .tabItem {
                    Label("Processes", systemImage: "list.bullet.rectangle")
                }
        }
        .padding(16)
        .frame(minWidth: 500, minHeight: 520)
    }

    private var generalSettings: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { viewModel.launchAtLoginEnabled },
                    set: { viewModel.setLaunchAtLoginEnabled($0) }
                ))

                if let settingsErrorMessage = viewModel.settingsErrorMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(settingsErrorMessage)
                            .foregroundStyle(.primary)
                    }
                        .font(.caption)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Settings warning: \(settingsErrorMessage)")
                }

                Picker("Refresh rate", selection: Binding(
                    get: { viewModel.highRefreshEnabled },
                    set: { viewModel.setHighRefreshEnabled($0) }
                )) {
                    Text("1 second").tag(true)
                    Text("10 seconds").tag(false)
                }
                .pickerStyle(.segmented)

                Picker("Network source", selection: Binding(
                    get: { viewModel.networkSource },
                    set: { viewModel.setNetworkSource($0) }
                )) {
                    ForEach(NetworkTotalsMonitor.Source.allCases, id: \.self) { source in
                        Text(source.label).tag(source)
                    }
                }

                Text("Primary follows the active macOS route. All physical combines active Wi-Fi and Ethernet. Include VPN also counts tunnel interfaces.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.75))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Panel opacity")
                        Spacer()
                        Text("\(Int(viewModel.backgroundOpacity * 100))%")
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { viewModel.backgroundOpacity },
                            set: { viewModel.setBackgroundOpacity($0) }
                        ),
                        in: 0.55...1,
                        step: 0.05
                    )
                    .accessibilityLabel("Panel opacity")
                    .accessibilityValue("\(Int(viewModel.backgroundOpacity * 100)) percent")
                }
            }

            Section("Current Memory") {
                LabeledContent("Pressure", value: viewModel.memoryPressureLabel)
                LabeledContent("Compressed", value: viewModel.formattedCompressedMemory)
                LabeledContent("Swap used", value: viewModel.formattedSwapUsed)

                Text(viewModel.systemMetricsFreshnessText)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.75))
            }

            Section("Diagnostics") {
                LabeledContent("System", value: viewModel.systemMetricsFreshnessText)
                LabeledContent("Network", value: viewModel.networkFreshnessText)
                LabeledContent("Applications", value: viewModel.processMonitoringStateText)

                Text(viewModel.monitoringIssueDetails)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.75))
            }
        }
        .formStyle(.grouped)
    }

    private var menuBarSettings: some View {
        Form {
            Section("Menu Bar Appearance") {
                Picker("Labels", selection: Binding(
                    get: { viewModel.menuBarLabelStyle },
                    set: { viewModel.setMenuBarLabelStyle($0) }
                )) {
                    ForEach(MenuBarViewModel.MenuBarLabelStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Text(viewModel.menuBarLabelStyle.helpText)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.75))

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(viewModel.menuBarTitle)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.vertical, 2)
                }
                .accessibilityLabel("Menu bar preview")
                .accessibilityValue(viewModel.menuBarTitle)
            }

            Section("Menu Bar Metrics") {
                ForEach(viewModel.trayMetricOrder) { metric in
                    let isRequired = viewModel.trayMetricEnabled(metric)
                        && viewModel.selectedTrayMetrics.count == 1
                    Toggle(metric.title, isOn: Binding(
                        get: { viewModel.trayMetricEnabled(metric) },
                        set: { enabled in
                            if viewModel.trayMetricEnabled(metric) != enabled {
                                viewModel.toggleTrayMetric(metric)
                            }
                        }
                    ))
                    .disabled(isRequired)
                    .help(
                        isRequired
                            ? "At least one metric must remain visible"
                            : "Use Up or Down Arrow to reorder, or open the context menu"
                    )
                    .accessibilityHint(
                        isRequired
                            ? "At least one metric must remain visible"
                            : "Use accessibility actions to change its menu bar position"
                    )
                    .accessibilityActions {
                        if canMoveTrayMetric(metric, direction: -1) {
                            Button("Move up") {
                                moveTrayMetric(metric, direction: -1)
                            }
                        }
                        if canMoveTrayMetric(metric, direction: 1) {
                            Button("Move down") {
                                moveTrayMetric(metric, direction: 1)
                            }
                        }
                    }
                    .onMoveCommand { direction in
                        switch direction {
                        case .up:
                            moveTrayMetric(metric, direction: -1)
                        case .down:
                            moveTrayMetric(metric, direction: 1)
                        default:
                            break
                        }
                    }
                    .contextMenu {
                        Button("Move Up") {
                            moveTrayMetric(metric, direction: -1)
                        }
                        .disabled(!canMoveTrayMetric(metric, direction: -1))

                        Button("Move Down") {
                            moveTrayMetric(metric, direction: 1)
                        }
                        .disabled(!canMoveTrayMetric(metric, direction: 1))
                    }
                }

                Text("At least one metric must remain visible. Focus a metric and use the arrow keys, open its context menu, or drag it in the popover to change the order.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.75))
            }

            Section("External Disks") {
                Picker("Show", selection: Binding(
                    get: { viewModel.externalDiskSelectionMode },
                    set: { viewModel.setExternalDiskSelectionMode($0) }
                )) {
                    ForEach(MenuBarViewModel.ExternalDiskSelectionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Text(
                    viewModel.externalDiskSelectionMode == .all
                        ? "All connected external disks are shown separately."
                        : "Only checked external disks are shown, each with its own reading."
                )
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.75))

                if viewModel.availableExternalDiskActivities.isEmpty {
                    Label("No external disks detected", systemImage: "externaldrive.badge.questionmark")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.availableExternalDiskActivities) { disk in
                        Toggle(isOn: Binding(
                            get: { viewModel.externalDiskSelected(disk) },
                            set: { viewModel.setExternalDisk(disk, selected: $0) }
                        )) {
                            HStack {
                                Image(systemName: disk.systemImageName)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(disk.displayName)
                                    if let capacity = viewModel.externalDiskCapacityText(for: disk) {
                                        Text(capacity)
                                            .font(.caption)
                                            .foregroundStyle(.primary.opacity(0.75))
                                    }
                                }
                                Spacer()
                                Text(disk.bsdName)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel(disk.displayName)
                        .accessibilityValue(
                            "\(disk.bsdName), \(viewModel.externalDiskSelected(disk) ? "selected" : "not selected")"
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var processSettings: some View {
        Form {
            Section("Visibility") {
                Toggle("Show active apps only", isOn: Binding(
                    get: { viewModel.activeAppsOnly },
                    set: { viewModel.setActiveAppsOnly($0) }
                ))

                Toggle("List helper processes separately", isOn: Binding(
                    get: { viewModel.showHelperProcesses },
                    set: { viewModel.setShowHelperProcesses($0) }
                ))

                Text("System daemons are hidden unless they have recent network activity.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.75))
            }

            Section("App Table") {
                Picker("Metric", selection: Binding(
                    get: { viewModel.appResourceFilter },
                    set: { viewModel.setAppResourceFilter($0) }
                )) {
                    ForEach(MenuBarViewModel.AppResourceFilter.allCases, id: \.self) { filter in
                        Text(filter.label).tag(filter)
                    }
                }

                Picker("Sort", selection: Binding(
                    get: { viewModel.appSortOrder },
                    set: { viewModel.setAppSortOrder($0) }
                )) {
                    ForEach(MenuBarViewModel.AppSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                            .disabled(viewModel.showHelperProcesses && order == .custom)
                    }
                }

                if viewModel.appResourceFilter != .all {
                    Picker("Minimum", selection: Binding(
                        get: { viewModel.appDisplayThresholdBytesPerSecond },
                        set: { viewModel.setAppDisplayThreshold($0) }
                    )) {
                        ForEach(viewModel.thresholdOptions, id: \.self) { threshold in
                            Text(thresholdLabel(for: threshold)).tag(threshold)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func thresholdLabel(for threshold: Double) -> String {
        switch viewModel.appResourceFilter {
        case .all:
            return "Off"
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

    private func canMoveTrayMetric(
        _ metric: MenuBarViewModel.TrayMetric,
        direction: Int
    ) -> Bool {
        guard let index = viewModel.trayMetricOrder.firstIndex(of: metric) else { return false }
        return viewModel.trayMetricOrder.indices.contains(index + direction)
    }

    private func moveTrayMetric(
        _ metric: MenuBarViewModel.TrayMetric,
        direction: Int
    ) {
        guard
            let index = viewModel.trayMetricOrder.firstIndex(of: metric),
            viewModel.trayMetricOrder.indices.contains(index + direction)
        else {
            return
        }

        let target = viewModel.trayMetricOrder[index + direction]
        viewModel.moveTrayMetric(metric, relativeTo: target, insertAfter: direction > 0)
    }
}
