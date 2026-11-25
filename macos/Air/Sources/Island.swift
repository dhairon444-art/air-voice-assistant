import AppKit
import Combine
import SwiftUI

/// The Island: a floating status pill at the top centre of the screen, hugging the notch on
/// notched Macs. It never takes focus (a non-activating panel), shows on every Space and over
/// full-screen apps, appears when a conversation starts, shrinks to a dot after a quiet spell,
/// expands on hover with the last captions and quick controls, and drops down tool confirmations.
@MainActor
final class IslandController: ObservableObject {
    enum Mode: Equatable { case hidden, pill, dot, expanded, confirm }

    @Published private(set) var mode: Mode = .hidden
    @Published var hovering = false { didSet { refresh() } }

    private let web: WebController
    private let prefs: Prefs
    private let open: () -> Void
    private var panel: IslandPanel?
    private var bag = Set<AnyCancellable>()
    private var lastActivity = Date()
    private var timer: Timer?
    /// -AirIslandDemo: keep the Island visible without a live session (screenshots).
    var demo = false

    static var enabled: Bool { UserDefaults.standard.object(forKey: "airIslandEnabled") as? Bool ?? true }
    static var dotDelay: Double {
        let v = UserDefaults.standard.double(forKey: "airIslandDotDelay")
        return v > 0 ? v : 60
    }
    static var display: String { UserDefaults.standard.string(forKey: "airIslandDisplay") ?? "auto" }

