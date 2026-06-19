import AppKit
import Combine
import SwiftUI

private final class StatusSegmentView: NSView {
    private enum Layout {
        static let horizontalPadding: CGFloat = 0
        static let verticalPadding: CGFloat = 0
    }

    private let label = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .labelColor
        label.alignment = .left
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

    func setFixedWidth(_ width: CGFloat) {
        if let widthConstraint {
            widthConstraint.constant = width
        } else {
            let constraint = widthAnchor.constraint(equalToConstant: width)
            constraint.isActive = true
            widthConstraint = constraint
        }
    }

    func update(text: String?) {
        let nextText = text ?? ""
        if label.stringValue != nextText {
            label.stringValue = nextText
        }

        let shouldHide = text == nil
        if isHidden != shouldHide {
            isHidden = shouldHide
        }
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
    private var lastOrderedMetrics: [MenuBarViewModel.TrayMetric] = []
    private var lastTextByMetric: [MenuBarViewModel.TrayMetric: String] = [:]
    private var lastShowHighRefreshBadge = false

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

        highRefreshSegment.setFixedWidth(20)
        cpuSegment.setFixedWidth(56)
        ramSegment.setFixedWidth(56)
        tempSegment.setFixedWidth(58)
        diskSegment.setFixedWidth(66)
        externalDiskSegment.setFixedWidth(58)
        networkSegment.setFixedWidth(98)

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
        let structureChanged = orderedMetrics != lastOrderedMetrics || showHighRefreshBadge != lastShowHighRefreshBadge

        if structureChanged {
            for arrangedSubview in stackView.arrangedSubviews {
                stackView.removeArrangedSubview(arrangedSubview)
                arrangedSubview.removeFromSuperview()
            }

            if showHighRefreshBadge {
                stackView.addArrangedSubview(highRefreshSegment)
            }

            var seen = Set<MenuBarViewModel.TrayMetric>()
            for metric in orderedMetrics {
                guard seen.insert(metric).inserted else { continue }
                guard let segment = segmentsByMetric[metric] else { continue }
                stackView.addArrangedSubview(segment)
            }
        }

        highRefreshSegment.update(text: showHighRefreshBadge ? "HR" : nil)
        for metric in MenuBarViewModel.TrayMetric.allCases {
            let nextText = orderedMetrics.contains(metric) ? textByMetric[metric] : nil
            if structureChanged || lastTextByMetric[metric] != nextText {
                segmentsByMetric[metric]?.update(text: nextText)
            }
        }

        lastOrderedMetrics = orderedMetrics
        lastTextByMetric = textByMetric
        lastShowHighRefreshBadge = showHighRefreshBadge

        if structureChanged {
            layoutSubtreeIfNeeded()
            invalidateIntrinsicContentSize()
        }
    }

    func requiredWidth() -> CGFloat {
        fittingSize.width
    }
}

