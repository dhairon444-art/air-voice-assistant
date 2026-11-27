import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// A Kokoro voice from Resources/voices.json (built from Kokoro's VOICES.md).
struct CatalogVoice: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let language: String
    let code: String
    let accent: String
    let gender: String
    let grade: String
    let style: [String]
    let needs_pack: Bool
    var note: String { [accent, gender, style.first].compactMap { $0 }.joined(separator: ", ") }
}

enum VoiceCatalog {
    private struct File: Decodable { let voices: [CatalogVoice] }
    static let voices: [CatalogVoice] = {
        guard let u = Bundle.main.url(forResource: "voices", withExtension: "json"),
              let d = try? Data(contentsOf: u), let f = try? JSONDecoder().decode(File.self, from: d) else { return [] }
        return f.voices
    }()
    static func voice(_ id: String) -> CatalogVoice? { voices.first { $0.id == id } }
    static var added: [String] {
        get { UserDefaults.standard.stringArray(forKey: "airVoices.added") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "airVoices.added") }
    }
}

/// Marketplace > Voices: every Kokoro voice with tags, a preview, and Add / Remove (the files are
/// already on the Mac with the Kokoro model, so adding downloads nothing).
struct VoicesMarket: View {
    @EnvironmentObject var web: WebController
    @EnvironmentObject var prefs: Prefs
    @State private var added = Set(VoiceCatalog.added)
    @State private var language = "any"
    @State private var gender = "any"
    @State private var goodOnly = false
    @State private var showClone = false

