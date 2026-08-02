import Foundation
import Darwin
import IOKit
import IOKit.hidsystem
import IOKit.storage

struct ExternalDiskActivity: Identifiable {
    let bsdName: String
    let displayName: String
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
    let isMemoryCard: Bool
    var id: String { bsdName }
    var systemImageName: String { isMemoryCard ? "sdcard" : "externaldrive" }
}

struct SystemMetricsSample: Sendable {
    let cpuUsagePercent: Double
    let memoryUsagePercent: Double
    let diskActivityMBPerSecond: Double
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
    private var previousDiskCounters: [String: DiskCounters] = [:]
    private var pollingInterval: TimeInterval = 1
    private var didResolveDiskNames = false
    private var lastDiskResolutionTime: CFAbsoluteTime = 0
    private let diskResolutionInterval: CFTimeInterval = 60
    private var cachedCPUTemperature: Double?
    private var lastTemperaturePollTime: CFAbsoluteTime = 0
    private let temperaturePollingInterval: CFTimeInterval = 5

    private struct ExternalDiskInfo {
        let displayName: String
        let isMemoryCard: Bool
    }

    private var cachedExternalDiskInfo: [String: ExternalDiskInfo] = [:]
    private var lastKnownDiskSet: Set<String> = []
    private var previousExternalDiskCounters: [String: DiskCounters] = [:]
    private var cachedExternalDiskListEntries: [[String: Any]] = []

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
        timer?.cancel()
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

    private func poll() {
        let now = CFAbsoluteTimeGetCurrent()
        if !didResolveDiskNames || now - lastDiskResolutionTime >= diskResolutionInterval {
            diskNames = resolveTrackedDiskNames()
            didResolveDiskNames = true
            lastDiskResolutionTime = now
        }

        let externalActivities = readExternalDiskActivities()
        if lastTemperaturePollTime == 0 || now - lastTemperaturePollTime >= temperaturePollingInterval {
            cachedCPUTemperature = readCPUTemperature()
            lastTemperaturePollTime = now
        }

        let sample = SystemMetricsSample(
            cpuUsagePercent: readCPUUsage(),
            memoryUsagePercent: readMemoryUsage(),
            diskActivityMBPerSecond: readDiskActivity(),
            cpuTemperatureCelsius: cachedCPUTemperature
        )

        Task { @MainActor in
            onSample?(sample)
            onExternalDiskSample?(externalActivities)
        }
    }

    private func readCPUUsage() -> Double {
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
            return 0
        }

        guard let previousCPUInfo else {
            self.previousCPUInfo = cpuInfo
            self.previousCPUInfoCount = cpuInfoCount
            return 0
        }

        guard previousCPUInfoCount == cpuInfoCount else {
            let previousSize = vm_size_t(previousCPUInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: previousCPUInfo), previousSize)
            self.previousCPUInfo = cpuInfo
            self.previousCPUInfoCount = cpuInfoCount
            return 0
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

