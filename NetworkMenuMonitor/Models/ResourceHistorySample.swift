import Foundation

struct ResourceHistorySample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let cpuUsagePercent: Double
    let memoryUsagePercent: Double
    let cpuTemperatureCelsius: Double?
    let diskBytesPerSecond: Double
    let externalDiskBytesPerSecond: Double

    var networkBytesPerSecond: Double {
        downloadBytesPerSecond + uploadBytesPerSecond
    }
}
