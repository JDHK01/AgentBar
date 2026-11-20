import AppKit
import AgentBarCore
import SwiftUI
import UserNotifications

@MainActor
final class AgentBarAppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private var model: AppModel!
    private var statusController: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let appModel = AppModel()
        self.model = appModel
        self.statusController = StatusBarController(model: appModel)

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let reqID = response.notification.request.identifier
        if let session = model.sessions.first(where: { $0.pendingApproval?.requestID == reqID }) {
            switch response.actionIdentifier {
            case "APPROVE":
                model.requestApprove(session, bypassHighRiskCheck: false)
            case "DENY":
                model.requestDeny(session, reason: "从系统通知拒绝")
            default:
                break
            }
        }
        completionHandler()
    }
}

@main
enum AgentBarMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--render-readme-shots"), args.indices.contains(idx + 1) {
            setenv("AGENTBAR_GENERIC_HOSTNAME", "1", 1)
            let outDir = args[idx + 1]
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            ReadmeScreenshotRenderer.renderAll(to: outDir)
            return
        }
        let app = NSApplication.shared
        let delegate = AgentBarAppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
private enum ReadmeScreenshotRenderer {
    static func renderAll(to outputDir: String) {
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        NSApp.activate(ignoringOtherApps: true)

        let collapsedModel = AppModel(showcaseOverview: false)
        collapsedModel.sessions.removeAll { $0.id == "demo:ssh1:codex-fail" }
        collapsedModel.expandedSessionIDs = []
        collapsedModel.isAllConversationsExpanded = false
        renderShot(
            model: collapsedModel,
            height: 758,
            outputPath: (outputDir as NSString).appendingPathComponent("sessions-panel.png")
        )

        let expandedModel = AppModel(showcaseOverview: false)
        expandedModel.balanceReadings = []
        expandedModel.selectedCategory = nil
        expandedModel.isAllConversationsExpanded = true
        expandedModel.expandedSessionIDs = ["demo:codex:acmecore-test"]
        expandedModel.sessions = expandedModel.sessions.filter {
            ["demo:codex:acmecore-test", "demo:claude:acmecore", "demo:dsh:aurora-ui", "demo:cursor:data-pipeline", "demo:ssh1:claude"].contains($0.id)
        }.map { session in
            var copy = session
            if copy.id == "demo:dsh:aurora-ui" {
                copy.status = .waitingForInput
                copy.isSeen = true
            }
            return copy
        }
        renderShot(
            model: expandedModel,
            height: 775,
            outputPath: (outputDir as NSString).appendingPathComponent("sessions-expanded.png")
        )

        let overviewModel = AppModel(showcaseOverview: true)
        renderShot(
            model: overviewModel,
            height: 690,
            outputPath: (outputDir as NSString).appendingPathComponent("overview-dashboard.png")
        )
    }

    private static func renderShot(model: AppModel, height: CGFloat, outputPath: String) {
        let badgeNSImage = MenuBarBadgeRenderer.renderStatusImage(
            counts: model.menuBarCounts,
            totalSessionCount: model.sessions.count,
            style: .multiDot,
            isDarkMenuBar: true
        )
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 860)
        let canvasWidth: CGFloat = 520
        let canvasHeight: CGFloat = height + 82
        let originX = round(visibleFrame.midX - canvasWidth / 2.0)
        let originY = round(visibleFrame.midY - canvasHeight / 2.0)
        let backdropRect = NSRect(x: originX, y: originY, width: canvasWidth, height: canvasHeight)

        let wallpaperRoot = ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.18, blue: 0.32),
                    Color(red: 0.44, green: 0.36, blue: 0.48),
                    Color(red: 0.92, green: 0.86, blue: 0.80)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(Color(red: 0.98, green: 0.64, blue: 0.38).opacity(0.55))
                    .frame(width: 280, height: 280)
                    .blur(radius: 52)
                    .offset(x: 40, y: 10)
            }
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color(red: 0.26, green: 0.62, blue: 0.96).opacity(0.52))
                    .frame(width: 300, height: 300)
                    .blur(radius: 58)
                    .offset(x: -50, y: -40)
            }
            .overlay(alignment: .bottomLeading) {
                Circle()
                    .fill(Color(red: 0.32, green: 0.82, blue: 0.74).opacity(0.45))
                    .frame(width: 280, height: 280)
                    .blur(radius: 50)
                    .offset(x: 20, y: 30)
            }

            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 12, weight: .semibold))
                    Text("AgentBar")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.90))
                Spacer()
                HStack(spacing: 12) {
                    Image(nsImage: badgeNSImage)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule()
                                .fill(.black.opacity(0.28))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.32), lineWidth: 0.6))
                        )
                    Image(systemName: "wifi")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    Text("14:28")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(.black.opacity(0.36))
        }
        .frame(width: canvasWidth, height: canvasHeight)

        let backdropWin = NSWindow(
            contentRect: backdropRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        backdropWin.level = .floating
        backdropWin.isOpaque = true
        backdropWin.hasShadow = false
        backdropWin.contentView = NSHostingView(rootView: wallpaperRoot)
        backdropWin.orderFrontRegardless()

        let pad: CGFloat = 28
        let glassScreenX = originX + round((canvasWidth - PanelView.panelWidth) / 2.0)
        let glassScreenY = originY + 20
        let panelOuterRect = NSRect(
            x: glassScreenX - pad,
            y: glassScreenY - pad,
            width: PanelView.panelWidth + pad * 2,
            height: height + pad * 2
        )

        let panel = FloatingGlassPanel(
            contentRect: panelOuterRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .aqua)

        let hostContainer = ClearGlassHostView(
            frame: NSRect(origin: .zero, size: panelOuterRect.size),
            cornerRadius: 22
        )
        let glassView = NSGlassEffectView(
            frame: NSRect(x: pad, y: pad, width: PanelView.panelWidth, height: height)
        )
        glassView.style = .regular
        glassView.cornerRadius = 22

        let panelHost = NSHostingView(rootView: PanelView(model: model, onOpenSettings: {}))
        panelHost.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView = panelHost
        if let cv = glassView.contentView {
            NSLayoutConstraint.activate([
                cv.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
                cv.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
                cv.topAnchor.constraint(equalTo: glassView.topAnchor),
                cv.bottomAnchor.constraint(equalTo: glassView.bottomAnchor)
            ])
        }
        hostContainer.addSubview(glassView)
        hostContainer.glassSubView = glassView
        panel.contentView = hostContainer
        panel.makeKeyAndOrderFront(nil)
        panel.setFrame(panelOuterRect, display: true)
        backdropWin.setFrame(backdropRect, display: true)

        for _ in 0..<12 {
            hostContainer.layoutSubtreeIfNeeded()
            backdropWin.displayIfNeeded()
            panel.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? visibleFrame.maxY
        let quartzX = Int(backdropRect.minX)
        let quartzY = Int(primaryHeight - backdropRect.maxY)
        let quartzW = Int(backdropRect.width)
        let quartzH = Int(backdropRect.height)

        let cap = Process()
        cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        cap.arguments = ["-x", "-R", "\(quartzX),\(quartzY),\(quartzW),\(quartzH)", outputPath]
        try? cap.run()
        cap.waitUntilExit()

        panel.orderOut(nil)
        backdropWin.orderOut(nil)
    }
}
