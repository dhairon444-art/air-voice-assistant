import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case talk = "Talk", history = "History", personalities = "Personalities"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .talk: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case .personalities: return "person.2.crop.square.stack"
        }
    }
}

/// Shared between the window, menus and shortcuts.
@MainActor
final class UIState: ObservableObject {
    @Published var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "AirInitialTab") ?? "") ?? .talk
    @Published var showOnboarding = false
}

struct ContentView: View {
    @EnvironmentObject var model: ModelProcess
    @EnvironmentObject var web: WebController
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var ui: UIState

    var body: some View {
        ZStack {
            // The engine's web view stays in the window (tiny, invisible) so audio keeps running on any tab.
            EngineHost(controller: web).frame(width: 2, height: 2).opacity(0.01).accessibilityHidden(true)
            Group {
                switch ui.tab {
                case .talk: talkView
                case .history: HistoryView()
                case .personalities: MarketplaceView()
                }
            }
        }
        .frame(minWidth: 640, minHeight: 560)
        .surface(.background)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $ui.tab) {
                    ForEach(Tab.allCases) { t in Label(t.rawValue, systemImage: t.symbol).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .fixedSize()
                .help("Talk (⌘1), History (⌘2), Personalities (⌘3)")
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 10) {
                    if web.live {
                        Label("Live", systemImage: "record.circle")
                            .foregroundStyle(.red)
                            .labelStyle(.titleAndIcon)
                            .font(.callout.weight(.medium))
                            .accessibilityLabel("Conversation is live")
                    }
                    if ui.tab == .talk {
                        Toggle(isOn: $prefs.showThinking) { Image(systemName: "sidebar.right") }
                            .toggleStyle(.button)
                            .help(prefs.showThinking ? "Hide thinking (⌥⌘T)" : "Show thinking: Aria's reasoning and activity (⌥⌘T)")
                            .accessibilityLabel("Show thinking")
                    }
                    Button { AppActions.openSettings(.general) } label: { Image(systemName: "gearshape") }
                        .help("Settings (⌘,)")
                        .accessibilityLabel("Settings")
                }
            }
        }
        .sheet(isPresented: $ui.showOnboarding) { OnboardingView() }
        .onChange(of: model.state) { _, s in
            switch s {
            case .ready(let port):
                EngineTasks.port = port
                web.load(port: port, config: prefs.engineConfig)
            default: web.unload()
            }
        }
        .onChange(of: prefs.engineConfigKey) { _, _ in web.updateConfig(prefs.engineConfig) }
        .onChange(of: prefs.personality) { _, _ in web.prime(persona: prefs.persona) }
        .onChange(of: prefs.brain) { _, b in
            model.restart(voice: prefs.voice, persona: prefs.persona, brain: b)
        }
    }

    @ViewBuilder var talkView: some View {
        switch model.state {
        case .ready:
            TalkView()
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
        VStack(spacing: 16) {
            OrbView(state: .connecting, mic: 0, out: 0)
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)
            Text("Aria is waking up").font(.title2.weight(.semibold))
            Text(model.status).foregroundStyle(.secondary).contentTransition(.opacity)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text("\(Int(ctx.date.timeIntervalSince(model.startedAt))) s · usually 15 to 30 s")
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            Label("Everything runs on this Mac.", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct FailedView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Aria couldn't start").font(.title2.weight(.semibold))
            ScrollView {
                Text(message).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 560, maxHeight: 180)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Show Log") { NSWorkspace.shared.open(ModelProcess.logURL) }
                Button("Try Again", action: retry).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var model: ModelProcess
    @State private var notes: [SessionNote] = []
    @State private var selection: SessionNote.ID?
    @State private var query = ""

    private var filtered: [SessionNote] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return notes }
        let words = q.split(separator: " ").map(String.init)
        return notes.filter { n in words.allSatisfy { n.searchText.contains($0) } }
    }

    private var groups: [(day: String, notes: [SessionNote])] {
        let cal = Calendar.current
        var out: [(String, [SessionNote])] = []
        for n in filtered {
            let label: String
            if let d = n.date {
                if cal.isDateInToday(d) { label = "Today" }
                else if cal.isDateInYesterday(d) { label = "Yesterday" }
                else { label = d.formatted(.dateTime.weekday(.wide).day().month(.wide).year()) }
            } else { label = "Undated" }
            if out.last?.0 == label { out[out.count - 1].1.append(n) } else { out.append((label, [n])) }
        }
        return out
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search conversations", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search conversations")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(10)
                List(selection: $selection) {
                    if filtered.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "No conversations yet" : "No matches",
                                               systemImage: query.isEmpty ? "text.bubble" : "magnifyingglass",
                                               description: Text(query.isEmpty ? "Talk to Aria and your conversations appear here." : "Try other words."))
                    }
                    ForEach(groups, id: \.day) { g in
                        Section(g.day) {
                            ForEach(g.notes) { n in HistoryRow(note: n).tag(n.id) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .amoledList()
            }
            .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
            Group {
                if let id = selection, let note = notes.first(where: { $0.id == id }) {
                    SessionDetail(note: note)
                } else {
                    ContentUnavailableView("Pick a conversation", systemImage: "text.bubble",
                                           description: Text("Each conversation is also a note in your Air vault in Obsidian."))
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            .surface(.background)
        }
        .onAppear(perform: reload)
        .onChange(of: model.sessionsChanged) { _, _ in reload() }
    }

    private func reload() {
        notes = SessionNote.all()
        if selection == nil { selection = notes.first?.id }
    }
}

struct HistoryRow: View {
    let note: SessionNote
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.timeLabel).font(.body.weight(.semibold))
                Spacer()
                Text(note.duration).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text([note.personality, note.voiceName].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if !note.summary.isEmpty {
                Text(note.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct SessionDetail: View {
    @Environment(\.airTheme) private var theme
    let note: SessionNote
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(note.title).font(.title2.weight(.semibold))
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([note.url]) } label: {
                            Image(systemName: "folder")
                        }
                        .help("Show the note in Finder").accessibilityLabel("Show in Finder")
                        ViewThatFits {
                            Button { Vault.open(note.url) } label: { Label("Open in Obsidian", systemImage: "arrow.up.forward.app") }
                            Button { Vault.open(note.url) } label: { Image(systemName: "arrow.up.forward.app") }
                                .accessibilityLabel("Open in Obsidian")
                        }
                        .help("Open this conversation in Obsidian")
                    }
                    HStack(spacing: 6) {
                        MetaChip(symbol: "clock", text: "\(note.start)–\(note.end) · \(note.duration)")
                        if !note.personality.isEmpty { MetaChip(symbol: "person.crop.circle", text: note.personality) }
                        MetaChip(symbol: "waveform", text: note.voiceName)
                        if note.status == "in-progress" { MetaChip(symbol: "record.circle", text: "In progress") }
                    }
                }
                if !note.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Summary", systemImage: "text.alignleft").font(.headline)
                        Text(note.summary).textSelection(.enabled)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                let lines = note.transcript()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Conversation").font(.headline)
                    if lines.isEmpty {
                        Text("Nothing was said in this session.").foregroundStyle(.secondary)
                    }
                    if !lines.contains(where: { $0.speaker == "You" }) && !lines.isEmpty {
                        Text("Only Aria's side was recorded in this session.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(line.time).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                .frame(width: 40, alignment: .trailing)
                            Text(line.speaker).font(.callout.weight(.semibold))
                                .foregroundStyle(line.speaker == "You" ? Color.secondary : theme.accent)
                                .frame(width: 34, alignment: .leading)
                            Text(line.text).textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if !note.persona.isEmpty {
                    DisclosureGroup("Personality used") {
                        Text(note.persona).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .id(note.id)
    }
}

struct MetaChip: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}
