import AppKit
import Foundation


struct NetworkProcessSample {
    let pid: pid_t
    let processName: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let identity: ProcessIdentity
}

final class NetworkProcessMonitor: @unchecked Sendable {
    var onUpdate: (([NetworkProcessSample]) -> Void)?
    var onStatusChange: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "NetworkMenuMonitor.NetworkProcessMonitor")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var watchdogTimer: DispatchSourceTimer?
    private var restartWorkItem: DispatchWorkItem?
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var frameCounters: [pid_t: CumulativeProcessCounters] = [:]
    private var hasOpenFrame = false
    private var lastPublishedSnapshot: CumulativeSnapshot?
    private var hasUsableRateSample = false
    private var lastFrameTimestamp: CFAbsoluteTime?
    private var pollingInterval: TimeInterval = 1
    private var isRunning = false
    private var lifecycleGeneration: UInt64 = 0
    private var processGeneration: UInt64 = 0
    private var consecutiveRestartCount = 0
    private var validFramesSinceLaunch = 0
    private var lastPublishedStatus: String?
    private var hasPublishedStatus = false
    private let executableURL: URL

    private static let maximumBufferedBytes = 1_048_576
    private static let maximumErrorBytes = 16_384
    private var networkSamplingInterval: TimeInterval { max(5, pollingInterval) }

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/nettop")) {
        self.executableURL = executableURL
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
                monitor.restartWorkItem?.cancel()
                monitor.restartWorkItem = nil
                monitor.tearDownProcessLocked(terminate: true)
                monitor.consecutiveRestartCount = 0
                monitor.launchProcessLocked()
            }
        }
    }

    private func startLocked() {
        guard !isRunning else { return }

        isRunning = true
        lifecycleGeneration &+= 1
        consecutiveRestartCount = 0
        validFramesSinceLaunch = 0
        publishStatus(nil)
        launchProcessLocked()
        startWatchdogLocked()
    }

    private func stopLocked() {
        isRunning = false
        lifecycleGeneration &+= 1
        restartWorkItem?.cancel()
        restartWorkItem = nil
        watchdogTimer?.cancel()
        watchdogTimer = nil
        tearDownProcessLocked(terminate: true)
        publishStatus(nil)
    }

    private func startWatchdogLocked() {
        watchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.checkProcessHealthLocked()
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func checkProcessHealthLocked() {
        guard isRunning else { return }
        guard process != nil else {
            guard restartWorkItem == nil else { return }
            scheduleRestartLocked(reason: "nettop is not running")
            return
        }

        let maximumSilence = max(8, pollingInterval * 2 + 5)
        if let lastFrameTimestamp,
           ProcessInfo.processInfo.systemUptime - lastFrameTimestamp > maximumSilence {
            scheduleRestartLocked(reason: "nettop stopped producing data")
        }
    }

    private func launchProcessLocked() {
        guard isRunning, process == nil, restartWorkItem == nil else { return }

        let newOutputPipe = Pipe()
        let newErrorPipe = Pipe()
        let newProcess = Process()
        // A persistent nettop process consumes an entire CPU core even at a
        // long display interval. A single cumulative CSV frame completes in a
        // few milliseconds; rates are calculated between these bounded
        // snapshots. Network samples are capped at once every five seconds,
        // while CPU, memory and disk can still follow the 1-second UI mode.
        newProcess.executableURL = executableURL
        newProcess.arguments = [
            "-P",
            "-L", "1",
            "-x",
            "-n",
            "-c",
            "-t", "external",
            "-J", "bytes_in,bytes_out"
        ]
        newProcess.standardOutput = newOutputPipe
        newProcess.standardError = newErrorPipe

        processGeneration &+= 1
        let generation = processGeneration
        newOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in
                self?.consumeOutputLocked(data, generation: generation)
            }
        }
        newErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in
                self?.consumeErrorLocked(data, generation: generation)
            }
        }
        newProcess.terminationHandler = { [weak self, weak newProcess] finishedProcess in
            // Let readability callbacks enqueue the final CSV bytes before the
            // termination record is evaluated.
            self?.queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self, weak newProcess] in
                guard let self, let newProcess, newProcess === finishedProcess else { return }
                self.processTerminatedLocked(newProcess, generation: generation)
            }
        }

        do {
            try newProcess.run()
            process = newProcess
            outputPipe = newOutputPipe
            errorPipe = newErrorPipe
            outputBuffer.removeAll(keepingCapacity: true)
            errorBuffer.removeAll(keepingCapacity: true)
            frameCounters.removeAll(keepingCapacity: true)
            hasOpenFrame = false
            lastFrameTimestamp = ProcessInfo.processInfo.systemUptime
        } catch {
            newOutputPipe.fileHandleForReading.readabilityHandler = nil
            newErrorPipe.fileHandleForReading.readabilityHandler = nil
            publishStatus("Per-app monitoring is unavailable because nettop could not be started: \(error.localizedDescription)")
            scheduleRestartLocked(reason: nil)
        }
    }

    private func consumeOutputLocked(_ data: Data, generation: UInt64) {
        guard generation == processGeneration, isRunning else { return }
        outputBuffer.append(data)
        guard outputBuffer.count <= Self.maximumBufferedBytes else {
            scheduleRestartLocked(reason: "nettop returned an oversized CSV record")
            return
        }

        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer[..<newlineIndex]
            outputBuffer.removeSubrange(...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8) else {
                scheduleRestartLocked(reason: "nettop returned invalid UTF-8 data")
                return
            }
            consumeCSVLineLocked(line.trimmingCharacters(in: .newlines))
            guard process != nil else { return }
        }
    }

    private func consumeCSVLineLocked(_ line: String) {
        let record = NetTopCSVRecord.parse(line)
        if record == .header {
            if hasOpenFrame { finishFrameLocked() }
            frameCounters.removeAll(keepingCapacity: true)
            hasOpenFrame = true
            return
        }
        guard hasOpenFrame else {
            scheduleRestartLocked(reason: "nettop returned data before its CSV header")
            return
        }
        guard case let .process(pid, processToken, bytesIn, bytesOut) = record else { return }

        if let existing = frameCounters[pid] {
            frameCounters[pid] = CumulativeProcessCounters(
                processToken: existing.processToken,
                bytesIn: Self.saturatedSum(existing.bytesIn, bytesIn),
                bytesOut: Self.saturatedSum(existing.bytesOut, bytesOut),
                identity: existing.identity
            )
        } else {
            frameCounters[pid] = CumulativeProcessCounters(
                processToken: processToken,
                bytesIn: bytesIn,
                bytesOut: bytesOut,
                identity: ProcessIdentity.capture(for: pid)
            )
        }
    }

    private func finishFrameLocked() {
        let now = ProcessInfo.processInfo.systemUptime
        lastFrameTimestamp = now
        validFramesSinceLaunch += 1
        if validFramesSinceLaunch >= 2 {
            consecutiveRestartCount = 0
            publishStatus(nil)
        }

        let currentSnapshot = CumulativeSnapshot(timestamp: now, countersByPID: frameCounters)
        guard let previous = lastPublishedSnapshot else {
            lastPublishedSnapshot = currentSnapshot
            return
        }
        let baselineAge = now - previous.timestamp
        guard SamplingFreshnessPolicy.canReuseBaseline(
            age: baselineAge,
            regularInterval: networkSamplingInterval
        ) else {
            // A long-hidden popover must not present an average across the
            // entire closed interval as a current rate. Start a fresh baseline;
            // processTerminatedLocked will request the follow-up in one second.
            lastPublishedSnapshot = currentSnapshot
            hasUsableRateSample = false
            return
        }
        // Launch cadence already enforces the steady-state interval. A one-
        // second second frame is intentional for initial/stale warm-up.
        guard baselineAge >= min(pollingInterval, 1) * 0.9 else { return }

        lastPublishedSnapshot = currentSnapshot
        let rates = Self.rateSamples(previous: previous, current: currentSnapshot)
        hasUsableRateSample = true
        resolveMetadataAndPublish(rates, lifecycleGeneration: lifecycleGeneration)
    }

    private func consumeErrorLocked(_ data: Data, generation: UInt64) {
        guard generation == processGeneration, isRunning else { return }
        errorBuffer.append(data)
        if errorBuffer.count > Self.maximumErrorBytes {
            errorBuffer.removeFirst(errorBuffer.count - Self.maximumErrorBytes)
        }
    }

    private func processTerminatedLocked(_ finishedProcess: Process, generation: UInt64) {
        guard generation == processGeneration, process === finishedProcess else { return }
        let status = finishedProcess.terminationStatus
        let stderr = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let completedFrame = status == 0 && hasOpenFrame
        if completedFrame {
            finishFrameLocked()
        }
        tearDownProcessLocked(terminate: false)
        guard isRunning else { return }

        if completedFrame {
            consecutiveRestartCount = 0
            // The first cumulative snapshot is only a baseline. Take the
            // second promptly so initial opening has no five- or ten-second
            // false-zero window. Reopens reuse the retained baseline.
            scheduleLaunchLocked(after: hasUsableRateSample ? networkSamplingInterval : 1)
            return
        }

        var message = "Per-app monitoring is unavailable because nettop exited with status \(status)."
        if let stderr, !stderr.isEmpty {
            message += " \(stderr.prefix(240))"
        }
        publishStatus(message)
        scheduleRestartLocked(reason: nil)
    }

    private func scheduleRestartLocked(reason: String?) {
        guard isRunning, restartWorkItem == nil else { return }
        if let reason {
            publishStatus("Per-app monitoring is restarting because \(reason).")
        }
        tearDownProcessLocked(terminate: true)

        let exponent = min(consecutiveRestartCount, 5)
        let delay = min(pow(2, Double(exponent)), 30)
        consecutiveRestartCount += 1
        scheduleLaunchLocked(after: delay)
    }

    private func scheduleLaunchLocked(after delay: TimeInterval) {
        guard isRunning, restartWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.launchProcessLocked()
        }
        restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func tearDownProcessLocked(terminate: Bool) {
        // Invalidate output and termination callbacks that may already be
        // queued for the process being torn down. Published samples are tied
        // to the wider start/stop lifecycle instead.
        processGeneration &+= 1
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if terminate, process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)
        errorBuffer.removeAll(keepingCapacity: false)
        frameCounters.removeAll(keepingCapacity: false)
        hasOpenFrame = false
        lastFrameTimestamp = nil
    }

    static func rateSamples(
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
                previousCounters.processToken == currentCounters.processToken,
                let identity = currentCounters.identity,
                previousCounters.identity == identity
            else {
                continue
            }

            guard let download = CounterRatePolicy.rate(current: currentCounters.bytesIn, previous: previousCounters.bytesIn, elapsed: elapsed, maximumAge: 15),
                  let upload = CounterRatePolicy.rate(current: currentCounters.bytesOut, previous: previousCounters.bytesOut, elapsed: elapsed, maximumAge: 15) else { continue }

            guard download > 0 || upload > 0 else { continue }

            samples.append(RawRateSample(
                pid: pid,
                processToken: currentCounters.processToken,
                downloadBytesPerSecond: download,
                uploadBytesPerSecond: upload,
                identity: identity
            ))
        }

        return samples.sorted { $0.pid < $1.pid }
    }

    private func resolveMetadataAndPublish(_ rates: [RawRateSample], lifecycleGeneration: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let samples = rates.compactMap { rate -> NetworkProcessSample? in
                let metadata = AppMetadata(processToken: rate.processToken)
                guard metadata.pid == rate.pid,
                      ProcessIdentity.capture(for: rate.pid) == rate.identity else { return nil }

                return NetworkProcessSample(
                    pid: rate.pid,
                    processName: metadata.displayName,
                    bundleIdentifier: metadata.bundleIdentifier,
                    icon: metadata.icon,
                    downloadBytesPerSecond: rate.downloadBytesPerSecond,
                    uploadBytesPerSecond: rate.uploadBytesPerSecond,
                    identity: rate.identity
                )
            }

            self.queue.async { [weak self] in
                guard
                    let self,
                    self.isRunning,
                    self.lifecycleGeneration == lifecycleGeneration
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

    struct CumulativeProcessCounters {
        let processToken: String
        let bytesIn: UInt64
        let bytesOut: UInt64
        let identity: ProcessIdentity?
    }

    struct CumulativeSnapshot {
        let timestamp: CFAbsoluteTime
        let countersByPID: [pid_t: CumulativeProcessCounters]
    }

    struct RawRateSample {
        let pid: pid_t
        let processToken: String
        let downloadBytesPerSecond: Double
        let uploadBytesPerSecond: Double
        let identity: ProcessIdentity
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
            return NSRunningApplication(processIdentifier: pid)
        }

        return DispatchQueue.main.sync {
            NSRunningApplication(processIdentifier: pid)
        }
    }
}
