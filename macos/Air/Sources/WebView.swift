import AppKit
import SwiftUI
import WebKit

/// What Aria is doing right now, as shown by the orb and the state label.
enum TalkState: String {
    case idle, connecting, listening, hearing, thinking, checking, working, speaking

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .connecting: return "Starting…"
        case .listening: return "Listening"
        case .hearing: return "Hearing you"
        case .thinking: return "Thinking"
        case .checking: return "Checking online"
        case .working: return "Working on it"
        case .speaking: return "Speaking"
        }
    }

    var hint: String {
        switch self {
        case .idle: return "Press Space or click the microphone to start."
        case .connecting: return "Getting the microphone ready."
        case .listening: return "Just talk. Pause when you're done."
        case .hearing: return "Pause briefly, or press Space, when you're done."
        case .thinking: return "Aria is working out a reply."
        case .checking: return "Looking it up. Only the search words leave your Mac."
        case .working: return "Using a tool on your Mac."
        case .speaking: return "Talk any time, or press Space, to interrupt."
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "mic"
        case .connecting: return "ellipsis"
        case .listening, .hearing: return "ear"
        case .thinking: return "sparkles"
        case .checking: return "globe"
        case .working: return "wrench.and.screwdriver"
        case .speaking: return "waveform"
        }
    }

    var isLive: Bool { self != .idle && self != .connecting }
}

struct Source: Identifiable, Hashable {
    let title: String
    let url: URL
    var id: URL { url }
    var host: String { url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString }
}

struct Turn: Identifiable, Equatable {
    enum Speaker { case you, aria }
    let id = UUID()
    let speaker: Speaker
    var text: String
    var sources: [Source] = []
    var files: [URL] = []
    var interrupted = false
    let time = Date()
}

struct ConfirmCard: Equatable {
    let tool: String
    let text: String
}

