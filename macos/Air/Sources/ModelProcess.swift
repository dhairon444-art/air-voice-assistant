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

    func start(voice: String, persona: String, brain: Brain) {
        guard process == nil else { return }
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
            "--llm", brain.rawValue,
            "--voice", voice,
            "--text-prompt", persona,
        ]
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
        startedAt = Date()
        recentLog = []
    }

    func noteSessionsChanged() { sessionsChanged += 1 }

    func restart(voice: String, persona: String, brain: Brain) {
        stop()
        start(voice: voice, persona: persona, brain: brain)
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
        if line.hasPrefix("AIR_STATUS ") {
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
