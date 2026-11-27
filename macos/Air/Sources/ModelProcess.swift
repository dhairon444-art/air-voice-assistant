import AppKit
import Foundation

/// Runs Aria's model server (speech recognition, language model, voice) as a child process.
///
/// Lifetime guarantees:
/// * normal quit: SIGTERM, then SIGKILL after a grace period (`stop()`)
/// * app crash / force quit: the child watches its stdin pipe and parent PID and exits itself
@MainActor
final class ModelProcess: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case ready(port: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var status: String = "Starting…"
    @Published private(set) var recentLog: [String] = []
    @Published private(set) var startedAt = Date()
    /// Real loading progress from the engine: completed fraction, current step, when it began and its estimate.
    @Published private(set) var progress = Progress()
    struct Progress: Equatable {
        var fraction = 0.0
        var next = 0.02
        var label = "Starting…"
        var since = Date()
        var estimate = 3.0
    }
    /// Bumped whenever the server saves a session note.
    @Published private(set) var sessionsChanged = 0

    private var process: Process?
    private var stdinPipe: Pipe?
    private var lineBuffer = Data()
    private var logHandle: FileHandle?

    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Air", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("server.log")
    }()

    var pythonPath: String {
        if let fromPlist = Bundle.main.object(forInfoDictionaryKey: "AirAriaPythonPath") as? String,
           !fromPlist.isEmpty, !fromPlist.hasPrefix("__") {
            return (fromPlist as NSString).expandingTildeInPath
        }
        return NSHomeDirectory() + "/Library/Application Support/Air/venv-smart/bin/python"
    }

    /// The model running in typed Chat mode (nil: the voice engine is running).
    @Published private(set) var chatModel: String?

    func start(voice: String, persona: String, brain: Brain, chat: String? = nil) {
        guard process == nil else { return }
        chatModel = chat
        let res = Bundle.main.resourceURL!
        let server = res.appendingPathComponent("server/aria_server.py").path
        let ui = res.appendingPathComponent("ui").path

        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            state = .failed("Python was not found at \(pythonPath). Set up the venv (see README) and relaunch.")
            return
        }

        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: Self.logURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = [
            "-u", "-s", server,
            "--vault", Vault.url.path,
            "--ui-dir", ui,
            "--parent-pid", String(getpid()),
            "--llm", chat ?? Self.voiceTalker(),
            "--voice", voice,
            "--text-prompt", persona,
        ] + (chat != nil ? ["--chat"] : Self.thinkerArgs())
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        // Fully offline: never contact Hugging Face, never send telemetry.
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        env["HF_DATASETS_OFFLINE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["DO_NOT_TRACK"] = "1"
        env.removeValue(forKey: "HF_TOKEN")
        env.removeValue(forKey: "HUGGING_FACE_HUB_TOKEN")
        p.environment = env

        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.didTerminate(proc) }
        }

        do {
            try p.run()
        } catch {
            state = .failed("Could not start the model: \(error.localizedDescription)")
            return
        }
        process = p
        stdinPipe = input
        state = .starting
        status = "Starting Python…"
        progress = Progress()
        startedAt = Date()
        recentLog = []
    }

    func noteSessionsChanged() { sessionsChanged += 1 }

    /// UI review without loading models (-AirDemo <state>).
    /// Recordings only: replay the engine's real loading stages (same fractions and labels) over ~9 s.
    func demoLoading(then done: @escaping () -> Void) {
        state = .starting
        startedAt = Date()
        let stages: [(Double, Double, String, Double)] = [
            (0.0, 0.02, "Starting the engine", 0.6), (0.6, 0.06, "Loading speech recognition", 0.9),
            (1.5, 0.14, "Loading the voice", 0.6), (2.1, 0.20, "Loading the language model", 2.4),
            (4.5, 0.40, "Warming up", 1.0), (5.5, 0.50, "Preparing your personality and memory", 3.2),
            (8.7, 1.00, "Ready", 0.1)]
        let stops: [Double] = [0.02, 0.06, 0.14, 0.20, 0.40, 0.50, 1.0]
        for (at, frac, label, est) in stages {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                self.progress = Progress(fraction: frac, next: stops.first { $0 > frac + 0.001 } ?? 1.0,
                                         label: label, since: Date(), estimate: est)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.6) { self.showDemoReady(); done() }
    }

    func showDemoReady() {
        state = .ready(port: 0)
        status = "Ready"
    }

    /// Talker + Thinker (Settings > Brain > Aria's models): the talker is the voice; the thinker sits
    /// behind it. A role whose model isn't installed falls back (talker: Qwen3 4B; thinker: none).
    nonisolated static func voiceTalker() -> String {
        let t = UserDefaults.standard.string(forKey: ModelRole.talker.key) ?? AriaModels.defaults[.talker]!
        return AriaModels.isInstalled(t) ? t : Brain.fast.rawValue
    }

    nonisolated static func thinkerArgs() -> [String] {
        let talker = voiceTalker()
        let t = UserDefaults.standard.string(forKey: ModelRole.thinker.key) ?? AriaModels.defaults[.thinker]!
        guard !t.isEmpty, t != talker, AriaModels.isInstalled(t) else { return [] }
        var out = ["--thinker", t]
        if t == Brain.deeper.rawValue, UserDefaults.standard.bool(forKey: "airSpeculative"),
           AriaModels.isInstalled("mlx-community/Qwen3-0.6B-4bit") {
            out += ["--thinker-draft", "mlx-community/Qwen3-0.6B-4bit"]
        }
        return out
    }

    /// Speculative decoding for the Deeper brain with Qwen3-0.6B as the draft (when it's downloaded and on).
    static func draftArgs(_ brain: Brain?) -> [String] {
        guard brain == .deeper, UserDefaults.standard.bool(forKey: "airSpeculative") else { return [] }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit")
        return FileManager.default.fileExists(atPath: dir.path) ? ["--draft", "mlx-community/Qwen3-0.6B-4bit"] : []
    }

    func restart(voice: String, persona: String, brain: Brain, chat: String? = nil) {
        stop()
        start(voice: voice, persona: persona, brain: brain, chat: chat)
    }

    /// Terminate the child and wait (bounded) until it is gone.
    func stop() {
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil
        if p.isRunning {
            kill(p.processIdentifier, SIGTERM)
            let deadline = Date().addingTimeInterval(4)
            while p.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
                p.waitUntilExit()
            }
        }
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil
        try? logHandle?.close()
        logHandle = nil
        state = .idle
    }

    private func didTerminate(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        if case .failed = state { return }
        let tail = recentLog.suffix(6).joined(separator: "\n")
        state = .failed("The model process stopped (exit code \(proc.terminationStatus)).\n\(tail)")
    }

    private func consume(_ data: Data) {
        logHandle?.write(data)
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<nl]
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "")
            handle(line: line)
        }
    }

    private func handle(line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        recentLog.append(line)
        if recentLog.count > 40 { recentLog.removeFirst(recentLog.count - 40) }
        if line.hasPrefix("AIR_PROGRESS ") {
            let f = line.dropFirst("AIR_PROGRESS ".count).split(separator: "|", maxSplits: 2).map(String.init)
            if f.count == 3, let frac = Double(f[0]) {
                let nextStops: [Double] = [0.02, 0.06, 0.14, 0.20, 0.40, 0.50, 1.0]
                progress = Progress(fraction: frac, next: nextStops.first { $0 > frac + 0.001 } ?? 1.0,
                                    label: f[1], since: Date(), estimate: max(1, Double(f[2]) ?? 3))
            }
        } else if line.hasPrefix("AIR_STATUS ") {
            let s = String(line.dropFirst("AIR_STATUS ".count))
            if case .starting = state { status = s }
        } else if line.hasPrefix("AIR_READY "), let port = Int(line.dropFirst("AIR_READY ".count)) {
            state = .ready(port: port)
            status = "Ready"
        } else if line.hasPrefix("AIR_ERROR ") {
            let msg = String(line.dropFirst("AIR_ERROR ".count))
            if case .ready = state { return }
            state = .failed(msg)
        } else if line.hasPrefix("AIR_TOOL ") {
            // AIR_TOOL <id> {"name": ..., "args": {...}}  ->  stdin: TOOL_RESULT <id> <json>
            let rest = line.dropFirst("AIR_TOOL ".count)
            guard let space = rest.firstIndex(of: " ") else { return }
            let callID = String(rest[..<space])
            let payload = Data(rest[rest.index(after: space)...].utf8)
            let req = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
            let name = req["name"] as? String ?? ""
            let args = req["args"] as? [String: Any] ?? [:]
            let pipe = stdinPipe
            Task { @MainActor in
                let result = await ToolRunner.shared.run(name: name, args: args)
                let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
                var line = Data("TOOL_RESULT \(callID) ".utf8)
                line.append(data)
                line.append(0x0A)
                try? pipe?.fileHandleForWriting.write(contentsOf: line)
            }
        } else if line.hasPrefix("AIR_SESSION_SAVED ") {
            sessionsChanged += 1
        }
    }
}
