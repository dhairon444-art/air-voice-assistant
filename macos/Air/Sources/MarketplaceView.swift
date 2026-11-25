import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Personalities: browse the catalogue by category, filter and sort, read the details, try one for
/// a conversation, install, favourite, duplicate and edit, create your own, import and export.
struct MarketplaceView: View {
    @ObservedObject private var market = Marketplace.shared
    @EnvironmentObject var prefs: Prefs
    @Environment(\.airTheme) private var theme

    enum Section: Hashable { case all, installed, favourites, builtIn, category(String) }
    enum Sort: String, CaseIterable, Identifiable { case popular = "Popular", new = "New", az = "A–Z", recent = "Recently used"; var id: String { rawValue } }

    @State private var section: Section = .all
    @State private var query = ""
    @State private var sort: Sort = .popular
    @State private var tone: String = "any"
    @State private var honesty: String = "any"
    @State private var length: String = "any"
    @State private var webOnly = false
    @State private var source: String = "any"
    @State private var detail: CatalogItem?
    @State private var showWizard = false
    @State private var importURL = ""
    @State private var showImportURL = false

    static let categories = ["Professionals", "Learning & Teaching", "Research & Analysis", "Business & Marketing", "Career",
                             "Writing & Creative", "Coaching & Wellbeing", "Spiritual & Astrology", "Tech & Code",
                             "Languages", "Debate & Critical thinking", "Skills", "Mine", "Fun & Characters"]

    private var builtIns: [CatalogItem] {
        Personas.presets.map { p in
            CatalogItem(id: p.id, kind: "personality", name: p.name, emoji: ProSpecs.spec(p.id)?.emoji ?? "⭐️", summary: p.summary, category: "Built-in",
                        tags: ["built-in"], tone: p.id == "freespirit" ? "emotional" : (p.id == "sparring" ? "blunt" : "objective"),
                        honesty: "factual", length: "concise", uses_web: true, voice: p.id == "freespirit" ? "af_bella" : "af_heart",
                        popularity: 10_000, original: p.text, removed: [], layered: p.text,
                        source: CatalogSource(name: "Air", url: "", author: "Air", licence: "Air"), added: nil)
        }
    }

