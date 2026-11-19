import AppKit
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
        let app = NSApplication.shared
        let delegate = AgentBarAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
