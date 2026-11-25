import AppKit
import SwiftUI

/// App-wide actions the views can trigger (set up by the AppDelegate).
@MainActor
enum AppActions {
    static var openSettings: (SettingsTab) -> Void = { _ in }
    static var showOnboarding: () -> Void = {}
    static var showMarketplace: () -> Void = {}
    static var showTalk: () -> Void = {}
}

// MARK: - Talk screen

struct TalkView: View {
    @EnvironmentObject var prefs: Prefs
    @AppStorage("airThinkingWidth") private var width: Double = 340

    var body: some View {
        GeometryReader { geo in
            // Too narrow for a side-by-side inspector: the panel floats over the right edge instead.
            let overlay = geo.size.width - width < 440
            HStack(spacing: 0) {
                TalkColumn()
                if prefs.showThinking && !overlay {
                    ResizeHandle(width: $width, total: geo.size.width)
                    ThinkingSidebar().frame(width: width)
                        .transition(.move(edge: .trailing))
                }
            }
            .overlay(alignment: .trailing) {
                if prefs.showThinking && overlay {
                    ThinkingSidebar()
                        .frame(width: min(width, geo.size.width - 48))
                        .surface(.regularMaterial)
                        .shadow(color: .black.opacity(0.25), radius: 12, x: -2)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: prefs.showThinking)
    }
}

/// Drag to resize the Thinking sidebar; the width is remembered.
struct ResizeHandle: View {
    @Binding var width: Double
    let total: CGFloat
    @State private var start: Double?
    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .overlay(Divider())
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if start == nil { start = width }
                    width = min(max(240, (start ?? width) - g.translation.width), max(260, Double(total) - 440))
                }
                .onEnded { _ in start = nil })
            .accessibilityHidden(true)
    }
}

struct TalkColumn: View {
    @EnvironmentObject var web: WebController
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var model: ModelProcess

    var body: some View {
        VStack(spacing: 0) {
            TalkTopBar()
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 6)
            if let err = web.error {
                Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: err) { web.error = nil }
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 8)
            StateHero()
            Spacer(minLength: 8)
            CaptionsView()
                .frame(maxHeight: .infinity)
            if web.live {
                TypeBox()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            if let ch = web.choice {
                ChoiceCardView(choice: ch)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let card = web.confirm {
                ConfirmCardView(card: card)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ControlBar()
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .surface(.bar)
        }
        .animation(.snappy(duration: 0.25), value: web.confirm)
        .animation(.snappy(duration: 0.25), value: web.error)
    }
}

/// Type to Aria (works with the mic muted).
struct TypeBox: View {
    @EnvironmentObject var web: WebController
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard").foregroundStyle(.secondary)
            TextField(web.micMuted ? "Mic muted. Type to Aria…" : "Or type to Aria…", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(send)
            if !text.isEmpty {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .onChange(of: web.micMuted) { _, muted in if muted { focused = true } }
    }
    private func send() {
        web.say(text)
        text = ""
    }
}

// MARK: Top bar: personality, voice, status chips

struct TalkTopBar: View {
    @Environment(\.airTheme) private var theme
    @EnvironmentObject var web: WebController
    @EnvironmentObject var prefs: Prefs
    @State private var showPersona = false
    @State private var showVoice = false

    var body: some View {
        HStack(spacing: 8) {
            PickerButton(symbol: "person.crop.circle", title: Personas.name(prefs.personality),
                         help: "Personality") { showPersona.toggle() }
                .popover(isPresented: $showPersona, arrowEdge: .bottom) { PersonalityPopover() }
                .disabled(web.live)
            PickerButton(symbol: "waveform", title: Voices.name(prefs.voice), help: "Voice") { showVoice.toggle() }
                .popover(isPresented: $showVoice, arrowEdge: .bottom) { VoicePopover() }
                .disabled(web.live)
            Spacer()
            StatusChip(symbol: "cpu", text: prefs.brain == .fast ? "Fast" : "Deeper",
                       help: "Brain: \(prefs.brain.label). Click to change.") { AppActions.openSettings(.brain) }
            if prefs.thinkFirst && prefs.brain.canThink {
                StatusChip(symbol: "brain", text: "Think first", help: "Aria reasons before answering. Click to change.") {
                    AppActions.openSettings(.brain)
                }
            }
            StatusChip(symbol: !prefs.factCheck ? "globe.badge.chevron.backward" : (web.online ? "checkmark.seal" : "wifi.slash"),
                       text: !prefs.factCheck ? "Fact-check off" : (web.online ? "Fact-check" : "Offline"),
                       tint: prefs.factCheck && !web.online ? .orange : nil,
                       help: !prefs.factCheck ? "Online fact-check is off." :
                             (web.online ? "Facts are checked online; only search words leave your Mac."
                                         : "Offline: Aria answers from what she knows and says so.")) {
                AppActions.openSettings(.online)
            }
        }
    }
}

struct PickerButton: View {
    let symbol: String
    let title: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).fontWeight(.medium)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(help): \(title)")
        .accessibilityHint("Opens a list to choose")
    }
}

