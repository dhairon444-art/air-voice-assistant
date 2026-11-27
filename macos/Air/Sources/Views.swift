import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case talk = "Talk", chat = "Chat", history = "History", personalities = "Personalities"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .talk: return "waveform"
        case .chat: return "text.bubble"
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
            Group {
                switch ui.tab {
                case .talk: talkView
                case .chat: chatView
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
                    LiveToggle()
                    Button { AppActions.showAssistant() } label: { Image(systemName: "checklist") }
                        .help("Assistant mode (⇧⌘A)")
                        .accessibilityLabel("Assistant mode")
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
        // Chat unloads the voice engine (more RAM for a bigger model); Talk brings it back.
        .onChange(of: ui.tab) { _, t in
            if UserDefaults.standard.string(forKey: "AirDemo") != nil { return }   // screenshots: no engine
            if t == .chat && model.chatModel != prefs.chatModel {
                web.stop()
                model.restart(voice: prefs.voice, persona: prefs.persona, brain: prefs.brain, chat: prefs.chatModel)
            } else if t == .talk && model.chatModel != nil {
                web.stop()
                model.restart(voice: prefs.voice, persona: prefs.persona, brain: prefs.brain)
            }
        }
        .onChange(of: prefs.chatModel) { _, m in
            if ui.tab == .chat { web.stop(); model.restart(voice: prefs.voice, persona: prefs.persona, brain: prefs.brain, chat: m) }
        }
        .onChange(of: prefs.brain) { _, b in
            if model.chatModel == nil { model.restart(voice: prefs.voice, persona: prefs.persona, brain: b) }
        }
    }

    @ViewBuilder var chatView: some View {
        switch model.state {
        case .ready where model.chatModel != nil || UserDefaults.standard.string(forKey: "AirDemo") != nil: ChatView()
        case .failed(let msg):
            FailedView(message: msg) { model.restart(voice: prefs.voice, persona: prefs.persona, brain: prefs.brain, chat: prefs.chatModel) }
        default: LoadingView()
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
    @EnvironmentObject var web: WebController

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let p = model.progress
            let elapsed = ctx.date.timeIntervalSince(p.since)
            // Within a step, move toward the next stop by its own estimate; never claim more than 95% of it.
            let frac = min(1, p.fraction + (p.next - p.fraction) * min(0.95, elapsed / p.estimate))
            let stalled = elapsed > p.estimate * 1.8 + 6
            let total = ctx.date.timeIntervalSince(model.startedAt)
            VStack(spacing: 0) {
                Orb3DView(state: .idle, meter: web.meter, assembly: frac, extent: 420.0 / 220.0)
                    .frame(width: 420, height: 420)
                    .padding(.top, -60)
                    .padding(.bottom, -100)
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text("Aria is waking up").font(.title3.weight(.semibold))
                    ProgressBar(value: frac).frame(width: 260, height: 4)
                    Text(stalled ? "Still \(p.label.lowercased())… this can take longer when memory is busy."
                                 : "\(p.label)… \(Int(frac * 100))%")
                        .font(.callout).foregroundStyle(stalled ? .orange : .secondary)
                        .contentTransition(.numericText())
                    if total > 4, frac > 0.12, frac < 0.98 {
                        let left = max(1, total / frac * (1 - frac))
                        Text("about \(Int(left.rounded())) s left").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .padding(.top, 24)
                Spacer()
                Label("Everything runs on this Mac.", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary).padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Aria is loading: \(p.label), \(Int(frac * 100)) percent")
        }
    }
}

/// A slim, rounded progress bar in the theme's colours.
struct ProgressBar: View {
    let value: Double
    @Environment(\.airTheme) private var theme
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(LinearGradient(colors: theme.colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, g.size.width * value))
            }
        }
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

struct LegacyHistoryView: View {
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


/// The toolbar's conversation toggle: "Start" when idle, a red "Live" while a conversation is open
/// (orange "Live · Muted" with the mic muted). Same colours as the Island and the menu bar icon.
struct LiveToggle: View {
    @EnvironmentObject var web: WebController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let connecting = web.state == .connecting
        let tint: Color = web.live ? (web.micMuted ? .orange : .red) : .secondary
        Button { web.toggle() } label: {
            HStack(spacing: 6) {
                if web.live {
                    // A steady dot: a forever-repeating pulse costs ~3% CPU in a window that's always on screen.
                    Circle().fill(tint).frame(width: 8, height: 8)
                } else {
                    Image(systemName: connecting ? "ellipsis" : "mic.fill").font(.caption)
                }
                Text(web.live ? (web.micMuted ? "Live · Muted" : "Live") : (connecting ? "Connecting…" : "Start"))
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(web.live ? tint : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(web.live ? tint.opacity(0.15) : Color.secondary.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(web.live ? tint.opacity(0.6) : Color.clear))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(!web.engineReady || connecting)
        .onAppear { pulse = web.live }
        .onChange(of: web.live) { _, l in pulse = l }
        .help(web.live ? "Conversation is live: Aria is listening\(web.micMuted ? " (mic muted)" : ""). Click to end (Esc, ⌘T)."
                       : "Start a conversation (Space, ⌘T, or ⌃⌥Space from anywhere)")
        .accessibilityLabel(web.live ? "End conversation" : "Start conversation")
        .accessibilityValue(web.live ? (web.micMuted ? "Live, mic muted" : "Live") : "Not live")
    }
}
