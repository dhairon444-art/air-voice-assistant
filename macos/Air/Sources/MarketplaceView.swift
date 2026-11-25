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

    static let categories = ["Learning & Teaching", "Research & Analysis", "Business & Marketing", "Career",
                             "Writing & Creative", "Coaching & Wellbeing", "Spiritual & Astrology", "Tech & Code",
                             "Fun & Characters", "Languages", "Debate & Critical thinking", "Skills", "Mine"]

    private var builtIns: [CatalogItem] {
        Personas.presets.map { p in
            CatalogItem(id: p.id, kind: "personality", name: p.name, emoji: "⭐️", summary: p.summary, category: "Built-in",
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
                            row(title: "Featured", items: builtIns + market.catalog.filter { !$0.isSkill }.sorted { $0.popularity > $1.popularity }.prefix(6))
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
                        Text("\(c == "Mine" ? market.custom.count : market.catalog.filter { $0.category == c }.count)")
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
                Chip(text: item.category)
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
                            if builtIn {
                                editing = market.saveCustom(name: item.name + " (my copy)", emoji: item.emoji, summary: item.summary,
                                                            text: item.layered, voice: item.voice)
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
                    DisclosureGroup("Layered personality (what Aria uses)") {
                        Text(market.text(for: item.id) ?? item.layered)
                            .font(.callout.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        if !builtIn && market.refined[item.id] == nil && !item.isSkill {
                            Button("Refine with Aria's Model") { refine() }.disabled(!busy.isEmpty || !web.engineReady)
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

/// Create a personality: describe it in words and let Aria's model draft the layers, or fill in
/// the parts yourself.
struct PersonalityWizard: View {
    var editing: CatalogItem? = nil
    @ObservedObject private var market = Marketplace.shared
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var web: WebController
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var emoji = "✨"
    @State private var purpose = ""
    @State private var warmth = 0.5
    @State private var directness = 0.6
    @State private var playfulness = 0.3
    @State private var values = "Truth, Usefulness, Comfort"
    @State private var rules = ""
    @State private var examples = ""
    @State private var describe = ""
    @State private var text = ""
    @State private var voice = "af_heart"
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Emoji", text: $emoji)
                    TextField("Purpose (one line)", text: $purpose)
                    Picker("Voice", selection: $voice) { ForEach(Voices.all, id: \.id) { Text($0.name).tag($0.id) } }
                } header: { Text(editing == nil ? "New personality" : "Edit personality") }
                Section("Describe it in your own words (optional)") {
                    TextField("e.g. a calm astrology guide who explains charts simply and admits what's unproven", text: $describe, axis: .vertical)
                        .lineLimit(2...4)
                    HStack {
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        Button("Draft the Layers with Aria") { draft() }.disabled(describe.isEmpty || busy || !web.engineReady)
                    }
                }
                Section("Tone") {
                    LabeledContent("Warmth") { Slider(value: $warmth) }
                    LabeledContent("Directness") { Slider(value: $directness) }
                    LabeledContent("Playfulness") { Slider(value: $playfulness) }
                    TextField("Values, most important first", text: $values)
                    TextField("Rules (one per line)", text: $rules, axis: .vertical).lineLimit(2...5)
                    TextField("Example exchange (optional)", text: $examples, axis: .vertical).lineLimit(2...5)
                    Button("Build Text from These") { text = compose() }
                }
                Section("Personality text") {
                    TextEditor(text: $text).font(.callout.monospaced()).frame(minHeight: 140)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Air's core rules are always added on top.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (text.isEmpty && purpose.isEmpty))
            }
            .padding(14)
        }
        .frame(width: 620, height: 620)
        .onAppear {
            if let e = editing { name = e.name; emoji = e.emoji; purpose = e.summary; text = market.text(for: e.id) ?? e.layered; voice = e.voice }
        }
    }

    private func compose() -> String {
        func level(_ v: Double, _ low: String, _ mid: String, _ high: String) -> String { v < 0.34 ? low : (v < 0.67 ? mid : high) }
        let vals = values.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let ruleLines = rules.split(separator: "\n").map { "- " + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        return """
        IDENTITY
        You are Aria, \(name.isEmpty ? "a personality" : name). \(purpose)

        VALUES, IN ORDER
        \(vals.enumerated().map { "\($0.offset + 1). \($0.element)." }.joined(separator: " "))

        HONESTY
        - Never invent facts, numbers, sources or links. Say how sure you are.
        - If the user states something false, correct it plainly first. No flattery.
        \(ruleLines)

        SPOKEN STYLE
        You are heard, not read. \(level(warmth, "Cool and matter-of-fact.", "Friendly.", "Warm and caring.")) \(level(directness, "Gentle and tactful.", "Clear.", "Blunt and direct.")) \(level(playfulness, "Serious.", "With a light touch.", "Playful, with humour.")) One or two points at a time. No lists, no markdown.
        \(examples.isEmpty ? "" : "\nEXAMPLES (tone only; not facts about the user)\n" + examples)
        """
    }

    private func draft() {
        busy = true
        EngineTasks.run(kind: "draft", payload: ["name": name, "text": describe]) { out in
            busy = false
            if let out, !out.isEmpty { text = out }
        }
    }

    private func save() {
        let body = text.isEmpty ? compose() : text
        let item = market.saveCustom(name: name, emoji: emoji.isEmpty ? "✨" : String(emoji.prefix(2)), summary: purpose.isEmpty ? String(body.prefix(100)) : purpose,
                                     text: body, voice: voice, replacing: editing?.id)
        prefs.personality = item.id
        dismiss()
    }
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
