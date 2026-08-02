import AppKit
import Foundation


struct NetworkProcessSample {
    let pid: pid_t
    let processName: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
}

final class NetworkProcessMonitor: @unchecked Sendable {
    var onUpdate: (([NetworkProcessSample]) -> Void)?
    var onStatusChange: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "NetworkMenuMonitor.NetworkProcessMonitor")
    private let ioQueue = DispatchQueue(
        label: "NetworkMenuMonitor.NetworkProcessMonitor.IO",
        qos: .utility,
        attributes: .concurrent
    )
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var timer: DispatchSourceTimer?
    private var process: Process?
    private var previousSnapshot: CumulativeSnapshot?
    private var pollingInterval: TimeInterval = 1
    private var isRunning = false
    private var lifecycleGeneration: UInt64 = 0
    private var lastPublishedStatus: String?
    private var hasPublishedStatus = false

    init() {
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopLocked()
        } else {
            queue.sync {
                stopLocked()
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
        queue.async { [weak self] in
            guard let monitor = self else { return }
            monitor.stopLocked()
            monitor.startLocked()
        }
    }

    func setPollingInterval(_ interval: TimeInterval) {
        let normalizedInterval = max(interval, 1)
        queue.async { [weak self] in
            guard let monitor = self else { return }
            guard abs(normalizedInterval - monitor.pollingInterval) > 0.01 else { return }
            monitor.pollingInterval = normalizedInterval
            if monitor.isRunning {
                let nextDelay = monitor.previousSnapshot == nil
                    ? min(normalizedInterval, 1)
                    : normalizedInterval
                monitor.scheduleTimerLocked(deadline: .now() + nextDelay)
            }
        }
    }

    private func startLocked() {
        guard !isRunning else { return }

        isRunning = true
        lifecycleGeneration &+= 1
        previousSnapshot = nil
        publishStatus(nil)
        scheduleTimerLocked(deadline: .now())
    }

    private func stopLocked() {
        isRunning = false
        lifecycleGeneration &+= 1
        timer?.cancel()
        timer = nil
        previousSnapshot = nil

        if let process {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        self.process = nil
        publishStatus(nil)
    }

    private func scheduleTimerLocked(deadline: DispatchTime) {
        timer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let leewayMilliseconds = Int(
            min(max(pollingInterval * 100, 100), 1_000)
        )
        timer.schedule(
            deadline: deadline,
            repeating: pollingInterval,
            leeway: .milliseconds(leewayMilliseconds)
        )
        timer.setEventHandler { [weak self] in
            self?.captureSnapshotLocked()
        }
        timer.resume()
        self.timer = timer
    }

    private func captureSnapshotLocked() {
        guard isRunning, process == nil else { return }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = [
            "-P",
            "-L", "1",
            "-x",
            "-n",
            "-c",
            "-t", "external",
            "-J", "bytes_in,bytes_out"
        ]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            self.process = process
        } catch {
            publishStatus("Per-app monitoring is unavailable because nettop could not be started: \(error.localizedDescription)")
            return
        }

        let generation = lifecycleGeneration
        let outputHandle = pipe.fileHandleForReading
        let stateQueue = queue

        ioQueue.async { [weak self, process, outputHandle, stateQueue] in
            let data = outputHandle.readDataToEndOfFile()
            process.waitUntilExit()
            let terminationStatus = process.terminationStatus

            stateQueue.async { [weak self, process] in
                self?.finishSnapshotLocked(
                    process: process,
                    data: data,
                    terminationStatus: terminationStatus,
                    generation: generation
                )
            }
        }
    }

    private func finishSnapshotLocked(
        process finishedProcess: Process,
        data: Data,
        terminationStatus: Int32,
        generation: UInt64
    ) {
        guard
            generation == lifecycleGeneration,
            process === finishedProcess
        else {
            return
        }

        process = nil
        guard isRunning else { return }

        guard terminationStatus == 0 else {
            publishStatus("Per-app monitoring is unavailable because nettop exited with status \(terminationStatus).")
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let counters = parseCumulativeCounters(from: data)
        let currentSnapshot = CumulativeSnapshot(
            timestamp: now,
            countersByPID: counters
        )

        let isInitialSnapshot = previousSnapshot == nil
        let rates = rateSamples(
            previous: previousSnapshot,
            current: currentSnapshot
        )
        previousSnapshot = currentSnapshot
        publishStatus(nil)
        resolveMetadataAndPublish(rates, generation: generation)
        if isInitialSnapshot, pollingInterval > 1 {
            // A cumulative first snapshot has no rate. Do one quick follow-up
            // so Eco mode does not leave Network empty for ten seconds.
            scheduleTimerLocked(deadline: .now() + 1)
        }
    }

    private func parseCumulativeCounters(from data: Data) -> [pid_t: CumulativeProcessCounters] {
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var countersByPID: [pid_t: CumulativeProcessCounters] = [:]

        for rawLine in output.split(whereSeparator: \.isNewline) {
            var columns = rawLine
                .split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init)

            while columns.last?.isEmpty == true {
                columns.removeLast()
            }

            guard columns.count >= 3 else { continue }
            guard
                let bytesOut = UInt64(columns.removeLast()),
                let bytesIn = UInt64(columns.removeLast())
            else {
                continue
            }

            let processToken = columns.joined(separator: ",")
            guard let pid = Self.extractPID(from: processToken) else { continue }

            if let existing = countersByPID[pid] {
                countersByPID[pid] = CumulativeProcessCounters(
                    processToken: existing.processToken,
                    bytesIn: Self.saturatedSum(existing.bytesIn, bytesIn),
                    bytesOut: Self.saturatedSum(existing.bytesOut, bytesOut)
                )
            } else {
                countersByPID[pid] = CumulativeProcessCounters(
                    processToken: processToken,
                    bytesIn: bytesIn,
                    bytesOut: bytesOut
                )
            }
        }

        return countersByPID
    }

    private func rateSamples(
        previous: CumulativeSnapshot?,
        current: CumulativeSnapshot
    ) -> [RawRateSample] {
        guard
            let previous,
            current.timestamp > previous.timestamp
        else {
            return []
        }

        let elapsed = current.timestamp - previous.timestamp
        var samples: [RawRateSample] = []

        for (pid, currentCounters) in current.countersByPID {
            guard
                let previousCounters = previous.countersByPID[pid],
                previousCounters.processToken == currentCounters.processToken
            else {
                continue
            }

            let download = currentCounters.bytesIn >= previousCounters.bytesIn
                ? Double(currentCounters.bytesIn - previousCounters.bytesIn) / elapsed
                : 0
            let upload = currentCounters.bytesOut >= previousCounters.bytesOut
                ? Double(currentCounters.bytesOut - previousCounters.bytesOut) / elapsed
                : 0
            guard download > 0 || upload > 0 else { continue }

            samples.append(RawRateSample(
                pid: pid,
                processToken: currentCounters.processToken,
                downloadBytesPerSecond: download,
                uploadBytesPerSecond: upload
            ))
        }

        return samples.sorted { $0.pid < $1.pid }
    }

    private func resolveMetadataAndPublish(_ rates: [RawRateSample], generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let samples = rates.compactMap { rate -> NetworkProcessSample? in
                let metadata = AppMetadata(processToken: rate.processToken)
                guard metadata.pid == rate.pid else { return nil }

                return NetworkProcessSample(
                    pid: rate.pid,
                    processName: metadata.displayName,
                    bundleIdentifier: metadata.bundleIdentifier,
                    icon: metadata.icon,
                    downloadBytesPerSecond: rate.downloadBytesPerSecond,
                    uploadBytesPerSecond: rate.uploadBytesPerSecond
                )
            }

            self.queue.async { [weak self] in
                guard
                    let self,
                    self.isRunning,
                    self.lifecycleGeneration == generation
                else {
                    return
                }

                let onUpdate = self.onUpdate
                onUpdate?(samples)
            }
        }
    }

    private static func extractPID(from token: String) -> pid_t? {
        guard let separator = token.lastIndex(of: ".") else { return nil }
        let pidCandidate = token[token.index(after: separator)...]
        guard let value = Int32(pidCandidate) else { return nil }
        return pid_t(value)
    }

    private static func saturatedSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private func publishStatus(_ message: String?) {
        guard !hasPublishedStatus || lastPublishedStatus != message else { return }
        hasPublishedStatus = true
        lastPublishedStatus = message

        let onStatusChange = onStatusChange
        DispatchQueue.main.async {
            onStatusChange?(message)
        }
    }

    private struct CumulativeProcessCounters {
        let processToken: String
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    private struct CumulativeSnapshot {
        let timestamp: CFAbsoluteTime
        let countersByPID: [pid_t: CumulativeProcessCounters]
    }

    private struct RawRateSample {
        let pid: pid_t
        let processToken: String
        let downloadBytesPerSecond: Double
        let uploadBytesPerSecond: Double
    }
}