    private var languages: [String] { Array(Set(VoiceCatalog.voices.map(\.language))).sorted() }
    private var list: [CatalogVoice] {
        VoiceCatalog.voices.filter { v in
            (language == "any" || v.language == language) && (gender == "any" || v.gender == gender)
                && (!goodOnly || ["A", "A-", "B+", "B", "B-", "C+"].contains(v.grade))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("Language", selection: $language) {
                    Text("Any language").tag("any")
                    ForEach(languages, id: \.self) { Text($0).tag($0) }
                }.fixedSize()
                Picker("Gender", selection: $gender) {
                    Text("Any").tag("any"); Text("Female").tag("female"); Text("Male").tag("male")
                }.pickerStyle(.segmented).fixedSize()
                Toggle("Best quality only", isOn: $goodOnly).toggleStyle(.checkbox)
                Spacer()
                Text("\(list.count) voices").font(.caption).foregroundStyle(.secondary)
            }
            Text("Kokoro voices run on this Mac, next to Aria's brain, and the files are already installed: Add just puts a voice in the Voice picker. Grades are Kokoro's own (A is best). A voice speaks its own language; English text with a Spanish voice sounds Spanish.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 12)], spacing: 12) {
                ForEach(list) { v in card(v) }
            }
            Divider().padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 8) {
                Text("Voice packs").font(.headline)
                Text("Other voice engines that run on this Mac. A pack loads when you pick one of its voices (only one pack at a time).")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(VoiceCatalog.packs) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.callout.weight(.semibold))
                            Text("\(p.engine) · \(p.accent) · \(p.size_mb) MB · \(p.licence)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if p.verified {
                            Button { web.preview(p.id) } label: { Image(systemName: web.previewing == p.id ? "stop.circle" : "play.circle") }
                                .buttonStyle(.plain).disabled(!web.engineReady).help("Preview")
                            Button(added.contains(p.id) ? "Remove" : "Add") { togglePack(p.id) }.controlSize(.small)
                        } else {
                            Text("Being measured on this Mac").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Text("Your voices").font(.headline)
                    Spacer()
                    Button { showClone = true } label: { Label("Create a voice from a clip", systemImage: "waveform.badge.plus") }
                }
                .padding(.top, 6)
                if VoiceCatalog.clones.isEmpty {
                    Text("Make a voice from 10 to 30 seconds of speech (MOSS-TTS-Nano). Only voices you have the right to use.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(VoiceCatalog.clones, id: \.self) { c in
                    HStack {
                        Image(systemName: "person.wave.2").foregroundStyle(.secondary)
                        Text(c)
                        Spacer()
                        Button { web.preview("clone:" + c) } label: { Image(systemName: "play.circle") }.buttonStyle(.plain).help("Preview")
                        Button(prefs.voice == "clone:" + c ? "In use" : "Use") { prefs.voice = "clone:" + c }
                            .controlSize(.small).disabled(prefs.voice == "clone:" + c || web.live)
                        Button { deleteClone(c) } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("Delete this voice and its clip")
                    }
                }
            }
            .sheet(isPresented: $showClone) { CloneVoiceSheet() }
        }
    }

    private func card(_ v: CatalogVoice) -> some View {
        let isBuiltIn = Voices.builtIn.contains { $0.id == v.id }
        let on = isBuiltIn || added.contains(v.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(v.name).font(.callout.weight(.semibold))
                if !v.grade.isEmpty { Text(v.grade).font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                Spacer()
                Button { web.preview(v.id) } label: {
                    Image(systemName: web.previewing == v.id ? "stop.circle" : "play.circle")
                }
                .buttonStyle(.plain).disabled(v.needs_pack || !web.engineReady).help("Preview")
            }
            HStack(spacing: 4) {
                ForEach([v.language, v.gender.capitalized] + v.style, id: \.self) { t in
                    Text(t).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                }
            }
            HStack {
                if v.needs_pack {
                    Text("Needs a \(v.language) language pack (not installed)").font(.caption).foregroundStyle(.secondary)
                } else if isBuiltIn {
                    Text("Built in").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(on ? "Remove" : "Add") { toggle(v) }.controlSize(.small)
                }
                Spacer()
                if on && !v.needs_pack {
                    Button(prefs.voice == v.id ? "In use" : "Use") { prefs.voice = v.id }
                        .controlSize(.small).disabled(prefs.voice == v.id || web.live)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
        .opacity(v.needs_pack ? 0.55 : 1)
    }

    private func togglePack(_ id: String) {
        if added.contains(id) { added.remove(id); if prefs.voice == id { prefs.voice = Voices.defaultVoice } } else { added.insert(id) }
        VoiceCatalog.added = Array(added)
    }

    private func deleteClone(_ c: String) {
        for ext in ["wav", "json"] { try? FileManager.default.removeItem(at: VoiceCatalog.cloneDir.appendingPathComponent(c + "." + ext)) }
        if prefs.voice == "clone:" + c { prefs.voice = Voices.defaultVoice }
        added = added   // refresh
    }

    private func toggle(_ v: CatalogVoice) {
        if added.contains(v.id) {
            added.remove(v.id)
            if prefs.voice == v.id { prefs.voice = Voices.defaultVoice }
        } else {
            added.insert(v.id)
        }
        VoiceCatalog.added = Array(added)
    }
}

// MARK: voice packs and clone voices

struct PackVoice: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let engine: String
    let licence: String
    let size_mb: Int
    let accent: String
    let verified: Bool
}

extension VoiceCatalog {
    private struct PackFile: Decodable { let packs: [PackVoice]? }
    static let packs: [PackVoice] = {
        guard let u = Bundle.main.url(forResource: "voices", withExtension: "json"),
              let d = try? Data(contentsOf: u), let f = try? JSONDecoder().decode(PackFile.self, from: d) else { return [] }
        return f.packs ?? []
    }()

    static var cloneDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Air/voices", isDirectory: true)
    }

    /// Clone voices made on this Mac (a clip plus a consent record).
    static var clones: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cloneDir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
            .filter { FileManager.default.fileExists(atPath: cloneDir.appendingPathComponent($0 + ".wav").path) }.sorted()
    }

    /// Picker entries beyond Kokoro: added (verified) pack voices and every clone voice.
    static var extraVoices: [(id: String, name: String, note: String)] {
        packs.filter { $0.verified && added.contains($0.id) }.map { ($0.id, $0.name, $0.engine) }
            + clones.map { ("clone:" + $0, $0, "your voice clone") }
    }
}