/// Owns the hidden WKWebView that runs Air's audio engine (microphone, playback, WebSocket) and
/// turns its events into observable state for the native Talk screen.
@MainActor
final class WebController: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    @Published private(set) var live = false
    @Published private(set) var state: TalkState = .idle
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var confirm: ConfirmCard?
    @Published private(set) var micLevel: Double = 0
    @Published private(set) var outLevel: Double = 0
    @Published var error: String?
    @Published private(set) var lag: Double = 0
    @Published private(set) var engineReady = false
    @Published private(set) var activeTool: String?
    @Published private(set) var previewing: String?
    @Published private(set) var online = true
    /// Set while Aria is capturing or reading the screen (visible indicator).
    @Published private(set) var looking: String?
    private var loadedPort: Int?
    private var statusTimer: Timer?
    private var ariaOpen = false
    var onSessionEnded: (() -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        super.init()
        config.userContentController.add(WeakHandler(self), name: "air")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityElement(false)
    }

    // MARK: lifecycle

    func load(port: Int, config: [String: Any]) {
        guard port != 0 else { return }  // demo mode: no server
        guard loadedPort != port else { return }
        loadedPort = port
        engineReady = false
        setUserConfig(config)
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        pollStatus(port: port)
    }

    func unload() {
        loadedPort = nil
        live = false
        state = .idle
        engineReady = false
        statusTimer?.invalidate()
        webView.loadHTMLString("", baseURL: nil)
    }

    func updateConfig(_ config: [String: Any]) {
        setUserConfig(config)
        let json = Self.json(config)
        webView.evaluateJavaScript("window.airSetConfig && window.airSetConfig(\(json))")
    }

    private func setUserConfig(_ config: [String: Any]) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: "window.airConfig = \(Self.json(config));",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    static func json(_ obj: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// Online/offline as the server sees it (for the fact-check chip), refreshed every 15 s.
    private func pollStatus(port: Int) {
        statusTimer?.invalidate()
        let check = { [weak self] in
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/status")!)
            req.timeoutInterval = 2
            URLSession.shared.dataTask(with: req) { data, _, _ in
                guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let on = obj["online"] as? Bool ?? true
                Task { @MainActor in self?.online = on }
            }.resume()
        }
        check()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in check() }
    }

    /// Ask the server to pre-warm its KV cache for a new personality (keeps the first reply fast).
    func prime(persona: String) {
        guard let port = loadedPort, !live else { return }
        var c = URLComponents(string: "http://127.0.0.1:\(port)/api/prime")!
        c.queryItems = [URLQueryItem(name: "persona", value: persona)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: controls

    private func js(_ s: String) { webView.evaluateJavaScript(s) }
    func start() {
        guard engineReady, !live else { return }
        turns = []
        error = nil
        js("window.airStart && window.airStart()")
    }
    func stop() { js("window.airStop && window.airStop()") }
    func toggle() { live ? stop() : start() }
    func endTurn() { js("window.airEndTurn && window.airEndTurn()") }
    func interrupt() { js("window.airInterrupt && window.airInterrupt()") }
    func answer(_ yes: Bool) {
        js("window.airConfirm && window.airConfirm('\(yes ? "yes" : "no")')")
        confirm = nil
    }
    func preview(_ voice: String) {
        if previewing == voice { js("window.airStopPreview && window.airStopPreview()"); return }
        js("window.airPreview && window.airPreview('\(voice)')")
    }

    /// Space: start; while you talk, end your turn; while Aria talks, interrupt her.
    func primaryAction() {
        if !live { start(); return }
        switch state {
        case .speaking: interrupt()
        case .listening, .hearing: endTurn()
        default: break
        }
    }

    // MARK: WKUIDelegate – microphone for our own local page only
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let local = (origin.host == "127.0.0.1" || origin.host == "localhost") && type == .microphone
        decisionHandler(local ? .grant : .deny)
    }

    // MARK: WKNavigationDelegate – keep the engine on the local page
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

    // MARK: events from the engine
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            engineReady = true
        case "levels":
            micLevel = body["mic"] as? Double ?? 0
            outLevel = body["out"] as? Double ?? 0
        case "state":
            handleState(body["state"] as? String ?? "")
        case "you":
            ariaOpen = false
            turns.append(Turn(speaker: .you, text: body["text"] as? String ?? ""))
        case "aria":
            appendAria(body["text"] as? String ?? "")
        case "interrupted":
            if ariaOpen, let i = turns.lastIndex(where: { $0.speaker == .aria }) { turns[i].interrupted = true }
            ariaOpen = false
        case "error":
            error = body["message"] as? String
        case "lag":
            lag = body["seconds"] as? Double ?? 0
        case "preview":
            let playing = body["playing"] as? Bool ?? false
            previewing = playing ? body["voice"] as? String : nil
        case "event":
            handleEvent(body)
        default:
            break
        }
    }

    private func handleState(_ s: String) {
        switch s {
        case "connecting": state = .connecting
        case "live": live = true; state = .listening
        case "ended", "idle":
            let was = live
            live = false
            state = .idle
            confirm = nil
            activeTool = nil
            ariaOpen = false
            micLevel = 0; outLevel = 0
            if was { onSessionEnded?() }
        default:
            if let t = TalkState(rawValue: s) {
                state = t
                if t == .listening || t == .hearing { ariaOpen = false }
            }
        }
    }

    private func appendAria(_ piece: String) {
        if ariaOpen, let i = turns.lastIndex(where: { $0.speaker == .aria }) {
            turns[i].text += piece
        } else {
            turns.append(Turn(speaker: .aria, text: piece))
            ariaOpen = true
        }
    }

    private func currentAriaIndex() -> Int {
        if ariaOpen, let i = turns.lastIndex(where: { $0.speaker == .aria }) { return i }
        turns.append(Turn(speaker: .aria, text: ""))
        ariaOpen = true
        return turns.count - 1
    }

    private func handleEvent(_ e: [String: Any]) {
        switch e["t"] as? String {
        case "tool":
            activeTool = (e["phase"] as? String) == "start" ? e["name"] as? String : nil
            if let n = e["name"] as? String, n == "look_at_screen" || n == "look_at_image" {
                looking = (e["phase"] as? String) == "start" ? (n == "look_at_screen" ? "your screen" : "the image") : nil
            }
        case "looking":
            if let app = e["app"] as? String, !app.isEmpty, looking == "your screen" { looking = "your screen (\(app))" }
        case "confirm":
            confirm = ConfirmCard(tool: e["tool"] as? String ?? "", text: e["text"] as? String ?? "")
        case "confirm_done":
            confirm = nil
        case "sources":
            let items = (e["items"] as? [[String: Any]] ?? []).compactMap { d -> Source? in
                guard let u = URL(string: d["url"] as? String ?? ""), u.scheme?.hasPrefix("http") == true else { return nil }
                return Source(title: d["title"] as? String ?? u.host ?? "", url: u)
            }
            let i = currentAriaIndex()
            turns[i].sources = items
        case "file":
            if let p = e["path"] as? String {
                let i = currentAriaIndex()
                turns[i].files.append(URL(fileURLWithPath: p))
            }
        default:
            break
        }
    }

    // MARK: demo states for screenshots and UI review (-AirDemo <state>)
    func loadDemo(_ name: String) {
        engineReady = true
        let you1 = Turn(speaker: .you, text: "Is the Great Wall of China visible from space?")
        var aria1 = Turn(speaker: .aria, text: "No. That's a common myth. From low Earth orbit the wall is far too narrow to make out with the naked eye; astronauts who looked for it, including China's Yang Liwei, said they couldn't see it. I'm certain on this one.")
        aria1.sources = [Source(title: "Wikipedia: Artificial structures visible from space", url: URL(string: "https://en.wikipedia.org/wiki/Artificial_structures_visible_from_space")!),
                         Source(title: "NASA: Great Wall", url: URL(string: "https://www.nasa.gov/image-article/great-wall/")!)]
        let you2 = Turn(speaker: .you, text: "Pull the table of the world's tallest buildings into Excel.")
        var aria2 = Turn(speaker: .aria, text: "Done. I saved the main table, 100 buildings with height, floors and city, as an Excel file.")
        aria2.files = [URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Air Exports/World's Tallest Buildings 2026-11-25.xlsx")]
        live = name != "idle" && name != "error" && name != "offline"
        switch name {
        case "listening": state = .listening; turns = [you1, aria1]; micLevel = 0.05
        case "hearing": state = .hearing; turns = [you1, aria1, Turn(speaker: .you, text: "Okay, and what about the pyramids")]; micLevel = 0.18
        case "thinking": state = .thinking; turns = [you1]
        case "checking": state = .checking; turns = [you1, Turn(speaker: .aria, text: "Let me check that.")]; activeTool = "web_search"
        case "speaking": state = .speaking; turns = [you1, aria1, you2, aria2]; outLevel = 0.16
        case "confirm":
            state = .listening
            turns = [Turn(speaker: .you, text: "Remind me to call Mum at six tonight."),
                     Turn(speaker: .aria, text: "I'm about to add a reminder: Call Mum, due Wednesday 25 November at 6 PM.")]
            confirm = ConfirmCard(tool: "add_reminder", text: "Add a reminder: Call Mum, due today at 6 PM")
        case "error": state = .idle; error = "Microphone unavailable: permission was denied. Allow Air in System Settings › Privacy & Security › Microphone."
        case "offline": state = .idle; online = false; turns = [you1, Turn(speaker: .aria, text: "No, it isn't visible to the naked eye from orbit. I'm offline, so I couldn't verify this online; this is from what I already know.")]
        default: state = .idle
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

/// The engine's web view, kept tiny and invisible but in the window so audio keeps running.
struct EngineHost: NSViewRepresentable {
    let controller: WebController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
