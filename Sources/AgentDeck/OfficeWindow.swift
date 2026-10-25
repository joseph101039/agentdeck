import AppKit
import Combine
import WebKit

/// The resident window showing the 3D office. Closing it only hides it —
/// the server keeps running, so reopening is instant and the scene keeps
/// its state — and whether it was open is remembered across launches.
@MainActor
final class OfficeWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    static let openDefaultsKey = "officeWindowOpen"
    /// The managed window always opens the 3D view, and shows sub-sessions
    /// so a Codex launched by Claude is visible the first time.
    private static let query = "/?view=office&quality=high&sub=1"

    private let server: OfficeServer
    private let webView: WKWebView
    private var statusObserver: AnyCancellable?
    /// What the web view is showing: the office at this base URL, or nil
    /// for the status page. A server restart on another port changes it.
    private var loadedBase: URL?

    init(server: OfficeServer) {
        self.server = server
        let config = WKWebViewConfiguration()
        let messages = WeakMessageHandler()
        config.userContentController.add(messages, name: "office")
        webView = WKWebView(frame: .zero, configuration: config)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Agent Office"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.center()
        // after center(): a saved frame, when there is one, wins
        window.setFrameAutosaveName("AgentDeckOffice")
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
        messages.onMessage = { [weak self] body in
            if body as? String == "retry" { self?.server.restart() }
        }
        statusObserver = server.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated { self?.render(status) }
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showOffice() {
        UserDefaults.standard.set(true, forKey: Self.openDefaultsKey)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        UserDefaults.standard.set(false, forKey: Self.openDefaultsKey)
        return false
    }

    private func render(_ status: OfficeServer.Status) {
        switch status {
        case .running(let base):
            guard base != loadedBase, let url = URL(string: Self.query, relativeTo: base)
            else { return }
            loadedBase = base
            webView.load(URLRequest(url: url))
        case .starting:
            loadedBase = nil
            showStatusPage(title: "Starting the office…", detail: nil, retry: false)
        case .failed(let reason):
            loadedBase = nil
            showStatusPage(title: "The office isn't running", detail: reason, retry: true)
        }
    }

    // A page that fails to load while the server is meant to be up (it
    // died between the ping and the request) is handled by the server's
    // restart; until then, say so instead of showing WebKit's blank page.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        guard loadedBase != nil else { return }
        loadedBase = nil
        showStatusPage(title: "Couldn't reach the office", detail: error.localizedDescription,
                       retry: true)
    }

    private func showStatusPage(title: String, detail: String?, retry: Bool) {
        let detailHTML = detail.map { "<p class=\"detail\">\(Self.escape($0))</p>" } ?? ""
        let button = retry
            ? "<button onclick=\"window.webkit.messageHandlers.office.postMessage('retry')\">Retry</button>"
            : ""
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          body { font: 14px -apple-system, sans-serif; display: flex; align-items: center;
                 justify-content: center; height: 100vh; margin: 0; text-align: center; }
          h1 { font-size: 18px; font-weight: 600; }
          .detail { color: GrayText; max-width: 560px; white-space: pre-wrap; }
          button { font-size: 14px; padding: 6px 18px; margin-top: 8px; }
        </style></head>
        <body><div><h1>\(Self.escape(title))</h1>\(detailHTML)\(button)</div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// `WKUserContentController` retains its handlers; routing through this
/// keeps it from retaining the window controller in a cycle.
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    var onMessage: ((Any) -> Void)?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        onMessage?(message.body)
    }
}
