import Foundation
import AppKit
import Darwin
import IOKit
import IOKit.hidsystem
import IOKit.storage

struct ExternalDiskActivity: Identifiable {
    let bsdName: String
    let persistentID: String
    let displayName: String
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
    let activityIsAvailable: Bool
    let isMemoryCard: Bool
    let capacityBytes: UInt64?
    let availableBytes: UInt64?
    var id: String { persistentID }
    var systemImageName: String { isMemoryCard ? "sdcard" : "externaldrive" }
}

struct SystemMetricsSample: Sendable {
    enum MemoryPressure: String, Sendable {
        case normal
        case warning
        case critical
    }

    let timestamp: Date
    let cpuUsagePercent: Double?
    let memoryUsagePercent: Double?
    let compressedMemoryBytes: UInt64?
    let swapUsedBytes: UInt64?
    let memoryPressure: MemoryPressure
    let diskActivityMBPerSecond: Double?
    let cpuTemperatureCelsius: Double?
}

private typealias IOHIDEventRef = OpaquePointer

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreatePrivate(_ allocator: CFAllocator?) -> IOHIDEventSystemClient

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEventPrivate(
    _ service: IOHIDServiceClient,
    _ eventType: Int64,
    _ options: Int32,
    _ timestamp: Int64
) -> IOHIDEventRef?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValuePrivate(_ event: IOHIDEventRef, _ field: Int32) -> Double

final class SystemMetricsMonitor: @unchecked Sendable {
    struct CollectionOptions: OptionSet, Sendable {
        let rawValue: Int

        static let cpu = CollectionOptions(rawValue: 1 << 0)
        static let memory = CollectionOptions(rawValue: 1 << 1)
        static let disk = CollectionOptions(rawValue: 1 << 2)
        static let temperature = CollectionOptions(rawValue: 1 << 3)
        static let externalDisks = CollectionOptions(rawValue: 1 << 4)
        static let all: CollectionOptions = [.cpu, .memory, .disk, .temperature, .externalDisks]
    }

    private struct DiskCounters {
        let readBytes: UInt64
        let writeBytes: UInt64
        let timestamp: CFAbsoluteTime
    }

    private enum CPUState {
        static let user = 0
        static let system = 1
        static let idle = 2
        static let nice = 3
        static let max = 4
    }

    var onSample: ((SystemMetricsSample) -> Void)?
    var onExternalDiskSample: (([ExternalDiskActivity]) -> Void)?