struct StatusChip: View {
    let symbol: String
    let text: String
    var tint: Color? = nil
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(text, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint ?? .secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background((tint ?? .secondary).opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct PersonalityPopover: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var web: WebController
    @ObservedObject private var market = Marketplace.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlight: String?
    private let rowHeight: CGFloat = 46

    struct Entry: Identifiable, Hashable { let id: String; let emoji: String; let name: String; let role: String }

    /// Active first, then pinned and recent, then everything else.
    private var entries: [Entry] {
        var seen = Set<String>(), out: [Entry] = []
        func add(_ id: String) {
            guard !seen.contains(id), !market.hiddenBuiltins.contains(id) else { return }
            let spec = market.spec(id), item = market.item(id), preset = Personas.preset(id)
            guard let name = spec?.name ?? item?.name ?? preset?.name ?? (id == Personas.customID ? "Custom" : nil) else { return }
            seen.insert(id)
            out.append(Entry(id: id, emoji: spec?.emoji ?? item?.emoji ?? "✨", name: name,
                             role: spec.map { $0.role } ?? item?.summary ?? preset?.summary ?? "Your own text"))
        }
        add(prefs.personality)
        market.favourites.sorted().forEach(add)
        market.recent.sorted { $0.value > $1.value }.map(\.key).forEach(add)
        Personas.presets.map(\.id).forEach(add)
        market.installedPersonalities.map(\.id).forEach(add)
        ProSpecs.professionals.map(\.id).forEach(add)
        add(Personas.customID)
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? out : out.filter { $0.name.lowercased().contains(q) || $0.role.lowercased().contains(q) }
    }

    var body: some View {
        let list = entries
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search personalities", text: $query).textFieldStyle(.plain)
                    .onSubmit { if let h = highlight ?? list.first?.id { choose(h) } }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            List(list, selection: $highlight) { e in
                HStack(spacing: 10) {
                    Text(e.emoji).font(.title3).frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text(e.role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if e.id == prefs.personality { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
                .frame(height: rowHeight - 8)
                .contentShape(Rectangle())
                .onTapGesture { choose(e.id) }
                .tag(e.id)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // About three rows show; the rest scroll inside (five at most when there are few).
            .frame(height: min(CGFloat(max(list.count, 1)), 3.5) * rowHeight)
            .onKeyPress(.return) { if let h = highlight { choose(h) }; return .handled }
            if prefs.personality == "freespirit" && prefs.brain == .fast {
                Text("Tip: Free Spirit is more reliable with the Deeper brain.").font(.caption).foregroundStyle(.secondary)
            }
            if prefs.personality == "frenchtutor" {
                Text("French sentences use the French voice; feedback covers words, not accent.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Browse Marketplace…") { dismiss(); AppActions.showMarketplace() }
                Spacer()
                Button("Edit…") { dismiss(); AppActions.openSettings(.personality) }
            }
            .buttonStyle(.link)
        }
        .padding(12)
        .frame(width: 330)
        .onAppear { highlight = prefs.personality }
    }

    private func choose(_ id: String) {
        prefs.personality = id
        market.markUsed(id)
        dismiss()
    }
}

struct VoicePopover: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var web: WebController
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Voice").font(.headline).padding(.bottom, 4)
            ForEach(Voices.all, id: \.id) { v in
                HStack {
                    ChoiceRow(title: v.name, subtitle: v.note, selected: prefs.voice == v.id) { prefs.voice = v.id }
                    PreviewButton(voice: v.id)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct PreviewButton: View {
    @Environment(\.airTheme) private var theme
    @EnvironmentObject var web: WebController
    let voice: String
    var body: some View {
        Button { web.preview(voice) } label: {
            Image(systemName: web.previewing == voice ? "stop.circle.fill" : "play.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.accent)
        }
        .buttonStyle(.plain)
        .disabled(!web.engineReady || web.live)
        .help(web.previewing == voice ? "Stop preview" : "Hear this voice")
        .accessibilityLabel(web.previewing == voice ? "Stop preview" : "Play a sample of \(Voices.name(voice))")
    }
}

struct ChoiceRow: View {
    @Environment(\.airTheme) private var theme
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark").font(.caption.weight(.bold))
                    .foregroundStyle(theme.accent).opacity(selected ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(selected ? .semibold : .regular)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Hero: orb + state

struct StateHero: View {
    @EnvironmentObject var web: WebController
    @AppStorage("airOrbFPS") private var orbFPS = 30
    var body: some View {
        VStack(spacing: 14) {
            Orb3DView(state: web.state, meter: web.meter, muted: web.micMuted, fps: orbFPS)
                .frame(width: 220, height: 220)
                .accessibilityHidden(true)
            if let what = web.looking {
                Label("Looking at \(what)", systemImage: "eye.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.red.gradient, in: Capsule())
                    .accessibilityLabel("Aria is looking at \(what)")
                    .transition(.scale.combined(with: .opacity))
            }
            VStack(spacing: 4) {
                let mutedMic = web.live && web.micMuted && (web.state == .listening || web.state == .hearing)
                Label(mutedMic ? "Mic muted" : web.state.title,
                      systemImage: mutedMic ? "mic.slash.fill" : web.state.symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(mutedMic ? Color.orange : Color.primary)
                    .contentTransition(.opacity)
                Text(mutedMic ? "Aria isn't listening. Type below, or unmute with ⇧⌘M." : web.state.hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if web.voiceMuted && web.live {
                    Label("Voice off: captions only (⇧⌘V)", systemImage: "speaker.slash.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(.orange)
                }
                if let r = web.research {
                    ResearchProgressRow(progress: r)
                }
                if web.lag >= 0.8 {
                    Label(String(format: "Running %.1f s behind", web.lag), systemImage: "tortoise")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Aria: \(web.state.title). \(web.state.hint)")
        }
        .animation(.easeInOut(duration: 0.2), value: web.state)
    }
}

/// Research in progress: the current step and the time so far.
struct ResearchProgressRow: View {
    let progress: ResearchProgress
    var body: some View {
        TimelineView(.periodic(from: progress.started, by: 1)) { ctx in
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress.text).lineLimit(1).truncationMode(.tail)
                Text("\(Int(ctx.date.timeIntervalSince(progress.started))) s").monospacedDigit().foregroundStyle(.tertiary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 460)
            .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Researching: \(progress.text)")
    }
}

/// Show thinking, as a right-side inspector: Aria's reasoning text (never spoken) and the activity
/// trace (what she heard, tool calls, searches, pages, sources, memory), one group per turn, the
/// current turn open at the bottom and earlier turns collapsed above.
struct ThinkingSidebar: View {
    @EnvironmentObject var web: WebController
    @EnvironmentObject var prefs: Prefs

    struct Group: Identifiable { let id: UUID; let title: String; let items: [TraceItem] }

    private var groups: [Group] {
        var out: [Group] = []
        var cur: [TraceItem] = []
        func flush() {
            guard let first = cur.first else { return }
            out.append(Group(id: first.id, title: first.kind == "heard" ? first.text : "Session", items: cur))
            cur = []
        }
        for t in web.trace {
            if t.kind == "heard" { flush() }
            cur.append(t)
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("Thinking", systemImage: "brain.head.profile").font(.headline)
                Spacer()
                Button("Clear") { web.clearTrace() }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(web.trace.isEmpty)
                Button { prefs.showThinking = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide thinking (⌥⌘T)")
                    .accessibilityLabel("Hide thinking")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if web.trace.isEmpty {
                            Text("Aria's reasoning and activity appear here as she works: what she heard, the tools she calls and with what, searches, pages, sources and memory. Reasoning text needs the Deeper brain with Think first.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        let gs = groups
                        ForEach(gs) { g in
                            TurnTraceGroup(group: g, isCurrent: g.id == gs.last?.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                    .textSelection(.enabled)
                }
                .onChange(of: web.trace.last?.text) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: web.trace.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
        .panelBackground(in: Rectangle())
    }
}

struct TurnTraceGroup: View {
    let group: ThinkingSidebar.Group
    let isCurrent: Bool
    @State private var open: Bool?
    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { open ?? isCurrent }, set: { open = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.items.filter { $0.kind != "heard" || group.title == "Session" }) { item in
                    TraceRow(item: item)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ear").foregroundStyle(.blue)
                Text(group.title).font(.callout.weight(.medium)).lineLimit(2)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct TraceRow: View {
    let item: TraceItem
    @State private var more = false
    private var meta: (String, String, Color) {
        switch item.kind {
        case "heard": return ("ear", "Heard", .blue)
        case "reasoning": return ("brain", "Reasoning", .purple)
        case "call": return ("hammer", "Tool call", .orange)
        case "result": return ("checkmark.circle", "Result", .green)
        case "research": return ("magnifyingglass", "Research", .teal)
        case "sources": return ("link", "Sources", .teal)
        case "memory": return ("books.vertical", "Memory", .pink)
        default: return ("circle", item.kind.capitalized, .secondary)
        }
    }
    var body: some View {
        let (symbol, label, tint) = meta
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(item.kind == "call" ? .caption.monospaced() : .caption)
                    .foregroundStyle(item.kind == "reasoning" ? .secondary : .primary)
                    .italic(item.kind == "reasoning")
                    .lineLimit(item.kind == "reasoning" && !more ? 4 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                if item.kind == "reasoning" && item.text.count > 260 {
                    Button(more ? "Less" : "More") { more.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A calm orb: breathes when idle, follows your voice while listening, swirls while thinking,
/// orbits while checking online, and pulses with Aria's voice while she speaks.
struct OrbView: View {
    @Environment(\.airTheme) private var theme
    let state: TalkState
    let mic: Double
    let out: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch state {
        case .checking: return .teal
        case .working: return .orange
        case .speaking: return theme.accent
        case .thinking: return .purple
        default: return theme.accent
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let base = min(size.width, size.height) / 2 * 0.62
                let level = state == .speaking ? out : (state == .listening || state == .hearing ? mic : 0)
                let amp = reduceMotion ? 0 : min(1, level * 5)
                let breathe = reduceMotion ? 0 : (state.isLive ? 0.015 : 0.03) * sin(t * 1.3)
                // halo rings
                for i in 0..<3 {
                    let k = Double(i)
                    let r = base * (1.18 + 0.16 * k + amp * 0.35 * (1 - k * 0.25) + breathe)
                    g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(tint.opacity(0.10 - 0.025 * k)))
                }
                // core with a soft wobble
                var core = Path()
                let n = 96
                for j in 0...n {
                    let a = Double(j) / Double(n) * 2 * .pi
                    let wobble = reduceMotion ? 0 :
                        (0.025 + amp * 0.08) * sin(3 * a + t * (state == .thinking ? 2.4 : 1.1))
                        + (0.015 + amp * 0.05) * sin(5 * a - t * 1.7)
                    let r = base * (1 + breathe + wobble)
                    let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                    if j == 0 { core.move(to: p) } else { core.addLine(to: p) }
                }
                core.closeSubpath()
                let semantic = state == .thinking || state == .checking || state == .working
                if semantic {
                    g.fill(core, with: .radialGradient(
                        Gradient(colors: [tint.opacity(0.55), tint, tint.opacity(0.85)]),
                        center: CGPoint(x: c.x - base * 0.35, y: c.y - base * 0.4),
                        startRadius: 0, endRadius: base * 1.6))
                } else {
                    // The theme's gradient, slowly turning, with a soft glass highlight.
                    let spin = reduceMotion ? 0 : t * 0.25
                    let d = CGPoint(x: cos(spin) * base, y: sin(spin) * base)
                    g.fill(core, with: .linearGradient(Gradient(colors: theme.colors),
                                                       startPoint: CGPoint(x: c.x - d.x, y: c.y - d.y),
                                                       endPoint: CGPoint(x: c.x + d.x, y: c.y + d.y)))
                    g.fill(core, with: .radialGradient(
                        Gradient(colors: [.white.opacity(0.38), .white.opacity(0)]),
                        center: CGPoint(x: c.x - base * 0.35, y: c.y - base * 0.42),
                        startRadius: 0, endRadius: base * 1.1))
                }
                // thinking: rotating arc; checking: orbiting dot
                if state == .thinking || state == .connecting {
                    let r = base * 1.22
                    var arc = Path()
                    let start = reduceMotion ? 0 : t * 2.2
                    arc.addArc(center: c, radius: r, startAngle: .radians(start), endAngle: .radians(start + 1.6), clockwise: false)
                    g.stroke(arc, with: .color(tint.opacity(0.9)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                if state == .checking || state == .working {
                    let r = base * 1.25
                    let a = reduceMotion ? 0 : t * 2.6
                    let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                    g.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(tint))
                }
            }
        }
    }
}

// MARK: Captions

struct CaptionsView: View {
    @EnvironmentObject var web: WebController
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if web.turns.isEmpty {
                        Text(web.live ? "Your words and Aria's replies appear here as you talk."
                                      : "Captions of both sides appear here. Conversations are saved to your Air vault.")
                            .font(.callout).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }
                    ForEach(web.turns) { turn in
                        TurnView(turn: turn).id(turn.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: web.turns) { _, turns in
                if let last = turns.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

struct TurnView: View {
    @Environment(\.airTheme) private var theme
    let turn: Turn
    var body: some View {
        if turn.speaker == .you {
            HStack {
                Spacer(minLength: 80)
                Text(turn.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("You said: \(turn.text)")
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkle").foregroundStyle(theme.accent).padding(.top, 3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(turn.text.trimmingCharacters(in: .whitespaces))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if turn.interrupted {
                            Text("Interrupted").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Aria said: \(turn.text)")
                }
                ForEach(turn.blocks) { DisplayBlockView(block: $0).padding(.leading, 24) }
                if !turn.sources.isEmpty { SourcesRow(sources: turn.sources).padding(.leading, 24) }
                ForEach(turn.files, id: \.self) { FileRow(url: $0).padding(.leading, 24) }
            }
        }
    }
}

struct SourcesRow: View {
    let sources: [Source]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Sources").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(sources.enumerated()), id: \.element.id) { i, s in
                    Link(destination: s.url) {
                        HStack(spacing: 4) {
                            Text("\(i + 1)").font(.caption2.weight(.bold)).monospacedDigit()
                                .padding(.horizontal, 4).background(.quaternary, in: Capsule())
                            Text(s.host).font(.caption)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                    .help(s.title)
                    .accessibilityLabel("Source \(i + 1): \(s.title). Opens in your browser.")
                }
            }
        }
    }
}

struct FileRow: View {
    let url: URL
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("Saved in \(url.deletingLastPathComponent().lastPathComponent)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .controlSize(.small)
        .padding(10)
        .panelBackground(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
    }
}

// MARK: Tool confirmation

struct ConfirmCardView: View {
    @Environment(\.airTheme) private var theme
    @EnvironmentObject var web: WebController
    let card: ConfirmCard
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Aria wants to").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(card.text.replacingOccurrences(of: "I'm about to ", with: "").capitalizedFirst)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Say yes or no, or choose below.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Cancel") { web.answer(false) }
                .keyboardShortcut(.cancelAction)
            Button("Confirm") { web.answer(true) }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(16)
        .panelBackground(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.accent.opacity(0.35)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirmation needed: Aria wants to \(card.text)")
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: Controls

struct ControlBar: View {
    @Environment(\.airTheme) private var theme
    @EnvironmentObject var web: WebController
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                MuteButton(on: web.micMuted, onSymbol: "mic.slash.fill", offSymbol: "mic.fill",
                           title: web.micMuted ? "Unmute mic" : "Mute mic", shortcut: "⇧⌘M") { web.toggleMicMute() }
                MuteButton(on: web.voiceMuted, onSymbol: "speaker.slash.fill", offSymbol: "speaker.wave.2.fill",
                           title: web.voiceMuted ? "Unmute voice" : "Mute voice", shortcut: "⇧⌘V") { web.toggleVoiceMute() }
                if !web.live {
                    Image(systemName: "headphones").foregroundStyle(.secondary)
                        .help("Headphones recommended: Aria stops talking when she hears you, so through speakers she may interrupt herself.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { web.toggle() } label: {
                Image(systemName: web.live ? "stop.fill" : "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(web.live ? Color.red.gradient : theme.accent.gradient, in: Circle())
                    .shadow(color: (web.live ? Color.red : theme.accent).opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(!web.engineReady || web.state == .connecting)
            .help(web.live ? "End the conversation" : "Start talking (Space)")
            .accessibilityLabel(web.live ? "End conversation" : "Start talking")

            HStack(spacing: 8) {
                if web.state == .speaking {
                    Button { web.interrupt() } label: { Label("Interrupt", systemImage: "hand.raised") }
                        .help("Stop Aria and listen (Space)")
                } else if web.live && !web.micMuted && (web.state == .listening || web.state == .hearing) {
                    Button { web.endTurn() } label: { Label("Done talking", systemImage: "return") }
                        .help("End your turn now instead of waiting for the pause (Space)")
                }
                Text(web.live ? "Space · Esc to end" : "Space to talk").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct MuteButton: View {
    let on: Bool
    let onSymbol: String
    let offSymbol: String
    let title: String
    let shortcut: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: on ? onSymbol : offSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.secondary)
                .frame(width: 34, height: 34)
                .background(on ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Circle())
        }
        .buttonStyle(.plain)
        .help("\(title) (\(shortcut))")
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Multiple choice: big options with letters, keys 1-6, an optional free answer; quiz results inline.
struct ChoiceCardView: View {
    let choice: ChoicePrompt
    @EnvironmentObject var web: WebController
    @Environment(\.airTheme) private var theme
    @State private var other = ""
    private let letters = Array("ABCDEF")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(choice.quiz ? "Quiz" : "Choose one", systemImage: choice.quiz ? "graduationcap" : "list.bullet.circle")
                .font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
            Text(choice.question).font(.headline).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                ForEach(Array(choice.options.enumerated()), id: \.offset) { i, opt in
                    Button { web.choose(i) } label: {
                        HStack(spacing: 10) {
                            Text(String(letters[i])).font(.callout.weight(.bold))
                                .frame(width: 26, height: 26)
                                .background(badge(i).opacity(0.18), in: Circle())
                            Text(opt).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            if let mark = mark(i) { Image(systemName: mark).foregroundStyle(badge(i)) }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(fill(i), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(badge(i).opacity(0.5)))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [])
                    .disabled(choice.answered != nil)
                    .help("Option \(letters[i]) (key \(i + 1), or say it)")
                }
            }
            if choice.allowOther && choice.answered == nil {
                HStack {
                    TextField("Other…", text: $other).textFieldStyle(.roundedBorder).onSubmit(sendOther)
                    Button("Send", action: sendOther).disabled(other.isEmpty)
                }
            }
            if let ok = choice.correct {
                Label(ok ? "Correct" : "Not quite", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? .green : .red).font(.callout.weight(.semibold))
                if !choice.explanation.isEmpty { Text(choice.explanation).font(.callout).foregroundStyle(.secondary) }
            }
            if choice.answered == nil {
                Text("Click, press 1–\(choice.options.count), or say the letter or the answer.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .panelBackground(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.accent.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }

    private func sendOther() { web.choose(-1, text: other); other = "" }
    private func badge(_ i: Int) -> Color {
        guard choice.answered == i else { return theme.accent }
        if let ok = choice.correct { return ok ? .green : .red }
        return theme.accent
    }
    private func fill(_ i: Int) -> Color { choice.answered == i ? badge(i).opacity(0.15) : Color.secondary.opacity(0.08) }
    private func mark(_ i: Int) -> String? {
        guard choice.answered == i else { return nil }
        if let ok = choice.correct { return ok ? "checkmark.circle.fill" : "xmark.circle.fill" }
        return "checkmark"
    }
}

struct Banner: View {
    let symbol: String
    let tint: Color
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
