import AgentBarCore
import AppKit
import Foundation

@MainActor
enum JumpService {
    static var onBeforeJump: (() -> Void)?

    static func jump(to session: AgentSession) {
        onBeforeJump?()
        if let cmd = session.resumeCommand {
            copyToPasteboard(cmd)
        }

        switch session.host {
        case .local:
            jumpToLocal(session: session)
        case .ssh(let alias):
            jumpToRemoteSSH(session: session, alias: alias)
        }
    }

    static func openInCodexThread(sessionID: String) {
        onBeforeJump?()
        let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        if let url = URL(string: "codex://threads/\(encoded)"),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
            forceActivateApp(bundleIDs: ["com.openai.codex", "com.openai.chat"])
            return
        }
        activateOrLaunchDesktopApp(kind: .codexDesktop, cwd: nil)
    }

    static func openInRemoteIDE(alias: String, cwd: String?, preferCursor: Bool = false) -> Bool {
        onBeforeJump?()
        let scheme = preferCursor ? "cursor" : "vscode"
        let fallbackScheme = preferCursor ? "vscode" : "cursor"
        for candidateScheme in [scheme, fallbackScheme] {
            guard let url = buildRemoteSSHIDEURL(scheme: candidateScheme, alias: alias, cwd: cwd),
                  NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
                continue
            }
            NSWorkspace.shared.open(url)
            let bids = candidateScheme == "cursor"
                ? ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"]
                : ["com.microsoft.VSCode", "com.visualstudio.code.oss"]
            forceActivateApp(bundleIDs: bids)
            return true
        }
        return false
    }

    static func canOpenRemoteIDE(preferCursor: Bool = false) -> Bool {
        let schemes = preferCursor ? ["cursor", "vscode"] : ["vscode", "cursor"]
        for s in schemes {
            if let u = URL(string: "\(s)://file/"),
               NSWorkspace.shared.urlForApplication(toOpen: u) != nil {
                return true
            }
        }
        return false
    }

    static func openDirectory(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        onBeforeJump?()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func jumpToLocal(session: AgentSession) {
        switch session.launchEnvironment {
        case .codexApp:
            openInCodexThread(sessionID: session.rawSessionID)
            return
        case .vscodeExtension:
            if openLocalIDEFolder(scheme: "vscode", bundleIDs: ["com.microsoft.VSCode"], cwd: session.cwd) {
                return
            }
        case .cursorExtension:
            if openLocalIDEFolder(scheme: "cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"], cwd: session.cwd) {
                return
            }
        case .traeExtension:
            activateOrLaunchDesktopApp(kind: .trae, cwd: session.cwd)
            return
        case .deepseekHarnessApp:
            if let url = URL(string: "dsh://open"),
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                forceActivateApp(bundleIDs: AgentKind.deepseekHarness.preferredBundleIdentifiers)
                return
            }
            activateOrLaunchDesktopApp(kind: .deepseekHarness, cwd: session.cwd)
            return
        case .terminalCLI, .auto:
            break
        }

        switch session.kind {
        case .codexDesktop:
            openInCodexThread(sessionID: session.rawSessionID)
        case .deepseekHarness:
            if let url = URL(string: "dsh://open"),
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                forceActivateApp(bundleIDs: session.kind.preferredBundleIdentifiers)
                return
            }
            activateOrLaunchDesktopApp(kind: session.kind, cwd: session.cwd)
        case .cursor:
            if !openLocalIDEFolder(scheme: "cursor", bundleIDs: session.kind.preferredBundleIdentifiers, cwd: session.cwd) {
                activateOrLaunchDesktopApp(kind: session.kind, cwd: session.cwd)
            }
        case .trae, .claudeDesktop, .deepseekChat, .doubao:
            activateOrLaunchDesktopApp(kind: session.kind, cwd: session.cwd)
        case .claudeCode, .codexCLI, .generic:
            jumpToLocalTerminal(session: session)
        }
    }

    private static func jumpToRemoteSSH(session: AgentSession, alias: String) {
        let isIDESession = session.launchEnvironment == .vscodeExtension
            || session.launchEnvironment == .cursorExtension
            || isRemoteSSHOpenInLocalVSCode(alias: alias)

        if isIDESession {
            let preferCursor = session.launchEnvironment == .cursorExtension || session.kind == .cursor
            if openInRemoteIDE(alias: alias, cwd: session.cwd, preferCursor: preferCursor) {
                return
            }
        }

        let shouldAutoRunResume = session.process == nil
        openSSHInTerminal(
            alias: alias,
            cwd: session.cwd,
            resumeCommand: session.resumeCommand,
            autoExecuteResume: shouldAutoRunResume
        )
    }

    private static func isRemoteSSHOpenInLocalVSCode(alias: String) -> Bool {
        let runningVSCode = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.microsoft.VSCode" || $0.bundleIdentifier == "com.todesktop.230313mzl4w4u92"
        }
        guard runningVSCode else { return false }
        let storagePath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Code/User/globalStorage/storage.json")
        if let content = try? String(contentsOfFile: storagePath, encoding: .utf8),
           content.contains("ssh-remote+\(alias)") {
            return true
        }
        return false
    }

    private static func buildRemoteSSHIDEURL(scheme: String, alias: String, cwd: String?) -> URL? {
        let encodedAlias = alias.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? alias
        let rawPath = (cwd?.isEmpty == false) ? cwd! : "/"
        let normalizedPath = rawPath.hasPrefix("/") ? rawPath : "/\(rawPath)"
        let encodedPath = normalizedPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { seg in
                String(seg).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(seg)
            }
            .joined(separator: "/")
        return URL(string: "\(scheme)://vscode-remote/ssh-remote+\(encodedAlias)\(encodedPath)")
    }

    private static func openLocalIDEFolder(scheme: String, bundleIDs: [String], cwd: String?) -> Bool {
        if let cwd, !cwd.isEmpty {
            let normalized = cwd.hasPrefix("/") ? cwd : "/\(cwd)"
            let encoded = normalized
                .split(separator: "/", omittingEmptySubsequences: false)
                .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                .joined(separator: "/")
            if let url = URL(string: "\(scheme)://file\(encoded)"),
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                forceActivateApp(bundleIDs: bundleIDs)
                return true
            }
        }
        for bid in bundleIDs {
            if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
                NSApp.deactivate()
                running.activate(options: [.activateAllWindows])
                return true
            }
        }
        return false
    }

    private static func forceActivateApp(bundleIDs: [String]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            for bid in bundleIDs {
                if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
                    running.activate(options: [.activateAllWindows])
                    return
                }
            }
        }
    }

    private static func activateOrLaunchDesktopApp(kind: AgentKind, cwd: String?) {
        let ws = NSWorkspace.shared
        for bid in kind.preferredBundleIdentifiers {
            if let running = ws.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
                NSApp.deactivate()
                running.activate(options: [.activateAllWindows])
                return
            }
            if let appURL = ws.urlForApplication(withBundleIdentifier: bid) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                ws.openApplication(at: appURL, configuration: cfg)
                return
            }
        }
        for path in kind.fallbackAppPaths where FileManager.default.fileExists(atPath: path) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            ws.openApplication(at: URL(fileURLWithPath: path), configuration: cfg)
            return
        }
        if let cwd {
            openDirectory(cwd)
        }
    }

    private static func jumpToLocalTerminal(session: AgentSession) {
        if let tty = session.process?.tty, !tty.isEmpty {
            let fullTTY = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            if focusITermTTY(fullTTY) || focusAppleTerminalTTY(fullTTY) {
                return
            }
            let activeTerminals = [
                "com.mitchellh.ghostty",
                "com.cmuxterm.app",
                "dev.warp.Warp-Stable",
                "com.googlecode.iterm2",
                "com.apple.Terminal"
            ]
            for bid in activeTerminals {
                if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
                    NSApp.deactivate()
                    running.activate(options: [.activateAllWindows])
                    return
                }
            }
        }

        if let resume = session.resumeCommand {
            var lines = ["#!/bin/zsh"]
            if let cwd = session.cwd, !cwd.isEmpty {
                let esc = cwd.replacingOccurrences(of: "'", with: "'\\''")
                lines.append("cd '\(esc)' 2>/dev/null || true")
            }
            lines.append("echo '▶ 正在恢复会话：\(resume)'")
            lines.append("\(resume) || true")
            lines.append("exec \"$SHELL\" -l")
            launchShellScriptInTerminal(lines.joined(separator: "\n"))
            return
        }

        if let cwd = session.cwd, FileManager.default.fileExists(atPath: cwd) {
            let termURL = preferredTerminalAppURL()
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: termURL, configuration: cfg)
        }
    }

    private static func focusITermTTY(_ fullTTY: String) -> Bool {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.googlecode.iterm2" }) else {
            return false
        }
        let src = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(fullTTY)" then
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "miss"
        """
        if let script = NSAppleScript(source: src) {
            var err: NSDictionary?
            let out = script.executeAndReturnError(&err)
            if err == nil, out.stringValue == "ok" {
                return true
            }
        }
        return false
    }

    private static func focusAppleTerminalTTY(_ fullTTY: String) -> Bool {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.Terminal" }) else {
            return false
        }
        let scriptSource = """
        tell application "Terminal"
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
        end tell
        return "miss"
        """
        if let script = NSAppleScript(source: scriptSource) {
            var err: NSDictionary?
            let out = script.executeAndReturnError(&err)
            if err == nil, out.stringValue == "ok" {
                return true
            }
        }
        return false
    }

    static func openSSHInTerminal(
        alias: String,
        cwd: String? = nil,
        resumeCommand: String? = nil,
        autoExecuteResume: Bool = true
    ) {
        onBeforeJump?()
        if let resumeCommand {
            copyToPasteboard(resumeCommand)
        }
        let safeAlias = alias.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
        let muxFlags: String
        if SSHProbeService.hasCustomControlPath(alias: safeAlias) {
            muxFlags = ""
        } else {
            let controlPath = SSHProbeService.sharedControlPathPattern
            muxFlags = "-o ControlMaster=auto -o ControlPath='\(controlPath)' -o ControlPersist=30m "
        }

        var remoteInnerParts: [String] = []
        if let cwd, !cwd.isEmpty {
            let escapedDir = cwd.replacingOccurrences(of: "'", with: "'\\''")
            remoteInnerParts.append("cd '\(escapedDir)' 2>/dev/null || true")
        }
        if let resumeCommand, !resumeCommand.isEmpty {
            if autoExecuteResume {
                let escResume = resumeCommand.replacingOccurrences(of: "'", with: "'\\''")
                remoteInnerParts.append("printf '\\033[1;36m▶ 正在恢复远程会话：%s\\033[0m\\n' '\(escResume)'")
                remoteInnerParts.append("\(resumeCommand) || true")
            } else {
                let escResume = resumeCommand.replacingOccurrences(of: "'", with: "'\\''")
                remoteInnerParts.append("printf '\\033[1;32m✓ 已进入项目目录（恢复命令已复制到剪贴板：%s）\\033[0m\\n' '\(escResume)'")
            }
        }
        remoteInnerParts.append("exec \\$SHELL -l")
        let remoteJoined = remoteInnerParts.joined(separator: "; ")

        let sshLine = "ssh \(muxFlags)-t '\(safeAlias)' \"\(remoteJoined)\""
        let scriptBody = """
        #!/bin/zsh
        \(sshLine)
        """
        launchShellScriptInTerminal(scriptBody)
    }

    private static func launchShellScriptInTerminal(_ scriptContent: String) {
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-jump-\(UUID().uuidString.prefix(8)).command")
        let fullContent = scriptContent + "\nrm -f \"\(scriptURL.path)\" 2>/dev/null || true\n"
        do {
            try Data(fullContent.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return
        }

        let escapedPath = scriptURL.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.googlecode.iterm2" }) {
            let src = """
            tell application "iTerm2"
                activate
                if (count of windows) = 0 then
                    create window with default profile command "'\(escapedPath)'"
                else
                    tell current window
                        create tab with default profile command "'\(escapedPath)'"
                    end tell
                end if
            end tell
            """
            if let script = NSAppleScript(source: src) {
                var err: NSDictionary?
                _ = script.executeAndReturnError(&err)
                if err == nil {
                    return
                }
            }
        }

        let termAppURL = preferredTerminalAppURL()
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([scriptURL], withApplicationAt: termAppURL, configuration: cfg)
    }

    private static func preferredTerminalAppURL() -> URL {
        let candidates = [
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "com.apple.Terminal"
        ]
        for bid in candidates {
            if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }),
               let url = running.bundleURL {
                return url
            }
        }
        for bid in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return url
            }
        }
        return URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    }
}
