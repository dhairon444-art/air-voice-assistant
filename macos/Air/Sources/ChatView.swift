import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// A model for typed Chat, with its approximate size and whether it fits comfortably on this Mac.
struct ChatModel: Identifiable, Hashable {
    let id: String
    let name: String
    let sizeGB: Double
    let note: String

    static let all: [ChatModel] = [
        ChatModel(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit", name: "Qwen3 4B", sizeGB: 2.3, note: "Fastest; same as the Fast voice brain"),
        ChatModel(id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3 8B", sizeGB: 4.6, note: "Good balance; can think first"),
        ChatModel(id: "mlx-community/Qwen3-14B-4bit", name: "Qwen3 14B", sizeGB: 8.4, note: "Stronger reasoning, slower"),
        ChatModel(id: "mlx-community/Qwen3-30B-A3B-3bit", name: "Qwen3 30B-A3B (3-bit)", sizeGB: 13.4, note: "Big mixture-of-experts, fast for its size"),
        ChatModel(id: "mlx-community/Qwen3-30B-A3B-4bit", name: "Qwen3 30B-A3B (4-bit)", sizeGB: 17.2, note: "Best quality here; heavy"),
        ChatModel(id: "mlx-community/gemma-4-26B-A4B-it-heretic-4bit", name: "Gemma 4 26B Heretic", sizeGB: 15.5, note: "Uncensored Gemma 4; heavy"),
    ]

    /// Downloaded? Resolve the snapshot's weight files (the hub stores them as symlinks into blobs).
    var installed: Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--" + id.replacingOccurrences(of: "/", with: "--") + "/snapshots")
        guard let snaps = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return false }
        for s in snaps {
            let files = (try? FileManager.default.contentsOfDirectory(at: s, includingPropertiesForKeys: nil)) ?? []
            let weights = files.filter { $0.pathExtension == "safetensors" }
            if !weights.isEmpty && weights.allSatisfy({ FileManager.default.fileExists(atPath: $0.resolvingSymlinksInPath().path) }) { return true }
        }
        return false
    }
    /// How it fits next to macOS and the apps on a Mac of this size.
    var fit: String {
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1e9
        if sizeGB > total * 0.55 { return "notRecommended" }
        if sizeGB > total * 0.35 { return "heavy" }
        return "ok"
    }
}

/// Free memory and swap, for the gauge.
struct MemoryReading {
    let usedGB: Double, totalGB: Double, swapGB: Double
    static func now() -> MemoryReading {
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1e9
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        let page = Double(vm_kernel_page_size)
        let used = kr == KERN_SUCCESS ? Double(UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page / 1e9 : 0
        var swap = xsw_usage(), size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        return MemoryReading(usedGB: used, totalGB: total, swapGB: Double(swap.xsu_used) / 1e9)
    }
}

/// Typed Chat: the same Aria (personalities, memory, tools and confirmations) with a choice of bigger
/// models. The voice engine is unloaded while you chat; Read aloud uses the voice on demand.
struct ChatView: View {
    @EnvironmentObject var web: WebController
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var model: ModelProcess
    @Environment(\.airTheme) private var theme
    @State private var draft = ""
    @State private var image: URL?
    @State private var mem = MemoryReading.now()
    @State private var pendingModel: ChatModel?
    @StateObject private var reader = ReadAloud()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if web.turns.isEmpty {
                            Text("Type to Aria. Same personality, memory and tools as voice; the model is \(ChatModel.all.first { $0.id == prefs.chatModel }?.name ?? prefs.chatModel).")
                                .foregroundStyle(.secondary).padding(.top, 30)
                        }
                        ForEach(web.turns) { t in
                            ChatBubble(turn: t, reader: reader).id(t.id)
                        }
                        if let card = web.confirm { ConfirmCardView(card: card) }
                        if let ch = web.choice { ChoiceCardView(choice: ch) }
                        if web.state == .thinking || web.state == .checking || web.state == .working {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(web.state.title).foregroundStyle(.secondary) }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(20)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: web.turns.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            composer
        }
        .onAppear { if web.engineReady && !web.live { web.start() } }
        .onChange(of: web.engineReady) { _, r in if r && !web.live { web.start() } }
        .onReceive(timer) { _ in mem = MemoryReading.now() }
        .alert(item: $pendingModel) { m in
            Alert(title: Text("\(m.name) is not recommended on this Mac"),
                  message: Text("It needs about \(Int(m.sizeGB.rounded())) GB, so macOS will likely swap and everything may slow down. Use it anyway?"),
                  primaryButton: .destructive(Text("Use It Anyway")) { prefs.chatModel = m.id },
                  secondaryButton: .cancel())
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(ChatModel.all) { m in
                    Button {
                        if m.fit == "notRecommended" { pendingModel = m } else { prefs.chatModel = m.id }
                    } label: {
                        Text("\(m.name) · \(String(format: "%.0f", m.sizeGB)) GB" + (m.fit == "notRecommended" ? " · Not recommended on this Mac" : (m.fit == "heavy" ? " · Heavy" : "")))
                    }
                    .disabled(!m.installed)
                }
            } label: {
                Label(ChatModel.all.first { $0.id == prefs.chatModel }?.name ?? "Model", systemImage: "cpu")
            }
            .fixedSize()
            .help("The model for Chat. Switching reloads it (about 10 to 60 seconds).")
            PickerButton(symbol: "person.crop.circle", title: Personas.name(prefs.personality), help: "Personality") {}
                .disabled(true)
            Spacer()
            MemoryGauge(reading: mem)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let image {
                HStack {
                    Label(image.lastPathComponent, systemImage: "photo").font(.caption)
                    Button { self.image = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    Spacer()
                    Text("Read on this Mac by the vision model").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { attach() } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless).help("Attach an image").padding(.bottom, 6)
                TextField("Message Aria", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .buttonStyle(.plain).foregroundStyle(theme.accent)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty && image == nil || !web.live)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return, or ⌘Return)")
            }
        }
        .padding(12)
        .surface(.bar)
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!t.isEmpty || image != nil), web.live else { return }
        if let image {
            web.sendToEngine(["type": "say", "text": t.isEmpty ? "What's in this image?" : t, "image": image.path])
        } else {
            web.say(t)
        }
        draft = ""
        image = nil
    }

    private func attach() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK { image = p.url }
    }
}

