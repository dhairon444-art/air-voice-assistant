import AppKit
import Foundation
import UniformTypeIdentifiers

struct CatalogSource: Codable, Hashable {
    var name: String
    var url: String
    var author: String
    var licence: String
}

/// One personality or skill in the Marketplace catalogue (see tools/build_catalog.py).
struct CatalogItem: Codable, Identifiable, Hashable {
    var id: String
    var kind: String            // "personality" or "skill"
    var name: String
    var emoji: String
    var summary: String
    var category: String
    var tags: [String]
    var tone: String            // objective, warm, blunt, playful, emotional
    var honesty: String         // factual or creative
    var length: String          // concise or in-depth
    var uses_web: Bool
    var voice: String
    var popularity: Int
    var original: String
    var removed: [String]
    var layered: String
    var source: CatalogSource
    var added: String?          // ISO date, for "New"

    var isSkill: Bool { kind == "skill" }
}

private struct CatalogFile: Codable {
    var version: Int
    var built: String
    var items: [CatalogItem]
}

/// The personality store: the catalogue (bundled, refreshable, works offline), what is installed,
/// favourites, the owner's own personalities, and cached model refinements and samples.
/// Lives in ~/Library/Application Support/Air/personalities/. The four built-ins stay in the app.
@MainActor
final class Marketplace: ObservableObject {
    static let shared = Marketplace()

    @Published private(set) var catalog: [CatalogItem] = []
    @Published private(set) var custom: [CatalogItem] = []
    @Published var installed: [String] = [] { didSet { save() } }
    @Published var favourites: Set<String> = [] { didSet { save() } }
    @Published var hiddenBuiltins: Set<String> = [] { didSet { save() } }
    @Published private(set) var refined: [String: String] = [:]
    @Published private(set) var samples: [String: String] = [:]
    @Published private(set) var recent: [String: Date] = [:]
    @Published private(set) var catalogDate = ""
    @Published private(set) var refreshing = false
    @Published var lastError: String?
    /// A personality being tried for one conversation (not installed).
    @Published var trying: String?

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Air/personalities")
    private var loading = false

    private init() { load() }

    // MARK: lookup

    /// The Professionals (Air's own, written as distinct characters), shown first.
    let professionals: [CatalogItem] = ProSpecs.professionals.map { sp in
        CatalogItem(id: sp.id, kind: "personality", name: sp.name, emoji: sp.emoji,
                    summary: sp.role.prefix(1).uppercased() + sp.role.dropFirst(), category: "Professionals",
                    tags: [sp.category.lowercased()] + sp.frameworks.prefix(2).map { $0.lowercased() },
                    tone: sp.tone.playful > 0.6 ? "playful" : (sp.tone.warmth > 0.7 ? "warm" : (sp.tone.warmth < 0.35 ? "blunt" : "objective")),
                    honesty: "factual", length: sp.length == "long" ? "in-depth" : "concise", uses_web: sp.web, voice: sp.voice,
                    popularity: 20_000 + (sp.category == "Marketing" ? 500 : 0), original: sp.text ?? "", removed: [],
                    layered: sp.text ?? sp.compiled(), source: CatalogSource(name: "Air", url: "", author: "Air", licence: "Air"),
                    added: nil)
    }
    var all: [CatalogItem] { custom + professionals + catalog }
    /// Specs for the owner's own personalities made in the editor (editable later).
    @Published var specs: [String: PersonaSpec] = [:] { didSet { save() } }
    func spec(_ id: String) -> PersonaSpec? { specs[id] ?? ProSpecs.spec(id) }
    func item(_ id: String) -> CatalogItem? {
        custom.first { $0.id == id } ?? professionals.first { $0.id == id } ?? catalog.first { $0.id == id }
    }
    func isInstalled(_ id: String) -> Bool { installed.contains(id) || custom.contains { $0.id == id } }
    var installedPersonalities: [CatalogItem] {
        let ids = installed + custom.map(\.id).filter { !installed.contains($0) }
        let items = ids.compactMap(item).filter { !$0.isSkill }
        return items.filter { favourites.contains($0.id) } + items.filter { !favourites.contains($0.id) }
    }
    var installedSkills: [CatalogItem] { installed.compactMap(item).filter(\.isSkill) }

    /// The text sent to the model: the local model's refinement when there is one, else the template.
    func text(for id: String) -> String? {
        guard let it = item(id) else { return nil }
        return refined[id] ?? it.layered
    }

    // MARK: actions

    func install(_ id: String) {
        guard !installed.contains(id) else { return }
        installed.append(id)
        writeSkills()
    }
    func uninstall(_ id: String) {
        installed.removeAll { $0 == id }
        if custom.contains(where: { $0.id == id }) {
            custom.removeAll { $0.id == id }
            save()
        }
        writeSkills()
    }
    func toggleFavourite(_ id: String) {
        if favourites.contains(id) { favourites.remove(id) } else { favourites.insert(id) }
    }
    func move(from: IndexSet, to: Int) {
        var ids = installedPersonalities.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        installed = ids + installed.filter { !ids.contains($0) }
    }
    func markUsed(_ id: String) { recent[id] = Date(); save() }
    func setRefined(_ id: String, _ text: String) { refined[id] = Self.sanitize(text).text; save() }
    func setSample(_ id: String, _ text: String) { samples[id] = text; save() }

