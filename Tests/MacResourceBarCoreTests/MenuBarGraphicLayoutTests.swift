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
        // NSControl dispatches actions through NSApplication. XCTest does not
        // create one consistently across macOS releases or test runners.
        _ = NSApplication.shared
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
        for style in [MenuBarGraphicRenderer.Style.twoLines, .twoLinesCompact, .twoLinesIcons, .icons] {
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
        for style in [MenuBarGraphicRenderer.Style.twoLines, .twoLinesCompact, .twoLinesIcons, .icons] {
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
    func testGraphicStylesReloadAndKeepWarmupDistinctFromZero() throws {
        let suite = "MacResourceBar.graphic-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MenuBarPreferences(defaults: defaults)
        preferences.trayMetricRawValues = ["cpu", "memory", "network"]
        preferences.trayMetricOrderRawValues = ["cpu", "memory", "network"]
        for style in [MenuBarViewModel.MenuBarLabelStyle.twoLines, .twoLinesCompact, .twoLinesIcons, .icons] {
            MenuBarViewModel(preferences: preferences, startMonitoring: false).setMenuBarLabelStyle(style)
            let reloaded = MenuBarViewModel(preferences: preferences, startMonitoring: false)
            XCTAssertEqual(reloaded.menuBarLabelStyle, style)
            let entries = reloaded.menuBarGraphicEntries(for: style)
            XCTAssertEqual(entries.map(\.id), ["cpu", "memory", "network-download", "network-upload"])
            XCTAssertTrue(entries.allSatisfy { $0.value == "N/A" })
            XCTAssertTrue(reloaded.menuBarAccessibilityComponents.allSatisfy { $0.contains("unavailable") })
        }
    }

    func testShortRatesPreserveTenthsAndPromoteRoundedUnits() {
        let mb: Double = 1024 * 1024
        let examples: [(Double, String)] = [(0.0, "0B"), (-1, "0B"), (67.9 * mb, "67.9M"),
            (326.6 * mb, "326.6M"), (1023.94 * 1024, "1023.9K"),
            (1023.96 * 1024, "1M"), (1.2 * mb * 1024, "1.2G"),
            (Double.greatestFiniteMagnitude, "1024+T"), (.infinity, "N/A"), (.nan, "N/A")]
        for (bytes, expected) in examples {
            XCTAssertEqual(ByteRateFormatter.twoLineMenuRate(for: bytes, shortUnits: true), expected)
        }
        XCTAssertEqual(ByteRateFormatter.twoLineMenuRate(for: 326.6 * mb, shortUnits: false), "326.6MB/s")
    }

    @MainActor
    func testTwoLineVariantsKeepAllEightValuesAndFixedColumnsAcrossUnits() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        func width(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        var widths: [CGFloat] = []
        for style in [MenuBarGraphicRenderer.Style.twoLines, .twoLinesCompact, .twoLinesIcons] {
            let short = style != .twoLines
            func entries(bytes: Double, missing: Bool = false, percent: String = "8%") -> [MenuBarGraphicEntry] {
                let rate = missing ? "N/A" : ByteRateFormatter.twoLineMenuRate(for: bytes, shortUnits: short)
                let template = short ? "1023.9M" : "1023.9MB/s"
                return [
                    .init(id: "temp", label: "Temp", value: missing ? "N/A" : "100°", widthTemplate: "100°", symbolName: "thermometer.medium"),
                    gauge("cpu", value: missing ? "N/A" : percent),
                    gauge("ram", value: missing ? "N/A" : percent),
                    .init(id: "disk", label: "Disk", value: rate, widthTemplate: template, symbolName: "internaldrive"),
                    .init(id: "backup", label: "BAC", value: rate, widthTemplate: template, symbolName: "externaldrive", showsLabelWithIcon: true),
                    .init(id: "sandisk", label: "SAN", value: rate, widthTemplate: template, symbolName: "externaldrive", showsLabelWithIcon: true),
                    .init(id: "download", label: "↓", value: rate, widthTemplate: template, symbolName: "arrow.down", pairID: "network"),
                    .init(id: "upload", label: "↑", value: rate, widthTemplate: template, symbolName: "arrow.up", pairID: "network")
                ]
            }
            let initial = MenuBarGraphicRenderer.layout(entries: entries(bytes: 0), style: style)
            XCTAssertEqual(initial.columns.map { $0.entries.map(\.id) },
                [["temp", "cpu"], ["ram", "disk"], ["backup", "sandisk"], ["download", "upload"]])
            XCTAssertEqual(initial.hiddenCount, 0)
            widths.append(initial.size.width)
            let rates = (0...4).flatMap { unit in
                [0.0, 9.6, 326.6, 1023.94, 1023.96].map { $0 * pow(1024, Double(unit)) }
            } + [Double.greatestFiniteMagnitude, .nan]
            for bytes in rates {
                let updated = MenuBarGraphicRenderer.layout(entries: entries(bytes: bytes, percent: "100%"), style: style)
                XCTAssertEqual(updated.size, initial.size)
                XCTAssertEqual(updated.columns.map(\.x), initial.columns.map(\.x))
                XCTAssertEqual(updated.columns.map(\.width), initial.columns.map(\.width))
                for column in updated.columns {
                    let valueSpace = column.width - column.labelWidth - (column.labelWidth > 0 ? 3 : 0)
                    for entry in column.entries { XCTAssertLessThanOrEqual(width(entry.value), valueSpace) }
                }
            }
            let unavailable = MenuBarGraphicRenderer.layout(entries: entries(bytes: 0, missing: true), style: style)
            XCTAssertEqual(unavailable.size, initial.size)
            XCTAssertEqual(unavailable.columns.map(\.x), initial.columns.map(\.x))
        }
        XCTAssertLessThan(widths[1], widths[0])
        XCTAssertLessThan(widths[2], widths[1])
    }
}
