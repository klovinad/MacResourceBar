import Foundation
import SystemConfiguration
import Darwin

/// Mutable state is confined to `queue`; public mutators only enqueue work.
final class NetworkTotalsMonitor: @unchecked Sendable {
    typealias Source = NetworkInterfaceScope

    struct Sample {
        let timestamp: Date
        let downloadBytesPerSecond: Double
        let uploadBytesPerSecond: Double
        let sourceDescription: String
    }

    var onSample: ((Sample) -> Void)?
    var onReset: (() -> Void)?
    var onStatusChange: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "MacResourceBar.NetworkTotals", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastCounters: Counters?
    private var pollingInterval: TimeInterval = 1
    private var source: Source = .primary

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    private func startLocked() {
        guard timer == nil else { return }

        lastCounters = readCounters()
        onStatusChange?(
            lastCounters == nil
                ? "Network totals are unavailable"
                : "Waiting for network traffic sample"
        )

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + min(pollingInterval, 1), repeating: pollingInterval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        lastCounters = nil
    }

    func setPollingInterval(_ interval: TimeInterval) {
        let normalizedInterval = max(interval, 1)
        queue.async { [weak self] in
            guard let self else { return }
            guard abs(normalizedInterval - pollingInterval) > 0.01 else { return }
            pollingInterval = normalizedInterval

            if timer != nil {
                stopLocked()
                startLocked()
            }
        }
    }

    func setSource(_ source: Source) {
        queue.async { [weak self] in
            guard let self, self.source != source else { return }
            self.source = source
            self.lastCounters = self.readCounters()
            self.onReset?()
            self.onStatusChange?(
                self.lastCounters == nil
                    ? "Network totals are unavailable"
                    : "Waiting for network traffic sample"
            )
        }
    }

    private func poll() {
        let now = Date()
        guard let current = readCounters() else {
            lastCounters = nil
            onStatusChange?("Network totals are unavailable")
            return
        }
        guard let previous = lastCounters else {
            lastCounters = current
            onStatusChange?("Waiting for network traffic sample")
            return
        }

        guard let rates = Self.rates(
            previous: previous,
            current: current,
            maximumAge: max(8, pollingInterval * 1.5)
        ) else {
            lastCounters = current
            onReset?()
            onStatusChange?("Waiting for network traffic sample")
            return
        }

        lastCounters = current
        onStatusChange?(nil)
        onSample?(Sample(
            timestamp: now,
            downloadBytesPerSecond: rates.download,
            uploadBytesPerSecond: rates.upload,
            sourceDescription: current.sourceDescription
        ))
    }

    private func readCounters() -> Counters? {
        guard let interfaces = Self.readInterfaceCounters() else { return nil }
        let primary = Self.primaryInterfaceName()
        let included = interfaces.filter { name, counters in
            (counters.flags & IFF_UP) != 0
                && (counters.flags & IFF_RUNNING) != 0
                && (counters.flags & IFF_LOOPBACK) == 0
                && NetworkInterfacePolicy.includes(name, scope: source, primaryInterface: primary)
        }
        guard !included.isEmpty else { return nil }
        return Counters(uptime: ProcessInfo.processInfo.systemUptime, interfaces: included)
    }

    // getifaddrs exposes 32-bit if_data byte counters on macOS. NET_RT_IFLIST2
    // supplies if_data64, so a fast transfer does not reset at every 4 GiB.
    static func readInterfaceCounters() -> [String: InterfaceCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            var data = Data(count: size)
            let result = data.withUnsafeMutableBytes { buffer in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
            }
            if result != 0 {
                if errno == ENOMEM { continue } // Interface inventory changed during the read.
                return nil
            }
            data.count = size
            return parseInterfaceMessages(data) { index in
                var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                guard if_indextoname(UInt32(index), &name) != nil else { return nil }
                let end = name.firstIndex(of: 0) ?? name.count
                return String(decoding: name.prefix(end).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }

    static func parseInterfaceMessages(
        _ data: Data,
        interfaceName: (UInt16) -> String?
    ) -> [String: InterfaceCounters]? {
        data.withUnsafeBytes { bytes in
            var result: [String: InterfaceCounters] = [:]
            var offset = 0
            while offset < bytes.count {
                guard bytes.count - offset >= 4 else { return nil }
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= bytes.count - offset else { return nil }
                defer { offset += length }
                guard bytes[offset + 3] == RTM_IFINFO2 else { continue }
                guard length >= MemoryLayout<if_msghdr2>.size else { return nil }
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard let name = interfaceName(header.ifm_index) else { continue }
                result[name] = InterfaceCounters(
                    index: header.ifm_index,
                    flags: header.ifm_flags,
                    inBytes: header.ifm_data.ifi_ibytes,
                    outBytes: header.ifm_data.ifi_obytes
                )
            }
            return result
        }
    }

    static func rates(previous: Counters, current: Counters, maximumAge: TimeInterval) -> (download: Double, upload: Double)? {
        guard Set(previous.interfaces.keys) == Set(current.interfaces.keys) else { return nil }
        var download = 0.0
        var upload = 0.0
        let elapsed = current.uptime - previous.uptime
        for (name, counters) in current.interfaces {
            guard let old = previous.interfaces[name], old.index == counters.index,
                  let incoming = CounterRatePolicy.rate(current: counters.inBytes, previous: old.inBytes, elapsed: elapsed, maximumAge: maximumAge),
                  let outgoing = CounterRatePolicy.rate(current: counters.outBytes, previous: old.outBytes, elapsed: elapsed, maximumAge: maximumAge) else { return nil }
            download += incoming
            upload += outgoing
        }
        return (download, upload)
    }

    private static func primaryInterfaceName() -> String? {
        let key = "State:/Network/Global/IPv4" as CFString
        guard
            let value = SCDynamicStoreCopyValue(nil, key) as? [String: Any],
            let name = value[kSCDynamicStorePropNetPrimaryInterface as String] as? String,
            !name.isEmpty
        else {
            return nil
        }
        return name
    }

    struct InterfaceCounters {
        let index: UInt16
        let flags: Int32
        let inBytes: UInt64
        let outBytes: UInt64
    }

    struct Counters {
        let uptime: TimeInterval
        let interfaces: [String: InterfaceCounters]
        var sourceDescription: String { interfaces.keys.sorted().joined(separator: ", ") }
    }
}
