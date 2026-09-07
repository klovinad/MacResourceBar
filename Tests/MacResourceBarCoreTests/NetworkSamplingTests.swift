import XCTest
import Darwin
@testable import MacResourceBarCore

final class NetworkSamplingTests: XCTestCase {
    func testRouteMessagesKeep64BitBytesAndRejectTruncation() throws {
        var message = if_msghdr2()
        message.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        message.ifm_type = UInt8(RTM_IFINFO2)
        message.ifm_index = 4
        message.ifm_flags = IFF_UP | IFF_RUNNING
        message.ifm_data.ifi_ibytes = 9_000_000_000
        message.ifm_data.ifi_obytes = 7_000_000_000
        let data = withUnsafeBytes(of: &message) { Data($0) }
        let parsed = try XCTUnwrap(NetworkTotalsMonitor.parseInterfaceMessages(data) { $0 == 4 ? "en0" : nil })
        XCTAssertEqual(parsed["en0"]?.inBytes, 9_000_000_000)
        XCTAssertEqual(parsed["en0"]?.outBytes, 7_000_000_000)
        XCTAssertNil(NetworkTotalsMonitor.parseInterfaceMessages(Data(data.dropLast())) { _ in "en0" })
        XCTAssertNil(NetworkTotalsMonitor.parseInterfaceMessages(Data([0, 0, 0, 0])) { _ in "en0" })
    }

    func testNetworkRatesCross4GiBAndDetectResetsBeforeSumming() throws {
        typealias C = NetworkTotalsMonitor.InterfaceCounters
        typealias S = NetworkTotalsMonitor.Counters
        let old = S(uptime: 10, interfaces: ["en0": C(index: 1, flags: 0, inBytes: 4_294_967_000, outBytes: 100)])
        let new = S(uptime: 12, interfaces: ["en0": C(index: 1, flags: 0, inBytes: 4_294_969_000, outBytes: 500)])
        let rates = try XCTUnwrap(NetworkTotalsMonitor.rates(previous: old, current: new, maximumAge: 15))
        XCTAssertEqual(rates.download, 1000)
        XCTAssertEqual(rates.upload, 200)
        let reset = S(uptime: 13, interfaces: ["en0": C(index: 1, flags: 0, inBytes: 20, outBytes: 500)])
        XCTAssertNil(NetworkTotalsMonitor.rates(previous: new, current: reset, maximumAge: 15))
        let replaced = S(uptime: 13, interfaces: ["en0": C(index: 9, flags: 0, inBytes: 8_000_000_000, outBytes: 700)])
        XCTAssertNil(NetworkTotalsMonitor.rates(previous: new, current: replaced, maximumAge: 15))
        let stale = S(uptime: 100, interfaces: new.interfaces)
        XCTAssertNil(NetworkTotalsMonitor.rates(previous: new, current: stale, maximumAge: 15))
        let disconnected = S(uptime: 13, interfaces: [:])
        XCTAssertNil(NetworkTotalsMonitor.rates(previous: new, current: disconnected, maximumAge: 15))
    }

    func testNativeInterfaceReaderReturnsValidCounters() throws {
        let counters = try XCTUnwrap(NetworkTotalsMonitor.readInterfaceCounters())
        XCTAssertFalse(counters.isEmpty)
        XCTAssertTrue(counters.values.allSatisfy { $0.index > 0 })
    }

    func testCSVHandlesCommasDotsEmptyFramesAndMalformedRows() {
        XCTAssertEqual(NetTopCSVRecord.parse(",bytes_in,bytes_out,"), .header)
        XCTAssertEqual(NetTopCSVRecord.parse("time,,bytes_in,bytes_out,\r"), .header)
        XCTAssertEqual(NetTopCSVRecord.parse("My,App.helper.42,4294968000,20,"),
                       .process(pid: 42, token: "My,App.helper.42", bytesIn: 4_294_968_000, bytesOut: 20))
        for line in ["", "bytes_in,wrong", "name,1,2", "bad.-1,1,2", "bad.42,NaN,2", "bad.42,-2,1", "bad.42,18446744073709551616,0"] {
            XCTAssertEqual(NetTopCSVRecord.parse(line), .ignored, line)
        }
    }

    func testNettopRatesRejectSameNamePIDReuseAndCounterReset() {
        typealias C = NetworkProcessMonitor.CumulativeProcessCounters
        typealias S = NetworkProcessMonitor.CumulativeSnapshot
        let identity = ProcessIdentity(pid: 42, startTimeMicroseconds: 1, executablePath: "/test")
        let old = S(timestamp: 10, countersByPID: [42: C(processToken: "test.42", bytesIn: 100, bytesOut: 50, identity: identity)])
        let new = S(timestamp: 12, countersByPID: [42: C(processToken: "test.42", bytesIn: 1100, bytesOut: 450, identity: identity)])
        let rates = NetworkProcessMonitor.rateSamples(previous: old, current: new)
        XCTAssertEqual(rates.first?.downloadBytesPerSecond, 500)
        XCTAssertEqual(rates.first?.uploadBytesPerSecond, 200)
        let replacement = ProcessIdentity(pid: 42, startTimeMicroseconds: 2, executablePath: "/test")
        let reused = S(timestamp: 13, countersByPID: [42: C(processToken: "test.42", bytesIn: 10000, bytesOut: 5000, identity: replacement)])
        XCTAssertTrue(NetworkProcessMonitor.rateSamples(previous: new, current: reused).isEmpty)
        let reset = S(timestamp: 13, countersByPID: [42: C(processToken: "test.42", bytesIn: 1, bytesOut: 2, identity: identity)])
        XCTAssertTrue(NetworkProcessMonitor.rateSamples(previous: new, current: reset).isEmpty)
        XCTAssertTrue(NetworkProcessMonitor.rateSamples(previous: new, current: S(timestamp: 100, countersByPID: new.countersByPID)).isEmpty)
    }

    func testNettopFailureIsReportedAndMonitorCanStop() {
        let reported = expectation(description: "nettop failure")
        reported.assertForOverFulfill = false
        let monitor = NetworkProcessMonitor(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        monitor.onStatusChange = { message in
            if message?.contains("exited with status") == true { reported.fulfill() }
        }
        monitor.start()
        wait(for: [reported], timeout: 4)
        monitor.stop()
    }
}
