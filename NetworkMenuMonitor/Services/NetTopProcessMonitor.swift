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
    private var pollTimer: DispatchSourceTimer?
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var buffer = Data()
    private var currentBatch: [pid_t: NetworkProcessSample] = [:]
    private var pollingInterval: TimeInterval = 1
    private var isRunning = false

    deinit {
        stopLocked()
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
            self?.stopLocked()
            self?.startLocked()
        }
    }

    func setPollingInterval(_ interval: TimeInterval) {
        let normalizedInterval = max(interval, 1)
        queue.async { [weak self] in
            guard let self else { return }
            guard abs(normalizedInterval - pollingInterval) > 0.01 else { return }
            pollingInterval = normalizedInterval
            if isRunning {
                stopLocked()
                startLocked()
            }
        }
    }

    private func startLocked() {
        guard !isRunning else { return }
        isRunning = true
        publishStatus(nil)
        runOneSampleLocked()
        schedulePollTimerLocked()
    }

    private func schedulePollTimerLocked() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollingInterval, repeating: pollingInterval)
        timer.setEventHandler { [weak self] in
            self?.runOneSampleLocked()
        }
        timer.resume()
        pollTimer = timer
    }

    private func runOneSampleLocked() {
        guard isRunning, process == nil else { return }

        buffer.removeAll(keepingCapacity: true)
        currentBatch.removeAll(keepingCapacity: true)

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-d", "-x", "-n", "-s", "1"]
        process.standardOutput = pipe
        process.standardError = pipe
        let queue = self.queue
        process.terminationHandler = { [weak self, queue] terminated in
            queue.async { [weak self] in
                guard let self else { return }
                self.stdoutHandle?.readabilityHandler = nil
                self.stdoutHandle = nil
                self.process = nil
                self.flushCurrentBatchIfNeeded()
                if terminated.terminationStatus != 0, self.isRunning {
                    self.publishStatus("Per-app monitoring is unavailable because nettop exited with status \(terminated.terminationStatus).")
                }
            }
        }

        do {
            try process.run()
            stdoutHandle = pipe.fileHandleForReading
            self.process = process
            publishStatus(nil)
            installReader(on: pipe.fileHandleForReading)
        } catch {
            self.process = nil
            publishStatus("Per-app monitoring is unavailable because nettop could not be started: \(error.localizedDescription)")
        }
    }

    private func stopLocked() {
        isRunning = false
        pollTimer?.cancel()
        pollTimer = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        buffer.removeAll(keepingCapacity: false)
        currentBatch.removeAll(keepingCapacity: false)
        publishStatus(nil)

        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil
    }

    private func installReader(on handle: FileHandle) {
        let queue = self.queue
        handle.readabilityHandler = { [weak self, queue] readableHandle in
            let data = readableHandle.availableData
            guard !data.isEmpty else { return }
            queue.async { [weak self] in
                self?.consume(data: data)
            }
        }
    }

    private func consume(data: Data) {
        buffer.append(data)

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)

            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else {
                continue
            }

            handle(line: line)
        }
    }

    private func handle(line: String) {
        if line.hasPrefix("time,,interface,state,bytes_in,bytes_out") {
            flushCurrentBatchIfNeeded()
            currentBatch.removeAll(keepingCapacity: true)
            return
        }

        let columns = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard columns.count >= 6 else {
            return
        }

        let processToken = columns[1]
        let download = Double(columns[4]) ?? 0
        let upload = Double(columns[5]) ?? 0

        guard download > 0 || upload > 0 else {
            return
        }

        let metadata = AppMetadata(processToken: processToken)
        guard let pid = metadata.pid else { return }

        let snapshot = NetworkProcessSample(
            pid: pid,
            processName: metadata.displayName,
            bundleIdentifier: metadata.bundleIdentifier,
            icon: metadata.icon,
            downloadBytesPerSecond: download,
            uploadBytesPerSecond: upload
        )

        currentBatch[pid] = snapshot
    }

    private func flushCurrentBatchIfNeeded() {
        guard !currentBatch.isEmpty else { return }

        let snapshots = Array(currentBatch.values)

        DispatchQueue.main.async { [onUpdate] in
            onUpdate?(snapshots)
        }
    }

    private func publishStatus(_ message: String?) {
        DispatchQueue.main.async { [onStatusChange] in
            onStatusChange?(message)
        }
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
