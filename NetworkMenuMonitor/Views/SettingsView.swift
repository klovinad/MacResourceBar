import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { viewModel.launchAtLoginEnabled },
                    set: { viewModel.setLaunchAtLoginEnabled($0) }
                ))

                Toggle("High refresh", isOn: Binding(
                    get: { viewModel.highRefreshEnabled },
                    set: { viewModel.setHighRefreshEnabled($0) }
                ))

                Toggle("Show active apps only", isOn: Binding(
                    get: { viewModel.activeAppsOnly },
                    set: { viewModel.setActiveAppsOnly($0) }
                ))

                Toggle("Show helper processes", isOn: Binding(
                    get: { viewModel.showHelperProcesses },
                    set: { viewModel.setShowHelperProcesses($0) }
                ))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Background opacity")
                        Spacer()
                        Text("\(Int(viewModel.backgroundOpacity * 100))%")
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { viewModel.backgroundOpacity },
                            set: { viewModel.setBackgroundOpacity($0) }
                        ),
                        in: 0.2...1,
                        step: 0.05
                    )
                }
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
            }

            Section("App Table") {
                Picker("Filter", selection: Binding(
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
                    }
                }

                Picker("Threshold", selection: Binding(
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
        .padding(20)
        .frame(width: 420)
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
