import AppKit
import Combine
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private enum Constants {
        static let popoverSizeExpanded = NSSize(width: 860, height: 620)
        static let popoverSizeCompact = NSSize(width: 860, height: 620)
        static let minimumStatusItemLength: CGFloat = 28
        static let statusItemHorizontalPadding: CGFloat = 8
        static let miniStatusItemHorizontalPadding: CGFloat = 4
        static let statusItemClipAllowance: CGFloat = 3
        static let minimumPopoverWidth: CGFloat = 648
        static let minimumPopoverHeight: CGFloat = 420
        static let popoverScreenMargin: CGFloat = 8
        static let fallbackStatusTitle = "…"
        static let miniStatusLabelValueGap: CGFloat = 4
        static let miniStatusMinimumGroupGap: CGFloat = 6
    }

    let viewModel = MenuBarViewModel()
    private lazy var popoverUpdates = PopoverUpdateRelay(viewModel: viewModel)
    private let responsivenessLog = Logger(subsystem: "com.klovinad.MacResourceBar", category: "Responsiveness")
    private let popover = NSPopover()
    private let statusMenu = NSMenu()
    private var statusItem: NSStatusItem?
    private var renderedStatusItemKey: String?
    private var renderedStatusItemToolTip: String?
    private var renderedStatusItemAccessibilityValue: String?
    private var appliedStatusItemLength: CGFloat?
    private var statusGraphicView: MenuBarGraphicView?
    private var cachedGraphicPresentation: (
        style: MenuBarViewModel.MenuBarLabelStyle,
        entries: [MenuBarGraphicEntry],
        maximumWidth: CGFloat,
        presentation: StatusItemPresentation
    )?
    private var menuBarTitleObserver: AnyCancellable?
    private var trayOrderingObserver: AnyCancellable?
    private var settingsObserver: NSObjectProtocol?
    private var statusItemEventMonitor: Any?
    private var globalStatusItemEventMonitor: Any?
    private var popoverDismissEventMonitor: Any?
    private var globalPopoverDismissEventMonitor: Any?
    private var settingsWindow: NSWindow?
    private var pinnedPopoverMinX: CGFloat?
    private var pinnedPopoverTopY: CGFloat?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configurePopover()
        bindViewModel()
        observeSettingsRequests()
        ensureStatusItem()
        if CommandLine.arguments.contains("--show-popover") {
            showPopover()
        }
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
        removePopoverDismissEventMonitor()
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
        // Native drag sessions are one of the interactions for which AppKit's
        // transient-popover closing behavior is intentionally unspecified.
        // Own dismissal so a metric can be dropped before the popover closes.
        popover.behavior = .applicationDefined
        // The panel should feel immediate and stable; the previous popover
        // animation visibly lagged behind rapid menu-bar updates.
        popover.animates = false
        popover.delegate = self
        popover.contentSize = Constants.popoverSizeExpanded
    }

    func popoverDidClose(_ notification: Notification) {
        responsivenessLog.info("Popover closed")
        removePopoverDismissEventMonitor()
        pinnedPopoverMinX = nil
        pinnedPopoverTopY = nil
        viewModel.setPopoverVisible(false)
        // Keep the laid-out panel for fast reopening. Its relay suppresses
        // model invalidations while hidden, so the table does no idle work.
        popoverUpdates.isActive = false
        updateStatusItemTitle()
        clearStatusItemHighlight()
        DispatchQueue.main.async { [weak self] in
            self?.clearStatusItemHighlight()
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        statusItem = item
        item.autosaveName = nil
        item.behavior = []
        item.isVisible = true
        configureStatusMenu()
        button.target = self
        button.action = #selector(activateStatusItem(_:))
        button.sendAction(on: [.leftMouseUp])
        if let buttonCell = button.cell as? NSButtonCell {
            buttonCell.highlightsBy = []
            buttonCell.showsStateBy = []
            // Tab-aligned Mini titles must always remain one physical line.
            // Without single-line mode AppKit can reflow the title after the
            // popover detaches, placing it below the menu bar's clip rect.
            buttonCell.wraps = false
            buttonCell.usesSingleLineMode = true
            buttonCell.lineBreakMode = .byClipping
        }
        button.lineBreakMode = .byClipping
        button.alignment = .left
        button.image = nil
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.setAccessibilityLabel("MacResourceBar")

        installStatusItemEventMonitor()
        updateStatusItemTitle()
    }

    private func ensureStatusItem() {
        if let button = statusItem?.button, button.window != nil {
            return
        }

        if let existingItem = statusItem {
            NSStatusBar.system.removeStatusItem(existingItem)
            statusItem = nil
            renderedStatusItemKey = nil
            renderedStatusItemToolTip = nil
            renderedStatusItemAccessibilityValue = nil
            appliedStatusItemLength = nil
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
        statusItemEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            guard self.eventHitsStatusItemButton(event) else { return event }
            self.showStatusMenuFromStatusItem()
            return nil
        }

        globalStatusItemEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            let screenPoint = event.locationInWindow
            Task { @MainActor [weak self] in
                guard let self, self.screenPointHitsStatusItemButton(screenPoint) else { return }
                self.showStatusMenuFromStatusItem()
            }
        }
    }

    private func installPopoverDismissEventMonitor() {
        guard popoverDismissEventMonitor == nil else { return }

        popoverDismissEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self, self.popover.isShown else { return event }

            if event.type == .keyDown, event.keyCode == 53 {
                self.popover.performClose(nil)
                return nil
            }

            if event.type == .leftMouseUp
                || event.type == .rightMouseUp
                || event.type == .otherMouseUp
            {
                let popoverWindow = self.popover.contentViewController?.view.window
                let statusItemWindow = self.statusItem?.button?.window
                if let eventWindow = event.window,
                   eventWindow !== popoverWindow,
                   eventWindow !== statusItemWindow
                {
                    self.popover.performClose(nil)
                }
            }
            return event
        }

        globalPopoverDismissEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] event in
            let screenPoint = event.locationInWindow
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                guard !self.screenPointHitsStatusItemButton(screenPoint) else { return }
                guard !self.screenPointHitsPopover(screenPoint) else { return }
                self.popover.performClose(nil)
            }
        }
    }

    private func removePopoverDismissEventMonitor() {
        if let popoverDismissEventMonitor {
            NSEvent.removeMonitor(popoverDismissEventMonitor)
            self.popoverDismissEventMonitor = nil
        }
        if let globalPopoverDismissEventMonitor {
            NSEvent.removeMonitor(globalPopoverDismissEventMonitor)
            self.globalPopoverDismissEventMonitor = nil
        }
    }

    private func eventHitsStatusItemButton(_ event: NSEvent) -> Bool {
        guard let button = statusItem?.button, event.window === button.window else {
            return false
        }

        let point = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(point)
    }

    private func screenPointHitsStatusItemButton(_ screenPoint: NSPoint) -> Bool {
        guard let button = statusItem?.button, let window = button.window else {
            return false
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = window.convertToScreen(buttonFrameInWindow)
        return buttonFrameOnScreen.insetBy(dx: -2, dy: -2).contains(screenPoint)
    }

    private func screenPointHitsPopover(_ screenPoint: NSPoint) -> Bool {
        guard let window = popover.contentViewController?.view.window else {
            return false
        }
        return window.frame.contains(screenPoint)
    }

    private func bindViewModel() {
        menuBarTitleObserver = viewModel.$menuBarTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemTitle()
            }

        let externalDiskStructure = viewModel.$externalDiskActivities
            .map { activities in
                activities.map { "\($0.bsdName)|\($0.displayName)" }
            }
            .removeDuplicates()

        trayOrderingObserver = viewModel.$trayMetricOrder
            .removeDuplicates()
            .combineLatest(
                viewModel.$selectedTrayMetrics.removeDuplicates(),
                externalDiskStructure,
                viewModel.$menuBarLabelStyle.removeDuplicates()
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.updateStatusItemTitle(force: true)
            }
    }

    private func togglePopoverFromStatusItem() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    @objc
    private func activateStatusItem(_ sender: AnyObject?) {
        if NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showStatusMenuForCurrentEvent()
        } else {
            togglePopoverFromStatusItem()
        }
    }

    private func showStatusMenuForCurrentEvent() {
        guard let button = statusItem?.button, let event = NSApp.currentEvent else { return }
        showStatusMenu(for: event, in: button)
    }

    private func showStatusMenuFromStatusItem() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        }
        updateStatusMenu()
        statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    private func showStatusMenu(for event: NSEvent, in button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        }
        updateStatusMenu()
        NSMenu.popUpContextMenu(statusMenu, with: event, for: button)
    }

    @objc
    private func togglePopoverFromMenu(_ sender: AnyObject?) {
        if popover.isShown {
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
        if let message = viewModel.settingsErrorMessage {
            let alert = NSAlert()
            alert.messageText = "Launch at Login"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc
    private func toggleHighRefreshFromMenu(_ sender: AnyObject?) {
        viewModel.setHighRefreshEnabled(!viewModel.highRefreshEnabled)
        updateStatusMenu()
        updateStatusItemTitle()
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
        if popover.isShown {
            popover.performClose(nil)
        }

        if let settingsWindow {
            viewModel.setSettingsVisible(true)
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        let window = NSWindow(contentViewController: controller)
        window.title = "MacResourceBar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 520, height: 560))
        window.minSize = NSSize(width: 500, height: 520)
        window.center()
        settingsWindow = window
        viewModel.setSettingsVisible(true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        viewModel.setSettingsVisible(false)
        settingsWindow?.contentViewController = nil
        settingsWindow = nil
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        viewModel.setSettingsVisible(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        viewModel.setSettingsVisible(true)
    }

    private func showPopover() {
        guard !popover.isShown else { return }
        let started = ProcessInfo.processInfo.systemUptime
        let reused = popover.contentViewController != nil
        defer {
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            responsivenessLog.info("Popover layout: \(milliseconds, privacy: .public) ms; reused: \(reused, privacy: .public)")
        }
        ensureStatusItem()
        guard let button = statusItem?.button else { return }

        popoverUpdates.isActive = true
        attachPopoverContentIfNeeded()
        updatePopoverSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installPopoverDismissEventMonitor()
        if let window = popover.contentViewController?.view.window {
            let origin = clampedPopoverOrigin(
                for: window.frame,
                on: screenForPopover(window: window)
            )
            window.setFrameOrigin(origin)
            pinnedPopoverMinX = origin.x
            pinnedPopoverTopY = origin.y + window.frame.height
        } else {
            pinnedPopoverMinX = nil
            pinnedPopoverTopY = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        viewModel.setPopoverVisible(true)
        // A selected status item is drawn on the system highlight pill. Use
        // the matching semantic menu-item foreground while that pill is
        // visible instead of inheriting the lower-alpha label color.
        updateStatusItemTitle(force: true)
        clearStatusItemHighlight()
        DispatchQueue.main.async { [weak self] in
            self?.clearStatusItemHighlight()
        }
    }

    private func attachPopoverContentIfNeeded() {
        guard popover.contentViewController == nil else { return }
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(viewModel: viewModel, updates: popoverUpdates)
        )
    }

    private func updatePopoverSize() {
        let screenFrame = screenForPopover(window: nil)?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maxWidth = (screenFrame?.width ?? Constants.popoverSizeCompact.width) - (Constants.popoverScreenMargin * 2)
        let maxHeight = (screenFrame?.height ?? Constants.popoverSizeCompact.height) - (Constants.popoverScreenMargin * 2)
        popover.contentSize = NSSize(
            width: min(
                maxWidth,
                max(Constants.minimumPopoverWidth, min(Constants.popoverSizeCompact.width, maxWidth))
            ),
            height: min(
                maxHeight,
                max(Constants.minimumPopoverHeight, min(Constants.popoverSizeCompact.height, maxHeight))
            )
        )
    }

    private struct StatusItemPresentation {
        let effectiveStyle: MenuBarViewModel.MenuBarLabelStyle
        let title: NSAttributedString
        let length: CGFloat
        var graphicLayout: MenuBarGraphicRenderer.Layout? = nil
        var graphicImage: NSImage? = nil
        var hiddenCount = 0
    }

    private func updateStatusItemTitle(force: Bool = false) {
        guard let item = statusItem, let button = item.button else { return }

        let preferredStyle = viewModel.menuBarLabelStyle
        let basePresentation = statusItemPresentation(preferredStyle: preferredStyle)
        let usesSelectedForeground = popover.isShown
        let presentation: StatusItemPresentation
        if usesSelectedForeground, basePresentation.graphicLayout == nil {
            let title = NSMutableAttributedString(attributedString: basePresentation.title)
            title.addAttribute(
                .foregroundColor,
                value: NSColor.selectedMenuItemTextColor,
                range: NSRange(location: 0, length: title.length)
            )
            presentation = StatusItemPresentation(
                effectiveStyle: basePresentation.effectiveStyle,
                title: title,
                length: basePresentation.length,
                hiddenCount: basePresentation.hiddenCount
            )
        } else {
            presentation = basePresentation
        }
        // Include attributed layout and reserved width, not only visible text.
        // Mini can keep the same characters while its tab stops change after a
        // disk is connected, renamed, or reordered.
        let titleKey = "\(usesSelectedForeground)|\(presentation.effectiveStyle.rawValue)|\(presentation.length)|\(presentation.title.hash)|\(presentation.title.string)"
        var lengthChanged = false

        if renderedStatusItemKey != titleKey {
            button.attributedTitle = presentation.title
            renderedStatusItemKey = titleKey
        }

        if appliedStatusItemLength.map({ abs($0 - presentation.length) > 0.5 }) ?? true {
            item.length = presentation.length
            appliedStatusItemLength = presentation.length
            lengthChanged = true
        }

        if let layout = presentation.graphicLayout {
            // A real cell image keeps AppKit's status-item tracking area alive
            // when the title is empty. The overlay supplies readable contrast.
            if button.image !== presentation.graphicImage {
                button.image = presentation.graphicImage
            }
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            if statusGraphicView?.superview !== button {
                statusGraphicView?.removeFromSuperview()
                let drawing = MenuBarGraphicView(frame: button.bounds)
                button.addSubview(drawing)
                statusGraphicView = drawing
            }
            statusGraphicView?.isHidden = false
            statusGraphicView?.apply(layout)
        } else {
            button.image = nil
            button.imagePosition = .noImage
            statusGraphicView?.isHidden = true
        }

        let accessibilityValue = viewModel.menuBarAccessibilityComponents.joined(separator: ", ")
        if renderedStatusItemAccessibilityValue != accessibilityValue {
            button.setAccessibilityValue(accessibilityValue)
            renderedStatusItemAccessibilityValue = accessibilityValue
        }

        var toolTipLines = [
            viewModel.menuBarAccessibilityComponents.joined(separator: " · "),
            viewModel.highRefreshEnabled ? "Updates every second" : "Updates every 10 seconds"
        ]
        if presentation.hiddenCount > 0 {
            toolTipLines.append("\(presentation.hiddenCount) more values in the panel")
        }
        let toolTip = toolTipLines.joined(separator: "\n")
        if renderedStatusItemToolTip != toolTip {
            button.toolTip = toolTip
            renderedStatusItemToolTip = toolTip
        }

        guard popover.isShown, lengthChanged || force else { return }
        pinPopoverPositionIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.pinPopoverPositionIfNeeded()
        }
    }

    private func statusItemPresentation(
        preferredStyle: MenuBarViewModel.MenuBarLabelStyle
    ) -> StatusItemPresentation {
        if let graphicStyle = preferredStyle.graphicStyle {
            let entries = viewModel.menuBarGraphicEntries(for: preferredStyle)
            let maximumWidth = maximumStatusItemLength() - 4
            if let cached = cachedGraphicPresentation, cached.style == preferredStyle,
               cached.entries == entries, cached.maximumWidth == maximumWidth {
                return cached.presentation
            }
            let layout = MenuBarGraphicRenderer.layout(entries: entries, style: graphicStyle, maximumWidth: maximumWidth)
            let presentation = StatusItemPresentation(
                effectiveStyle: preferredStyle, title: NSAttributedString(string: ""),
                length: max(Constants.minimumStatusItemLength, layout.size.width + 4),
                graphicLayout: layout, graphicImage: MenuBarGraphicRenderer.image(for: layout),
                hiddenCount: layout.hiddenCount
            )
            cachedGraphicPresentation = (preferredStyle, entries, maximumWidth, presentation)
            return presentation
        }
        // Respect the selected format even when it needs an overflow indicator.
        // Falling through Full -> Compact -> Mini made different selections
        // display the same text on narrower menu bars.
        let style = preferredStyle
        let maximumLength = maximumStatusItemLength()
        let separator = viewModel.menuBarComponentSeparator(for: style)
        let slots = viewModel.menuBarDisplaySlots(for: style)
        let title: NSAttributedString
        let contentWidth: CGFloat
        if style == .mini, let miniLayout = miniStatusItemTitle(slots: slots) {
            title = miniLayout.title
            contentWidth = miniLayout.width
        } else {
            title = statusItemTitle(
                components: slots.map {
                    stableStatusItemComponent(text: $0.text, widthTemplate: $0.widthTemplate)
                },
                separator: separator,
                style: style
            )
            let template = statusItemTitle(
                components: slots.map(\.widthTemplate),
                separator: separator,
                style: style
            )
            contentWidth = max(template.size().width, title.size().width)
        }
        let naturalLength = max(
            Constants.minimumStatusItemLength,
            ceil(contentWidth)
                + (style == .mini
                    ? Constants.miniStatusItemHorizontalPadding
                    : Constants.statusItemHorizontalPadding)
                + Constants.statusItemClipAllowance
        )
        if naturalLength <= maximumLength {
            return StatusItemPresentation(
                effectiveStyle: style, title: title, length: naturalLength
            )
        }
        return overflowStatusItemPresentation(
            from: slots, style: style, maximumLength: maximumLength
        )
    }

    private func overflowStatusItemPresentation(
        from slots: [MenuBarViewModel.MenuBarDisplaySlot],
        style: MenuBarViewModel.MenuBarLabelStyle,
        maximumLength: CGFloat
    ) -> StatusItemPresentation {
        guard !slots.isEmpty else {
            return StatusItemPresentation(
                effectiveStyle: style,
                title: NSAttributedString(string: Constants.fallbackStatusTitle),
                length: min(Constants.minimumStatusItemLength, maximumLength)
            )
        }

        for visibleCount in stride(from: slots.count - 1, through: 0, by: -1) {
            // Keep both network directions visible or move both into overflow.
            if visibleCount > 0, let pairID = slots[visibleCount - 1].pairID,
               slots[visibleCount].pairID == pairID { continue }
            let hiddenCount = slots.count - visibleCount
            var candidateSlots = Array(slots.prefix(visibleCount))
            if hiddenCount > 0 {
                candidateSlots.append(MenuBarViewModel.MenuBarDisplaySlot(
                    id: "overflow-count",
                    text: "+\(hiddenCount)",
                    widthTemplate: "+99"
                ))
            }

            let title: NSAttributedString
            let contentWidth: CGFloat
            if style == .mini, let miniLayout = miniStatusItemTitle(slots: candidateSlots) {
                title = miniLayout.title
                contentWidth = miniLayout.width
            } else {
                let separator = viewModel.menuBarComponentSeparator(for: style)
                title = statusItemTitle(
                    components: candidateSlots.map {
                        stableStatusItemComponent(text: $0.text, widthTemplate: $0.widthTemplate)
                    },
                    separator: separator,
                    style: style
                )
                let template = statusItemTitle(
                    components: candidateSlots.map(\.widthTemplate),
                    separator: separator,
                    style: style
                )
                contentWidth = max(title.size().width, template.size().width)
            }

            let length = ceil(contentWidth)
                + (style == .mini
                    ? Constants.miniStatusItemHorizontalPadding
                    : Constants.statusItemHorizontalPadding)
                + Constants.statusItemClipAllowance
            if length <= maximumLength {
                return StatusItemPresentation(
                    effectiveStyle: style,
                    title: title,
                    length: max(min(length, maximumLength), Constants.minimumStatusItemLength),
                    hiddenCount: hiddenCount
                )
            }
        }

        return StatusItemPresentation(
            effectiveStyle: style,
            title: NSAttributedString(string: Constants.fallbackStatusTitle),
            length: min(Constants.minimumStatusItemLength, maximumLength),
            hiddenCount: slots.count
        )
    }

    private func pinPopoverPositionIfNeeded() {
        guard popover.isShown else { return }
        guard let targetMinX = pinnedPopoverMinX, let targetTopY = pinnedPopoverTopY else { return }
        guard let window = popover.contentViewController?.view.window else { return }

        let requestedOrigin = NSPoint(
            x: targetMinX,
            y: targetTopY - window.frame.height
        )
        let requestedFrame = NSRect(origin: requestedOrigin, size: window.frame.size)
        let targetOrigin = clampedPopoverOrigin(
            for: requestedFrame,
            on: screenForPopover(window: window)
        )
        if window.frame.origin != targetOrigin {
            window.setFrameOrigin(targetOrigin)
        }
    }

    private func statusItemTitle(
        components: [String],
        separator: String,
        style: MenuBarViewModel.MenuBarLabelStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = statusItemFont(for: style)
        let componentAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let separatorAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        for (index, component) in components.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: separator, attributes: separatorAttributes))
            }
            result.append(NSAttributedString(string: component, attributes: componentAttributes))
        }
        return result
    }

    private struct MiniStatusItemLayout {
        let title: NSAttributedString
        let width: CGFloat
    }

    /// Mini keeps a fixed label/value gap and a fixed-width value field for
    /// every slot. Changing digits cannot move any following metric.
    private func miniStatusItemTitle(
        slots: [MenuBarViewModel.MenuBarDisplaySlot]
    ) -> MiniStatusItemLayout? {
        let font = statusItemFont(for: .mini)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let measuredSlots = slots.compactMap { slot -> (
            component: (label: String, value: String),
            labelWidth: CGFloat,
            valueWidth: CGFloat,
            reservedValueWidth: CGFloat
        )? in
            guard
                let component = splitMiniStatusComponent(slot.text),
                let template = splitMiniStatusComponent(slot.widthTemplate)
            else {
                return nil
            }

            let valueWidth = miniStatusTextWidth(component.value, attributes: attributes)
            return (
                component: component,
                labelWidth: miniStatusTextWidth(component.label, attributes: attributes),
                valueWidth: valueWidth,
                reservedValueWidth: max(
                    valueWidth,
                    miniStatusTextWidth(template.value, attributes: attributes)
                )
            )
        }
        guard measuredSlots.count == slots.count, !measuredSlots.isEmpty else { return nil }

        let groupCount = measuredSlots.count - 1
        let reservedWidth = measuredSlots.reduce(CGFloat.zero) { result, slot in
            result
                + slot.labelWidth
                + Constants.miniStatusLabelValueGap
                + slot.reservedValueWidth
        } + (CGFloat(groupCount) * Constants.miniStatusMinimumGroupGap)

        var title = ""
        var tabStops: [NSTextTab] = []
        var currentX: CGFloat = 0

        for (index, slot) in measuredSlots.enumerated() {
            title += slot.component.label
            currentX += slot.labelWidth

            let valueStart = currentX + Constants.miniStatusLabelValueGap
            tabStops.append(NSTextTab(textAlignment: .left, location: valueStart))
            title += "\t\(slot.component.value)"
            currentX = valueStart + slot.valueWidth

            if index < measuredSlots.count - 1 {
                let unusedValueWidth = slot.reservedValueWidth - slot.valueWidth
                let nextLabelStart = currentX
                    + unusedValueWidth
                    + Constants.miniStatusMinimumGroupGap
                tabStops.append(NSTextTab(textAlignment: .left, location: nextLabelStart))
                title += "\t"
                currentX = nextLabelStart
            }
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = 0
        paragraph.lineBreakMode = .byClipping
        paragraph.tabStops = tabStops

        let attributedTitle = NSMutableAttributedString(string: title, attributes: attributes)
        attributedTitle.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: attributedTitle.length)
        )
        return MiniStatusItemLayout(title: attributedTitle, width: reservedWidth)
    }

    private func splitMiniStatusComponent(_ component: String) -> (label: String, value: String)? {
        guard let separatorIndex = component.firstIndex(of: " ") else { return nil }
        let valueStart = component.index(after: separatorIndex)
        return (
            String(component[..<separatorIndex]),
            String(component[valueStart...])
        )
    }

    private func miniStatusTextWidth(
        _ text: String,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        NSAttributedString(string: text, attributes: attributes).size().width
    }

    /// Full and Compact reserve their measured character slots so neither the
    /// status item nor following metrics move as live values change.
    private func stableStatusItemComponent(
        text: String,
        widthTemplate: String
    ) -> String {
        let missingCharacters = max(0, widthTemplate.count - text.count)
        return text + String(repeating: " ", count: missingCharacters)
    }

    private func statusItemFont(
        for style: MenuBarViewModel.MenuBarLabelStyle
    ) -> NSFont {
        switch style {
        case .full:
            NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        case .compact:
            NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        case .mini, .twoLines, .icons:
            NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        }
    }

    private func clearStatusItemHighlight() {
        guard let button = statusItem?.button else { return }
        button.state = .off
        button.highlight(false)
    }

    private func maximumStatusItemLength() -> CGFloat {
        let screenWidth = screenForPopover(window: nil)?.frame.width ?? 1_440
        return max(
            Constants.minimumStatusItemLength,
            min(
                screenWidth - 48,
                min(720, screenWidth * 0.30)
            )
        )
    }

    private func screenForPopover(window: NSWindow?) -> NSScreen? {
        window?.screen ?? statusItem?.button?.window?.screen ?? NSScreen.main
    }

    private func clampedPopoverOrigin(
        for frame: NSRect,
        on screen: NSScreen?
    ) -> NSPoint {
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
