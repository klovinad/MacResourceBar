import AppKit
import XCTest
@testable import MacResourceBarCore

final class MenuBarGraphicLayoutTests: XCTestCase {
    @MainActor
    private final class ClickTarget: NSObject {
        var count = 0
        @objc func clicked(_ sender: Any?) { count += 1 }
    }

    @MainActor
    func testGraphicSurfaceForwardsOneInsideClickToTheNativeButton() throws {
        let target = ClickTarget()
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        button.target = target
        button.action = #selector(ClickTarget.clicked(_:))
        let drawing = MenuBarGraphicView(frame: button.bounds)
        button.addSubview(drawing)
        func event(_ type: NSEvent.EventType, x: CGFloat = 20) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 12),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        drawing.mouseUp(with: try event(.leftMouseUp))
        XCTAssertEqual(target.count, 0)
        drawing.mouseDown(with: try event(.leftMouseDown))
        drawing.mouseUp(with: try event(.leftMouseUp))
        XCTAssertEqual(target.count, 1)
        drawing.mouseDown(with: try event(.leftMouseDown))
        drawing.mouseUp(with: try event(.leftMouseUp, x: 180))
        XCTAssertEqual(target.count, 1)
        XCTAssertTrue(drawing.acceptsFirstMouse(for: nil))
    }

    private func gauge(_ id: String, value: String = "48%") -> MenuBarGraphicEntry {
        .init(id: id, label: id.uppercased(), value: value, widthTemplate: "100%", symbolName: "cpu")
    }

    @MainActor
    func testLiveDigitsAndUnavailableValuesKeepColumnPositions() {
        for style in [MenuBarGraphicRenderer.Style.twoLines, .icons] {
            let initial = MenuBarGraphicRenderer.layout(entries: [gauge("cpu"), gauge("ram"), gauge("temp")], style: style)
            for value in ["0%", "100%", "N/A"] {
                let changed = MenuBarGraphicRenderer.layout(entries: [gauge("cpu", value: value), gauge("ram"), gauge("temp")], style: style)
                XCTAssertEqual(changed.size, initial.size)
                XCTAssertEqual(changed.columns.map(\.x), initial.columns.map(\.x))
            }
        }
    }

    @MainActor
    func testOddMetricCountAndOverflowKeepNetworkDirectionsTogether() {
        let network = ["download", "upload"].map {
            MenuBarGraphicEntry(id: $0, label: $0 == "download" ? "↓" : "↑", value: "28 MB/s",
                                widthTemplate: "999+ MB/s", symbolName: "arrow.down", pairID: "network")
        }
        let entries = [gauge("cpu")] + network + [gauge("ram"), gauge("temp")]
        let full = MenuBarGraphicRenderer.layout(entries: entries, style: .twoLines)
        XCTAssertEqual(full.columns.map { $0.entries.map(\.id) }, [["cpu"], ["download", "upload"], ["ram", "temp"]])
        for style in [MenuBarGraphicRenderer.Style.twoLines, .icons] {
            for width in [28.0, 80, 140, 240] {
                let layout = MenuBarGraphicRenderer.layout(entries: entries, style: style, maximumWidth: width)
                let shown = layout.columns.flatMap(\.entries).filter { $0.id != "overflow" }
                XCTAssertLessThanOrEqual(layout.size.width, width)
                XCTAssertEqual(shown.contains { $0.id == "download" }, shown.contains { $0.id == "upload" })
                XCTAssertEqual(shown.count + layout.hiddenCount, entries.count)
                XCTAssertEqual(shown.map(\.id), Array(entries.prefix(shown.count)).map(\.id))
            }
        }
    }

    @MainActor
    func testBothNewStylesReloadAndKeepWarmupDistinctFromZero() throws {
        let suite = "MacResourceBar.graphic-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MenuBarPreferences(defaults: defaults)
        preferences.trayMetricRawValues = ["cpu", "memory", "network"]
        preferences.trayMetricOrderRawValues = ["cpu", "memory", "network"]
        for style in [MenuBarViewModel.MenuBarLabelStyle.twoLines, .icons] {
            MenuBarViewModel(preferences: preferences, startMonitoring: false).setMenuBarLabelStyle(style)
            let reloaded = MenuBarViewModel(preferences: preferences, startMonitoring: false)
            XCTAssertEqual(reloaded.menuBarLabelStyle, style)
            let entries = reloaded.menuBarGraphicEntries(for: style)
            XCTAssertEqual(entries.map(\.id), ["cpu", "memory", "network-download", "network-upload"])
            XCTAssertTrue(entries.allSatisfy { $0.value == "N/A" })
            XCTAssertTrue(reloaded.menuBarAccessibilityComponents.allSatisfy { $0.contains("unavailable") })
        }
    }
}
