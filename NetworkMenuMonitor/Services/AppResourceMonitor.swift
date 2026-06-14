import AppKit
import Foundation
import Darwin

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
            guard let monitor = self else { return }
            monitor.queue.async { [monitor] in
                let byPid = Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0) })
                monitor.latestNetwork = byPid
                monitor.publishIfNeeded()
            }
        }

        networkMonitor.onStatusChange = { [weak self] message in
            guard let monitor = self else { return }
            monitor.publishStatus(message)
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
            self.networkMonitor.setPollingInterval(normalizedInterval)
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
        networkMonitor.setPollingInterval(pollingInterval)
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
        let metadataByPid = runningApplicationMetadataByPid()
        let activePids = allProcessIdentifiers()

        latestCPU = cpuMonitor.sample(activePids: activePids)
        latestMemory = memoryMonitor.sample(activePids: activePids)
        latestDisk = diskMonitor.sample(activePids: activePids)
        publishUpdate(collectSnapshots(metadataByPid: metadataByPid))
    }

    private func publishUpdate(_ snapshots: [AppResourceSnapshot]) {
        onUpdate?(snapshots)
    }

    private func publishStatus(_ message: String?) {
        onStatusChange?(message)
    }

    private func publishIfNeeded() {
        guard isRunning else { return }
        publishUpdate(collectSnapshots(metadataByPid: runningApplicationMetadataByPid()))
    }

    private func collectSnapshots(metadataByPid: [pid_t: ProcessMetadata]) -> [AppResourceSnapshot] {
        var result: [AppResourceSnapshot] = []
        let allPids = Set(latestNetwork.keys)
            .union(latestCPU.keys)
            .union(latestMemory.keys)
            .union(latestDisk.keys)

        for pid in allPids {
            guard let metadata = metadata(for: pid, metadataByPid: metadataByPid) else {
                continue
            }
            let cpu = latestCPU[pid] ?? 0
            let ram = latestMemory[pid] ?? 0
            let disk = latestDisk[pid]
            let network = latestNetwork[pid]

            result.append(AppResourceSnapshot(
                processName: metadata.displayName,
                pid: pid,
                pids: [pid],
                bundleIdentifier: metadata.bundleIdentifier,
                icon: metadata.icon,
                cpuUsagePercent: cpu,
                ramBytes: ram,
                diskReadBytesPerSecond: disk?.readBytesPerSecond ?? 0,
                diskWriteBytesPerSecond: disk?.writeBytesPerSecond ?? 0,
                downloadBytesPerSecond: network?.downloadBytesPerSecond ?? 0,
                uploadBytesPerSecond: network?.uploadBytesPerSecond ?? 0,
                isApproximation: network != nil || !latestNetwork.isEmpty,
                childProcessCount: 1
            ))
        }

        return result
    }

    private func runningApplicationMetadataByPid() -> [pid_t: ProcessMetadata] {
        let snapshot: [pid_t: ProcessMetadata]
        if Thread.isMainThread {
            snapshot = Self.readRunningApplicationMetadataByPid()
        } else {
            snapshot = DispatchQueue.main.sync {
                Self.readRunningApplicationMetadataByPid()
            }
        }

        return snapshot
    }

    private func allProcessIdentifiers() -> Set<pid_t> {
        let capacity = max(proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0), 0)
        guard capacity > 0 else { return [] }

        let pidCount = (Int(capacity) / MemoryLayout<pid_t>.stride) * 2
        var pids = Array(repeating: pid_t(0), count: pidCount)
        let bytesWritten = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.stride)
            )
        }

        guard bytesWritten > 0 else { return [] }
        return Set(pids.prefix(Int(bytesWritten) / MemoryLayout<pid_t>.stride).filter { $0 > 0 })
    }

    private static func readRunningApplicationMetadataByPid() -> [pid_t: ProcessMetadata] {
        Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { app in
            (
                app.processIdentifier,
                ProcessMetadata(
                    displayName: app.localizedName ?? "PID \(app.processIdentifier)",
                    bundleIdentifier: app.bundleIdentifier,
                    icon: app.icon
                )
            )
        })
    }

    private func metadata(
        for pid: pid_t,
        metadataByPid: [pid_t: ProcessMetadata]
    ) -> ProcessMetadata? {
        if let metadata = metadataByPid[pid] {
            return metadata
        }

        if let network = latestNetwork[pid] {
            return ProcessMetadata(
                displayName: network.processName,
                bundleIdentifier: network.bundleIdentifier,
                icon: network.icon
            )
        }

        if let processName = processName(for: pid) ?? executableName(for: pid) {
            return ProcessMetadata(
                displayName: processName,
                bundleIdentifier: nil,
                icon: NSWorkspace.shared.icon(for: .application)
            )
        }

        return nil
    }

    private func processName(for pid: pid_t) -> String? {
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        let result = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        guard result > 0 else { return nil }
        let nameLength = nameBuffer.firstIndex(of: 0) ?? nameBuffer.count
        return String(decoding: nameBuffer.prefix(nameLength).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func executableName(for pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard result > 0 else { return nil }

        let pathLength = pathBuffer.firstIndex(of: 0) ?? pathBuffer.count
        let path = String(decoding: pathBuffer.prefix(pathLength).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path).lastPathComponent.nilIfEmpty
    }

    private struct ProcessMetadata {
        let displayName: String
        let bundleIdentifier: String?
        let icon: NSImage?
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
