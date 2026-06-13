import AppKit
import Combine
import SwiftUI

private final class StatusSegmentView: NSView {
    private enum Layout {
        static let horizontalPadding: CGFloat = 1
        static let verticalPadding: CGFloat = 1
    }

    private let label = NSTextField(labelWithString: "")
    private var minimumWidthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.cell?.wraps = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Layout.verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.verticalPadding)
        ])

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setMinimumWidth(_ width: CGFloat) {
        if let minimumWidthConstraint {
            minimumWidthConstraint.constant = width
        } else {
            let constraint = widthAnchor.constraint(greaterThanOrEqualToConstant: width)
            constraint.isActive = true
            minimumWidthConstraint = constraint
        }
    }

    func update(text: String?) {
        label.stringValue = text ?? ""
        isHidden = text == nil
        invalidateIntrinsicContentSize()
    }
}

private final class StatusItemContentView: NSView {
    private let stackView = NSStackView()
    private let highRefreshSegment = StatusSegmentView()
    private let cpuSegment = StatusSegmentView()
    private let ramSegment = StatusSegmentView()
    private let tempSegment = StatusSegmentView()
    private let diskSegment = StatusSegmentView()
    private let externalDiskSegment = StatusSegmentView()
    private let networkSegment = StatusSegmentView()
    private lazy var segmentsByMetric: [MenuBarViewModel.TrayMetric: StatusSegmentView] = [
        .cpu: cpuSegment,
        .memory: ramSegment,
        .cpuTemp: tempSegment,
        .disk: diskSegment,
        .externalDisk: externalDiskSegment,
        .network: networkSegment
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 2
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 2)
        stackView.detachesHiddenViews = true
        stackView.setContentHuggingPriority(.required, for: .horizontal)
        stackView.setContentCompressionResistancePriority(.required, for: .horizontal)

        highRefreshSegment.setMinimumWidth(26)
        cpuSegment.setMinimumWidth(58)
        ramSegment.setMinimumWidth(58)
        tempSegment.setMinimumWidth(58)
        diskSegment.setMinimumWidth(74)
        externalDiskSegment.setMinimumWidth(74)
        networkSegment.setMinimumWidth(92)

        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(
        orderedMetrics: [MenuBarViewModel.TrayMetric],
        textByMetric: [MenuBarViewModel.TrayMetric: String],
        showHighRefreshBadge: Bool
    ) {
        for arrangedSubview in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        highRefreshSegment.update(text: nil)
        for metric in MenuBarViewModel.TrayMetric.allCases {
            segmentsByMetric[metric]?.update(text: nil)
        }

        if showHighRefreshBadge {
            highRefreshSegment.update(text: "HR")
            stackView.addArrangedSubview(highRefreshSegment)
        }

        var seen = Set<MenuBarViewModel.TrayMetric>()
        for metric in orderedMetrics {
            guard seen.insert(metric).inserted else { continue }
            guard let segment = segmentsByMetric[metric] else { continue }
            segment.update(text: textByMetric[metric])
            stackView.addArrangedSubview(segment)
        }

        layoutSubtreeIfNeeded()
        invalidateIntrinsicContentSize()
    }

    func requiredWidth() -> CGFloat {
        fittingSize.width
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Constants {
        static let popoverSizeExpanded = NSSize(width: 380, height: 430)
        static let popoverSizeCompact = NSSize(width: 380, height: 250)
        static let minimumStatusItemLength: CGFloat = 60
        static let fallbackStatusSymbolName = "waveform.path.ecg"
    }

    let viewModel = MenuBarViewModel()
    private let popover = NSPopover()
    private let statusMenu = NSMenu()
    private var statusItem: NSStatusItem?
    private var statusItemContentView: StatusItemContentView?
    private var menuBarTitleObserver: AnyCancellable?
    private var popoverLayoutObserver: AnyCancellable?
    private var trayOrderingObserver: AnyCancellable?
    private var pinnedPopoverMinX: CGFloat?
    private var pinnedPopoverTopY: CGFloat?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configurePopover()
        bindViewModel()
        ensureStatusItem()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ensureStatusItem()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ensureStatusItem()
        showPopover()
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = Constants.popoverSizeExpanded
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(viewModel: viewModel)
        )
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        item.autosaveName = nil
        item.behavior = []
        item.isVisible = true
        configureStatusMenu()
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.lineBreakMode = .byTruncatingHead
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let fallbackImage = NSImage(systemSymbolName: Constants.fallbackStatusSymbolName, accessibilityDescription: "NetworkMenuMonitor")?
            .withSymbolConfiguration(symbolConfig)
        fallbackImage?.isTemplate = true
        button.image = fallbackImage
        button.imagePosition = .imageLeading
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")

        let contentView = StatusItemContentView(frame: .zero)
        contentView.isHidden = true
        statusItemContentView = contentView
        updateStatusItemTitle()