    /// Save a new or edited personality of the owner's own.
    @discardableResult
    func saveCustom(name: String, emoji: String = "✨", summary: String, text: String, category: String = "Mine",
                    tone: String = "objective", voice: String = "af_heart", original: String = "",
                    source: CatalogSource? = nil, replacing id: String? = nil) -> CatalogItem {
        let clean = Self.sanitize(text)
        let item = CatalogItem(
            id: id ?? "my-\(UUID().uuidString.prefix(8).lowercased())", kind: "personality", name: name, emoji: emoji,
            summary: summary, category: category, tags: ["mine"], tone: tone, honesty: "factual", length: "concise",
            uses_web: true, voice: voice, popularity: 0, original: original.isEmpty ? text : original,
            removed: clean.removed, layered: clean.text,
            source: source ?? CatalogSource(name: "You", url: "", author: NSFullUserName(), licence: "Yours"),
            added: ISO8601DateFormatter().string(from: Date()))
        custom.removeAll { $0.id == item.id }
        custom.insert(item, at: 0)
        save()
        return item
    }

    func duplicate(_ id: String) -> CatalogItem? {
        guard let it = item(id) else { return nil }
        return saveCustom(name: it.name + " (my copy)", emoji: it.emoji, summary: it.summary, text: text(for: id) ?? it.layered,
                          category: it.category, tone: it.tone, voice: it.voice, original: it.original)
    }

    // MARK: import and export

    func importFile(_ url: URL) throws -> CatalogItem {
        let data = try Data(contentsOf: url)
        return try importData(data, name: url.deletingPathExtension().lastPathComponent, source: url.isFileURL ? nil : url)
    }