    private var filtered: [CatalogItem] {
        var items: [CatalogItem]
        switch section {
        case .all: items = market.all
        case .installed: items = builtIns.filter { !market.hiddenBuiltins.contains($0.id) } + market.installed.compactMap(market.item) +
            market.custom.filter { !market.installed.contains($0.id) }
        case .favourites: items = market.all.filter { market.favourites.contains($0.id) }
        case .builtIn: items = builtIns
        case .category(let c): items = c == "Mine" ? market.custom : market.all.filter { $0.category == c }
        }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            items = items.filter {
                $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q) ||
                    $0.tags.contains { $0.contains(q) } || $0.category.lowercased().contains(q)
            }
        }
        if tone != "any" { items = items.filter { $0.tone == tone } }
        if honesty != "any" { items = items.filter { $0.honesty == honesty } }
        if length != "any" { items = items.filter { $0.length == length } }
        if webOnly { items = items.filter(\.uses_web) }
        if source != "any" { items = items.filter { $0.source.name == source } }
        switch sort {
        case .popular: items.sort { $0.popularity > $1.popularity }
        case .new: items.sort { ($0.added ?? "") > ($1.added ?? "") }
        case .az: items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recent: items.sort { (market.recent[$0.id] ?? .distantPast) > (market.recent[$1.id] ?? .distantPast) }
        }
        return items
    }

    private var filtersActive: Bool {
        tone != "any" || honesty != "any" || length != "any" || webOnly || source != "any"
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
            VStack(spacing: 0) {
                toolbar
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if section == .all && query.isEmpty && !filtersActive {
                            let pinned = market.all.filter { market.favourites.contains($0.id) }
                            if !pinned.isEmpty { row(title: "Pinned", items: pinned) }
                            let recent = market.recentlyUsed
                            if !recent.isEmpty { row(title: "Recently used", items: recent) }
                            row(title: "Professionals", items: market.professionals.sorted { $0.popularity > $1.popularity }.prefix(10))
                            row(title: "Air's own", items: builtIns)
                            let rec = market.recommended()
                            if !rec.isEmpty { row(title: "Recommended for you", items: rec) }
                        }
                        let items = filtered
                        Text("\(items.count) \(items.count == 1 ? "result" : "results")").font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)], spacing: 12) {
                            ForEach(items) { it in
                                MarketCard(item: it, installed: isInstalled(it), favourite: market.favourites.contains(it.id))
                                    .onTapGesture { detail = it }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(item: $detail) { it in MarketDetail(item: it, builtIn: builtIns.contains { $0.id == it.id }) }
        .onAppear {
            // Screenshots: -AirMarketDetail <name> opens a detail page, -AirMarketWizard YES the wizard.
            let d = UserDefaults.standard
            if let n = d.string(forKey: "AirMarketDetail") { detail = market.all.first { $0.name == n } ?? builtIns.first { $0.name == n } }
            if d.bool(forKey: "AirMarketWizard") { showWizard = true }
            if let c = d.string(forKey: "AirMarketCategory") { section = .category(c) }
        }
        .sheet(isPresented: $showWizard) { PersonalityWizard() }
        .alert("Import from a link", isPresented: $showImportURL) {
            TextField("https://…", text: $importURL)
            Button("Import") { importFromURL() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A JSON, YAML, Markdown or text file. Anything that tries to override Air's safety rules is removed.")
        }
    }

    private func isInstalled(_ it: CatalogItem) -> Bool {
        builtIns.contains { $0.id == it.id } ? !market.hiddenBuiltins.contains(it.id) : market.isInstalled(it.id)
    }

    private var sidebar: some View {
        List(selection: Binding(get: { section }, set: { if let s = $0 { section = s } })) {
            Label("All", systemImage: "square.grid.2x2").tag(Section.all)
            Label("Installed", systemImage: "checkmark.circle").tag(Section.installed)
            Label("Favourites", systemImage: "star").tag(Section.favourites)
            Label("Built-in", systemImage: "seal").tag(Section.builtIn)
            SwiftUI.Section("Categories") {
                ForEach(Self.categories, id: \.self) { c in
                    HStack {
                        Text(c)
                        Spacer()
                        Text("\(c == "Mine" ? market.custom.count : (c == "Professionals" ? market.professionals.count : market.catalog.filter { $0.category == c }.count))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(Section.category(c))
                }
            }
        }
        .listStyle(.sidebar)
        .amoledList()
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search names, descriptions and tags", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            Menu {
                Picker("Tone", selection: $tone) {
                    Text("Any tone").tag("any")
                    ForEach(["objective", "warm", "blunt", "playful", "emotional"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Honesty", selection: $honesty) {
                    Text("Any").tag("any"); Text("Strictly factual").tag("factual"); Text("Creative").tag("creative")
                }
                Picker("Length", selection: $length) {
                    Text("Any").tag("any"); Text("Concise").tag("concise"); Text("In-depth").tag("in-depth")
                }
                Toggle("Uses the web and tools", isOn: $webOnly)
                Picker("Source", selection: $source) {
                    Text("Any source").tag("any")
                    ForEach(["Air", "prompts.chat", "Fabric", "PersonaNexus", "You"], id: \.self) { Text($0).tag($0) }
                }
                Divider()
                Button("Clear Filters") { tone = "any"; honesty = "any"; length = "any"; webOnly = false; source = "any" }
            } label: {
                Label(filtersActive ? "Filters •" : "Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
                .fixedSize()
            Spacer(minLength: 0)
            Menu {
                Button("New Personality…") { showWizard = true }
                Divider()
                Button("Import from File…") { importFromFile() }
                Button("Import from Link…") { showImportURL = true }
                Divider()
                Button(market.refreshing ? "Refreshing…" : "Refresh Catalogue") { market.refresh(python: AirPaths.python) }
                    .disabled(market.refreshing)
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: { showWizard = true }
            .fixedSize()
            .help("New personality (click), or import and refresh (menu)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func row<S: Sequence>(title: String, items: S) -> some View where S.Element == CatalogItem {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(items)) { it in
                        MarketCard(item: it, installed: isInstalled(it), favourite: market.favourites.contains(it.id))
                            .frame(width: 240)
                            .onTapGesture { detail = it }
                    }
                }
            }
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, UTType(filenameExtension: "md") ?? .plainText,
                                     UTType(filenameExtension: "yaml") ?? .plainText, UTType(filenameExtension: "yml") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { detail = try market.importFile(url) } catch { market.lastError = error.localizedDescription }
    }

    private func importFromURL() {
        guard let url = URL(string: importURL.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                detail = try market.importData(data, name: url.deletingPathExtension().lastPathComponent, source: url)
            } catch {
                market.lastError = error.localizedDescription
            }
        }
    }
}

struct MarketCard: View {
    let item: CatalogItem
    let installed: Bool
    let favourite: Bool
    @Environment(\.airTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(item.emoji).font(.system(size: 26))
                    .frame(width: 40, height: 40)
                    .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer()
                if favourite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                if installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent).help("Installed") }
            }
            Text(item.name).font(.headline).lineLimit(1)
            Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            HStack(spacing: 6) {
                Chip(text: item.category == "Professionals" ? (ProSpecs.spec(item.id)?.category ?? item.category) : item.category)
                Chip(text: item.source.licence, symbol: "doc.badge.ellipsis")
                Spacer(minLength: 0)
                Image(systemName: "waveform").font(.caption2).foregroundStyle(.tertiary)
                Text(Voices.name(item.voice)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .panelBackground(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(installed ? theme.accent.opacity(0.5) : Color.secondary.opacity(0.2)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name). \(item.summary). \(item.category). \(installed ? "Installed" : "Not installed")")
        .accessibilityAddTraits(.isButton)
    }
}

struct Chip: View {
    let text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
    }
}

struct MarketDetail: View {
    let item: CatalogItem
    let builtIn: Bool
    @ObservedObject private var market = Marketplace.shared
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var web: WebController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.airTheme) private var theme
    @State private var busy = ""
    @State private var editing: CatalogItem?

    private var installed: Bool { builtIn ? !market.hiddenBuiltins.contains(item.id) : market.isInstalled(item.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Text(item.emoji).font(.system(size: 40))
                    .frame(width: 64, height: 64)
                    .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.title2.weight(.semibold))
                    Text(item.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Chip(text: item.category)
                        Chip(text: item.tone.capitalized)
                        Chip(text: item.honesty == "creative" ? "Creative" : "Factual")
                        Chip(text: item.source.licence, symbol: "doc.badge.ellipsis")
                    }
                }
                Spacer()
                Button { market.toggleFavourite(item.id) } label: {
                    Image(systemName: market.favourites.contains(item.id) ? "star.fill" : "star")
                }
                .buttonStyle(.borderless).font(.title2).foregroundStyle(.yellow)
                .help("Favourite")
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        if builtIn {
                            Button(installed ? "Hide" : "Show") {
                                if installed { market.hiddenBuiltins.insert(item.id) } else { market.hiddenBuiltins.remove(item.id) }
                            }
                        } else if installed {
                            Button("Uninstall", role: .destructive) { market.uninstall(item.id) }
                        } else {
                            Button("Install") { install() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        }
                        if !item.isSkill {
                            Button("Try It") { tryIt() }
                                .help("Use it for the next conversation only, without installing")
                            if !installed || builtIn { } else {
                                Button("Use Now") { prefs.personality = item.id; market.markUsed(item.id); dismiss() }
                            }
                        }
                        Button("Duplicate & Edit") {
                            if var sp = market.spec(item.id) {
                                sp.id = "my-\(UUID().uuidString.prefix(8).lowercased())"
                                sp.name += " (my copy)"
                                sp.category = "Mine"
                                sp.text = sp.compiled()
                                market.specs[sp.id] = sp
                                editing = market.saveCustom(name: sp.name, emoji: sp.emoji, summary: sp.role, text: sp.text ?? "",
                                                            voice: sp.voice, replacing: sp.id)
                            } else {
                                editing = market.duplicate(item.id)
                            }
                        }
                        Button("Export…") { export() }.disabled(builtIn)
                        Spacer()
                        if !busy.isEmpty { ProgressView().controlSize(.small); Text(busy).font(.caption).foregroundStyle(.secondary) }
                    }
                    if !item.isSkill {
                        HStack(spacing: 8) {
                            Label("Suggested voice: \(Voices.name(item.voice))", systemImage: "waveform").foregroundStyle(.secondary)
                            PreviewButton(voice: item.voice)
                            if prefs.voice != item.voice {
                                Button("Use This Voice") { prefs.voice = item.voice }.controlSize(.small)
                            }
                        }
                    }
                    GroupBox("Sample exchange") {
                        if let s = market.samples[item.id] {
                            Text(s).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        } else {
                            HStack {
                                Text("A short example of how this personality talks, written once by Aria's local model and kept.")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Write Sample") { sample() }.disabled(!busy.isEmpty || !web.engineReady)
                            }
                        }
                    }
                    DisclosureGroup("Personality text (what Aria uses)") {
                        Text(market.text(for: item.id) ?? item.layered)
                            .font(.callout.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        if !builtIn && market.refined[item.id] == nil && !item.isSkill {
                            Button("Adapt for Speech with Aria's Model") { refine() }.disabled(!busy.isEmpty || !web.engineReady)
                                .help("Rewrites the converted text into Air's layers with the local model, in the background")
                        }
                    }
                    if item.original != item.layered && !builtIn {
                        DisclosureGroup("Original prompt") {
                            Text(item.original).font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        }
                    }
                    if !item.removed.isEmpty {
                        Label("\(item.removed.count) line(s) were removed because they tried to override Air's safety, confirmation or privacy rules.",
                              systemImage: "shield.lefthalf.filled")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    GroupBox("Source") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(item.source.name) · \(item.source.author)")
                            Text("Licence: \(item.source.licence)").foregroundStyle(.secondary)
                            if let u = URL(string: item.source.url), !item.source.url.isEmpty {
                                Link(item.source.url, destination: u).font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Air's core rules always come first: Aria asks before anything that changes, sends or deletes; nothing private leaves the Mac; she never makes up facts or links; and she stays Aria.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            Divider()
            HStack {
                if let e = market.lastError { Text(e).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 640, height: 640)
        .sheet(item: $editing) { it in PersonalityWizard(editing: it) }
    }

    private func install() {
        market.install(item.id)
        if !item.isSkill {
            // Installing from the detail page also makes it the active personality.
            market.trying = nil
            prefs.personality = item.id
            market.markUsed(item.id)
        }
        if !item.isSkill && market.refined[item.id] == nil && web.engineReady { refine() }
    }

    private func tryIt() {
        if market.trying == nil { UserDefaults.standard.set(prefs.personality, forKey: "airTryPrevious") }
        market.trying = item.id
        prefs.personality = item.id
        dismiss()
        AppActions.showTalk()
    }

    private func export() {
        guard let data = market.exportData(item.id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name + ".json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }

    private func refine() {
        busy = "Refining…"
        EngineTasks.run(kind: "refine", payload: ["name": item.name, "text": item.original, "layered": item.layered]) { out in
            busy = ""
            if let out, !out.isEmpty { market.setRefined(item.id, out) }
        }
    }

    private func sample() {
        busy = "Writing a sample…"
        EngineTasks.run(kind: "sample", payload: ["name": item.name, "text": market.text(for: item.id) ?? item.layered]) { out in
            busy = ""
            if let out, !out.isEmpty { market.setSample(item.id, out) }
        }
    }
}

/// Create or edit a personality as its own character: describe it in a sentence and let Aria draft
/// the fields, or fill them in. A live preview answers a test question before you save.
struct PersonalityWizard: View {
    var editing: CatalogItem? = nil
    @ObservedObject private var market = Marketplace.shared
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var web: WebController
    @Environment(\.dismiss) private var dismiss

    @State private var spec = PersonaSpec.blank()
    @State private var describe = ""
    @State private var question = "Should I raise my freelance rates?"
    @State private var preview = ""
    @State private var busy = ""

    private func list(_ v: Binding<[String]>) -> Binding<String> {
        Binding(get: { v.wrappedValue.joined(separator: "\n") },
                set: { v.wrappedValue = $0.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }
    private var example: Binding<String> {
        Binding(get: { spec.examples.map { "User: \($0.first ?? "")\nAria: \($0.last ?? "")" }.joined(separator: "\n\n") },
                set: { txt in
                    var out: [[String]] = []
                    for block in txt.components(separatedBy: "\n\n") {
                        let u = block.components(separatedBy: "\n").first { $0.hasPrefix("User:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        let a = block.components(separatedBy: "\n").first { $0.hasPrefix("Aria:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let u, let a { out.append([u, a]) }
                    }
                    spec.examples = out
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Simple mode") {
                    HStack(alignment: .top) {
                        TextField("Describe it in a sentence, e.g. a no-nonsense CRM expert who loves holdout tests",
                                  text: $describe, axis: .vertical).lineLimit(1...3)
                        Button("Draft") { draft() }.disabled(describe.isEmpty || !busy.isEmpty || !web.engineReady)
                    }
                }
                Section("Who") {
                    HStack {
                        TextField("Emoji", text: $spec.emoji).frame(width: 60)
                        TextField("Name", text: $spec.name)
                    }
                    TextField("Role (one line)", text: $spec.role)
                    TextField("Expertise", text: $spec.expertise)
                    TextField("Focus topics (one per line)", text: list($spec.focus), axis: .vertical).lineLimit(1...4)
                }
                Section("Tone") {
                    ToneSlider(label: "Casual ↔ Formal", value: $spec.tone.formal)
                    ToneSlider(label: "Blunt ↔ Warm", value: $spec.tone.warmth)
                    ToneSlider(label: "Concise ↔ Detailed", value: $spec.tone.detail)
                    ToneSlider(label: "Cautious ↔ Bold", value: $spec.tone.bold)
                    ToneSlider(label: "Serious ↔ Playful", value: $spec.tone.playful)
                }
                Section("Speaking style") {
                    TextField("Sentence length (e.g. short, punchy)", text: $spec.sentences)
                    TextField("Signature phrases (one per line)", text: list($spec.phrases), axis: .vertical).lineLimit(1...3)
                    TextField("Frameworks it uses (one per line, e.g. SWOT, first principles)", text: list($spec.frameworks), axis: .vertical).lineLimit(1...4)
                    Toggle("Asks questions back", isOn: $spec.asks_questions)
                }
                Section("Do's and don'ts") {
                    TextField("Do (one per line)", text: list($spec.dos), axis: .vertical).lineLimit(1...4)
                    TextField("Don't (one per line)", text: list($spec.donts), axis: .vertical).lineLimit(1...3)
                    TextField("Example lines (User: … / Aria: …)", text: example, axis: .vertical).lineLimit(2...6)
                    TextField("Disclaimer (legal, medical, financial; optional)", text: $spec.disclaimer)
                }
                Section("Defaults") {
                    Picker("Voice", selection: $spec.voice) { ForEach(Voices.all, id: \.id) { Text($0.name).tag($0.id) } }
                    Picker("Brain", selection: $spec.brain) { Text("Fast").tag("fast"); Text("Deeper").tag("deeper") }
                    LabeledContent("Creativity") { Slider(value: $spec.temperature, in: 0.1...1.0) }
                    Picker("Answer length", selection: $spec.length) { Text("Short").tag("short"); Text("Medium").tag("medium"); Text("Long").tag("long") }
                    Picker("Tables & diagrams", selection: $spec.rich) { Text("Rarely").tag("rarely"); Text("When helpful").tag("sometimes"); Text("Often").tag("often") }
                    Toggle("Uses web research", isOn: $spec.web)
                }
                Section("Live preview") {
                    HStack {
                        TextField("Test question", text: $question)
                        Button("Preview") { runPreview() }.disabled(!busy.isEmpty || !web.engineReady || spec.name.isEmpty)
                    }
                    if !busy.isEmpty { HStack { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.secondary) } }
                    if !preview.isEmpty { Text(preview).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Air's core rules (confirmations, privacy, no made-up facts, Aria's identity) always apply.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(spec.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 640, height: 640)
        .onAppear {
            if let e = editing {
                spec = market.spec(e.id) ?? {
                    var b = PersonaSpec.blank(name: e.name); b.id = e.id; b.emoji = e.emoji; b.role = e.summary; b.voice = e.voice
                    return b
                }()
            }
        }
    }

    private func runPreview() {
        busy = "Writing a sample answer…"
        EngineTasks.run(kind: "preview", payload: ["name": spec.name, "text": spec.compiled(), "question": question]) { out in
            busy = ""; preview = out ?? "No answer (is Aria running?)"
        }
    }

    private func draft() {
        busy = "Drafting the fields…"
        EngineTasks.run(kind: "draftspec", payload: ["name": spec.name, "text": describe]) { out in
            busy = ""
            guard let out, let a = out.firstIndex(of: "{"), let b = out.lastIndex(of: "}"),
                  let o = try? JSONSerialization.jsonObject(with: Data(out[a...b].utf8)) as? [String: Any] else { return }
            func strs(_ k: String) -> [String] { (o[k] as? [Any])?.compactMap { $0 as? String } ?? [] }
            if let v = o["name"] as? String { spec.name = v }
            if let v = o["emoji"] as? String { spec.emoji = v }
            if let v = o["role"] as? String { spec.role = v }
            if let v = o["expertise"] as? String { spec.expertise = v }
            spec.focus = strs("focus"); spec.frameworks = strs("frameworks"); spec.phrases = strs("phrases")
            spec.dos = strs("dos"); spec.donts = strs("donts")
            if let t = o["tone"] as? [String: Double] {
                spec.tone = .init(formal: t["formal"] ?? 0.5, warmth: t["warmth"] ?? 0.5, detail: t["detail"] ?? 0.5,
                                  bold: t["bold"] ?? 0.5, playful: t["playful"] ?? 0.3)
            }
            if let ex = o["examples"] as? [[String]] { spec.examples = ex.filter { $0.count == 2 } }
            if let v = o["length"] as? String, ["short", "medium", "long"].contains(v) { spec.length = v }
            if let v = o["temperature"] as? Double { spec.temperature = min(1, max(0.1, v)) }
            if let v = o["disclaimer"] as? String { spec.disclaimer = v }
        }
    }

    private func save() {
        var sp = spec
        if editing == nil || ProSpecs.spec(sp.id) != nil { sp.id = "my-\(UUID().uuidString.prefix(8).lowercased())" }
        sp.category = "Mine"
        sp.text = sp.compiled()
        market.specs[sp.id] = sp
        let item = market.saveCustom(name: sp.name, emoji: sp.emoji, summary: sp.role, text: sp.text ?? "",
                                     voice: sp.voice, replacing: sp.id)
        prefs.personality = item.id
        dismiss()
    }
}

struct ToneSlider: View {
    let label: String
    @Binding var value: Double
    var body: some View { LabeledContent(label) { Slider(value: $value, in: 0...1) } }
}

/// One-off jobs for Aria's local model (refine, sample, draft), through the engine's /api/task.
@MainActor
enum EngineTasks {
    static var port = 0
    static func run(kind: String, payload: [String: String], done: @escaping (String?) -> Void) {
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/api/task") else { done(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = payload
        body["kind"] = kind
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let out = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["text"] as? String
            Task { @MainActor in done(out) }
        }.resume()
    }
}

enum AirPaths {
    static var python: String {
        Bundle.main.object(forInfoDictionaryKey: "AirAriaPythonPath") as? String ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Air/venv-smart/bin/python").path
    }
}