/// "Create a voice from a clip": record or pick 10-30 s, confirm the right to use it, save locally.
struct CloneVoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var consent = false
    @State private var clip: URL?
    @State private var seconds: Double = 0
    @State private var recording = false
    @State private var recorder: AVAudioRecorder?
    @State private var timer: Timer?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create a voice from a clip").font(.title3.weight(.semibold))
            Text("Record or choose 10 to 30 seconds of one person speaking clearly. MOSS-TTS-Nano makes a voice from it on this Mac; the clip and the voice never leave it.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Button { recording ? stopRecording() : startRecording() } label: {
                    Label(recording ? "Stop (\(Int(seconds)) s)" : "Record", systemImage: recording ? "stop.circle" : "mic.circle")
                }
                Button { pickFile() } label: { Label("Choose a file", systemImage: "folder") }.disabled(recording)
                if let clip, !recording {
                    Text("\(clip.lastPathComponent) · \(Int(seconds)) s").font(.caption).foregroundStyle(seconds >= 10 && seconds <= 30 ? Color.secondary : Color.orange)
                }
            }
            Toggle(isOn: $consent) {
                Text("This is my own voice, or I have the person's permission to make a voice from it. I won't use it to pretend to be someone.")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { stopRecording(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save voice") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(!consent || clip == nil || recording || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || seconds < 8 || seconds > 40)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func startRecording() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("air-clip-\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        guard let r = try? AVAudioRecorder(url: url, settings: settings), r.record() else { error = "Couldn't start recording."; return }
        recorder = r; clip = url; seconds = 0; recording = true; error = nil
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                seconds = recorder?.currentTime ?? 0
                if seconds >= 30 { stopRecording() }
            }
        }
    }

    private func stopRecording() {
        timer?.invalidate(); timer = nil
        if let r = recorder { seconds = r.currentTime; r.stop() }
        recorder = nil; recording = false
    }

    private func pickFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let u = p.url, let f = try? AVAudioFile(forReading: u) else { return }
        clip = u
        seconds = Double(f.length) / f.processingFormat.sampleRate
        error = seconds > 40 ? "That's longer than 30 seconds; trim it first." : nil
    }

    /// Saved as 24 kHz mono 16-bit WAV plus a consent record.
    private func save() {
        guard let clip else { return }
        let safe = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        do {
            try FileManager.default.createDirectory(at: VoiceCatalog.cloneDir, withIntermediateDirectories: true)
            let dest = VoiceCatalog.cloneDir.appendingPathComponent(safe + ".wav")
            let input = try AVAudioFile(forReading: clip)
            let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
            let outSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1,
                                              AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
            let out = try AVAudioFile(forWriting: dest, settings: outSettings, commonFormat: .pcmFormatInt16, interleaved: true)
            guard let conv = AVAudioConverter(from: input.processingFormat, to: fmt) else { throw CocoaError(.fileReadCorruptFile) }
            let inBuf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))!
            try input.read(into: inBuf)
            let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(input.length) * 24000 / input.processingFormat.sampleRate) + 1024)!
            var fed = false
            var err: NSError?
            conv.convert(to: outBuf, error: &err) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return inBuf
            }
            if let err { throw err }
            try out.write(from: outBuf)
            let meta: [String: Any] = ["consent": true, "created": ISO8601DateFormatter().string(from: Date()),
                                       "source": clip.path.contains("air-clip-") ? "recorded" : "file", "seconds": Int(seconds)]
            try JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted)
                .write(to: VoiceCatalog.cloneDir.appendingPathComponent(safe + ".json"))
            dismiss()
        } catch {
            self.error = "Couldn't save the voice: \(error.localizedDescription)"
        }
    }
}
