import AppKit
import CoreText

struct MenuBarGraphicEntry: Equatable {
    let id: String
    let label: String
    let value: String
    let widthTemplate: String
    let symbolName: String?
    var showsLabelWithIcon = false
    var pairID: String?
}

/// Draws inside the native status button, preserving its click, menu and
/// accessibility behavior. The preview uses the same measured columns.
@MainActor
enum MenuBarGraphicRenderer {
    enum Style { case twoLines, icons }

    struct Column: Equatable {
        let entries: [MenuBarGraphicEntry]
        let x: CGFloat
        let width: CGFloat
        let labelWidth: CGFloat
    }

    struct Layout: Equatable {
        let style: Style
        let columns: [Column]
        let size: NSSize
        let hiddenCount: Int
    }

    static func groups(for entries: [MenuBarGraphicEntry], style: Style) -> [[MenuBarGraphicEntry]] {
        var groups: [[MenuBarGraphicEntry]] = []
        for entry in entries {
            if let last = groups.last, last.count == 1,
               (entry.pairID != nil && last[0].pairID == entry.pairID)
                || (style == .twoLines && entry.pairID == nil && last[0].pairID == nil) {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }
        return groups
    }

    static func layout(entries: [MenuBarGraphicEntry], style: Style, maximumWidth: CGFloat = 720) -> Layout {
        let groups = groups(for: entries, style: style)
        let natural = measure(groups, style: style, hiddenCount: 0)
        if natural.size.width <= maximumWidth { return natural }

        // Drop complete columns; never leave only one network direction.
        for count in stride(from: groups.count - 1, through: 0, by: -1) {
            let hidden = groups.dropFirst(count).reduce(0) { $0 + $1.count }
            let overflow = MenuBarGraphicEntry(
                id: "overflow", label: "", value: "+\(hidden)",
                widthTemplate: "+\(hidden)", symbolName: nil
            )
            let candidate = measure(Array(groups.prefix(count)) + [[overflow]], style: style, hiddenCount: hidden)
            if candidate.size.width <= maximumWidth { return candidate }
        }
        return measure([[MenuBarGraphicEntry(
            id: "overflow", label: "", value: "…", widthTemplate: "…", symbolName: nil
        )]], style: style, hiddenCount: entries.count)
    }

    static func image(for layout: Layout) -> NSImage {
        let image = NSImage(size: layout.size, flipped: false) { _ in
            draw(layout, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func draw(_ layout: Layout, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let font = font(for: layout.style)
        for column in layout.columns {
            if layout.style == .twoLines {
                for (index, entry) in column.entries.enumerated() {
                    let rowY: CGFloat = column.entries.count == 1 ? 5.5 : (index == 0 ? 11 : 0)
                    draw(entry.label, font: font, x: column.x, rowY: rowY, rowHeight: 11, context: context, color: color)
                    let valueX = column.x + column.labelWidth + (column.labelWidth > 0 ? 3 : 0)
                    draw(entry.value, font: font, x: valueX, rowY: rowY, rowHeight: 11, context: context, color: color)
                }
            } else {
                var x = column.x
                for entry in column.entries {
                    if let name = entry.symbolName {
                        let box = NSRect(x: x, y: 4.5, width: 13, height: 13)
                        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)
                            .applying(.init(paletteColors: [color]))) {
                            let scale = min(box.width / symbol.size.width, box.height / symbol.size.height)
                            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                            symbol.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                                                   width: size.width, height: size.height))
                        } else {
                            draw(entry.label, font: font, x: x, rowY: 0, rowHeight: 22, context: context, color: color)
                        }
                        x += iconWidth(for: entry, font: font)
                    }
                    let prefix = entry.showsLabelWithIcon ? entry.label + " " : ""
                    draw(prefix + entry.value, font: font, x: x, rowY: 0, rowHeight: 22, context: context, color: color)
                    x += valueWidth(for: entry, font: font, prefix: prefix) + 6
                }
            }
        }
    }

    private static func measure(_ groups: [[MenuBarGraphicEntry]], style: Style, hiddenCount: Int) -> Layout {
        let font = font(for: style)
        var x: CGFloat = 2
        let columns = groups.map { entries -> Column in
            let labelWidth: CGFloat
            let width: CGFloat
            if style == .twoLines {
                labelWidth = entries.map { textWidth($0.label, font: font) }.max() ?? 0
                width = labelWidth + (labelWidth > 0 ? 3 : 0)
                    + (entries.map { valueWidth(for: $0, font: font) }.max() ?? 0)
            } else {
                labelWidth = 0
                width = entries.reduce(0) { result, entry in
                    result + iconWidth(for: entry, font: font)
                        + valueWidth(for: entry, font: font, prefix: entry.showsLabelWithIcon ? entry.label + " " : "")
                } + CGFloat(max(0, entries.count - 1)) * 6
            }
            let column = Column(entries: entries, x: x, width: ceil(width), labelWidth: labelWidth)
            x += ceil(width) + 10
            return column
        }
        return Layout(style: style, columns: columns,
                      size: NSSize(width: max(22, x - 10 + 2), height: 22), hiddenCount: hiddenCount)
    }

    private static func font(for style: Style) -> NSFont {
        .monospacedDigitSystemFont(ofSize: style == .twoLines ? 10 : 12, weight: .medium)
    }

    private static func iconWidth(for entry: MenuBarGraphicEntry, font: NSFont) -> CGFloat {
        guard let name = entry.symbolName else { return 0 }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil
            ? textWidth(entry.label, font: font) + 3 : 16
    }

    private static func valueWidth(for entry: MenuBarGraphicEntry, font: NSFont, prefix: String = "") -> CGFloat {
        [entry.value, entry.widthTemplate, "N/A"].map { textWidth(prefix + $0, font: font) }.max() ?? 0
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    private static func draw(_ text: String, font: NSFont, x: CGFloat, rowY: CGFloat,
                             rowHeight: CGFloat, context: CGContext, color: NSColor) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color]
        ))
        context.textPosition = CGPoint(x: x, y: rowY + (rowHeight - font.ascender - abs(font.descender)) / 2 + abs(font.descender))
        CTLineDraw(line, context)
    }
}

/// Keeps native button actions and accessibility while drawing full-contrast
/// content. Menu-bar hosting does not reliably pass clicks through a child view.
@MainActor
final class MenuBarGraphicView: NSView {
    private var layout: MenuBarGraphicRenderer.Layout?
    private var tracksPrimaryPress = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        tracksPrimaryPress = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let shouldActivate = tracksPrimaryPress && bounds.contains(convert(event.locationInWindow, from: nil))
        tracksPrimaryPress = false
        if shouldActivate { (superview as? NSButton)?.performClick(self) }
    }

    func apply(_ layout: MenuBarGraphicRenderer.Layout) {
        guard self.layout != layout else { return }
        self.layout = layout
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let imageRect = (superview as? NSButton)?.cell?.imageRect(forBounds: bounds)
        context.translateBy(x: imageRect?.minX ?? floor((bounds.width - layout.size.width) / 2),
                            y: imageRect?.minY ?? floor((bounds.height - layout.size.height) / 2))
        MenuBarGraphicRenderer.draw(layout, color: .labelColor)
        context.restoreGState()
    }
}
