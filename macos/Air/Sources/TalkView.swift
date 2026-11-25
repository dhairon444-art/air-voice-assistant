import AppKit
import SwiftUI

/// App-wide actions the views can trigger (set up by the AppDelegate).
@MainActor
enum AppActions {
    static var openSettings: (SettingsTab) -> Void = { _ in }
    static var showOnboarding: () -> Void = {}
}

// MARK: - Talk screen

struct TalkView: View {
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
            if prefs.showThinking {
                ThinkingPanel()
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
                .background(.bar)
        }
        .animation(.snappy(duration: 0.25), value: web.confirm)
        .animation(.snappy(duration: 0.25), value: web.error)
        .animation(.snappy(duration: 0.25), value: prefs.showThinking)
    }
}

// MARK: Top bar: personality, voice, status chips

struct TalkTopBar: View {
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
            StatusChip(symbol: "brain.head.profile", text: "Show thinking",
                       tint: prefs.showThinking ? .accentColor : nil,
                       help: prefs.showThinking ? "Showing Aria's reasoning and activity. Click to hide."
                                                : "Show Aria's reasoning and activity (what she heard, tools, searches, sources).") {
                prefs.showThinking.toggle()
            }
            .accessibilityAddTraits(prefs.showThinking ? .isSelected : [])
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
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Personality").font(.headline).padding(.bottom, 4)
            ForEach(Personas.presets) { p in
                ChoiceRow(title: p.name, subtitle: p.summary, selected: prefs.personality == p.id) {
                    prefs.personality = p.id
                }
            }
            ChoiceRow(title: "Custom", subtitle: "Your own text", selected: prefs.personality == Personas.customID) {
                prefs.personality = Personas.customID
            }
            Divider().padding(.vertical, 4)
            Button("Edit personalities…") { AppActions.openSettings(.personality) }
                .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 320)
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
    @EnvironmentObject var web: WebController
    let voice: String
    var body: some View {
        Button { web.preview(voice) } label: {
            Image(systemName: web.previewing == voice ? "stop.circle.fill" : "play.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(!web.engineReady || web.live)
        .help(web.previewing == voice ? "Stop preview" : "Hear this voice")
        .accessibilityLabel(web.previewing == voice ? "Stop preview" : "Play a sample of \(Voices.name(voice))")
    }
}

struct ChoiceRow: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark").font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor).opacity(selected ? 1 : 0)
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
    var body: some View {
        VStack(spacing: 14) {
            OrbView(state: web.state, mic: web.micLevel, out: web.outLevel)
                .frame(width: 150, height: 150)
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
                Label(web.state.title, systemImage: web.state.symbol)
                    .font(.title2.weight(.semibold))
                    .contentTransition(.opacity)
                Text(web.state.hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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

/// Show thinking: Aria's reasoning text (never spoken) and an activity trace of what she heard,
/// which tools she called with what, the searches, pages and sources, and memory she recalled.
struct ThinkingPanel: View {
    @EnvironmentObject var web: WebController
    @AppStorage("airThinkingExpanded") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    expanded.toggle()
                } label: {
                    Label("Thinking", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse thinking" : "Expand thinking")
                Spacer()
                Text("\(web.trace.count) steps").font(.caption).foregroundStyle(.tertiary)
                Button("Clear") { web.clearTrace() }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(web.trace.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if expanded {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            if web.trace.isEmpty {
                                Text("Aria's reasoning and activity will appear here: what she heard, the tools she calls, searches, pages and sources. Reasoning text needs the Deeper brain with Think first.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(web.trace) { item in
                                TraceRow(item: item).id(item.id)
                            }
                        }
                        .padding(12)
                        .textSelection(.enabled)
                    }
                    .frame(height: 170)
                    .onChange(of: web.trace.last?.text) { _, _ in
                        if let id = web.trace.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }
}

struct TraceRow: View {
    let item: TraceItem
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A calm orb: breathes when idle, follows your voice while listening, swirls while thinking,
/// orbits while checking online, and pulses with Aria's voice while she speaks.
struct OrbView: View {
    let state: TalkState
    let mic: Double
    let out: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch state {
        case .checking: return .teal
        case .working: return .orange
        case .speaking: return .accentColor
        case .thinking: return .purple
        default: return .accentColor
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
                g.fill(core, with: .radialGradient(
                    Gradient(colors: [tint.opacity(0.55), tint, tint.opacity(0.85)]),
                    center: CGPoint(x: c.x - base * 0.35, y: c.y - base * 0.4),
                    startRadius: 0, endRadius: base * 1.6))
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
    let turn: Turn
    var body: some View {
        if turn.speaker == .you {
            HStack {
                Spacer(minLength: 80)
                Text(turn.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("You said: \(turn.text)")
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkle").foregroundStyle(Color.accentColor).padding(.top, 3)
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
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
    }
}

// MARK: Tool confirmation

struct ConfirmCardView: View {
    @EnvironmentObject var web: WebController
    let card: ConfirmCard
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35)))
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
    @EnvironmentObject var web: WebController
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "headphones").foregroundStyle(.secondary)
                Text("Headphones recommended").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Aria stops talking when she hears you, so through speakers she may interrupt herself.")

            Button { web.toggle() } label: {
                Image(systemName: web.live ? "stop.fill" : "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(web.live ? Color.red.gradient : Color.accentColor.gradient, in: Circle())
                    .shadow(color: (web.live ? Color.red : Color.accentColor).opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(!web.engineReady || web.state == .connecting)
            .help(web.live ? "End the conversation" : "Start talking (Space)")
            .accessibilityLabel(web.live ? "End conversation" : "Start talking")

            HStack(spacing: 8) {
                if web.state == .speaking {
                    Button { web.interrupt() } label: { Label("Interrupt", systemImage: "hand.raised") }
                        .help("Stop Aria and listen (Space)")
                } else if web.live && (web.state == .listening || web.state == .hearing) {
                    Button { web.endTurn() } label: { Label("Done talking", systemImage: "return") }
                        .help("End your turn now instead of waiting for the pause (Space)")
                }
                Text(web.live ? "Space · Esc to end" : "Space to talk").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
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
