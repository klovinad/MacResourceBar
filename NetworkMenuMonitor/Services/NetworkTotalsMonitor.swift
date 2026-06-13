import Foundation

final class NetworkTotalsMonitor {
    struct Sample {
        let timestamp: Date
        let downloadBytesPerSecond: Double
        let uploadBytesPerSecond: Double
    }

    var onSample: ((Sample) -> Void)?
    var onReset: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private var lastCounters: Counters?
    private var pollingInterval: TimeInterval = 1

    func start() {
        guard timer == nil else { return }

        lastCounters = readCounters()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + pollingInterval, repeating: pollingInterval)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastCounters = nil
    }

    func setPollingInterval(_ interval: TimeInterval) {
        let normalizedInterval = max(interval, 1)
        guard abs(normalizedInterval - pollingInterval) > 0.01 else { return }
        pollingInterval = normalizedInterval

        if timer != nil {
            stop()
            start()
        }
    }

    private func poll() {
        let now = Date()
        let current = readCounters()

        guard let previous = lastCounters else {
            lastCounters = current
            return
        }

        guard previous.activeInterfaces == current.activeInterfaces,
              current.inBytes >= previous.inBytes,
              current.outBytes >= previous.outBytes else {
            lastCounters = current
            onReset?()
            onSample?(Sample(timestamp: now, downloadBytesPerSecond: 0, uploadBytesPerSecond: 0))
            return
        }

        let deltaTime = max(current.timestamp.timeIntervalSince(previous.timestamp), 0.5)
        let download = max(Double(current.inBytes &- previous.inBytes) / deltaTime, 0)
        let upload = max(Double(current.outBytes &- previous.outBytes) / deltaTime, 0)

        lastCounters = current
        onSample?(Sample(timestamp: now, downloadBytesPerSecond: download, uploadBytesPerSecond: upload))
    }

    private func readCounters() -> Counters {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return Counters(timestamp: Date(), inBytes: 0, outBytes: 0, activeInterfaces: [])
        }

        defer { freeifaddrs(pointer) }

        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var activeInterfaces = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            guard let data = interface.ifa_data else {
                continue
            }

            let networkData = data.assumingMemoryBound(to: if_data.self).pointee
            if let name = String(validatingCString: interface.ifa_name) {
                activeInterfaces.insert(name)
            }
            inBytes += UInt64(networkData.ifi_ibytes)
            outBytes += UInt64(networkData.ifi_obytes)
        }

        return Counters(
            timestamp: Date(),
            inBytes: inBytes,
            outBytes: outBytes,
            activeInterfaces: activeInterfaces
        )
    }

    private struct Counters {
        let timestamp: Date
        let inBytes: UInt64
        let outBytes: UInt64
        let activeInterfaces: Set<String>
    }
}
