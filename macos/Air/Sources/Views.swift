import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case talk = "Talk", history = "History", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .talk: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "slider.horizontal.3"
        }
    }
}

enum Voices {
    static let all: [(id: String, label: String)] = [
        ("NATF0", "Natural female 0"), ("NATF1", "Natural female 1"),
        ("NATF2", "Natural female 2"), ("NATF3", "Natural female 3"),
        ("NATM0", "Natural male 0"), ("NATM1", "Natural male 1"),
        ("NATM2", "Natural male 2"), ("NATM3", "Natural male 3"),
        ("VARF0", "Variety female 0"), ("VARF1", "Variety female 1"),
        ("VARF2", "Variety female 2"), ("VARF3", "Variety female 3"),
        ("VARF4", "Variety female 4"),
        ("VARM0", "Variety male 0"), ("VARM1", "Variety male 1"),
        ("VARM2", "Variety male 2"), ("VARM3", "Variety male 3"),
        ("VARM4", "Variety male 4"),
    ]
    static let legacyPersona = "You are Myra, a warm and curious companion. Listen carefully, answer clearly and keep the conversation natural."
    static var defaultPersona: String { Personas.presets[0].text }
}

/// Persona presets, phrased the way NVIDIA's PersonaPlex examples are ("You enjoy having a good
/// conversation." / "You are a wise and friendly teacher..." + scenario + persona details).
enum Personas {
    static let presets: [(name: String, text: String)] = [
        ("Warm companion",
         "You enjoy having a good conversation. Your name is Myra, and you are a warm, kind and encouraging friend who is genuinely curious about the person you are talking to. Have a relaxed, friendly conversation. Give full, thoughtful answers of several sentences, explain things with examples, share your own view, and then ask a gentle follow-up question. Always be patient, supportive and positive; never sarcastic, dismissive or rude."),
        ("Thoughtful teacher",
         "You are a wise and friendly teacher. Answer questions or provide advice in a clear and engaging way. Your name is Myra. Explain ideas step by step with simple, everyday examples, check whether the explanation makes sense, and encourage curiosity with a follow-up question. Be patient and kind, never condescending."),
        ("Coach",
         "You enjoy having a good conversation. Your name is Myra, and you are an upbeat, supportive life coach. Help the person think through their goals and challenges. Listen carefully, reflect back what you heard, offer practical ideas in a few clear steps, and ask an encouraging question to keep them going. Be warm and motivating, never judgmental."),
    ]
    static func name(for text: String) -> String {
        presets.first { $0.text == text }?.name ?? "Custom"
    }
}

struct ContentView: View {
    @EnvironmentObject var model: ModelProcess
    @EnvironmentObject var web: WebController
    @AppStorage("voice") private var voice = "NATF2"
    @AppStorage("persona") private var persona = Voices.defaultPersona
    // `-AirInitialTab History` on the command line opens another tab first (used for testing).
    @State private var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "AirInitialTab") ?? "") ?? .talk

    var body: some View {
        ZStack {
            // The web view stays in the hierarchy so a live conversation keeps running on other tabs.
            talkView.opacity(tab == .talk ? 1 : 0).allowsHitTesting(tab == .talk)
            if tab == .history { HistoryView().background(Color(nsColor: .windowBackgroundColor)) }
            if tab == .settings { SettingsView().background(Color(nsColor: .windowBackgroundColor)) }
        }
        .frame(minWidth: 720, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { t in Label(t.rawValue, systemImage: t.symbol).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
            }
            ToolbarItem(placement: .status) {
                if web.live {
                    Label("Live", systemImage: "record.circle").foregroundStyle(.red)
                }
            }
        }
        .onChange(of: model.state) { _, s in
            switch s {
            case .ready(let port): web.load(port: port, voice: voice, persona: persona)
            default: web.unload()
            }
        }
        .onChange(of: voice) { _, v in web.updateConfig(voice: v, persona: persona) }
        .onChange(of: persona) { _, p in web.updateConfig(voice: voice, persona: p) }
    }

    @ViewBuilder var talkView: some View {
        switch model.state {
        case .ready:
            WebViewHost(controller: web)
        case .failed(let msg):
            FailedView(message: msg) { model.restart(voice: voice, persona: persona) }
        default:
            LoadingView()
        }
    }
}

