import AppKit
import Foundation

final class AppResourceMonitor: @unchecked Sendable {
    var onUpdate: (([AppResourceSnapshot]) -> Void)?
    var onStatusChange: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "NetworkMenuMonitor.AppResourceMonitor")
    private let networkMonitor = NetworkProcessMonitor()
    private let cpuMonitor = CPUProcessMonitor()
    private let memoryMonitor = MemoryProcessMonitor()
    private let diskMonitor = DiskProcessMonitor()

    private var timer: DispatchSourceTimer?
    private var pollingInterval: TimeInterval = 1
    private var latestNetwork: [pid_t: NetworkProcessSample] = [:]
    private var latestCPU: [pid_t: Double] = [:]
    private var latestMemory: [pid_t: UInt64] = [:]
    private var latestDisk: [pid_t: DiskProcessSample] = [:]
    private var isRunning = false

    init() {
        networkMonitor.onUpdate = { [weak self] samples in
            self?.queue.async {
                let byPid = Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0) })
                self?.latestNetwork = byPid
                self?.publishIfNeeded()
            }
        }

        networkMonitor.onStatusChange = { [weak self] message in
            self?.publishStatus(message)
        }
    }

    func start() {
        let owner = Unmanaged.passUnretained(self)
        queue.async {
            owner.takeUnretainedValue().startLocked()
        }
    }

    func stop() {
        let owner = Unmanaged.passUnretained(self)
        queue.async {
            owner.takeUnretainedValue().stopLocked()
        }
    }

    func restart() {
        stop()
        start()
    }

    func setPollingInterval(_ interval: TimeInterval) {
        let normalizedInterval = max(interval, 1)
        queue.async {
            guard abs(normalizedInterval - self.pollingInterval) > 0.01 else { return }
            self.pollingInterval = normalizedInterval
            if self.timer != nil {
                self.stopLocked()
                self.startLocked()
            }
        }
    }

    private func startLocked() {
        guard !isRunning else { return }

        isRunning = true
        publishStatus(nil)
        networkMonitor.start()
        scheduleTimer()
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        isRunning = false
        latestNetwork.removeAll(keepingCapacity: false)
        latestCPU.removeAll(keepingCapacity: false)
        latestMemory.removeAll(keepingCapacity: false)
        latestDisk.removeAll(keepingCapacity: false)
        networkMonitor.stop()
        publishUpdate([])
    }

    private func scheduleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: pollingInterval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        latestCPU = cpuMonitor.sample()
        latestMemory = memoryMonitor.sample()
        latestDisk = diskMonitor.sample()
        publishUpdate(collectSnapshots())
    }

    private func publishUpdate(_ snapshots: [AppResourceSnapshot]) {
        onUpdate?(snapshots)
    }

    private func publishStatus(_ message: String?) {
        onStatusChange?(message)
    }

    private func publishIfNeeded() {
        guard isRunning else { return }
        publishUpdate(collectSnapshots())
    }

    private func collectSnapshots() -> [AppResourceSnapshot] {
        var result: [AppResourceSnapshot] = []
        let allPids = Set(latestNetwork.keys)
            .union(latestCPU.keys)
            .union(latestMemory.keys)
            .union(latestDisk.keys)

        for pid in allPids {
            let metadata = metadata(for: pid)
            let cpu = latestCPU[pid] ?? 0
            let ram = latestMemory[pid] ?? 0
            let disk = latestDisk[pid]
            let network = latestNetwork[pid]

            result.append(AppResourceSnapshot(
                processName: metadata.displayName,
                pid: pid,
                bundleIdentifier: metadata.bundleIdentifier,
                icon: metadata.icon,
                cpuUsagePercent: cpu,
                ramBytes: ram,
                diskReadBytesPerSecond: disk?.readBytesPerSecond ?? 0,
                diskWriteBytesPerSecond: disk?.writeBytesPerSecond ?? 0,
                downloadBytesPerSecond: network?.downloadBytesPerSecond ?? 0,
                uploadBytesPerSecond: network?.uploadBytesPerSecond ?? 0,
                isApproximation: network != nil || !latestNetwork.isEmpty
            ))
        }

        return result
    }

    private func metadata(for pid: pid_t) -> ProcessMetadata {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) {
            return ProcessMetadata(
                displayName: app.localizedName ?? "Unknown",
                bundleIdentifier: app.bundleIdentifier,
                icon: app.icon
            )
        }

        if let network = latestNetwork[pid] {
            return ProcessMetadata(
                displayName: network.processName,
                bundleIdentifier: network.bundleIdentifier,
                icon: network.icon
            )
        }

        return ProcessMetadata(
            displayName: "PID \(pid)",
            bundleIdentifier: nil,
            icon: NSWorkspace.shared.icon(for: .application)
        )
    }

    private struct ProcessMetadata {
        let displayName: String
        let bundleIdentifier: String?
        let icon: NSImage?
    }
}