@MainActor
private final class StatusItemEventView: NSView {
    var onPrimaryClick: (() -> Void)?
    var onSecondaryClick: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onPrimaryClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onSecondaryClick?(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 1 {
            onSecondaryClick?(event)
        } else {
            super.otherMouseDown(with: event)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Constants {
        static let popoverSizeExpanded = NSSize(width: 820, height: 720)
        static let popoverSizeCompact = NSSize(width: 820, height: 680)
        static let minimumStatusItemLength: CGFloat = 28
        static let maximumStatusItemLength: CGFloat = 760
        static let maximumAdaptiveStatusItemLength: CGFloat = 430
        static let maximumStatusItemScreenFraction: CGFloat = 0.36
        static let statusItemContentPadding: CGFloat = 6
        static let popoverScreenMargin: CGFloat = 8
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
    private var statusItemEventMonitor: Any?
    private var globalStatusItemEventMonitor: Any?
    private var settingsWindow: NSWindow?
    private var pinnedPopoverMinX: CGFloat?
    private var pinnedPopoverTopY: CGFloat?
    private var suppressPrimaryClickUntil = Date.distantPast

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
        if let statusItemEventMonitor {
            NSEvent.removeMonitor(statusItemEventMonitor)
            self.statusItemEventMonitor = nil
        }
        if let globalStatusItemEventMonitor {
            NSEvent.removeMonitor(globalStatusItemEventMonitor)
            self.globalStatusItemEventMonitor = nil
        }
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
        button.sendAction(on: [.leftMouseUp, .rightMouseDown])
        button.lineBreakMode = .byTruncatingTail
        button.image = nil
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        installStatusItemEventMonitor()

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

        let eventView = StatusItemEventView(frame: .zero)
        eventView.onPrimaryClick = { [weak self] in
            self?.togglePopoverFromStatusItem()
        }
        eventView.onSecondaryClick = { [weak self] event in
            self?.showStatusMenu(for: event)
        }
        button.addSubview(eventView)
        NSLayoutConstraint.activate([
            eventView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            eventView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            eventView.topAnchor.constraint(equalTo: button.topAnchor),
            eventView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])

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

    private func installStatusItemEventMonitor() {
        guard statusItemEventMonitor == nil else { return }
        statusItemEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            guard self.eventHitsStatusItemButton(event) else { return event }

            if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                self.showStatusMenuFromStatusItem()
                return nil
            }

            return event
        }

        globalStatusItemEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.mouseLocationHitsStatusItemButton() else { return }
                self.showStatusMenuFromStatusItem()
            }
        }
    }

    private func eventHitsStatusItemButton(_ event: NSEvent) -> Bool {
        guard let button = statusItem?.button, event.window === button.window else {
            return false
        }

        let point = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(point)
    }

    private func mouseLocationHitsStatusItemButton() -> Bool {
        guard let button = statusItem?.button, let window = button.window else {
            return false
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = window.convertToScreen(buttonFrameInWindow)
        return buttonFrameOnScreen.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
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

        if NSApp.currentEvent?.type == .rightMouseDown {
            if let button = statusItem?.button, let event = NSApp.currentEvent {
                showStatusMenu(for: event, in: button)
            } else {
                showStatusMenuForCurrentEvent()
            }
            return
        }

        togglePopoverFromStatusItem()
    }

    private func togglePopoverFromStatusItem() {
        guard Date() >= suppressPrimaryClickUntil else { return }

        if popover.isShown {
            pinnedPopoverMinX = nil
            pinnedPopoverTopY = nil
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showStatusMenuForCurrentEvent() {
        guard let button = statusItem?.button, let event = NSApp.currentEvent else { return }
        showStatusMenu(for: event, in: button)
    }

    private func showStatusMenu(for event: NSEvent) {
        guard let button = statusItem?.button else { return }
        showStatusMenu(for: event, in: button)
    }

    private func showStatusMenuFromStatusItem() {
        guard let button = statusItem?.button else { return }
        suppressPrimaryClickUntil = Date().addingTimeInterval(0.45)
        if popover.isShown {
            pinnedPopoverMinX = nil
            pinnedPopoverTopY = nil
            popover.performClose(nil)
        }
        updateStatusMenu()
        statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    private func showStatusMenu(for event: NSEvent, in button: NSStatusBarButton) {
        if popover.isShown {
            pinnedPopoverMinX = nil
            pinnedPopoverTopY = nil
            popover.performClose(nil)
        }
        updateStatusMenu()
        NSMenu.popUpContextMenu(statusMenu, with: event, for: button)
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
            window.isOpaque = false
            window.backgroundColor = .clear
            let clampedOrigin = clampedPopoverOrigin(for: window.frame, on: screenForPopover(window: window))
            window.setFrameOrigin(clampedOrigin)
            pinnedPopoverMinX = clampedOrigin.x
            pinnedPopoverTopY = clampedOrigin.y + window.frame.height
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
        let screenFrame = screenForPopover(window: nil)?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maxWidth = (screenFrame?.width ?? Constants.popoverSizeCompact.width) - (Constants.popoverScreenMargin * 2)
        let maxHeight = (screenFrame?.height ?? Constants.popoverSizeCompact.height) - (Constants.popoverScreenMargin * 2)
        popover.contentSize = NSSize(
            width: min(Constants.popoverSizeCompact.width, max(Constants.minimumStatusItemLength, maxWidth)),
            height: min(Constants.popoverSizeCompact.height, max(Constants.minimumStatusItemLength, maxHeight))
        )
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

        var textByMetric = visibleMetrics.reduce(into: [MenuBarViewModel.TrayMetric: String]()) { partial, metric in
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
            let maximumLength = maximumStatusItemLength()
            var measuredWidth = ceil((statusItemContentView?.requiredWidth() ?? 0) + Constants.statusItemContentPadding)
            var targetWidth = measuredWidth

            if measuredWidth > maximumLength {
                textByMetric = visibleMetrics.reduce(into: [MenuBarViewModel.TrayMetric: String]()) { partial, metric in
                    partial[metric] = viewModel.compactTrayText(for: metric)
                }
                statusItemContentView?.update(
                    orderedMetrics: visibleMetrics,
                    textByMetric: textByMetric,
                    showHighRefreshBadge: viewModel.highRefreshEnabled
                )
                measuredWidth = ceil((statusItemContentView?.requiredWidth() ?? 0) + Constants.statusItemContentPadding)
                targetWidth = min(measuredWidth, Constants.maximumStatusItemLength)
            }

            statusItem?.length = max(targetWidth, Constants.minimumStatusItemLength)
        }
        statusItem?.button?.needsLayout = true
        pinPopoverPositionIfNeeded()
    }

    private func pinPopoverPositionIfNeeded() {
        guard popover.isShown else { return }
        guard let targetMinX = pinnedPopoverMinX, let targetTopY = pinnedPopoverTopY else { return }
        guard let window = popover.contentViewController?.view.window else { return }
        let requestedOrigin = NSPoint(x: targetMinX, y: targetTopY - window.frame.height)
        let requestedFrame = NSRect(origin: requestedOrigin, size: window.frame.size)
        let targetOrigin = clampedPopoverOrigin(for: requestedFrame, on: screenForPopover(window: window))
        if window.frame.origin != targetOrigin {
            window.setFrameOrigin(targetOrigin)
        }
    }

    private func maximumStatusItemLength() -> CGFloat {
        let screenWidth = screenForPopover(window: nil)?.visibleFrame.width ?? Constants.maximumStatusItemLength
        let adaptiveLength = min(
            Constants.maximumAdaptiveStatusItemLength,
            screenWidth * Constants.maximumStatusItemScreenFraction
        )
        return min(Constants.maximumStatusItemLength, max(Constants.minimumStatusItemLength, adaptiveLength))
    }

    private func screenForPopover(window: NSWindow?) -> NSScreen? {
        window?.screen ?? statusItem?.button?.window?.screen ?? NSScreen.main
    }

    private func clampedPopoverOrigin(for frame: NSRect, on screen: NSScreen?) -> NSPoint {
        guard let screen else { return frame.origin }

        let visibleFrame = screen.visibleFrame.insetBy(
            dx: Constants.popoverScreenMargin,
            dy: Constants.popoverScreenMargin
        )
        let minX = visibleFrame.minX
        let maxX = max(minX, visibleFrame.maxX - frame.width)
        let minY = visibleFrame.minY
        let maxY = max(minY, visibleFrame.maxY - frame.height)

        return NSPoint(
            x: min(max(frame.minX, minX), maxX),
            y: min(max(frame.minY, minY), maxY)
        )
    }

}
