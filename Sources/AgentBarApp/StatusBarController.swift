import AgentBarCore
import AppKit
import SwiftUI

final class FloatingGlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let panel: FloatingGlassPanel
    private let model: AppModel
    private var settingsWindow: NSWindow?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var anchorTopY: CGFloat?
    private var anchorMidX: CGFloat?
    private weak var anchorScreen: NSScreen?
    private var resizeScheduled = false

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let rect = NSRect(x: 0, y: 0, width: PanelView.panelWidth, height: 600)
        self.panel = FloatingGlassPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        configurePanel()
        configureStatusItem()

        model.onStatusBarNeedsUpdate = { [weak self] in
            self?.updateStatusButtonImage()
        }
        model.onPreferredHeightChanged = { [weak self] in
            self?.scheduleResizeVisiblePanel()
        }
        updateStatusButtonImage()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let glassView = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: PanelView.panelWidth, height: 600))
        glassView.style = .regular
        glassView.cornerRadius = 22
        glassView.autoresizingMask = [.width, .height]

        let rootView = PanelView(model: model) { [weak self] in
            self?.openSettingsWindow()
        }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView = hostingView
        if let content = glassView.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
                content.topAnchor.constraint(equalTo: glassView.topAnchor),
                content.bottomAnchor.constraint(equalTo: glassView.bottomAnchor)
            ])
        }
        panel.contentView = glassView
    }

    func updateStatusButtonImage() {
        guard let button = statusItem.button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let img = MenuBarBadgeRenderer.renderStatusImage(
            counts: model.menuBarCounts,
            totalSessionCount: model.sessions.count,
            style: model.menuBarStyle,
            isDarkMenuBar: isDark
        )
        button.image = img
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if panel.isVisible {
            closePanel()
        } else {
            showPanelRelativeToButton(sender)
        }
    }

    private func showPanelRelativeToButton(_ button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonFrameInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        self.anchorMidX = buttonFrameInScreen.midX
        self.anchorTopY = buttonFrameInScreen.minY - 6.0
        self.anchorScreen = buttonWindow.screen ?? NSScreen.main

        let initialFrame = computeTargetPanelFrame()
        panel.setFrame(initialFrame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        let finalFrame = computeTargetPanelFrame()
        panel.setFrame(finalFrame, display: true)
        panel.makeKeyAndOrderFront(nil)
        installDismissMonitors()

        scheduleResizeVisiblePanel()

        Task {
            await model.refreshLocalSessions()
        }
    }

    private func scheduleResizeVisiblePanel() {
        guard panel.isVisible, !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resizeVisiblePanelToFitContent()
        }
    }

    private func resizeVisiblePanelToFitContent() {
        guard panel.isVisible else { return }
        let target = computeTargetPanelFrame()
        if abs(panel.frame.height - target.height) > 1.0 || abs(panel.frame.origin.y - target.origin.y) > 1.0 {
            panel.setFrame(target, display: true, animate: false)
        }
    }

    private func computeTargetPanelFrame() -> NSRect {
        let panelWidth = PanelView.panelWidth
        let screenFrame = anchorScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let topY = anchorTopY ?? (screenFrame.maxY - 6.0)
        let midX = anchorMidX ?? (screenFrame.maxX - panelWidth)

        let maxSpaceBelow = max(320, topY - screenFrame.minY - 12.0)
        let maxAllowedHeight = min(960, maxSpaceBelow)
        let panelHeight = round(min(maxAllowedHeight, max(200, model.preferredPanelHeight)))

        let originX = round(max(screenFrame.minX + 8, min(midX - panelWidth / 2.0, screenFrame.maxX - panelWidth - 8)))
        let originY = round(topY - panelHeight)
        return NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight)
    }

    func closePanel() {
        panel.orderOut(nil)
        removeDismissMonitors()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePanel()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.closePanel()
                return nil
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    func openSettingsWindow() {
        closePanel()
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsWindowView(model: model))
        let win = NSWindow(contentViewController: hosting)
        win.title = "AgentBar 设置"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = win
    }
}
