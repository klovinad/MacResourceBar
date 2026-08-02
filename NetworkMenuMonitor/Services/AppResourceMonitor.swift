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
    private var latestProcessMetadataByPid: [pid_t: ProcessMetadata] = [:]
    private var isRunning = false
    private var completedSampleCount = 0
    private var cachedRunningApplicationMetadata: [pid_t: ProcessMetadata] = [:]
    private var runningApplicationObservers: [NSObjectProtocol] = []

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

        observeRunningApplicationChanges()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        runningApplicationObservers.forEach(center.removeObserver)
    }

    private func observeRunningApplicationChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            let metadata = Self.readRunningApplicationMetadataByPid()
            self.queue.async { [self] in
                self.cachedRunningApplicationMetadata = metadata
            }
        }

        runningApplicationObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: refresh),
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: refresh)
        ]

        if Thread.isMainThread {
            cachedRunningApplicationMetadata = Self.readRunningApplicationMetadataByPid()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let metadata = Self.readRunningApplicationMetadataByPid()
                self.queue.async { [self] in
                    self.cachedRunningApplicationMetadata = metadata
                }
            }
        }
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
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
                self.timer?.cancel()
                let nextDelay = self.completedSampleCount < 2
                    ? min(normalizedInterval, 1)
                    : normalizedInterval
                self.scheduleTimer(deadline: .now() + nextDelay)
            }
        }
    }

    private func startLocked() {
        guard !isRunning else { return }

        isRunning = true
        completedSampleCount = 0
        publishStatus(nil)
        networkMonitor.setPollingInterval(pollingInterval)
        networkMonitor.start()
        // Prime cumulative CPU/disk counters immediately, then take a usable
        // second sample after one second even in the 10-second refresh mode.
        tick()
        scheduleTimer(deadline: .now() + min(pollingInterval, 1))
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        isRunning = false
        completedSampleCount = 0
        latestNetwork.removeAll(keepingCapacity: false)
        latestCPU.removeAll(keepingCapacity: false)
        latestMemory.removeAll(keepingCapacity: false)
        latestDisk.removeAll(keepingCapacity: false)
        latestProcessMetadataByPid.removeAll(keepingCapacity: false)
        cpuMonitor.reset()
        diskMonitor.reset()
        networkMonitor.stop()
        // Keep the last published snapshot while the popover is closed. Clearing
        // it made every reopen flash an incorrect empty table before the first
        // fresh sample arrived.
    }

    private func scheduleTimer(deadline: DispatchTime) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: deadline, repeating: pollingInterval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let metadataByPid = Self.metadataIncludingDescendants(
            of: cachedRunningApplicationMetadata
        )
        latestProcessMetadataByPid = metadataByPid
        // Include descendants so renderer/helper CPU, memory and disk activity
        // does not disappear simply because it has no current network traffic.
        // Unrelated daemons remain out of scope.
        let activePids = Set(metadataByPid.keys).union(latestNetwork.keys)

        // The second, one-second sample is intentionally an early warm-up so
        // other apps do not all show 0% for ten seconds. Do not attribute the
        // cost of creating and laying out this popover to MacResourceBar's
        // first visible CPU value; establish its baseline at this point and
        // report the representative interval that follows.
        if completedSampleCount == 1 {
            cpuMonitor.reset(pid: getpid())
        }
        latestCPU = cpuMonitor.sample(activePids: activePids)
        latestMemory = memoryMonitor.sample(activePids: activePids)
        latestDisk = diskMonitor.sample(activePids: activePids)
        completedSampleCount += 1
        if completedSampleCount >= 2 {
            publishUpdate(collectSnapshots(metadataByPid: metadataByPid))
        }
    }

    private func publishUpdate(_ snapshots: [AppResourceSnapshot]) {
        onUpdate?(snapshots)
    }

    private func publishStatus(_ message: String?) {
        onStatusChange?(message)
    }

    private func publishIfNeeded() {
        guard isRunning, completedSampleCount >= 2 else { return }
        publishUpdate(collectSnapshots(
            metadataByPid: latestProcessMetadataByPid.isEmpty
                ? cachedRunningApplicationMetadata
                : latestProcessMetadataByPid
        ))
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

    private static func readRunningApplicationMetadataByPid() -> [pid_t: ProcessMetadata] {
        var metadataByPid: [pid_t: ProcessMetadata] = [:]

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }

            metadataByPid[pid] = ProcessMetadata(
                displayName: app.localizedName ?? "PID \(pid)",
                bundleIdentifier: app.bundleIdentifier,
                icon: app.icon
            )
        }

        return metadataByPid
    }

    private static func metadataIncludingDescendants(
        of rootMetadata: [pid_t: ProcessMetadata]
    ) -> [pid_t: ProcessMetadata] {
        guard !rootMetadata.isEmpty else { return [:] }

        let rootPids = Set(rootMetadata.keys)
        let parentByPid = processParentMap()
        var result = rootMetadata

        for pid in parentByPid.keys where !rootPids.contains(pid) {
            var cursor = pid
            var visited: Set<pid_t> = [pid]
            var owningRoot: pid_t?

            while let parent = parentByPid[cursor], parent > 0 {
                if rootPids.contains(parent) {
                    owningRoot = parent
                    break
                }
                guard visited.insert(parent).inserted else { break }
                cursor = parent
            }

            guard
                let owningRoot,
                let owner = rootMetadata[owningRoot],
                let displayName = processName(for: pid) ?? executableName(for: pid)
            else {
                continue
            }

            result[pid] = ProcessMetadata(
                displayName: displayName,
                bundleIdentifier: owner.bundleIdentifier,
                icon: owner.icon
            )
        }

        return result
    }

    private static func processParentMap() -> [pid_t: pid_t] {
        let estimatedCount = max(proc_listallpids(nil, 0), 0)
        guard estimatedCount > 0 else { return [:] }

        var pids = [pid_t](
            repeating: 0,
            count: Int(estimatedCount) + 64
        )
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.stride)
            )
        }
        guard count > 0 else { return [:] }

        var result: [pid_t: pid_t] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let readSize = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(
                    pid,
                    PROC_PIDTBSDINFO,
                    0,
                    pointer,
                    expectedSize
                )
            }
            guard readSize == expectedSize else { continue }
            result[pid] = pid_t(info.pbi_ppid)
        }
        return result
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

        if let processName = Self.processName(for: pid) ?? Self.executableName(for: pid) {
            return ProcessMetadata(
                displayName: processName,
                bundleIdentifier: nil,
                icon: NSWorkspace.shared.icon(for: .application)
            )
        }

        return nil
    }

    private static func processName(for pid: pid_t) -> String? {
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        let result = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        guard result > 0 else { return nil }
        let nameLength = nameBuffer.firstIndex(of: 0) ?? nameBuffer.count
        return String(decoding: nameBuffer.prefix(nameLength).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func executableName(for pid: pid_t) -> String? {
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
