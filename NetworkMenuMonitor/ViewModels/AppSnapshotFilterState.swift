import Foundation

struct AppSnapshotFilterState {
    struct SnapshotLists {
        let table: [AppResourceSnapshot]
        let filtered: [AppResourceSnapshot]
    }

    let snapshots: [AppResourceSnapshot]
    let searchText: String
    let resourceFilter: MenuBarViewModel.AppResourceFilter
    let threshold: Double
    let sortOrder: MenuBarViewModel.AppSortOrder
    let customOrder: [String]
    let activeOnly: Bool
    let showHelperProcesses: Bool

    var tableSnapshots: [AppResourceSnapshot] {
        showHelperProcesses ? snapshots : groupedSnapshots()
    }

    var filteredSnapshots: [AppResourceSnapshot] {
        snapshotLists.filtered
    }

    var snapshotLists: SnapshotLists {
        let table = tableSnapshots
        let customOrderIndex = customOrderIndex
        let filtered = table
            .filter(matchesSearch)
            .filter(isActive)
            .sorted { sort($0, $1, customOrderIndex: customOrderIndex) }
        return SnapshotLists(table: table, filtered: filtered)
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesSearch(_ snapshot: AppResourceSnapshot) -> Bool {
        let search = normalizedSearch
        return search.isEmpty || snapshot.displayName.localizedCaseInsensitiveContains(search)
    }

    private func isActive(_ snapshot: AppResourceSnapshot) -> Bool {
        // Minimum is an independent filter. Previously it silently stopped
        // working when "All" applications was selected.
        if threshold > 0, activityValue(for: snapshot) < threshold {
            return false
        }
        guard activeOnly else { return true }

        // "Active" has one stable meaning regardless of the metric selected
        // for Minimum.
        return snapshot.cpuUsagePercent >= 0.1
            || snapshot.diskBytesPerSecond >= 1_024
            || snapshot.networkBytesPerSecond >= 1_024
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

    private func sort(_ lhs: AppResourceSnapshot, _ rhs: AppResourceSnapshot, customOrderIndex: [String: Int]) -> Bool {
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
        case .custom:
            let lhsIndex = customOrderIndex[lhs.orderKey] ?? Int.max
            let rhsIndex = customOrderIndex[rhs.orderKey] ?? Int.max
            return lhsIndex != rhsIndex
                ? lhsIndex < rhsIndex
                : lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var customOrderIndex: [String: Int] {
        var result: [String: Int] = [:]
        for (index, key) in customOrder.enumerated() where result[key] == nil {
            result[key] = index
        }
        return result
    }

    private func groupedSnapshots() -> [AppResourceSnapshot] {
        var grouped: [String: AppResourceSnapshot] = [:]

        // `parentAppName` performs several locale-aware searches. Compute it
        // once per process instead of on every sort comparison and grouping
        // pass; the old comparator called it hundreds of times per refresh.
        let stableSnapshots = snapshots
            .map { snapshot in
                DecoratedSnapshot(
                    snapshot: snapshot,
                    helperParentName: AppResourceSnapshot.parentAppName(
                        for: snapshot.processName
                    )
                )
            }
            .sorted {
                if $0.isHelperProcess != $1.isHelperProcess {
                    return !$0.isHelperProcess
                }
                let nameComparison = $0.snapshot.displayName.localizedCaseInsensitiveCompare(
                    $1.snapshot.displayName
                )
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }
                return ($0.snapshot.pid ?? 0) < ($1.snapshot.pid ?? 0)
            }

        let parentCandidates: [ParentAppCandidate] = stableSnapshots.compactMap { decorated in
            let snapshot = decorated.snapshot
            guard
                !decorated.isHelperProcess,
                let bundleIdentifier = snapshot.bundleIdentifier,
                !bundleIdentifier.isEmpty
            else {
                return nil
            }
            return ParentAppCandidate(
                displayName: snapshot.displayName,
                bundleIdentifier: bundleIdentifier
            )
        }

        for decorated in stableSnapshots {
            let snapshot = decorated.snapshot
            let resolvedParent = resolvedParent(
                for: snapshot,
                isHelperProcess: decorated.isHelperProcess,
                candidates: parentCandidates
            )
            // Do not relabel a helper unless its bundle identity proves which
            // parent owns it. Name-only grouping can merge Chrome channels or
            // embedded WebKit processes from unrelated apps.
            let displayName = resolvedParent?.displayName ?? snapshot.displayName
            let nameKey = displayName.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let resolvedBundle = resolvedParent?.bundleIdentifier ?? snapshot.bundleIdentifier
            let key = "\(nameKey)|bundle:\(resolvedBundle ?? "unbundled")"

            guard let current = grouped[key] else {
                grouped[key] = AppResourceSnapshot(
                    processName: displayName,
                    pid: nil,
                    pids: snapshot.pids,
                    bundleIdentifier: resolvedBundle,
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

        return grouped.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func resolvedParent(
        for snapshot: AppResourceSnapshot,
        isHelperProcess: Bool,
        candidates: [ParentAppCandidate]
    ) -> ParentAppCandidate? {
        guard
            isHelperProcess,
            let helperBundle = snapshot.bundleIdentifier?.lowercased(),
            !helperBundle.isEmpty
        else {
            return nil
        }

        let compatible = candidates.filter { candidate in
            let parentBundle = candidate.bundleIdentifier.lowercased()
            return helperBundle == parentBundle
                || helperBundle.hasPrefix(parentBundle + ".")
        }
        guard let longestLength = compatible.map({ $0.bundleIdentifier.count }).max() else {
            return nil
        }
        let strongest = compatible.filter { $0.bundleIdentifier.count == longestLength }
        guard strongest.count == 1 else { return nil }
        return strongest[0]
    }

    private struct ParentAppCandidate {
        let displayName: String
        let bundleIdentifier: String
    }

    private struct DecoratedSnapshot {
        let snapshot: AppResourceSnapshot
        let helperParentName: String?

        var isHelperProcess: Bool {
            helperParentName != nil
        }
    }
}
