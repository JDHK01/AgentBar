import AppKit
import Foundation
import WebKit

@MainActor
final class WebBalanceExtractor: NSObject, WKNavigationDelegate {
    static let shared = WebBalanceExtractor()

    private var loginWindow: NSWindow?
    private var headlessWebView: WKWebView?
    private var pendingContinuation: CheckedContinuation<String, Error>?
    private var pendingExpression: String = ""

    func openInteractiveLoginWindow(urlString: String, title: String) {
        guard let url = URL(string: urlString) else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 660), configuration: config)
        webView.load(URLRequest(url: url))

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "AgentBar 登录 · \(title)（登录完成后直接关闭窗口即可保存 Cookie）"
        win.contentView = webView
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.loginWindow = win
    }

    func evaluateOnPage(url: URL, jsOrSelector: String) async throws -> String {
        if pendingContinuation != nil {
            throw NSError(domain: "WebBalanceExtractor", code: 9, userInfo: [NSLocalizedDescriptionKey: "正在加载另一个页面"])
        }
        let expr: String
        let trimmed = jsOrSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("document.") || trimmed.contains("window.") || trimmed.contains("(") {
            expr = trimmed
        } else {
            let escaped = trimmed.replacingOccurrences(of: "'", with: "\\'")
            expr = "document.querySelector('\(escaped)')?.innerText ?? ''"
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        wv.navigationDelegate = self
        self.headlessWebView = wv
        self.pendingExpression = expr

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.pendingContinuation = cont
            wv.load(URLRequest(url: url, timeoutInterval: 15))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let expr = pendingExpression
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard let cont = self.pendingContinuation else { return }
            self.pendingContinuation = nil
            do {
                let result = try await webView.evaluateJavaScript(expr)
                let str = result.map { "\($0)" } ?? ""
                cont.resume(returning: str)
            } catch {
                cont.resume(throwing: error)
            }
            self.headlessWebView = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let cont = pendingContinuation {
            pendingContinuation = nil
            cont.resume(throwing: error)
        }
        headlessWebView = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let cont = pendingContinuation {
            pendingContinuation = nil
            cont.resume(throwing: error)
        }
        headlessWebView = nil
    }
}