private struct AppMetadata {
    let displayName: String
    let pid: pid_t?
    let bundleIdentifier: String?
    let icon: NSImage?

    init(processToken: String) {
        let pid = AppMetadata.extractPID(from: processToken)
        let baseName = AppMetadata.stripPID(from: processToken)

        if let pid,
           let app = Self.runningApplication(for: pid) {
            self.displayName = app.localizedName ?? baseName
            self.pid = pid
            self.bundleIdentifier = app.bundleIdentifier
            self.icon = app.icon
        } else {
            self.displayName = baseName
            self.pid = pid
            self.bundleIdentifier = nil
            self.icon = NSWorkspace.shared.icon(for: .application)
        }
    }

    private static func extractPID(from token: String) -> pid_t? {
        guard let separator = token.lastIndex(of: ".") else { return nil }
        let pidCandidate = token[token.index(after: separator)...]
        guard let value = Int32(pidCandidate) else { return nil }
        return pid_t(value)
    }

    private static func stripPID(from token: String) -> String {
        guard let separator = token.lastIndex(of: ".") else { return token }
        let suffix = token[token.index(after: separator)...]
        guard Int(suffix) != nil else { return token }
        return String(token[..<separator])
    }

    private static func runningApplication(for pid: pid_t) -> NSRunningApplication? {
        if Thread.isMainThread {
            return NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
        }

        return DispatchQueue.main.sync {
            NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
        }
    }
}