    private let queue = DispatchQueue(label: "NetworkMenuMonitor.SystemMetricsMonitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var previousCPUInfo: processor_info_array_t?
    private var previousCPUInfoCount: mach_msg_type_number_t = 0
    private var diskNames: [String] = []
    private var internalDiskNames: [String] = []
    private var previousDiskCounters: [String: DiskCounters] = [:]
    private var pollingInterval: TimeInterval = 1
    private var collectionOptions: CollectionOptions = .all
    private var lastDiskResolutionTime: CFAbsoluteTime = 0
    private let diskResolutionInterval: CFTimeInterval = 30
    private let inventoryQueue = DispatchQueue(label: "MacResourceBar.DiskInventory", qos: .utility)
    private var inventoryRefreshInProgress = false
    private var volumeObservers: [NSObjectProtocol] = []
    private let diskListReader: @Sendable (String) -> [[String: Any]]?
    private var cachedCPUTemperature: Double?
    private var lastTemperaturePollTime: CFAbsoluteTime = 0
    private let temperaturePollingInterval: CFTimeInterval = 5

    private struct ExternalDiskInfo: Sendable {
        let persistentID: String
        let displayName: String
        let isMemoryCard: Bool
        let capacityBytes: UInt64?
        let availableBytes: UInt64?
    }

    private var cachedExternalDiskInfo: [String: ExternalDiskInfo] = [:]
    private var previousExternalDiskCounters: [String: DiskCounters] = [:]
    private var memoryPressureLevel: SystemMetricsSample.MemoryPressure = .normal
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(diskListReader: @escaping @Sendable (String) -> [[String: Any]]? = { SystemMetricsMonitor.fetchPhysicalDiskListEntries(location: $0) }) {
        self.diskListReader = diskListReader
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.lastDiskResolutionTime = 0 }
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            if event.contains(.critical) {
                self.memoryPressureLevel = .critical
            } else if event.contains(.warning) {
                self.memoryPressureLevel = .warning
            } else if event.contains(.normal) {
                self.memoryPressureLevel = .normal
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    private func startLocked() {
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: pollingInterval,
            leeway: .milliseconds(Int(min(max(pollingInterval * 100, 100), 1_000)))
        )
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    deinit {
        volumeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        timer?.cancel()
        memoryPressureSource?.cancel()
        if let previousCPUInfo {
            let previousSize = vm_size_t(previousCPUInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: previousCPUInfo), previousSize)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        // Preserve CPU baseline across mode switches so the next sample is useful.
    }

    func setPollingInterval(_ interval: TimeInterval) {
        let normalizedInterval = max(interval, 1)
        queue.async { [weak self] in
            guard let self else { return }
            guard abs(normalizedInterval - self.pollingInterval) > 0.01 else { return }
            self.pollingInterval = normalizedInterval

            if self.timer != nil {
                self.stopLocked()
                self.startLocked()
            }
        }
    }

    func setCollectionOptions(_ options: CollectionOptions) {
        queue.async { [weak self] in
            guard let self, self.collectionOptions != options else { return }
            let previousOptions = self.collectionOptions
            self.collectionOptions = options

            if previousOptions.contains(.cpu) != options.contains(.cpu) {
                self.resetCPUBaseline()
            }
            if previousOptions.contains(.disk) != options.contains(.disk) {
                self.previousDiskCounters.removeAll()
            }
            if previousOptions.contains(.externalDisks) != options.contains(.externalDisks) {
                self.previousExternalDiskCounters.removeAll()
            }
            if options.contains(.temperature), !previousOptions.contains(.temperature) {
                self.lastTemperaturePollTime = 0
            }

            if self.timer != nil {
                self.poll()
            }
        }
    }

    private func poll() {
        guard !collectionOptions.isEmpty else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let needsDiskInventory = collectionOptions.contains(.disk)
            || collectionOptions.contains(.externalDisks)
        if needsDiskInventory,
           !inventoryRefreshInProgress,
           (lastDiskResolutionTime == 0 || now - lastDiskResolutionTime >= diskResolutionInterval) {
            refreshDiskInventory(at: now)
        }

        let externalActivities = collectionOptions.contains(.externalDisks)
            ? readExternalDiskActivities()
            : nil
        if collectionOptions.contains(.temperature),
           lastTemperaturePollTime == 0 || now - lastTemperaturePollTime >= temperaturePollingInterval {
            cachedCPUTemperature = readCPUTemperature()
            lastTemperaturePollTime = now
        }

        let memory = collectionOptions.contains(.memory) ? readMemoryUsage() : nil
        let sample = SystemMetricsSample(
            timestamp: Date(),
            cpuUsagePercent: collectionOptions.contains(.cpu) ? readCPUUsage() : nil,
            memoryUsagePercent: memory?.usagePercent,
            compressedMemoryBytes: memory?.compressedBytes,
            swapUsedBytes: collectionOptions.contains(.memory) ? readSwapUsedBytes() : nil,
            memoryPressure: memoryPressureLevel,
            diskActivityMBPerSecond: collectionOptions.contains(.disk) ? readDiskActivity() : nil,
            cpuTemperatureCelsius: collectionOptions.contains(.temperature) ? cachedCPUTemperature : nil
        )

        Task { @MainActor in
            onSample?(sample)
            if let externalActivities {
                onExternalDiskSample?(externalActivities)
            }
        }
    }

    private func resetCPUBaseline() {
        if let previousCPUInfo {
            let previousSize = vm_size_t(previousCPUInfoCount)
                * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: previousCPUInfo),
                previousSize
            )
        }
        previousCPUInfo = nil
        previousCPUInfoCount = 0
    }

    private func readCPUUsage() -> Double? {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &cpuInfoCount
        )

        guard result == KERN_SUCCESS, let cpuInfo else {
            return nil
        }

        guard let previousCPUInfo else {
            self.previousCPUInfo = cpuInfo
            self.previousCPUInfoCount = cpuInfoCount
            return nil
        }

