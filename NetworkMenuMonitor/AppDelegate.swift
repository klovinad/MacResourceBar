import AppKit
import Combine
import SwiftUI

private final class StatusSegmentView: NSView {
    private enum Layout {
        static let horizontalPadding: CGFloat = 0
        static let verticalPadding: CGFloat = 0
    }

    private let label = NSTextField(labelWithString: "")
    private var minimumWidthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.cell?.wraps = false
        label.cell?.usesSingleLineMode = true
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
        stackView.spacing = 5
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stackView.detachesHiddenViews = true
        stackView.setContentHuggingPriority(.required, for: .horizontal)
        stackView.setContentCompressionResistancePriority(.required, for: .horizontal)

        highRefreshSegment.setMinimumWidth(20)
        cpuSegment.setMinimumWidth(50)
        ramSegment.setMinimumWidth(50)
        tempSegment.setMinimumWidth(52)
        diskSegment.setMinimumWidth(64)
        externalDiskSegment.setMinimumWidth(54)
        networkSegment.setMinimumWidth(82)

        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor)
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
        static let popoverSizeExpanded = NSSize(width: 820, height: 720)
        static let popoverSizeCompact = NSSize(width: 820, height: 680)
        static let minimumStatusItemLength: CGFloat = 28
        static let maximumStatusItemLength: CGFloat = 760
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
    private var settingsObserver: NSObjectProtocol?
    private var settingsWindow: NSWindow?
    private var pinnedPopoverMinX: CGFloat?
    private var pinnedPopoverTopY: CGFloat?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configurePopover()
        bindViewModel()
        observeSettingsRequests()
        ensureStatusItem()
        showPopoverAfterInitialLaunch()
        showPopoverForVerificationIfRequested()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ensureStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stopMonitoring()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
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
        button.lineBreakMode = .byTruncatingTail
        button.image = nil
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")

        let contentView = StatusItemContentView(frame: .zero)
        contentView.isHidden = false
        button.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 3),
            contentView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
            contentView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            contentView.heightAnchor.constraint(equalToConstant: 18)
        ])
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
            withTitle: "Show Popover",
            action: #selector(togglePopoverFromMenu(_:)),
            keyEquivalent: ""
        )
        statusMenu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
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
                viewModel.$perAppStatusMessage
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
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
            if let button = statusItem?.button, let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(statusMenu, with: event, for: button)
            } else {
                statusItem?.menu = statusMenu
                statusItem?.button?.performClick(nil)
            }
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
    private func openSettings(_ sender: AnyObject?) {
        showSettingsWindow()
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
        statusMenu.item(at: 3)?.title = popover.isShown ? "Hide Popover" : "Show Popover"
    }

    private func observeSettingsRequests() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .networkMenuMonitorOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showSettingsWindow()
            }
        }
    }

    private func showSettingsWindow() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        let window = NSWindow(contentViewController: controller)
        window.title = "MacResourceBar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 520))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    private func showPopoverForVerificationIfRequested() {
        guard ProcessInfo.processInfo.environment["NETWORK_MENU_MONITOR_SHOW_POPOVER"] == "1" else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showPopover()
        }
    }

    private func showPopoverAfterInitialLaunch() {
        guard ProcessInfo.processInfo.environment["MAC_RESOURCE_BAR_START_HIDDEN"] != "1" else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.ensureStatusItem()
            self.showPopover()
        }
    }

    private func updatePopoverSize() {
        popover.contentSize = Constants.popoverSizeCompact
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
        if visibleMetrics.isEmpty {
            visibleMetrics = [.network]
        }

        let textByMetric = visibleMetrics.reduce(into: [MenuBarViewModel.TrayMetric: String]()) { partial, metric in
            partial[metric] = viewModel.trayText(for: metric)
        }

        statusItemContentView?.update(
            orderedMetrics: visibleMetrics,
            textByMetric: textByMetric,
            showHighRefreshBadge: viewModel.highRefreshEnabled
        )

        statusItemContentView?.isHidden = false
        statusItem?.button?.title = ""
        statusItem?.button?.attributedTitle = NSAttributedString(string: "")
        statusItem?.button?.image = nil
        if !popover.isShown || force {
            let measuredWidth = ceil((statusItemContentView?.requiredWidth() ?? 0) + 6)
            statusItem?.length = min(
                max(measuredWidth, Constants.minimumStatusItemLength),
                Constants.maximumStatusItemLength
            )
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
