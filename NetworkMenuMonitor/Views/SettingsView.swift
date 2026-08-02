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
                    Label(settingsErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("Refresh rate", selection: Binding(
                    get: { viewModel.highRefreshEnabled },
                    set: { viewModel.setHighRefreshEnabled($0) }
                )) {
                    Text("1 second").tag(true)
                    Text("10 seconds").tag(false)
                }
                .pickerStyle(.segmented)

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
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(viewModel.menuBarTitle)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.vertical, 2)
                }
                .accessibilityLabel("Menu bar preview")
                .accessibilityValue(viewModel.menuBarTitle)
            }

            Section("Menu Bar Metrics") {
                ForEach(viewModel.trayMetricOrder) { metric in
                    Toggle(metric.title, isOn: Binding(
                        get: { viewModel.trayMetricEnabled(metric) },
                        set: { enabled in
                            if viewModel.trayMetricEnabled(metric) != enabled {
                                viewModel.toggleTrayMetric(metric)
                            }
                        }
                    ))
                }

                Text("At least one metric must remain visible. Drag metrics in the popover to change their order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)

                if viewModel.availableExternalDiskActivities.isEmpty {
                    Text("No external disks detected")
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
                                Text(disk.displayName)
                                Spacer()
                                Text(disk.bsdName)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                    .foregroundStyle(.secondary)
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
        .formStyle(.grouped)
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
}
