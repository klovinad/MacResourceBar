import Foundation

struct MenuBarPreferences {
    private enum Key {
        static let appResourceThreshold = "appResourceDisplayThresholdBytesPerSecond"
        static let appResourceFilter = "appResourceFilter"
        static let trayMetrics = "trayMetrics"
        static let trayMetricOrder = "trayMetricOrder"
        static let highRefreshEnabled = "highRefreshEnabled"
        static let appSortOrder = "appSortOrder"
        static let appSearchText = "appSearchText"
        static let activeAppsOnly = "activeAppsOnly"
        static let showHelperProcesses = "showHelperProcesses"
        static let backgroundOpacity = "backgroundOpacity"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var appResourceThreshold: Double {
        get { defaults.double(forKey: Key.appResourceThreshold) }
        nonmutating set { defaults.set(newValue, forKey: Key.appResourceThreshold) }
    }

    var appResourceFilterRawValue: String? {
        get { defaults.string(forKey: Key.appResourceFilter) }
        nonmutating set { defaults.set(newValue, forKey: Key.appResourceFilter) }
    }

    var appSortOrderRawValue: String? {
        get { defaults.string(forKey: Key.appSortOrder) }
        nonmutating set { defaults.set(newValue, forKey: Key.appSortOrder) }
    }

    var highRefreshEnabled: Bool {
        get { bool(forKey: Key.highRefreshEnabled, defaultValue: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.highRefreshEnabled) }
    }

    var appSearchText: String {
        get { defaults.string(forKey: Key.appSearchText) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.appSearchText) }
    }

    var activeAppsOnly: Bool {
        get { bool(forKey: Key.activeAppsOnly, defaultValue: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.activeAppsOnly) }
    }

    var showHelperProcesses: Bool {
        get { bool(forKey: Key.showHelperProcesses, defaultValue: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.showHelperProcesses) }
    }

    var backgroundOpacity: Double {
        get { double(forKey: Key.backgroundOpacity, defaultValue: 0.9) }
        nonmutating set { defaults.set(newValue, forKey: Key.backgroundOpacity) }
    }

    var trayMetricRawValues: [String] {
        get { csvValues(forKey: Key.trayMetrics) }
        nonmutating set { defaults.set(newValue.joined(separator: ","), forKey: Key.trayMetrics) }
    }

    var trayMetricOrderRawValues: [String] {
        get { csvValues(forKey: Key.trayMetricOrder) }
        nonmutating set { defaults.set(newValue.joined(separator: ","), forKey: Key.trayMetricOrder) }
    }

    private func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private func double(forKey key: String, defaultValue: Double) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.double(forKey: key)
    }

    private func csvValues(forKey key: String) -> [String] {
        (defaults.string(forKey: key) ?? "")
            .split(separator: ",")
            .map(String.init)
    }
}