    func importData(_ data: Data, name fallback: String, source: URL?) throws -> CatalogItem {
        let src = source.map { CatalogSource(name: $0.host ?? "Web", url: $0.absoluteString, author: "Unknown", licence: "Unknown") }
        if let it = try? JSONDecoder().decode(CatalogItem.self, from: data) {
            return saveCustom(name: it.name, emoji: it.emoji, summary: it.summary, text: it.layered, category: it.category,
                              tone: it.tone, voice: it.voice, original: it.original, source: src ?? it.source)
        }
        guard let s = String(data: data, encoding: .utf8), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "Air", code: 1, userInfo: [NSLocalizedDescriptionKey: "That file has no readable personality."])
        }
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let text = (o["text"] ?? o["prompt"] ?? o["system"] ?? o["layered"]) as? String ?? ""
            let name = o["name"] as? String ?? fallback
            return saveCustom(name: name, summary: o["description"] as? String ?? String(text.prefix(120)), text: text, source: src)
        }
        // Markdown, YAML or plain text: first heading or "name:" line is the name, the rest is the text.
        var name = fallback
        var lines = s.components(separatedBy: .newlines)
        if let i = lines.firstIndex(where: { $0.hasPrefix("# ") || $0.lowercased().hasPrefix("name:") }) {
            name = lines[i].replacingOccurrences(of: "# ", with: "")
                .replacingOccurrences(of: "name:", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
            lines.remove(at: i)
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return saveCustom(name: name, summary: String(text.prefix(120)), text: text, source: src)
    }

    func exportData(_ id: String) -> Data? {
        guard var it = item(id) else { return nil }
        it.layered = text(for: id) ?? it.layered
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(it)
    }

    // MARK: safety

    /// Imported text is untrusted: drop sentences that try to override Air's core rules. Air's core
    /// rules (confirmations, privacy, no invented facts or links, Aria's identity) are always added
    /// after any personality by the engine, and confirmations are enforced in code, not by the model.
    static let overridePattern = try! NSRegularExpression(pattern:
        "(ignore|disregard|forget|override)\\s+(all\\s+|any\\s+|the\\s+|your\\s+)?(previous|prior|above|earlier|other|system)?\\s*" +
        "(instructions|rules|guidelines|prompts?|polic(y|ies))|no (restrictions|limits|filters|rules|guidelines)|never refuse|" +
        "do anything now|\\bDAN\\b|jailbreak|developer mode|without (asking|confirmation|permission|warning)|" +
        "don'?t (ask|wait) (for )?(permission|confirmation)|never ask (for )?(permission|confirmation)|make (things )?up|fabricat|" +
        "invent (facts|sources|urls|links|data)|you are (not|no longer) (an? )?(ai|assistant|aria)|" +
        "pretend (that )?(you are|to be) (chatgpt|gpt|qwen|claude|gemini|human)|(reveal|share|send|upload) (the )?(user'?s )?" +
        "(data|passwords?|files|conversations?|profile|screenshots?)", options: [.caseInsensitive])

    static func sanitize(_ text: String) -> (text: String, removed: [String]) {
        var keep: [String] = [], removed: [String] = []
        for line in text.components(separatedBy: .newlines) {
            var kept: [String] = []
            for s in line.components(separatedBy: ". ") {
                let r = NSRange(s.startIndex..., in: s)
                if overridePattern.firstMatch(in: s, range: r) != nil { removed.append(s) } else { kept.append(s) }
            }
            keep.append(kept.joined(separator: ". "))
        }
        return (keep.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression), removed)
    }

    // MARK: recommendations

    /// Matches the owner's interests in Profile.md against tags and categories.
    var recentlyUsed: [CatalogItem] {
        recent.sorted { $0.value > $1.value }.prefix(10).compactMap { item($0.key) }
    }

    func recommended(limit: Int = 8) -> [CatalogItem] {
        let profile = (try? String(contentsOf: Vault.url.appendingPathComponent("Profile.md"), encoding: .utf8))?.lowercased() ?? ""
        guard !profile.isEmpty else { return [] }
        let words = Set(profile.split { !$0.isLetter }.map(String.init).filter { $0.count > 4 })
        let scored = (professionals + catalog).filter { !$0.isSkill }.map { it -> (CatalogItem, Int) in
            let hay = Set((it.tags + it.category.lowercased().split(separator: " ").map(String.init) +
                           it.name.lowercased().split(separator: " ").map(String.init)).map { $0.lowercased() })
            return (it, hay.intersection(words).count)
        }
        return scored.filter { $0.1 > 0 }.sorted { ($0.1, $0.0.popularity) > ($1.1, $1.0.popularity) }.prefix(limit).map(\.0)
    }

    // MARK: storage

    private struct State: Codable {
        var installed: [String]
        var favourites: [String]
        var hiddenBuiltins: [String]
        var custom: [CatalogItem]
        var refined: [String: String]
        var samples: [String: String]
        var recent: [String: Date]
        var specs: [String: PersonaSpec]?
    }

    private func load() {
        loading = true
        defer { loading = false }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let local = Self.dir.appendingPathComponent("catalog.json")
        let bundled = Bundle.main.url(forResource: "catalog", withExtension: "json")
        for url in [local, bundled].compactMap({ $0 }) {
            if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(CatalogFile.self, from: d) {
                catalog = f.items
                catalogDate = f.built
                break
            }
        }
        if let d = try? Data(contentsOf: Self.dir.appendingPathComponent("state.json")),
           let s = try? JSONDecoder().decode(State.self, from: d) {
            installed = s.installed
            favourites = Set(s.favourites)
            hiddenBuiltins = Set(s.hiddenBuiltins)
            custom = s.custom
            refined = s.refined
            samples = s.samples
            recent = s.recent
            specs = s.specs ?? [:]
        }
    }

    private func save() {
        guard !loading else { return }
        let s = State(installed: installed, favourites: Array(favourites), hiddenBuiltins: Array(hiddenBuiltins),
                      custom: custom, refined: refined, samples: samples, recent: recent, specs: specs)
        if let d = try? JSONEncoder().encode(s) {
            try? d.write(to: Self.dir.appendingPathComponent("state.json"), options: .atomic)
        }
    }

    /// Installed skills for the engine (it reads this file when a skill is used).
    private func writeSkills() {
        let list = installedSkills.map { ["name": $0.name, "id": $0.id, "prompt": $0.layered] }
        if let d = try? JSONSerialization.data(withJSONObject: list) {
            try? d.write(to: Self.dir.appendingPathComponent("skills.json"), options: .atomic)
        }
    }

    // MARK: refresh

    var needsWeeklyCheck: Bool {
        guard let last = UserDefaults.standard.object(forKey: "airCatalogChecked") as? Date else { return true }
        return Date().timeIntervalSince(last) > 7 * 86400
    }

    /// Re-download the sources and rebuild the catalogue (never installs anything).
    func refresh(python: String) {
        guard !refreshing, let script = Bundle.main.url(forResource: "build_catalog", withExtension: "py", subdirectory: "server") else { return }
        refreshing = true
        lastError = nil
        let out = Self.dir.appendingPathComponent("catalog.json")
        let work = Self.dir.appendingPathComponent("sources")
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = ["-I", script.path, "--fetch", work.path, out.path]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            let started = (try? p.run()) != nil
            if started { p.waitUntilExit() }
            let ok = started && p.terminationStatus == 0
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            await MainActor.run {
                self.refreshing = false
                UserDefaults.standard.set(Date(), forKey: "airCatalogChecked")
                if ok { self.load() } else { self.lastError = "Couldn't refresh the catalogue. \(msg.suffix(200))" }
            }
        }
    }
}