struct MemoryGauge: View {
    let reading: MemoryReading
    var body: some View {
        let frac = min(1, reading.usedGB / max(reading.totalGB, 1))
        HStack(spacing: 8) {
            Gauge(value: frac) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(frac > 0.85 ? .red : (frac > 0.7 ? .orange : .green))
                .frame(width: 90)
            Text(String(format: "%.1f / %.0f GB", reading.usedGB, reading.totalGB)).font(.caption.monospacedDigit())
            if reading.swapGB > 1 {
                Label(String(format: "swap %.1f GB", reading.swapGB), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .help("macOS is swapping: bigger models will be slower. A smaller model or closing apps helps.")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: "Memory %.1f of %.0f gigabytes used", reading.usedGB, reading.totalGB))
    }
}

struct ChatBubble: View {
    let turn: Turn
    @ObservedObject var reader: ReadAloud
    @EnvironmentObject var prefs: Prefs
    @Environment(\.airTheme) private var theme
    var body: some View {
        if turn.speaker == .you {
            HStack { Spacer(minLength: 60)
                Text(turn.text).textSelection(.enabled).padding(10)
                    .background(theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownTextView(markdown: turn.text)
                ForEach(turn.blocks) { DisplayBlockView(block: $0) }
                if !turn.sources.isEmpty { SourcesRow(sources: turn.sources) }
                ForEach(turn.files, id: \.self) { FileRow(url: $0) }
                HStack(spacing: 10) {
                    Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { reader.toggle(turn.text, voice: prefs.voice) } label: {
                        Label(reader.playing == turn.text ? "Stop" : "Read aloud", systemImage: reader.playing == turn.text ? "stop.fill" : "speaker.wave.2")
                    }
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.text + turn.blocks.map { "\n\n" + $0.body }.joined(), forType: .string)
    }
}

/// Read aloud with Kokoro (loaded on first use in Chat), via the engine's /api/speak.
@MainActor
final class ReadAloud: ObservableObject {
    @Published var playing: String?
    private var player: AVAudioPlayer?
    func toggle(_ text: String, voice: String) {
        if playing == text { player?.stop(); playing = nil; return }
        guard EngineTasks.port > 0, var c = URLComponents(string: "http://127.0.0.1:\(EngineTasks.port)/api/speak") else { return }
        c.queryItems = [URLQueryItem(name: "text", value: text), URLQueryItem(name: "voice", value: voice)]
        guard let url = c.url else { return }
        playing = text
        URLSession.shared.dataTask(with: url) { data, _, _ in
            Task { @MainActor in
                guard let data, let p = try? AVAudioPlayer(data: data) else { self.playing = nil; return }
                self.player = p
                p.play()
                DispatchQueue.main.asyncAfter(deadline: .now() + p.duration + 0.2) { if self.playing == text { self.playing = nil } }
            }
        }.resume()
    }
}
