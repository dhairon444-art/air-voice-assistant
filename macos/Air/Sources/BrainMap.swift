import AppKit
import SwiftUI

/// Settings > Brain map: who answers what. Presets, a flow map (You -> Orchestrator -> roles) whose
/// path for the last request lights up, drag and drop of models onto roles, and a live memory meter.
struct BrainMapSettings: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var model: ModelProcess
    @EnvironmentObject var web: WebController
    @ObservedObject private var cloud = CloudStore.shared
    @AppStorage(ModelRole.talker.key) private var talker = AriaModels.defaults[.talker]!
    @AppStorage(ModelRole.thinker.key) private var thinker = AriaModels.defaults[.thinker]!
    @AppStorage(ModelRole.heavy.key) private var heavy = AriaModels.defaults[.heavy]!
    @State private var applied: [String] = []
    @State private var refusal: String?
    @State private var showCloud = false
    @State private var dropTarget: ModelRole?

    private var resident: Double { AriaModels.residentGB(talker: talker, thinker: thinker) }
    private var limit: Double { AriaModels.budgetGB - AriaModels.headroomGB }
    private var changed: Bool { applied != [talker, thinker, heavy] }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    presets
                    flowMap
                    if let r = refusal {
                        Label(r, systemImage: "hand.raised").font(.callout).foregroundStyle(.orange)
                            .transition(.opacity)
                    }
                    memory
                    if changed {
                        HStack {
                            Button("Restart Aria with this map") { restart() }
                                .buttonStyle(.borderedProminent).disabled(resident > limit || web.live)
                            Button("Undo") { revert() }
                            if web.live { Text("End the conversation first.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Divider()
                    Toggle("Thinker reasons first", isOn: $prefs.thinkFirst)
                    Text("For questions the thinker answers, it reasons silently first (adds about 10 to 15 seconds to those turns). Chat and simple actions are never slowed down.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Show thinking", isOn: $prefs.showThinking)
                    Text("A panel on the Talk screen shows Aria's reasoning and what she did; it's also saved, collapsed, in the session note.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            Divider()
            ModelShelf(showCloud: $showCloud)
                .frame(width: 230)
        }
        .onAppear { if applied.isEmpty { applied = [talker, thinker, heavy] } }
        .sheet(isPresented: $showCloud) {
            VStack(spacing: 0) {
                Form { CloudModelsSection() }.formStyle(.grouped)
                HStack { Spacer(); Button("Done") { showCloud = false }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            .frame(width: 520, height: 560)
        }
    }

    // MARK: presets

    private var presets: some View {
        HStack(spacing: 8) {
            ForEach(AriaModels.presets) { p in
                PresetButton(title: p.name, note: p.note, on: isPreset(p)) { apply(p) }
            }
            PresetButton(title: "Custom", note: "Your own map", on: !AriaModels.presets.contains(where: isPreset)) {}
                .allowsHitTesting(false)
        }
    }

    private func isPreset(_ p: AriaModels.Preset) -> Bool { p.talker == talker && p.thinker == thinker && p.heavy == heavy }

    private func apply(_ p: AriaModels.Preset) {
        let missing = [p.talker, p.thinker, p.heavy].filter { !$0.isEmpty && !AriaModels.isInstalled($0) }
        if !missing.isEmpty {
            refusal = "\(p.name) needs \(missing.compactMap { AriaModels.model($0)?.name }.joined(separator: ", ")), which isn't installed."
            return
        }
        refusal = nil
        withAnimation(.snappy) { talker = p.talker; thinker = p.thinker; heavy = p.heavy }
    }

    // MARK: flow map

    private var flowMap: some View {
        let lit = web.lastPath
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                FlowNode(title: "You", subtitle: "voice or typing", model: nil, symbol: "person.wave.2", lit: !lit.isEmpty)
                FlowArrow(lit: !lit.isEmpty)
                FlowNode(title: "Orchestrator", subtitle: "router (bge-small, CPU); decides", model: nil,
                         symbol: "arrow.triangle.branch", lit: !lit.isEmpty)
                    .help("The router picks the talker, the thinker or a specialist's lens for each request. It's fixed; the talker breaks close calls.")
            }
            FlowFan(count: 4, lit: [lit.contains("talker"), lit.contains("thinker"), lit.contains("lens"), lit.contains("heavy")])
                .frame(height: 22)
            HStack(alignment: .top, spacing: 10) {
                roleNode(.talker, title: "Talker", subtitle: "chat, quick actions", symbol: "bubble.left.and.text.bubble.right",
                         value: $talker, lit: lit.contains("talker"))
                roleNode(.thinker, title: "Thinker", subtitle: "deep answers, research, plans", symbol: "brain",
                         value: $thinker, lit: lit.contains("thinker"))
                FlowNode(title: "Specialist lens", subtitle: "uses the Thinker", model: AriaModels.model(thinker)?.name ?? "Talker",
                         symbol: "eyeglasses", lit: lit.contains("lens"))
                    .help("A specialist's view (Lawyer, Mentor...) is answered by the thinker.")
                roleNode(.heavy, title: "Heavy brain", subtitle: "on demand; asks first", symbol: "bolt.shield",
                         value: $heavy, lit: lit.contains("heavy"))
            }
            if let why = web.lastRouteWhy, !lit.isEmpty {
                Text("Last request: \(lit.contains("thinker") ? "Thinker" : "Talker")\(lit.contains("lens") ? " with a specialist lens" : "") (\(why))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Drag a model from the right onto a role. The path your last request took lights up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: lit)
    }

    private func roleNode(_ role: ModelRole, title: String, subtitle: String, symbol: String,
                          value: Binding<String>, lit: Bool) -> some View {
        FlowNode(title: title, subtitle: subtitle, model: label(value.wrappedValue, role: role), symbol: symbol, lit: lit,
                 droppable: true, targeted: dropTarget == role, clear: role == .talker ? nil : { value.wrappedValue = "" })
            .dropDestination(for: String.self, action: { items, _ in
                guard let id = items.first else { return false }
                if let why = AriaModels.refuse(id, for: role, talker: talker, thinker: thinker) {
                    withAnimation { refusal = why }
                    return false
                }
                withAnimation(.snappy) { refusal = nil; value.wrappedValue = id }
                return true
            }, isTargeted: { on in
                if on { dropTarget = role } else if dropTarget == role { dropTarget = nil }
            })
    }

    private func label(_ id: String, role: ModelRole) -> String {
        if id.isEmpty { return role == .heavy ? "None" : "None (talker answers)" }
        if let c = CloudRef(id) { return "\(c.provider.short) (cloud)" }
        return AriaModels.model(id)?.name ?? id
    }

    // MARK: memory

    private var memory: some View {
        let used = resident
        let tint: Color = used > limit ? .red : used > limit - 3 ? .orange : .green
        let heavyGB = CloudRef(heavy) == nil ? AriaModels.model(heavy)?.ramGB : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory in use with this map").font(.headline)
                Spacer()
                Text(String(format: "%.1f GB of %.0f GB", used, AriaModels.budgetGB)).monospacedDigit().foregroundStyle(tint)
            }
            GeometryReader { g in
                let w = g.size.width, total = AriaModels.budgetGB
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(tint.gradient).frame(width: max(6, w * min(used, total) / total))
                    if let h = heavyGB {
                        Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).foregroundStyle(.secondary)
                            .frame(width: max(6, w * min(used + h, total) / total))
                    }
                    Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1.5).offset(x: w * limit / total)
                }
            }
            .frame(height: 12)
            .animation(.snappy, value: used)
            Text(breakdown(heavyGB: heavyGB)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if used > limit {
                Label("Too heavy: this leaves under \(Int(AriaModels.headroomGB)) GB for macOS and your apps. Pick a smaller model.",
                      systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            } else if let h = heavyGB, used + h > AriaModels.budgetGB - 2 {
                Label("The heavy brain won't fit next to the thinker; Aria will unload the thinker while it runs.",
                      systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func breakdown(heavyGB: Double?) -> String {
        let t = AriaModels.model(talker)?.ramGB ?? 0
        let k = thinker.isEmpty || thinker == talker ? 0 : (AriaModels.model(thinker)?.ramGB ?? 0)
        let h = CloudRef(heavy) != nil ? "0 (cloud)" : heavyGB.map { String(format: "%.1f when loaded", $0) } ?? "none"
        return String(format: "Talker %.1f · Thinker %.1f · Hearing and voice %.1f · Heavy brain %@", t, k, AriaModels.pipelineGB, h)
    }

    private func restart() {
        applied = [talker, thinker, heavy]
        model.restart(voice: prefs.voice, persona: prefs.persona, brain: prefs.brain)
    }

    private func revert() {
        guard applied.count == 3 else { return }
        talker = applied[0]; thinker = applied[1]; heavy = applied[2]
        refusal = nil
    }
}

/// "cloud:anthropic:claude-opus-5-5" as a heavy-brain choice.
struct CloudRef {
    let provider: CloudProvider
    let model: String
    init?(_ id: String) {
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "cloud", let p = CloudProvider(rawValue: parts[1]) else { return nil }
        provider = p; model = parts[2]
    }
    static func id(_ p: CloudProvider, _ m: String) -> String { "cloud:\(p.rawValue):\(m)" }
}

extension AriaModels {
    /// Why this model can't take this role (nil: it can).
    static func refuse(_ id: String, for role: ModelRole, talker: String, thinker: String) -> String? {
        if let c = CloudRef(id) {
            return role == .heavy ? nil : "\(c.provider.short) is a cloud model: it can only be the heavy brain, and Aria asks before each use."
        }
        guard let m = model(id) else { return "Air hasn't been tested with this model yet." }
        guard m.installed else { return "\(m.name) isn't installed." }
        switch role {
        case .talker:
            if !m.roles.contains(.talker) { return "\(m.name) is too slow to be the talker; the voice needs a quick first word." }
            if residentGB(talker: id, thinker: thinker) > budgetGB - headroomGB { return "With \(m.name) as talker the map would be over the memory budget." }
        case .thinker:
            if !m.roles.contains(.thinker) { return "\(m.name) is too big to stay loaded next to speech; make it the heavy brain instead." }
            if id == talker { return "That's already the talker; the thinker should be a stronger model." }
            if residentGB(talker: talker, thinker: id) > budgetGB - headroomGB { return "With \(m.name) as thinker the map would be over the memory budget." }
        case .heavy:
            break
        }
        return nil
    }
}

// MARK: pieces

struct PresetButton: View {
    let title: String
    let note: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .help(note)
    }
}

struct FlowNode: View {
    let title: String
    let subtitle: String
    let model: String?
    let symbol: String
    let lit: Bool
    var droppable = false
    var targeted = false
    var clear: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(lit ? Color.green : Color.secondary)
                Text(title).font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                if let clear, model != nil, !(model ?? "").hasPrefix("None") {
                    Button(action: clear) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Remove")
                }
            }
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            if let model {
                Text(model).font(.caption.weight(.medium)).lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 11).fill(lit ? Color.green.opacity(0.10) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(
            targeted ? Color.accentColor : (lit ? Color.green : Color.secondary.opacity(0.25)),
            style: StrokeStyle(lineWidth: targeted || lit ? 1.8 : 1, dash: droppable && !lit && !targeted ? [5, 3] : [])))
        .shadow(color: lit ? Color.green.opacity(0.35) : .clear, radius: 8)
        .accessibilityElement(children: .combine)
    }
}

struct FlowArrow: View {
    let lit: Bool
    var body: some View {
        Image(systemName: "arrow.right").font(.callout.weight(.semibold))
            .foregroundStyle(lit ? Color.green : Color.secondary.opacity(0.6))
    }
}

/// The orchestrator fanning out to the role nodes below it.
struct FlowFan: View {
    let count: Int
    let lit: [Bool]
    var body: some View {
        Canvas { ctx, size in
            let top = CGPoint(x: size.width * 0.75, y: 0)
            for i in 0..<count {
                let x = size.width * (CGFloat(i) + 0.5) / CGFloat(count)
                var p = Path()
                p.move(to: top)
                p.addCurve(to: CGPoint(x: x, y: size.height), control1: CGPoint(x: top.x, y: size.height * 0.6),
                           control2: CGPoint(x: x, y: size.height * 0.4))
                let on = i < lit.count && lit[i]
                ctx.stroke(p, with: .color(on ? .green : .secondary.opacity(0.35)), lineWidth: on ? 2.2 : 1)
            }
        }
    }
}

/// Right panel: installed models (drag onto a role), cloud models with a key, and the Marketplace.
struct ModelShelf: View {
    @Binding var showCloud: Bool
    @ObservedObject private var cloud = CloudStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Installed models").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(AriaModels.all.filter(\.installed)) { m in
                        ShelfItem(title: m.name, detail: String(format: "%.1f GB · %@", m.diskGB, m.note), symbol: "cpu")
                            .draggable(m.id)
                    }
                    let keyed = CloudProvider.allCases.filter { cloud.hasKey[$0] == true }
                    if !keyed.isEmpty {
                        Text("Cloud").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(keyed) { p in
                            let m = cloud.selectedModel(p)
                            ShelfItem(title: p.short, detail: m.isEmpty ? "Key set; test it to pick a model" : m, symbol: "cloud")
                                .draggable(CloudRef.id(p, m.isEmpty ? "default" : m))
                        }
                    }
                }
                .padding(12)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Button { showCloud = true } label: { Label("Cloud keys", systemImage: "key") }
                    .buttonStyle(.plain).help("Add or test Claude and Gemini keys (stored in the Keychain)")
                Button { AppActions.showMarketplace() } label: { Label("Models marketplace", systemImage: "square.grid.2x2") }
                    .buttonStyle(.plain).help("Get more models")
            }
            .font(.callout)
            .padding(12)
        }
        .background(Color.secondary.opacity(0.04))
    }
}

struct ShelfItem: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .contentShape(Rectangle())
        .help("Drag onto a role")
    }
}
