import Foundation

enum NetworkInterfaceScope: String, CaseIterable {
    case primary
    case physical
    case allIncludingVPN

    var label: String {
        switch self {
        case .primary: "Primary"
        case .physical: "All physical"
        case .allIncludingVPN: "Include VPN"
        }
    }
}

enum NetworkInterfacePolicy {
    static func includes(
        _ name: String,
        scope: NetworkInterfaceScope,
        primaryInterface: String?
    ) -> Bool {
        switch scope {
        case .primary:
            if let primaryInterface, !primaryInterface.isEmpty {
                return name == primaryInterface
            }
            return isPhysical(name)
        case .physical:
            return isPhysical(name)
        case .allIncludingVPN:
            return isPhysical(name)
                || name.hasPrefix("utun")
                || name.hasPrefix("ipsec")
                || name.hasPrefix("ppp")
        }
    }

    static func isPhysical(_ name: String) -> Bool {
        name.range(of: #"^en\d+$"#, options: .regularExpression) != nil
    }
}

enum PhysicalDiskPolicy {
    static func wholeDiskIdentifier(from identifier: String) -> String? {
        guard identifier.range(
            of: #"^disk\d+(?:s\d+)*$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }

        var result = identifier
        while let range = result.range(of: #"s\d+$"#, options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result
    }
}

enum StableOrderPolicy {
    /// Extends a persisted order with items visible in the current session
    /// without deleting dormant items that may return later.
    static func merging(stored: [String], available: [String]) -> [String] {
        var seen = Set<String>()
        var result = stored.filter { seen.insert($0).inserted }
        result.append(contentsOf: available.filter { seen.insert($0).inserted })
        return result
    }
}

enum SamplingFreshnessPolicy {
    static func canReuseBaseline(age: TimeInterval, regularInterval: TimeInterval) -> Bool {
        age >= 0 && age <= max(regularInterval * 1.5, 8)
    }
}

enum CounterRatePolicy {
    /// A counter reset or a gap requires a new baseline, not a zero sample.
    static func rate(current: UInt64, previous: UInt64, elapsed: TimeInterval, maximumAge: TimeInterval) -> Double? {
        guard elapsed.isFinite, elapsed > 0, elapsed <= maximumAge,
              current >= previous else { return nil }
        return Double(current - previous) / elapsed
    }
}

enum NetTopCSVRecord: Equatable {
    case header
    case process(pid: Int32, token: String, bytesIn: UInt64, bytesOut: UInt64)
    case ignored

    static func parse(_ line: String) -> NetTopCSVRecord {
        var columns = line.trimmingCharacters(in: .newlines)
            .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        while columns.last?.isEmpty == true { columns.removeLast() }
        if columns.suffix(2) == ["bytes_in", "bytes_out"] { return .header }
        guard columns.count >= 3,
              let outgoing = UInt64(columns.removeLast()),
              let incoming = UInt64(columns.removeLast()) else { return .ignored }
        let token = columns.joined(separator: ",")
        guard let dot = token.lastIndex(of: "."),
              let pid = Int32(token[token.index(after: dot)...]), pid > 1 else { return .ignored }
        return .process(pid: pid, token: token, bytesIn: incoming, bytesOut: outgoing)
    }
}