struct LoadingView: View {
    @EnvironmentObject var model: ModelProcess
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Myra is waking up").font(.title2.weight(.semibold))
            ProgressView().controlSize(.large)
            Text(model.status).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text("\(Int(ctx.date.timeIntervalSince(model.startedAt)))s · first load can take a minute or two")
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            Text("🎧 Use headphones: Myra has no echo cancellation.")
                .font(.callout).padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FailedView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
            Text("The model could not start").font(.title2.weight(.semibold))
            ScrollView {
                Text(message).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 560, maxHeight: 180)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            HStack {
                Button("Try again", action: retry).keyboardShortcut(.defaultAction)
                Button("Show log") { NSWorkspace.shared.open(ModelProcess.logURL) }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: ModelProcess
    @State private var notes: [SessionNote] = []
    @State private var selection: SessionNote.ID?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                if notes.isEmpty {
                    Text("No conversations yet").foregroundStyle(.secondary)
                }
                ForEach(notes) { n in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.title).font(.body.weight(.medium))
                        Text([n.mode, n.duration, n.voice].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(n.id)
                    .contextMenu {
                        Button("Open in Obsidian") { Vault.open(n.url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            Group {
                if let id = selection, let note = notes.first(where: { $0.id == id }) {
                    SessionDetail(note: note)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "text.bubble").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text("Pick a conversation to read it").foregroundStyle(.secondary)
                        Button("Open Air Index in Obsidian") { Vault.open(Vault.indexURL) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: reload)
        .onChange(of: model.sessionsChanged) { _, _ in reload() }
    }

    private func reload() {
        notes = SessionNote.all()
        if selection == nil { selection = notes.first?.id }
    }
}

struct SessionDetail: View {
    let note: SessionNote
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title).font(.title2.weight(.semibold))
                    Text("\(note.mode) · \(note.start)–\(note.end) · \(note.duration) · voice \(note.voice)\(note.status == "in-progress" ? " · in progress" : "")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Vault.open(note.url)
                } label: { Label("Open in Obsidian", systemImage: "arrow.up.forward.app") }
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Persona") {
                        Text(note.persona).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    let lines = note.transcript()
                    if !lines.contains(where: { $0.speaker == "You" }) {
                        Text("\(note.mode)'s side of the conversation. This mode does not transcribe your speech.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if lines.isEmpty {
                        Text("Nothing was said in this session.").italic().foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(line.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(line.speaker).font(.callout.weight(.semibold))
                                .foregroundStyle(line.speaker == "You" ? Color.green : Color.accentColor)
                            Text(line.text).textSelection(.enabled)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(note.id)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: ModelProcess
    @EnvironmentObject var web: WebController
    @AppStorage("voice") private var voice = "NATF2"
    @AppStorage("persona") private var persona = Voices.defaultPersona

    var body: some View {
        Form {
            Section {
                Picker("Voice", selection: $voice) {
                    ForEach(Voices.all, id: \.id) { v in Text("\(v.id) · \(v.label)").tag(v.id) }
                }
            } footer: {
                Text("NAT voices are natural recordings, VAR voices add variety. Changes apply to the next conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Preset", selection: Binding(
                    get: { Personas.name(for: persona) },
                    set: { name in
                        if let p = Personas.presets.first(where: { $0.name == name }) { persona = p.text }
                    })) {
                    ForEach(Personas.presets, id: \.name) { Text($0.name).tag($0.name) }
                    Text("Custom").tag("Custom")
                }
                TextEditor(text: $persona)
                    .font(.body)
                    .frame(minHeight: 120)
                HStack {
                    Spacer()
                    Button("Reset to default") { persona = Voices.defaultPersona }
                }
            } header: {
                Text("Persona")
            } footer: {
                Text("Pick a preset or write your own (editing the text makes it Custom). Sent to the model at the start of each conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Conversation history") {
                LabeledContent("Obsidian vault") {
                    Text(Vault.url.path).font(.caption).textSelection(.enabled).lineLimit(2)
                }
                HStack {
                    Button("Open vault in Obsidian") { Vault.open(Vault.indexURL) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Vault.indexURL]) }
                }
            }
            Section("Model") {
                LabeledContent("Python", value: model.pythonPath)
                LabeledContent("Mode", value: "Myra")
                LabeledContent("Model", value: "nvidia/personaplex-7b-v1 · 4-bit · offline · 127.0.0.1 only")
                HStack {
                    Button("Restart model") { model.restart(voice: voice, persona: persona) }
                        .disabled(web.live)
                    Button("Show log") { NSWorkspace.shared.open(ModelProcess.logURL) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
