import Foundation

struct AppSnapshotFilterState {
    let snapshots: [AppResourceSnapshot]
    let searchText: String
    let resourceFilter: MenuBarViewModel.AppResourceFilter
    let threshold: Double
    let sortOrder: MenuBarViewModel.AppSortOrder
    let activeOnly: Bool
    let showHelperProcesses: Bool

    var tableSnapshots: [AppResourceSnapshot] {
        showHelperProcesses ? snapshots : groupedSnapshots()
    }

    var filteredSnapshots: [AppResourceSnapshot] {
        tableSnapshots
            .filter(matchesSearch)
            .filter(isActive)
            .sorted(by: sort)
    }

    var filteredCountText: String {
        let tableSnapshots = tableSnapshots
        let count = tableSnapshots
            .lazy
            .filter(matchesSearch)
            .filter(isActive)
            .count
        return "\(count) of \(tableSnapshots.count)"
    }

    var searchMatchCountText: String? {
        let search = normalizedSearch
        guard !search.isEmpty else { return nil }

        let matchCount = tableSnapshots
            .lazy
            .filter { $0.displayName.localizedCaseInsensitiveContains(search) }
            .count

        return "\(matchCount) matches"
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesSearch(_ snapshot: AppResourceSnapshot) -> Bool {
        let search = normalizedSearch
        return search.isEmpty || snapshot.displayName.localizedCaseInsensitiveContains(search)
    }

    private func isActive(_ snapshot: AppResourceSnapshot) -> Bool {
        guard activeOnly else { return true }
        return activityValue(for: snapshot) >= threshold
    }

    private func activityValue(for snapshot: AppResourceSnapshot) -> Double {
        switch resourceFilter {
        case .all:
            return snapshot.totalActivityScore
        case .cpu:
            return snapshot.cpuUsagePercent
        case .memory:
            return Double(snapshot.ramBytes)
        case .disk:
            return snapshot.diskBytesPerSecond
        case .network:
            return snapshot.networkBytesPerSecond
        }
    }

    private func sort(_ lhs: AppResourceSnapshot, _ rhs: AppResourceSnapshot) -> Bool {
        switch sortOrder {
        case .totalRate:
            return lhs.totalActivityScore != rhs.totalActivityScore
                ? lhs.totalActivityScore > rhs.totalActivityScore
                : lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        case .cpuRate:
            return lhs.cpuUsagePercent != rhs.cpuUsagePercent
                ? lhs.cpuUsagePercent > rhs.cpuUsagePercent
                : lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        case .memoryRate:
            return lhs.ramBytes != rhs.ramBytes
                ? lhs.ramBytes > rhs.ramBytes
                : lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        case .diskRate:
            return lhs.diskBytesPerSecond != rhs.diskBytesPerSecond
                ? lhs.diskBytesPerSecond > rhs.diskBytesPerSecond
                : lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        case .networkRate:
            return lhs.networkBytesPerSecond != rhs.networkBytesPerSecond
                ? lhs.networkBytesPerSecond > rhs.networkBytesPerSecond
                : lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        case .name:
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func groupedSnapshots() -> [AppResourceSnapshot] {
        var grouped: [String: AppResourceSnapshot] = [:]

        for snapshot in snapshots {
            let displayName = snapshot.groupedDisplayName
            let key = snapshot.bundleIdentifier ?? displayName.lowercased()

            guard let current = grouped[key] else {
                grouped[key] = AppResourceSnapshot(
                    processName: displayName,
                    pid: snapshot.isHelperProcess ? nil : snapshot.pid,
                    pids: snapshot.pids,
                    bundleIdentifier: snapshot.bundleIdentifier,
                    icon: snapshot.icon,
                    cpuUsagePercent: snapshot.cpuUsagePercent,
                    ramBytes: snapshot.ramBytes,
                    diskReadBytesPerSecond: snapshot.diskReadBytesPerSecond,
                    diskWriteBytesPerSecond: snapshot.diskWriteBytesPerSecond,
                    downloadBytesPerSecond: snapshot.downloadBytesPerSecond,
                    uploadBytesPerSecond: snapshot.uploadBytesPerSecond,
                    isApproximation: snapshot.isApproximation,
                    childProcessCount: snapshot.childProcessCount
                )
                continue
            }

            grouped[key] = AppResourceSnapshot(
                processName: current.displayName,
                pid: nil,
                pids: Array(Set(current.pids + snapshot.pids)).sorted(),
                bundleIdentifier: current.bundleIdentifier ?? snapshot.bundleIdentifier,
                icon: current.icon ?? snapshot.icon,
                cpuUsagePercent: current.cpuUsagePercent + snapshot.cpuUsagePercent,
                ramBytes: current.ramBytes + snapshot.ramBytes,
                diskReadBytesPerSecond: current.diskReadBytesPerSecond + snapshot.diskReadBytesPerSecond,
                diskWriteBytesPerSecond: current.diskWriteBytesPerSecond + snapshot.diskWriteBytesPerSecond,
                downloadBytesPerSecond: current.downloadBytesPerSecond + snapshot.downloadBytesPerSecond,
                uploadBytesPerSecond: current.uploadBytesPerSecond + snapshot.uploadBytesPerSecond,
                isApproximation: current.isApproximation || snapshot.isApproximation,
                childProcessCount: current.childProcessCount + snapshot.childProcessCount
            )
        }

        return Array(grouped.values)
    }
}
