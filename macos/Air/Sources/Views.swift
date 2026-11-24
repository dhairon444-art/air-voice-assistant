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

struct ContentView: View {
    @EnvironmentObject var model: ModelProcess
    @EnvironmentObject var web: WebController
    @EnvironmentObject var prefs: Prefs
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
            case .ready(let port): web.load(port: port, voice: prefs.voice, persona: prefs.persona)
            default: web.unload()
            }
        }
        .onChange(of: prefs.voice) { _, v in web.updateConfig(voice: v, persona: prefs.persona) }
        .onChange(of: prefs.persona) { _, p in web.updateConfig(voice: prefs.voice, persona: p) }
        .onChange(of: prefs.brain) { _, b in
            model.restart(voice: prefs.voice, persona: prefs.persona, brain: b)
        }
    }

    @ViewBuilder var talkView: some View {
        switch model.state {
        case .ready:
            WebViewHost(controller: web)
        case .failed(let msg):
            FailedView(message: msg) { model.restart(voice: prefs.voice, persona: prefs.persona, brain: prefs.brain) }
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
            Text("Aria is waking up").font(.title2.weight(.semibold))
            ProgressView().controlSize(.large)
            Text(model.status).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text("\(Int(ctx.date.timeIntervalSince(model.startedAt)))s · first load can take a minute or two")
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            Text("🎧 Use headphones: Aria stops talking when she hears you.")
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
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        Form {
            Section {
                Picker("Brain", selection: $prefs.brain) {
                    ForEach(Brain.allCases) { b in Text(b.label).tag(b) }
                }
                .disabled(web.live)
            } footer: {
                Text(prefs.brain.footer + " Aria can use tools on this Mac (apps, calendar, reminders, notes, files, music, Shortcuts, mail); anything that changes, sends or deletes is read back and needs your spoken yes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Voice", selection: $prefs.voice) {
                    ForEach(Voices.all, id: \.id) { v in Text("\(v.id) · \(v.label)").tag(v.id) }
                }
            } footer: {
                Text("Kokoro voices. Changes apply to the next conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Preset", selection: Binding(
                    get: { Personas.presetName(for: prefs.persona) },
                    set: { name in
                        if let p = Personas.templates.first(where: { $0.name == name }) { prefs.persona = p.text }
                    })) {
                    ForEach(Personas.templates, id: \.name) { Text($0.name).tag($0.name) }
                    Text("Custom").tag("Custom")
                }
                TextEditor(text: $prefs.persona)
                    .font(.body)
                    .frame(minHeight: 120)
                HStack {
                    Spacer()
                    Button("Reset to default") { prefs.persona = Personas.defaultText }
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
                LabeledContent("Models", value: "\(prefs.brain.rawValue.split(separator: "/").last ?? "") · parakeet-tdt-0.6b-v2 · Kokoro-82M · offline · 127.0.0.1 only")
                HStack {
                    Button("Restart model") { model.restart(voice: prefs.voice, persona: prefs.persona, brain: prefs.brain) }
                        .disabled(web.live)
                    Button("Show log") { NSWorkspace.shared.open(ModelProcess.logURL) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