        statusItem = item
    }

    private func ensureStatusItem() {
        if let button = statusItem?.button, button.window != nil {
            return
        }

        if let existingItem = statusItem {
            NSStatusBar.system.removeStatusItem(existingItem)
            statusItem = nil
        }

        configureStatusItem()
        updateStatusItemTitle()
        statusItem?.isVisible = true
    }

    private func configureStatusMenu() {
        statusMenu.removeAllItems()
        let launchItem = NSMenuItem(
            title: "Launch at login",
            action: #selector(toggleLaunchAtLoginFromMenu(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        statusMenu.addItem(launchItem)
        let refreshItem = NSMenuItem(
            title: "High Refresh (1s)",
            action: #selector(toggleHighRefreshFromMenu(_:)),
            keyEquivalent: ""
        )
        refreshItem.target = self
        statusMenu.addItem(refreshItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(
            withTitle: "Show",
            action: #selector(togglePopoverFromMenu(_:)),
            keyEquivalent: ""
        )
        statusMenu.addItem(.separator())
        statusMenu.addItem(
            withTitle: "Quit",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        statusMenu.items.forEach { $0.target = self }
    }

    private func bindViewModel() {
        menuBarTitleObserver = viewModel.$menuBarTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemTitle()
            }

        popoverLayoutObserver = viewModel.$appSnapshots
            .combineLatest(
                viewModel.$appDisplayThresholdBytesPerSecond,
                viewModel.$perAppStatusMessage,
                viewModel.$showAllInfo
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.updatePopoverSize()
            }

        trayOrderingObserver = viewModel.$trayMetricOrder
            .combineLatest(
                viewModel.$selectedTrayMetrics,
                viewModel.$externalDiskActivities
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.updateStatusItemTitle(force: true)
            }
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        ensureStatusItem()
        guard statusItem?.button != nil else { return }

        if NSApp.currentEvent?.type == .rightMouseUp {
            if popover.isShown {
                pinnedPopoverMinX = nil
                pinnedPopoverTopY = nil
                popover.performClose(sender)
            }
            updateStatusMenu()
            statusItem?.popUpMenu(statusMenu)
            return
        }

        if popover.isShown {
            pinnedPopoverMinX = nil
            pinnedPopoverTopY = nil
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    @objc
    private func togglePopoverFromMenu(_ sender: AnyObject?) {
        if popover.isShown {
            pinnedPopoverMinX = nil
            pinnedPopoverTopY = nil
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    @objc
    private func quitApplication(_ sender: AnyObject?) {
        NSApp.terminate(sender)
    }

    @objc
    private func toggleLaunchAtLoginFromMenu(_ sender: AnyObject?) {
        viewModel.setLaunchAtLoginEnabled(!viewModel.launchAtLoginEnabled)
        updateStatusMenu()
    }

    @objc
    private func toggleHighRefreshFromMenu(_ sender: AnyObject?) {
        viewModel.setHighRefreshEnabled(!viewModel.highRefreshEnabled)
        updateStatusMenu()
        updateStatusItemTitle(force: true)
    }

    private func updateStatusMenu() {
        statusMenu.item(at: 0)?.state = viewModel.launchAtLoginEnabled ? .on : .off
        statusMenu.item(at: 1)?.state = viewModel.highRefreshEnabled ? .on : .off
        statusMenu.item(at: 3)?.title = popover.isShown ? "Hide" : "Show"
    }

    private func showPopover() {
        ensureStatusItem()
        guard let button = statusItem?.button else { return }

        updatePopoverSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            pinnedPopoverMinX = window.frame.minX
            pinnedPopoverTopY = window.frame.maxY
            window.makeKey()
        } else {
            pinnedPopoverMinX = nil
            pinnedPopoverTopY = nil
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updatePopoverSize() {
        popover.contentSize = viewModel.showAllInfo
            ? Constants.popoverSizeExpanded
            : Constants.popoverSizeCompact
        pinPopoverPositionIfNeeded()
    }

    private func updateStatusItemTitle() {
        updateStatusItemTitle(force: false)
    }

    private func updateStatusItemTitle(force: Bool) {
        // Freeze status item mutations while popover is shown to avoid any anchor drift.
        if popover.isShown && !force {
            return
        }
        let orderedMetrics = viewModel.orderedVisibleTrayMetrics
        var dedupedMetrics: [MenuBarViewModel.TrayMetric] = []
        var seen = Set<MenuBarViewModel.TrayMetric>()
        for metric in orderedMetrics where seen.insert(metric).inserted {
            dedupedMetrics.append(metric)
        }

        var visibleMetrics = dedupedMetrics
        if viewModel.highRefreshEnabled && !visibleMetrics.contains(.network) {
            visibleMetrics.append(.network)
        }
        if visibleMetrics.isEmpty {
            visibleMetrics = [.network]
        }

        let textByMetric = visibleMetrics.reduce(into: [MenuBarViewModel.TrayMetric: String]()) { partial, metric in
            partial[metric] = viewModel.trayText(for: metric)
        }

        var segments: [String] = []
        if viewModel.highRefreshEnabled {
            segments.append("HR")
        }
        segments.append(contentsOf: visibleMetrics.compactMap { textByMetric[$0] })

        let title = segments.joined(separator: "  ")
        statusItemContentView?.isHidden = true
        statusItem?.button?.title = " \(title)"
        statusItem?.button?.imagePosition = .imageLeading
        statusItem?.button?.attributedTitle = NSAttributedString(
            string: " \(title)",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
        if !popover.isShown {
            statusItem?.length = NSStatusItem.variableLength
        }
        statusItem?.button?.needsLayout = true
        pinPopoverPositionIfNeeded()
    }

    private func pinPopoverPositionIfNeeded() {
        guard popover.isShown else { return }
        guard let targetMinX = pinnedPopoverMinX, let targetTopY = pinnedPopoverTopY else { return }
        guard let window = popover.contentViewController?.view.window else { return }
        let targetOrigin = NSPoint(x: targetMinX, y: targetTopY - window.frame.height)
        if window.frame.origin != targetOrigin {
            window.setFrameOrigin(targetOrigin)
        }
    }

}