        guard previousCPUInfoCount == cpuInfoCount else {
            let previousSize = vm_size_t(previousCPUInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: previousCPUInfo), previousSize)
            self.previousCPUInfo = cpuInfo
            self.previousCPUInfoCount = cpuInfoCount
            return nil
        }

        var totalTicksUsed: UInt64 = 0
        var totalTicks: UInt64 = 0

        for cpu in 0 ..< Int(cpuCount) {
            let offset = CPUState.max * cpu

            let user = tickDelta(
                current: cpuInfo[offset + CPUState.user],
                previous: previousCPUInfo[offset + CPUState.user]
            )
            let system = tickDelta(
                current: cpuInfo[offset + CPUState.system],
                previous: previousCPUInfo[offset + CPUState.system]
            )
            let nice = tickDelta(
                current: cpuInfo[offset + CPUState.nice],
                previous: previousCPUInfo[offset + CPUState.nice]
            )
            let idle = tickDelta(
                current: cpuInfo[offset + CPUState.idle],
                previous: previousCPUInfo[offset + CPUState.idle]
            )

            totalTicksUsed += user + system + nice
            totalTicks += user + system + nice + idle
        }

        let previousSize = vm_size_t(previousCPUInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: previousCPUInfo), previousSize)

        self.previousCPUInfo = cpuInfo
        self.previousCPUInfoCount = cpuInfoCount

        guard totalTicks > 0 else { return nil }
        return min(max((Double(totalTicksUsed) / Double(totalTicks)) * 100, 0), 100)
    }

    private func tickDelta(current: integer_t, previous: integer_t) -> UInt64 {
        let currentBits = UInt32(bitPattern: current)
        let previousBits = UInt32(bitPattern: previous)
        return UInt64(currentBits &- previousBits)
    }

    private struct MemorySnapshot {
        let usagePercent: Double
        let compressedBytes: UInt64
    }

    private func readMemoryUsage() -> MemorySnapshot? {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let usedPages =
            UInt64(stats.active_count) +
            UInt64(stats.wire_count) +
            UInt64(stats.compressor_page_count)
        let usedMemory = usedPages * UInt64(pageSize)

        guard totalMemory > 0 else { return nil }
        return MemorySnapshot(
            usagePercent: min(max((Double(usedMemory) / Double(totalMemory)) * 100, 0), 100),
            compressedBytes: UInt64(stats.compressor_page_count) * UInt64(pageSize)
        )
    }

    private func readSwapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return nil
        }
        return usage.xsu_used
    }

    private func readDiskActivity() -> Double? {
        guard !internalDiskNames.isEmpty else { return nil }
        let now = CFAbsoluteTimeGetCurrent()
        var currentCounters: [String: DiskCounters] = [:]
        var totalBytesPerSecond = 0.0
        var hasDelta = false

        for diskName in internalDiskNames {
            guard let counters = diskCounters(for: diskName, timestamp: now) else { continue }
            currentCounters[diskName] = counters

            guard let previous = previousDiskCounters[diskName] else { continue }
            let elapsed = counters.timestamp - previous.timestamp
            guard elapsed > 0 else { continue }

            let previousTotal = previous.readBytes + previous.writeBytes
            let currentTotal = counters.readBytes + counters.writeBytes
            guard currentTotal >= previousTotal else { continue }

            totalBytesPerSecond += Double(currentTotal - previousTotal) / elapsed
            hasDelta = true
        }

        previousDiskCounters = currentCounters
        return hasDelta ? totalBytesPerSecond / (1024 * 1024) : nil
    }

    private func detectExternalDisks(among names: [String], entries: [[String: Any]]) -> [String: ExternalDiskInfo] {
        var result: [String: ExternalDiskInfo] = [:]
        let metadataByDisk = externalMetadataByWholeDisk(entries: entries)

        for name in names {
            guard let media = serviceForBSDName(name) else { continue }
            defer { IOObjectRelease(media) }

            guard
                let protocolChars = IORegistryEntrySearchCFProperty(
                    media,
                    kIOServicePlane,
                    "Protocol Characteristics" as CFString,
                    kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
                ) as? [String: Any],
                let location = protocolChars["Physical Interconnect Location"] as? String,
                location == "External"
            else { continue }

            let interconnect = (protocolChars["Physical Interconnect"] as? String) ?? ""

            let displayName: String
            let productName: String
            if let deviceChars = IORegistryEntrySearchCFProperty(
                media,
                kIOServicePlane,
                "Device Characteristics" as CFString,
                kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
            ) as? [String: Any],
            let product = deviceChars["Product Name"] as? String,
            !product.trimmingCharacters(in: .whitespaces).isEmpty {
                productName = product.trimmingCharacters(in: .whitespaces)
                displayName = metadataByDisk[name]?.displayName ?? productName
            } else {
                productName = ""
                displayName = metadataByDisk[name]?.displayName ?? name
            }

            let isMemoryCard = interconnect.localizedCaseInsensitiveContains("SD") ||
                               productName.localizedCaseInsensitiveContains("SD")

            let metadata = metadataByDisk[name]
            result[name] = ExternalDiskInfo(
                persistentID: metadata?.persistentID ?? "bsd:\(name)",
                displayName: displayName,
                isMemoryCard: isMemoryCard,
                capacityBytes: metadata?.capacityBytes,
                availableBytes: metadata?.availableBytes
            )
        }
        return result
    }

    private func readExternalDiskActivities() -> [ExternalDiskActivity] {
        guard !cachedExternalDiskInfo.isEmpty else { return [] }

        let now = CFAbsoluteTimeGetCurrent()
        var freshCounters: [String: DiskCounters] = [:]
        var activities: [ExternalDiskActivity] = []

        for (bsdName, info) in cachedExternalDiskInfo {
            guard let counters = diskCounters(for: bsdName, timestamp: now) else { continue }
            freshCounters[bsdName] = counters

            let readRate: Double
            let writeRate: Double
            let activityIsAvailable: Bool
            if let prev = previousExternalDiskCounters[bsdName] {
                let elapsed = counters.timestamp - prev.timestamp
                if elapsed > 0,
                   counters.readBytes >= prev.readBytes,
                   counters.writeBytes >= prev.writeBytes {
                    readRate = Double(counters.readBytes - prev.readBytes) / elapsed
                    writeRate = Double(counters.writeBytes - prev.writeBytes) / elapsed
                    activityIsAvailable = true
                } else {
                    readRate = 0
                    writeRate = 0
                    activityIsAvailable = false
                }
            } else {
                readRate = 0
                writeRate = 0
                activityIsAvailable = false
            }

            activities.append(ExternalDiskActivity(
                bsdName: bsdName,
                persistentID: info.persistentID,
                displayName: info.displayName,
                readBytesPerSecond: readRate,
                writeBytesPerSecond: writeRate,
                activityIsAvailable: activityIsAvailable,
                isMemoryCard: info.isMemoryCard,
                capacityBytes: info.capacityBytes,
                availableBytes: info.availableBytes
            ))
        }

        previousExternalDiskCounters = freshCounters
        return activities.sorted { $0.bsdName < $1.bsdName }
    }

    private func diskCounters(for diskName: String, timestamp: CFAbsoluteTime) -> DiskCounters? {
        guard let media = serviceForBSDName(diskName) else { return nil }
        defer { IOObjectRelease(media) }
        guard let driver = parentBlockStorageDriver(of: media) else { return nil }
        defer {
            if driver != media {
                IOObjectRelease(driver)
            }
        }

        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(driver, &properties, kCFAllocatorDefault, 0)
        guard
            result == KERN_SUCCESS,
            let dictionary = properties?.takeRetainedValue() as? [String: Any],
            let statistics = dictionary["Statistics"] as? [String: Any]
        else {
            return nil
        }

        guard
            let readBytes = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value,
            let writeBytes = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value
        else {
            return nil
        }
        return DiskCounters(readBytes: readBytes, writeBytes: writeBytes, timestamp: timestamp)
    }

    private func serviceForBSDName(_ bsdName: String) -> io_service_t? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        return service == 0 ? nil : service
    }

    private func parentBlockStorageDriver(of service: io_service_t) -> io_service_t? {
        var current = service

        while current != 0 {
            if let className = IOObjectCopyClass(current)?.takeRetainedValue() as String?,
               className == kIOBlockStorageDriverClass {
                return current
            }

            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if current != service {
                IOObjectRelease(current)
            }
            guard result == KERN_SUCCESS, parent != 0 else { return nil }
            current = parent
        }

        return nil
    }

    private func readCPUTemperature() -> Double? {
        let client = IOHIDEventSystemClientCreatePrivate(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        let temperatureEventType: Int64 = 15
        let temperatureField = Int32(temperatureEventType) << 16

        let dieValues = services.compactMap { service -> Double? in
            let usagePage = (IOHIDServiceClientCopyProperty(service, "PrimaryUsagePage" as CFString) as? NSNumber)?.intValue
            let usage = (IOHIDServiceClientCopyProperty(service, "PrimaryUsage" as CFString) as? NSNumber)?.intValue
            let product = (IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String) ?? ""

            guard usagePage == 0xff00, usage == 5 else { return nil }
            guard product.hasPrefix("PMU tdie") else { return nil }
            guard let event = IOHIDServiceClientCopyEventPrivate(service, temperatureEventType, 0, 0) else {
                return nil
            }

            // CopyEvent returns a retained CF object; the opaque pointer is
            // not managed by Swift ARC.
            defer { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release() }
            let value = IOHIDEventGetFloatValuePrivate(event, temperatureField)
            guard value.isFinite, value > 0, value < 150 else { return nil }
            return value
        }

        return dieValues.max()
    }

    private struct DiskInventory: Sendable {
        let names: [String]
        let internalNames: [String]
        let externalInfo: [String: ExternalDiskInfo]
    }

    private func refreshDiskInventory(at now: CFAbsoluteTime) {
        inventoryRefreshInProgress = true
        lastDiskResolutionTime = now
        // diskutil and mounted-volume metadata may wait on a busy drive. Keep
        // those waits off the sampling queue so CPU/RAM/network stay current.
        inventoryQueue.async { [weak self] in
            guard let self else { return }
            let inventory = self.resolveDiskInventory()
            self.queue.async {
                self.inventoryRefreshInProgress = false
                guard let inventory else { return }
                self.diskNames = inventory.names
                self.internalDiskNames = inventory.internalNames
                self.cachedExternalDiskInfo = inventory.externalInfo
                let names = Set(inventory.names)
                self.previousDiskCounters = self.previousDiskCounters.filter { names.contains($0.key) }
                self.previousExternalDiskCounters = self.previousExternalDiskCounters.filter { names.contains($0.key) }
            }
        }
    }

    private func resolveDiskInventory() -> DiskInventory? {
        guard let externalEntries = diskListReader("external"),
              let internalEntries = diskListReader("internal") else { return nil }
        let externalNames = Set(externalEntries.compactMap {
            ($0["DeviceIdentifier"] as? String).flatMap(wholeDiskIdentifier(from:))
        })
        let internalNames = Set(internalEntries.compactMap {
            ($0["DeviceIdentifier"] as? String).flatMap(wholeDiskIdentifier(from:))
        })
        return DiskInventory(
            names: internalNames.union(externalNames).sorted(),
            internalNames: internalNames.sorted(),
            externalInfo: detectExternalDisks(among: externalNames.sorted(), entries: externalEntries)
        )
    }

    static func fetchPhysicalDiskListEntries(location: String) -> [[String: Any]]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["list", "-plist", location, "physical"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        guard finished.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.25)
            }
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            process.terminationStatus == 0,
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = plist as? [String: Any],
            let disks = dictionary["AllDisksAndPartitions"] as? [[String: Any]]
        else {
            return nil
        }

        return disks
    }

    private struct ExternalDiskMetadata {
        let persistentID: String
        let displayName: String?
        let capacityBytes: UInt64?
        let availableBytes: UInt64?
    }

    private func externalMetadataByWholeDisk(entries: [[String: Any]]) -> [String: ExternalDiskMetadata] {
        var metadataByDisk: [String: ExternalDiskMetadata] = [:]
        for disk in entries {
            guard let identifier = disk["DeviceIdentifier"] as? String else { continue }
            guard let wholeDisk = wholeDiskIdentifier(from: identifier) else { continue }
            let partitions = disk["Partitions"] as? [[String: Any]] ?? []
            let preferredPartition = partitions.first { volumeName(from: $0) != nil }

            let uuid = (preferredPartition?["VolumeUUID"] as? String)
                ?? (preferredPartition?["DiskUUID"] as? String)
                ?? (disk["DiskUUID"] as? String)
                ?? identifier
            let capacity = (disk["Size"] as? NSNumber)?.uint64Value

            let available: UInt64?
            if let mountPoint = preferredPartition?["MountPoint"] as? String,
               let attributes = try? FileManager.default.attributesOfFileSystem(forPath: mountPoint),
               let free = attributes[.systemFreeSize] as? NSNumber {
                available = free.uint64Value
            } else {
                available = nil
            }

            metadataByDisk[wholeDisk] = ExternalDiskMetadata(
                persistentID: "volume:\(uuid.lowercased())",
                displayName: preferredPartition.flatMap(volumeName(from:)),
                capacityBytes: capacity,
                availableBytes: available
            )
        }

        return metadataByDisk
    }

    private func volumeName(from partition: [String: Any]) -> String? {
        guard
            let name = partition["VolumeName"] as? String,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            name.localizedCaseInsensitiveCompare("EFI") != .orderedSame
        else {
            return nil
        }

        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wholeDiskIdentifier(from identifier: String) -> String? {
        PhysicalDiskPolicy.wholeDiskIdentifier(from: identifier)
    }
}
