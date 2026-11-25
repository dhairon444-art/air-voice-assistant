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
    var blocks: [DisplayBlock] = []
    var interrupted = false
    let time = Date()
}

/// One line of the Show thinking activity trace.
struct TraceItem: Identifiable, Equatable {
    let id = UUID()
    let kind: String   // heard, reasoning, call, result, research, sources, memory
    var text: String
    let time = Date()
}

struct ResearchProgress: Equatable {
    var step: String
    var text: String
    let started = Date()
}

@MainActor
final class AudioMeter: ObservableObject {
    /// A meter that never changes (for indicators that should hold still).
    static let still = AudioMeter()
    @Published var mic: Double = 0
    @Published var out: Double = 0
    @Published var bands: [Double] = Array(repeating: 0, count: 8)
}

/// A multiple-choice question from Aria (ask_choice): clarifying, picking a plan, or a quiz.
struct ChoicePrompt: Equatable {
    let question: String
    let options: [String]
    let quiz: Bool
    let allowOther: Bool
    var answered: Int?
    var correct: Bool?
    var explanation = ""
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
    @Published private(set) var choice: ChoicePrompt?
    /// Audio levels and bands change ~16 times a second; they live in their own object so only the
    /// orb and the level bars redraw, not every view that watches the conversation.
    let meter = AudioMeter()
    var micLevel: Double { get { meter.mic } set { if meter.mic != newValue { meter.mic = newValue } } }
    var outLevel: Double { get { meter.out } set { if meter.out != newValue { meter.out = newValue } } }
    @Published var error: String?
    @Published private(set) var lag: Double = 0
    @Published private(set) var engineReady = false
    @Published private(set) var activeTool: String?
    @Published private(set) var previewing: String?
    @Published private(set) var online = true
    /// Set while Aria is capturing or reading the screen (visible indicator).
    @Published private(set) var looking: String?
    /// Show thinking: this turn's reasoning text and the session's activity trace.
    @Published private(set) var trace: [TraceItem] = []
    @Published private(set) var research: ResearchProgress?
    /// Mute: the mic (nothing captured or transcribed; the session stays open) and Aria's voice
    /// (captions only). Not remembered across launches: Air always starts unmuted.
    @Published private(set) var micMuted = false
    /// Eight frequency bands (0..1) of the voice being heard or spoken, for the orb.
    var bands: [Double] { get { meter.bands } set { meter.bands = newValue } }
    @Published private(set) var voiceMuted = false
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
        applyMutes()
        js("window.airStart && window.airStart()")
    }
    func setMicMuted(_ on: Bool) { micMuted = on; if on { micLevel = 0 }; applyMutes() }
    func setVoiceMuted(_ on: Bool) { voiceMuted = on; if on { outLevel = 0 }; applyMutes() }
    func toggleMicMute() { setMicMuted(!micMuted) }
    func toggleVoiceMute() { setVoiceMuted(!voiceMuted) }
    private func applyMutes() {
        js("window.airMuteMic && window.airMuteMic(\(micMuted)); window.airMuteVoice && window.airMuteVoice(\(voiceMuted))")
    }
    /// A typed turn (works with the mic muted).
    func say(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard live, !t.isEmpty else { return }
        js("window.airSay && window.airSay(\(Self.json(["t": t]))['t'])")
    }
    func stop() { js("window.airStop && window.airStop()") }
    func toggle() { live ? stop() : start() }
    func endTurn() { js("window.airEndTurn && window.airEndTurn()") }
    func interrupt() { js("window.airInterrupt && window.airInterrupt()") }
    /// Pick option i (0-based), or give a free answer with i = -1.
    func choose(_ i: Int, text: String? = nil) {
        guard let c = choice, c.answered == nil else { return }
        let t = text ?? (c.options.indices.contains(i) ? c.options[i] : "")
        js("window.airChoice && window.airChoice(\(i), \(Self.json(["t": t]))['t'])")
    }
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
            applyMutes()
        case "levels":
            micLevel = body["mic"] as? Double ?? 0
            outLevel = body["out"] as? Double ?? 0
            if let b = body["bands"] as? [Double], b.count == 8 { bands = b }
        case "state":
            handleState(body["state"] as? String ?? "")
        case "you":
            ariaOpen = false
            if choice?.answered != nil { choice = nil }  // the card stays until the next thing you say
            research = nil
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
            research = nil
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
        case "choice":
            choice = ChoicePrompt(question: e["question"] as? String ?? "", options: e["options"] as? [String] ?? [],
                                  quiz: e["quiz"] as? Bool ?? false, allowOther: e["allow_other"] as? Bool ?? false)
        case "choice_done":
            let i = e["index"] as? Int ?? -1
            if i < 0 && choice?.allowOther != true { choice = nil }
            else {
                choice?.answered = i
                choice?.correct = e["correct"] as? Bool
                choice?.explanation = e["explanation"] as? String ?? ""
            }
        case "research":
            let step = e["step"] as? String ?? ""
            let text = e["text"] as? String ?? ""
            if step == "done" { research = nil } else if research == nil { research = ResearchProgress(step: step, text: text) }
            else { research?.step = step; research?.text = text }
        case "thought":
            let t = e["text"] as? String ?? ""
            if let last = trace.last, last.kind == "reasoning" { trace[trace.count - 1].text += t }
            else if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { appendTrace("reasoning", t) }
        case "trace":
            appendTrace(e["kind"] as? String ?? "", e["text"] as? String ?? "")
        case "sources":
            let items = (e["items"] as? [[String: Any]] ?? []).compactMap { d -> Source? in
                guard let u = URL(string: d["url"] as? String ?? ""), u.scheme?.hasPrefix("http") == true else { return nil }
                return Source(title: d["title"] as? String ?? u.host ?? "", url: u)
            }
            let i = currentAriaIndex()
            turns[i].sources = items
        case "display":
            let i = currentAriaIndex()
            turns[i].blocks.append(DisplayBlock(kind: e["kind"] as? String ?? "markdown", body: e["body"] as? String ?? ""))
        case "file":
            if let p = e["path"] as? String {
                let i = currentAriaIndex()
                turns[i].files.append(URL(fileURLWithPath: p))
            }
        default:
            break
        }
    }

    private func appendTrace(_ kind: String, _ text: String) {
        trace.append(TraceItem(kind: kind, text: text))
        if trace.count > 200 { trace.removeFirst(trace.count - 200) }
    }

    func clearTrace() { trace = [] }

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
        bands = ["speaking", "listening", "hearing", "thinking-panel"].contains(name)
            ? [0.35, 0.7, 0.9, 0.55, 0.45, 0.3, 0.5, 0.2] : Array(repeating: 0, count: 8)
        if UserDefaults.standard.bool(forKey: "AirDemoVoice"), ["speaking", "listening", "hearing"].contains(name) {
            // Recordings: a synthetic, speech-like signal (syllable bursts with a moving pitch).
            let start = Date()
            Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let t = Date().timeIntervalSince(start)
                    let env = max(0, sin(t * 7.5)) * (0.6 + 0.4 * sin(t * 0.9))
                    let pitch = 2.5 + 2 * sin(t * 1.3)
                    if UserDefaults.standard.bool(forKey: "AirDemoDry") { _ = env + pitch; return }
                    if UserDefaults.standard.bool(forKey: "AirDemoLevelOnly") { self.outLevel = env * 0.15; return }
                    self.bands = (0..<8).map { i in max(0, env * exp(-pow(Double(i) - pitch, 2) / 3) * (0.8 + 0.2 * sin(t * 13 + Double(i)))) }
                    if name == "speaking" { self.outLevel = env * 0.15 } else { self.micLevel = env * 0.12 }
                }
            }
        }
        switch name {
        case "listening": state = .listening; turns = [you1, aria1]; micLevel = 0.05
        case "hearing": state = .hearing; turns = [you1, aria1, Turn(speaker: .you, text: "Okay, and what about the pyramids")]; micLevel = 0.18
        case "thinking": state = .thinking; turns = [you1]
        case "research":
            state = .checking; activeTool = "research"
            turns = [Turn(speaker: .you, text: "Research whether the Great Wall is visible from space."),
                     Turn(speaker: .aria, text: "Let me research that. It takes about fifteen seconds.")]
            research = ResearchProgress(step: "read", text: "Reading 6 pages: britannica.com, nasa.gov, wikipedia.org, scientificamerican.com…")
            trace = [TraceItem(kind: "heard", text: "Research whether the Great Wall is visible from space."),
                     TraceItem(kind: "call", text: "research({\"question\": \"Is the Great Wall of China visible from space?\"})"),
                     TraceItem(kind: "research", text: "Searching: Is the Great Wall of China visible from space; Great Wall visible from orbit astronaut; Great Wall space myth fact check"),
                     TraceItem(kind: "research", text: "Reading 6 pages: britannica.com, nasa.gov, wikipedia.org, scientificamerican.com, skyatnightmagazine.com, sciencefocus.com")]
        case "rich":
            state = .listening
            var a1 = Turn(speaker: .aria, text: "I've put a comparison table on screen: the iPhone wins on video, the Pixel on zoom and price.")
            a1.blocks = [DisplayBlock(kind: "table", body: "| Phone | Video | Zoom | Battery | Price |\n|---|---|---|---|---|\n| iPhone 17 Pro | **Best** | 8x | ~1 day | $1,099 |\n| Pixel 10 Pro | Good | **100x** | ~1 day | $999 |\n| Galaxy S26 | Good | 30x | **1.5 days** | $1,049 |")]
            var a2 = Turn(speaker: .aria, text: "Here are the steps as a flowchart on screen. The biggest wait is the appointment.")
            a2.blocks = [DisplayBlock(kind: "mermaid", body: "flowchart LR\n  A[Check visa type] --> B[Gather documents]\n  B --> C[Fill in the form]\n  C --> D[Pay the fee]\n  D --> E[Book appointment]\n  E --> F[Biometrics]\n  F --> G{Decision}\n  G -->|Approved| H[Travel]\n  G -->|Refused| I[Appeal or reapply]")]
            var a3 = Turn(speaker: .aria, text: "The sources are on screen as links.")
            a3.blocks = [DisplayBlock(kind: "links", body: "- [Apple: iPhone 17 Pro tech specs](https://www.apple.com/iphone/)\n- [MacRumors: iPhone 17 Pro vs Pixel 10 Pro](https://www.macrumors.com/)\n- [Tech Advisor camera test](https://www.techadvisor.com/)")]
            turns = [Turn(speaker: .you, text: "Compare these three phones in a table."), a1,
                     Turn(speaker: .you, text: "Draw the steps of applying for a visa as a flowchart."), a2,
                     Turn(speaker: .you, text: "Give me the sources as links."), a3]
        case "muted":
            state = .listening; turns = [you1, aria1]; micMuted = true
        case "voicemuted":
            state = .speaking; turns = [you1, aria1]; voiceMuted = true; outLevel = 0
        case "thinking-panel":
            state = .speaking; outLevel = 0.3
            turns = [you1, aria1]
            trace = [TraceItem(kind: "heard", text: "Is the Great Wall of China visible from space?"),
                     TraceItem(kind: "reasoning", text: "The user is asking about a well-known claim. I recall it's a myth, but I should check sources rather than rely on memory, and say how sure I am."),
                     TraceItem(kind: "call", text: "web_search({\"query\": \"Great Wall of China visible from space\"})"),
                     TraceItem(kind: "result", text: "web_search: 6 sources in 820 ms"),
                     TraceItem(kind: "sources", text: "britannica.com, nasa.gov, en.wikipedia.org, scientificamerican.com"),
                     TraceItem(kind: "memory", text: "Recalled: 2026-11-20: talked about space photography and the ISS")]
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