        guard totalTicks > 0 else { return 0 }
        return min(max((Double(totalTicksUsed) / Double(totalTicks)) * 100, 0), 100)
    }

    private func tickDelta(current: integer_t, previous: integer_t) -> UInt64 {
        let currentBits = UInt32(bitPattern: current)
        let previousBits = UInt32(bitPattern: previous)
        return UInt64(currentBits &- previousBits)
    }

    private func readMemoryUsage() -> Double {
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
            return 0
        }

        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let usedPages =
            UInt64(stats.active_count) +
            UInt64(stats.wire_count) +
            UInt64(stats.compressor_page_count)
        let usedMemory = usedPages * UInt64(pageSize)

        guard totalMemory > 0 else { return 0 }
        return min(max((Double(usedMemory) / Double(totalMemory)) * 100, 0), 100)
    }

    private func readDiskActivity() -> Double {
        guard !diskNames.isEmpty else { return 0 }
        let now = CFAbsoluteTimeGetCurrent()
        var currentCounters: [String: DiskCounters] = [:]
        var totalBytesPerSecond = 0.0

        for diskName in diskNames {
            guard let counters = diskCounters(for: diskName, timestamp: now) else { continue }
            currentCounters[diskName] = counters

            guard let previous = previousDiskCounters[diskName] else { continue }
            let elapsed = counters.timestamp - previous.timestamp
            guard elapsed > 0 else { continue }

            let previousTotal = previous.readBytes + previous.writeBytes
            let currentTotal = counters.readBytes + counters.writeBytes
            guard currentTotal >= previousTotal else { continue }

            totalBytesPerSecond += Double(currentTotal - previousTotal) / elapsed
        }

        previousDiskCounters = currentCounters
        return totalBytesPerSecond / (1024 * 1024)
    }

    private func detectExternalDisks(among names: [String]) -> [String: ExternalDiskInfo] {
        var result: [String: ExternalDiskInfo] = [:]
        let volumeNamesByDisk = externalVolumeNamesByWholeDisk()

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
                displayName = volumeNamesByDisk[name] ?? productName
            } else {
                productName = ""
                displayName = volumeNamesByDisk[name] ?? name
            }

            let isMemoryCard = interconnect.localizedCaseInsensitiveContains("SD") ||
                               productName.localizedCaseInsensitiveContains("SD")

            result[name] = ExternalDiskInfo(displayName: displayName, isMemoryCard: isMemoryCard)
        }
        return result
    }

    private func readExternalDiskActivities() -> [ExternalDiskActivity] {
        let currentDiskSet = Set(diskNames)
        if currentDiskSet != lastKnownDiskSet {
            cachedExternalDiskInfo = detectExternalDisks(among: diskNames)
            lastKnownDiskSet = currentDiskSet
        }

        guard !cachedExternalDiskInfo.isEmpty else { return [] }

        let now = CFAbsoluteTimeGetCurrent()
        var freshCounters: [String: DiskCounters] = [:]
        var activities: [ExternalDiskActivity] = []

        for (bsdName, info) in cachedExternalDiskInfo {
            guard let counters = diskCounters(for: bsdName, timestamp: now) else { continue }
            freshCounters[bsdName] = counters

            let readRate: Double
            let writeRate: Double
            if let prev = previousExternalDiskCounters[bsdName] {
                let elapsed = counters.timestamp - prev.timestamp
                if elapsed > 0 {
                    readRate = counters.readBytes >= prev.readBytes ? Double(counters.readBytes - prev.readBytes) / elapsed : 0
                    writeRate = counters.writeBytes >= prev.writeBytes ? Double(counters.writeBytes - prev.writeBytes) / elapsed : 0
                } else {
                    readRate = 0
                    writeRate = 0
                }
            } else {
                readRate = 0
                writeRate = 0
            }

            activities.append(ExternalDiskActivity(
                bsdName: bsdName,
                displayName: info.displayName,
                readBytesPerSecond: readRate,
                writeBytesPerSecond: writeRate,
                isMemoryCard: info.isMemoryCard
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

        let readBytes = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
        let writeBytes = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
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

            let value = IOHIDEventGetFloatValuePrivate(event, temperatureField)
            guard value.isFinite, value > 0, value < 150 else { return nil }
            return value
        }

        return dieValues.max()
    }

    private func resolveTrackedDiskNames() -> [String] {
        cachedExternalDiskListEntries = fetchExternalDiskListEntries()

        let mountedIdentifiers = mountedDiskIdentifiers()
        var resolved = Set(externalPhysicalDiskIdentifiers())

        for identifier in mountedIdentifiers {
            resolved.formUnion(physicalDiskIdentifiers(for: identifier))
        }

        return resolved.sorted()
    }

    private func fetchExternalDiskListEntries() -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["list", "-plist", "external", "physical"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = plist as? [String: Any],
            let disks = dictionary["AllDisksAndPartitions"] as? [[String: Any]]
        else {
            return []
        }

        return disks
    }

    private func externalPhysicalDiskIdentifiers() -> [String] {
        cachedExternalDiskListEntries
            .compactMap { $0["DeviceIdentifier"] as? String }
            .map(wholeDiskIdentifier(from:))
    }

    private func externalVolumeNamesByWholeDisk() -> [String: String] {
        var namesByDisk: [String: String] = [:]
        for disk in cachedExternalDiskListEntries {
            guard let identifier = disk["DeviceIdentifier"] as? String else { continue }
            let wholeDisk = wholeDiskIdentifier(from: identifier)
            guard let partitions = disk["Partitions"] as? [[String: Any]] else { continue }

            if let name = partitions.compactMap(volumeName(from:)).first {
                namesByDisk[wholeDisk] = name
            }
        }

        return namesByDisk
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

    private func mountedDiskIdentifiers() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "df -l | tail -n +2 | awk '{print $1}' | sed 's#^/dev/##' | sort -u"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func physicalDiskIdentifiers(for identifier: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/dev/\(identifier)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [wholeDiskIdentifier(from: identifier)]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = plist as? [String: Any]
        else {
            return [wholeDiskIdentifier(from: identifier)]
        }

        if let stores = dictionary["APFSPhysicalStores"] as? [[String: Any]] {
            let physicalStores = stores.compactMap { $0["APFSPhysicalStore"] as? String }
            if !physicalStores.isEmpty {
                return physicalStores.map(wholeDiskIdentifier(from:))
            }
        }

        if let parentWholeDisk = dictionary["ParentWholeDisk"] as? String, !parentWholeDisk.isEmpty {
            return [wholeDiskIdentifier(from: parentWholeDisk)]
        }

        if let deviceIdentifier = dictionary["DeviceIdentifier"] as? String, !deviceIdentifier.isEmpty {
            return [wholeDiskIdentifier(from: deviceIdentifier)]
        }

        return [wholeDiskIdentifier(from: identifier)]
    }

    private func wholeDiskIdentifier(from identifier: String) -> String {
        var result = identifier
        while let range = result.range(of: #"s\d+$"#, options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result
    }
}
