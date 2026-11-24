import AppKit
import Foundation

/// Runs the PersonaPlex model server as a child process and tracks its state.
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

    @Published private(set) var mode: Mode = .myra

    func pythonPath(for mode: Mode) -> String {
        if let fromPlist = Bundle.main.object(forInfoDictionaryKey: mode.pythonInfoKey) as? String,
           !fromPlist.isEmpty, !fromPlist.hasPrefix("__") {
            return (fromPlist as NSString).expandingTildeInPath
        }
        return mode.defaultPython
    }
    var pythonPath: String { pythonPath(for: mode) }

    func start(mode: Mode, voice: String, persona: String) {
        self.mode = mode
        guard process == nil else { return }
        let res = Bundle.main.resourceURL!
        let server = res.appendingPathComponent("server/" + mode.script).path
        let ui = res.appendingPathComponent("ui").path
        let pyLib = res.appendingPathComponent("python").path

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
        ] + (mode == .myra ? ["-q", "4", "--stt-python", pythonPath(for: .aria)] : []) + [
            "--voice", voice,
            "--text-prompt", persona,
        ]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = pyLib
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

    func restart(mode: Mode, voice: String, persona: String) {
        stop()
        start(mode: mode, voice: voice, persona: persona)
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
        } else if line.hasPrefix("AIR_SESSION_SAVED ") {
            sessionsChanged += 1
        }
    }
}