    init(web: WebController, prefs: Prefs, open: @escaping () -> Void) {
        self.web = web
        self.prefs = prefs
        self.open = open
        // Anything that counts as activity keeps the pill from shrinking to a dot.
        web.$state.sink { [weak self] s in
            if s != .listening { self?.touch() }
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &bag)
        web.$turns.sink { [weak self] _ in self?.touch() }.store(in: &bag)
        web.meter.$mic.sink { [weak self] l in if l > 0.04 { self?.touch() } }.store(in: &bag)
        web.$confirm.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &bag)
        web.$live.sink { [weak self] live in
            if live { self?.touch() }
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.place(animated: false) }
            .store(in: &bag)
    }

    private func touch() {
        lastActivity = Date()
        if mode == .dot { refresh() }
    }

    func refresh() {
        let next: Mode
        if demo, let f = UserDefaults.standard.string(forKey: "AirIslandMode"),
           let m = ["pill": Mode.pill, "dot": .dot, "expanded": .expanded, "confirm": .confirm][f] {
            next = m
        } else if !Self.enabled || (!web.live && !demo) {
            next = .hidden
        } else if web.confirm != nil {
            next = .confirm
        } else if hovering {
            next = .expanded
        } else if !demo && Date().timeIntervalSince(lastActivity) > Self.dotDelay && web.state == .listening {
            next = .dot
        } else {
            next = .pill
        }
        guard next != mode || (next != .hidden && panel?.isVisible != true) else { return }
        mode = next
        apply()
    }

    private func apply() {
        if mode == .hidden {
            timer?.invalidate(); timer = nil
            panel?.orderOut(nil)
            return
        }
        if panel == nil { makePanel() }
        if timer == nil {
            // Cheap: one check a second, only while the Island is up.
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        place(animated: panel?.isVisible == true)
        panel?.orderFrontRegardless()
        // Keyboard (Return / Esc) for a confirmation: the panel takes key focus without activating Air.
        if mode == .confirm { panel?.makeKey() }
    }

    func size(for m: Mode) -> CGSize {
        switch m {
        case .hidden: return .zero
        case .dot: return CGSize(width: 44, height: 26)
        case .pill: return CGSize(width: 250, height: 38)
        case .expanded: return CGSize(width: 400, height: 150)
        case .confirm: return CGSize(width: 400, height: 132)
        }
    }

    private func makePanel() {
        let p = IslandPanel(contentRect: NSRect(origin: .zero, size: size(for: .pill)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.becomesKeyOnlyIfNeeded = true
        let root = IslandView(controller: self, openAir: open)
            .environmentObject(web).environmentObject(prefs)
            .airThemed()
        let host = NSHostingView(rootView: root)
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        p.contentView = host
        panel = p
    }

    /// The display to use: the one with the active window (auto), the main display, or the built-in one.
    private func screen() -> NSScreen? {
        switch Self.display {
        case "builtin": return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
        case "main": return NSScreen.screens.first
        default:
            if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
               let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
               let w = info.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == front && ($0[kCGWindowLayer as String] as? Int) == 0 }),
               let b = w[kCGWindowBounds as String] as? [String: CGFloat] {
                let primaryH = NSScreen.screens.first?.frame.height ?? 0
                let center = CGPoint(x: (b["X"] ?? 0) + (b["Width"] ?? 0) / 2, y: primaryH - ((b["Y"] ?? 0) + (b["Height"] ?? 0) / 2))
                if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return s }
            }
            return NSScreen.main ?? NSScreen.screens.first
        }
    }

    func place(animated: Bool) {
        guard let panel, let s = screen(), mode != .hidden else { return }
        let size = size(for: mode)
        let notch = s.safeAreaInsets.top
        // Notched Macs: hug the bottom of the notch. Others: just below the menu bar.
        let top = notch > 0 ? s.frame.maxY - notch - 4 : s.visibleFrame.maxY - 6
        let frame = NSRect(x: s.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

/// A borderless panel that can take key focus (for Return/Esc on confirmations) without
/// activating Air.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Views

struct IslandView: View {
    @ObservedObject var controller: IslandController
    let openAir: () -> Void
    @EnvironmentObject var web: WebController
    @EnvironmentObject var prefs: Prefs
    @Environment(\.airTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the Island shows, in priority order.
    private var look: (text: String, symbol: String, tint: Color) {
        if web.error != nil && !web.live { return ("Something went wrong", "exclamationmark.triangle.fill", .orange) }
        if web.micMuted && (web.state == .listening || web.state == .hearing) { return ("Mic muted", "mic.slash.fill", .red) }
        switch web.state {
        case .idle, .connecting: return ("Starting", "ellipsis", .gray)
        case .listening: return ("Listening", "waveform", .green)
        case .hearing: return ("Hearing you", "waveform", .green)
        case .thinking: return ("Thinking", "sparkles", .purple)
        case .checking:
            if let r = web.research { return (r.text.hasPrefix("Reading") ? shortReading(r.text) : "Researching", "globe", .blue) }
            return (web.online ? "Checking online" : "Offline", web.online ? "globe" : "wifi.slash", web.online ? .blue : .orange)
        case .working: return ("Working", "gearshape.fill", .blue)
        case .speaking: return web.voiceMuted ? ("Replying in text", "text.bubble.fill", .white) : ("Speaking", "waveform", .white)
        }
    }

    private func shortReading(_ s: String) -> String {
        // "Reading 6 pages: a, b, c" -> "Reading 6 pages"
        String(s.split(separator: ":").first ?? Substring(s))
    }

    var body: some View {
        let l = look
        VStack(spacing: 0) {
            switch controller.mode {
            case .dot:
                Capsule().fill(.black)
                    .overlay(Circle().fill(l.tint).frame(width: 8, height: 8))
                    .onTapGesture { controller.hovering = true }
            case .confirm:
                confirmCard
            case .expanded:
                expanded(l)
            default:
                pill(l)
            }
        }
        .frame(width: controller.size(for: controller.mode).width, height: controller.size(for: controller.mode).height)
        .onHover { controller.hovering = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: controller.mode)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: web.state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Air: \(l.text)")
    }

    private func pill(_ l: (text: String, symbol: String, tint: Color)) -> some View {
        HStack(spacing: 8) {
            Orb3DView(state: web.state, meter: web.meter, muted: web.micMuted, fps: 15, tiny: true)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text(l.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer(minLength: 4)
            if web.voiceMuted { Image(systemName: "speaker.slash.fill").font(.caption).foregroundStyle(.orange) }
            LevelBars(meter: web.meter, speaking: web.state == .speaking, muted: web.micMuted,
                      tint: l.tint, active: web.state == .listening || web.state == .hearing || web.state == .speaking,
                      busy: web.state == .thinking || web.state == .checking || web.state == .working)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(.black))
        .overlay(Capsule().strokeBorder(l.tint.opacity(0.55), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture(perform: openAir)
    }

    private func expanded(_ l: (text: String, symbol: String, tint: Color)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: l.symbol).foregroundStyle(l.tint)
                Text(l.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                LevelBars(meter: web.meter, speaking: web.state == .speaking, muted: web.micMuted, tint: l.tint,
                          active: web.state == .listening || web.state == .hearing || web.state == .speaking,
                          busy: web.state == .thinking || web.state == .checking || web.state == .working)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let you = web.turns.last(where: { $0.speaker == .you }) {
                    Text("You: \(you.text)").font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                if let aria = web.turns.last(where: { $0.speaker == .aria }) {
                    Text(aria.text).font(.caption).foregroundStyle(.white).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                IslandButton(symbol: web.micMuted ? "mic.slash.fill" : "mic.fill", on: web.micMuted,
                             help: web.micMuted ? "Unmute mic (⇧⌘M)" : "Mute mic (⇧⌘M)") { web.toggleMicMute() }
                IslandButton(symbol: web.voiceMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", on: web.voiceMuted,
                             help: web.voiceMuted ? "Unmute voice (⇧⌘V)" : "Mute voice (⇧⌘V)") { web.toggleVoiceMute() }
                IslandButton(symbol: "hand.raised.fill", on: false, help: "Interrupt") { web.interrupt() }
                    .disabled(web.state != .speaking)
                IslandButton(symbol: "brain.head.profile", on: prefs.showThinking, help: "Show thinking (⌥⌘T)") {
                    prefs.showThinking.toggle(); openAir()
                }
                Spacer()
                IslandButton(symbol: "macwindow", on: false, help: "Open Air", action: openAir)
                IslandButton(symbol: "stop.fill", on: false, tint: .red, help: "End conversation") { web.stop() }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(l.tint.opacity(0.5), lineWidth: 1))
    }

    private var confirmCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Aria wants to", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
            Text(web.confirm?.text ?? "")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Text("Say yes or no, or press Return / Esc").font(.caption2).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button { web.answer(false) } label: { Label("Cancel", systemImage: "xmark") }
                    .keyboardShortcut(.cancelAction)
                Button { web.answer(true) } label: { Label("Confirm", systemImage: "checkmark") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(theme.accent.opacity(0.7), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

/// Five bars: follow the live level while listening or speaking, ripple gently while busy.
struct LevelBars: View {
    @ObservedObject var meter: AudioMeter
    let speaking: Bool
    let muted: Bool
    private var level: Double { speaking ? meter.out : (muted ? 0 : meter.mic) }
    let tint: Color
    let active: Bool
    let busy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    private let weights: [Double] = [0.55, 0.85, 1.0, 0.8, 0.5]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(tint)
                    .frame(width: 3, height: height(i))
            }
        }
        .frame(height: 18)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .onAppear { if busy && !reduceMotion { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { phase = true } } }
        .onChange(of: busy) { _, b in
            phase = false
            if b && !reduceMotion { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { phase = true } }
        }
        .accessibilityHidden(true)
    }

    private func height(_ i: Int) -> CGFloat {
        if active { return CGFloat(4 + min(1, level * 6) * 14 * weights[i]) }
        if busy { return CGFloat(phase ? (i % 2 == 0 ? 14 : 6) : (i % 2 == 0 ? 6 : 14)) }
        return 4
    }
}

struct IslandButton: View {
    let symbol: String
    let on: Bool
    var tint: Color = .white
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? .black : tint)
                .frame(width: 30, height: 26)
                .background(on ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.white.opacity(0.14)), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Settings › Appearance › Island.
struct IslandSettingsSection: View {
    @AppStorage("airIslandEnabled") private var enabled = true
    @AppStorage("airIslandDotDelay") private var delay = 60.0
    @AppStorage("airIslandDisplay") private var display = "auto"
    var body: some View {
        Section {
            Toggle("Show the Island while talking", isOn: $enabled)
            Picker("Shrink to a dot after", selection: $delay) {
                Text("30 seconds").tag(30.0)
                Text("1 minute").tag(60.0)
                Text("2 minutes").tag(120.0)
                Text("5 minutes").tag(300.0)
            }
            .disabled(!enabled)
            Picker("Display", selection: $display) {
                Text("The one I'm using").tag("auto")
                Text("Main display").tag("main")
                Text("Built-in display").tag("builtin")
            }
            .disabled(!enabled)
        } header: {
            Text("Island")
        } footer: {
            Text("A small status pill under the notch (or the menu bar) while you talk: listening, thinking, checking online, speaking, muted. Hover for the last lines and quick controls; confirmations drop down from it. Click it to open Air.")
        }
    }
}
