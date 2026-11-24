import AppKit
import SwiftUI
import WebKit

/// Owns the single WKWebView so it survives switching between tabs.
@MainActor
final class WebController: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    @Published var live = false
    private var loadedPort: Int?
    var onSessionEnded: (() -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakHandler(self), name: "air")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    func load(port: Int, voice: String, persona: String) {
        guard loadedPort != port else { return }
        loadedPort = port
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: "window.airConfig = \(Self.configJSON(voice: voice, persona: persona));",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
    }

    func unload() {
        loadedPort = nil
        live = false
        webView.loadHTMLString("", baseURL: nil)
    }

    func updateConfig(voice: String, persona: String) {
        let json = Self.configJSON(voice: voice, persona: persona)
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: "window.airConfig = \(json);",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.evaluateJavaScript("window.airSetConfig && window.airSetConfig(\(json))")
    }

    static func configJSON(voice: String, persona: String) -> String {
        let obj = ["mode": "aria", "name": "Aria", "voice": voice, "persona": persona]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: WKUIDelegate – microphone for our own local page only
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let local = (origin.host == "127.0.0.1" || origin.host == "localhost") && type == .microphone
        decisionHandler(local ? .grant : .deny)
    }

    // MARK: WKNavigationDelegate – keep the window on the local UI
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "about" || url.host == "127.0.0.1" {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    // MARK: messages from the page
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "state", let s = body["state"] as? String {
            live = (s == "live")
            if s == "ended" { onSessionEnded?() }
        }
    }
}

/// Breaks the retain cycle between WKUserContentController and its handler.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

struct WebViewHost: NSViewRepresentable {
    let controller: WebController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
