import XCTest
@testable import MacResourceBarCore

final class MonitoringPolicyTests: XCTestCase {
    func testPrimaryScopeUsesOnlyThePrimaryRoute() {
        XCTAssertTrue(NetworkInterfacePolicy.includes("en0", scope: .primary, primaryInterface: "en0"))
        XCTAssertFalse(NetworkInterfacePolicy.includes("en5", scope: .primary, primaryInterface: "en0"))
        XCTAssertFalse(NetworkInterfacePolicy.includes("utun4", scope: .primary, primaryInterface: "en0"))
    }

    func testPrimaryScopeFallsBackToPhysicalInterfaces() {
        XCTAssertTrue(NetworkInterfacePolicy.includes("en0", scope: .primary, primaryInterface: nil))
        XCTAssertTrue(NetworkInterfacePolicy.includes("en12", scope: .primary, primaryInterface: nil))
        XCTAssertFalse(NetworkInterfacePolicy.includes("utun2", scope: .primary, primaryInterface: nil))
    }

    func testPhysicalAndVPNScopeExcludePeerToPeerNoise() {
        XCTAssertTrue(NetworkInterfacePolicy.includes("en0", scope: .physical, primaryInterface: nil))
        XCTAssertFalse(NetworkInterfacePolicy.includes("bridge0", scope: .physical, primaryInterface: nil))
        XCTAssertTrue(NetworkInterfacePolicy.includes("utun6", scope: .allIncludingVPN, primaryInterface: nil))
        XCTAssertFalse(NetworkInterfacePolicy.includes("bridge0", scope: .allIncludingVPN, primaryInterface: nil))
        XCTAssertFalse(NetworkInterfacePolicy.includes("awdl0", scope: .allIncludingVPN, primaryInterface: nil))
        XCTAssertFalse(NetworkInterfacePolicy.includes("llw0", scope: .allIncludingVPN, primaryInterface: nil))
    }

    func testWholeDiskIdentifierRejectsPseudoFilesystems() {
        XCTAssertEqual(PhysicalDiskPolicy.wholeDiskIdentifier(from: "disk4s2"), "disk4")
        XCTAssertEqual(PhysicalDiskPolicy.wholeDiskIdentifier(from: "disk10"), "disk10")
        XCTAssertNil(PhysicalDiskPolicy.wholeDiskIdentifier(from: "devices"))
        XCTAssertNil(PhysicalDiskPolicy.wholeDiskIdentifier(from: "file:///tmp/device"))
    }

    func testNetworkMenuRatesUseStableMegabyteUnits() {
        XCTAssertEqual(ByteRateFormatter.networkMenuRate(for: 0), "0.0M")
        XCTAssertEqual(ByteRateFormatter.networkMenuRate(for: 512 * 1024), "0.5M")
        XCTAssertEqual(ByteRateFormatter.networkMenuRate(for: 5 * 1024 * 1024), "5.0M")
        XCTAssertEqual(ByteRateFormatter.networkMenuRate(for: 50 * 1024 * 1024), "50M")
        XCTAssertEqual(ByteRateFormatter.networkMenuRate(for: -1), "0.0M")
    }

    func testStableOrderKeepsDormantApplications() {
        XCTAssertEqual(
            StableOrderPolicy.merging(
                stored: ["app-a", "closed-app", "app-b"],
                available: ["app-b", "app-a", "new-app"]
            ),
            ["app-a", "closed-app", "app-b", "new-app"]
        )
    }

    func testStableOrderRemovesDuplicatesWithoutDroppingItems() {
        XCTAssertEqual(
            StableOrderPolicy.merging(
                stored: ["app-a", "app-a", "closed-app"],
                available: ["app-a", "new-app", "new-app"]
            ),
            ["app-a", "closed-app", "new-app"]
        )
    }

    func testRecentSamplingBaselineCanBeReused() {
        XCTAssertTrue(SamplingFreshnessPolicy.canReuseBaseline(age: 7.5, regularInterval: 5))
        XCTAssertTrue(SamplingFreshnessPolicy.canReuseBaseline(age: 15, regularInterval: 10))
    }

    func testStaleSamplingBaselineRequiresWarmup() {
        XCTAssertFalse(SamplingFreshnessPolicy.canReuseBaseline(age: 9, regularInterval: 5))
        XCTAssertFalse(SamplingFreshnessPolicy.canReuseBaseline(age: 60, regularInterval: 10))
        XCTAssertFalse(SamplingFreshnessPolicy.canReuseBaseline(age: -1, regularInterval: 5))
    }
}
