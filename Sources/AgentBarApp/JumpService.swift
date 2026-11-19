import AgentBarCore
import AppKit
import Foundation

@MainActor
enum JumpService {
    static func jump(to session: AgentSession) {
        switch session.host {
        case .local:
            if session.kind.isCLI {
                jumpToLocalTerminal(session: session)
            } else {
                activateOrLaunchDesktopApp(kind: session.kind, cwd: session.cwd)
            }
        case .ssh(let alias):
            openSSHInTerminal(alias: alias, cwd: session.cwd, resumeCommand: session.resumeCommand)
        }
    }

    static func openDirectory(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func activateOrLaunchDesktopApp(kind: AgentKind, cwd: String?) {
        let ws = NSWorkspace.shared
        for bid in kind.preferredBundleIdentifiers {
            if let running = ws.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
                running.activate()
                return
            }
            if let appURL = ws.urlForApplication(withBundleIdentifier: bid) {
                ws.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        for path in kind.fallbackAppPaths where FileManager.default.fileExists(atPath: path) {
            ws.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if let cwd {
            openDirectory(cwd)
        }
    }

    private static func jumpToLocalTerminal(session: AgentSession) {
        if let tty = session.process?.tty, !tty.isEmpty {
            let fullTTY = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            let scriptSource = """
            tell application "Terminal"
                if it is running then
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(fullTTY)" then
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end if
            end tell
            return "miss"
            """
            if let script = NSAppleScript(source: scriptSource) {
                var err: NSDictionary?
                let out = script.executeAndReturnError(&err)
                if out.stringValue == "ok" {
                    return
                }
            }
        }

        let terminalCandidates = [
            "com.mitchellh.ghostty",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "com.apple.Terminal"
        ]
        for bid in terminalCandidates {
            if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
                running.activate()
                return
            }
        }
        if let cwd = session.cwd, FileManager.default.fileExists(atPath: cwd) {
            let termURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: termURL, configuration: cfg)
        }
    }

    private static func openSSHInTerminal(alias: String, cwd: String?, resumeCommand: String?) {
        if let resumeCommand {
            copyToPasteboard(resumeCommand)
        }
        let safeAlias = alias.replacingOccurrences(of: "\"", with: "")
        let remoteCmd: String
        if let cwd, !cwd.isEmpty {
            let escapedDir = cwd.replacingOccurrences(of: "'", with: "'\\''")
            remoteCmd = "ssh -t \(safeAlias) \"cd '\(escapedDir)' 2>/dev/null; exec \\$SHELL -l\""
        } else {
            remoteCmd = "ssh \(safeAlias)"
        }
        let escapedForAS = remoteCmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = """
        tell application "Terminal"
            activate
            do script "\(escapedForAS)"
        end tell
        """
        if let script = NSAppleScript(source: scriptSource) {
            var err: NSDictionary?
            _ = script.executeAndReturnError(&err)
        }
    }
}
