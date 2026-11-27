import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Index (in memory; hundreds of notes stay fast)

/// Everything History needs about one conversation, derived once from its note.
struct HistoryEntry: Identifiable, Hashable {
    let note: SessionNote
    var id: URL { note.url }
    let seconds: Int
    let model: String
    let hasSources: Bool
    let hasFiles: Bool
    let toolCount: Int
    let usedScreen: Bool
    let topics: [String]
    let firstLine: String

    var usedTools: Bool { toolCount > 0 }
    var date: Date { note.date ?? .distantPast }

    init(_ n: SessionNote) {
        note = n
        let t = n.searchText
        let fm = SessionNote.frontmatter((try? String(contentsOf: n.url, encoding: .utf8)) ?? "")
        seconds = Int(fm["duration_seconds"] ?? "") ?? 0
        model = (fm["model"] ?? "").components(separatedBy: " + ").first?.components(separatedBy: "/").last ?? ""
        hasSources = t.contains("## sources and web activity") || t.contains("## research")
        hasFiles = t.contains("air exports") || t.contains(" saved: ")
        toolCount = t.components(separatedBy: "| ok: ").count - 1 + t.components(separatedBy: "| failed: ").count - 1
        usedScreen = t.contains("look_at_screen") || t.contains("looked at screen")
        firstLine = n.transcript().first { $0.speaker == "You" }?.text ?? ""
        topics = Self.topics(from: n.summary.isEmpty ? firstLine : n.summary)
    }

    /// Up to three topic words from the summary (cheap and local).
    static func topics(from s: String) -> [String] {
        let stop: Set<String> = ["the", "user", "users", "about", "their", "with", "that", "this", "from", "which", "discussed",
                                 "asked", "aria", "conversation", "talked", "using", "would", "could", "there", "these",
                                 "while", "also", "into", "they", "them", "what", "when", "where", "after", "before", "being",
                                 "should", "their", "there", "other", "first", "small", "specific", "general", "visible"]
        var counts: [String: Int] = [:]
        for w in s.lowercased().split(whereSeparator: { !$0.isLetter }) where w.count > 4 && !stop.contains(String(w))
            && !w.hasSuffix("ed") && !w.hasSuffix("ing") && !w.hasSuffix("ly") && !w.hasSuffix("ions") {
            counts[String(w), default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(3).map(\.key)
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var entries: [HistoryEntry] = []
    @Published var pins: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "airHistoryPins") ?? []) {
        didSet { UserDefaults.standard.set(Array(pins), forKey: "airHistoryPins") }
    }
    @Published var titles: [String: String] = UserDefaults.standard.dictionary(forKey: "airHistoryTitles") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(titles, forKey: "airHistoryTitles") }
    }
    private var cache: [URL: (Date, HistoryEntry)] = [:]

    func reload() {
        var out: [HistoryEntry] = []
        for n in SessionNote.all() {
            let mod = (try? n.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let (m, e) = cache[n.url], m == mod { out.append(e); continue }
            let e = HistoryEntry(n)
            cache[n.url] = (mod, e)
            out.append(e)
        }
        entries = out
    }

    func title(_ e: HistoryEntry) -> String {
        if let t = titles[e.note.url.lastPathComponent], !t.isEmpty { return t }
        let src = e.note.summary.isEmpty ? e.firstLine : e.note.summary
        let s = src.replacingOccurrences(of: "The user ", with: "").replacingOccurrences(of: "User ", with: "")
        let words = s.split(separator: " ").prefix(7).joined(separator: " ")
        return words.isEmpty ? e.note.title : (words.prefix(1).uppercased() + words.dropFirst()).trimmingCharacters(in: .punctuationCharacters)
    }

    func isPinned(_ e: HistoryEntry) -> Bool { pins.contains(e.note.url.lastPathComponent) }
    func togglePin(_ e: HistoryEntry) {
        let k = e.note.url.lastPathComponent
        if pins.contains(k) { pins.remove(k) } else { pins.insert(k) }
    }

    /// Never a hard delete: the note moves to the vault's .trash folder (Obsidian's own convention).
    func trash(_ e: HistoryEntry) throws {
        let trash = Vault.url.appendingPathComponent(".trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var dst = trash.appendingPathComponent(e.note.url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = trash.appendingPathComponent(e.note.url.deletingPathExtension().lastPathComponent + " \(n).md"); n += 1
        }
        try FileManager.default.moveItem(at: e.note.url, to: dst)
        reload()
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var model: ModelProcess
    @ObservedObject private var store = HistoryStore.shared
    @AppStorage("airHistoryLayout") private var layout = "list"
    @State private var selection: URL?
    @State private var query = ""
    @State private var range = "all"
    @State private var personality = "any"
    @State private var flags: Set<String> = []
    @State private var lengthFilter = "any"
    @State private var sort = "newest"
    @State private var day: Date?

    static let flagNames: [(String, String, String)] = [
        ("sources", "Has sources", "link"), ("files", "Has files", "doc"), ("tools", "Used tools", "hammer"),
        ("screen", "Used the screen", "eye"), ("pinned", "Pinned", "pin"), ("assistant", "Assistant", "checklist"),
    ]

    private var filtered: [HistoryEntry] {
        var items = store.entries
        let cal = Calendar.current, now = Date()
        switch range {
        case "today": items = items.filter { cal.isDateInToday($0.date) }
        case "7": items = items.filter { $0.date > now.addingTimeInterval(-7 * 86400) }
        case "30": items = items.filter { $0.date > now.addingTimeInterval(-30 * 86400) }
        default: break
        }
        if let day { items = items.filter { cal.isDate($0.date, inSameDayAs: day) } }
        if personality != "any" { items = items.filter { $0.note.personality == personality } }
        if flags.contains("sources") { items = items.filter(\.hasSources) }
        if flags.contains("files") { items = items.filter(\.hasFiles) }
        if flags.contains("tools") { items = items.filter(\.usedTools) }
        if flags.contains("screen") { items = items.filter(\.usedScreen) }
        if flags.contains("pinned") { items = items.filter { store.isPinned($0) } }
        if flags.contains("assistant") { items = items.filter { $0.note.url.pathComponents.contains("Assistant") } }
        switch lengthFilter {
        case "short": items = items.filter { $0.seconds < 120 }
        case "medium": items = items.filter { $0.seconds >= 120 && $0.seconds < 600 }
        case "long": items = items.filter { $0.seconds >= 600 }
        default: break
        }
        let words = query.lowercased().split(separator: " ").map(String.init)
        if !words.isEmpty {
            items = items.filter { e in words.allSatisfy { e.note.searchText.contains($0) || store.title(e).lowercased().contains($0) } }
        }
        switch sort {
        case "oldest": items.sort { $0.date < $1.date }
        case "longest": items.sort { $0.seconds > $1.seconds }
        case "tools": items.sort { $0.toolCount > $1.toolCount }
        default: items.sort { $0.date > $1.date }
        }
        // Pinned first in every order.
        return items.filter { store.isPinned($0) } + items.filter { !store.isPinned($0) }
    }

    private var filtersActive: Bool { range != "all" || personality != "any" || !flags.isEmpty || lengthFilter != "any" || day != nil }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                StatsHeader(entries: store.entries)
                toolbar
                Divider()
                let items = filtered
                Group {
                    if items.isEmpty {
                        ContentUnavailableView(store.entries.isEmpty ? "No conversations yet" : "No matches",
                                               systemImage: store.entries.isEmpty ? "text.bubble" : "magnifyingglass",
                                               description: Text(store.entries.isEmpty ? "Talk to Aria and your conversations appear here." : "Try other words or clear the filters."))
                            .frame(maxHeight: .infinity)
                    } else if layout == "cards" {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                                ForEach(items) { e in
                                    EntryCard(entry: e, query: query, selected: selection == e.id).onTapGesture { selection = e.id }
                                }
                            }
                            .padding(12)
                        }
                    } else if layout == "timeline" {
                        VStack(spacing: 0) {
                            CalendarStrip(entries: store.entries, day: $day)
                            Divider()
                            entryList(items)
                        }
                    } else {
                        entryList(items)
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
            Group {
                if let id = selection, let e = store.entries.first(where: { $0.id == id }) {
                    HistoryDetail(entry: e, query: query) { selection = nil }
                } else {
                    ContentUnavailableView("Pick a conversation", systemImage: "text.bubble",
                                           description: Text("Each conversation is also a note in your Air vault in Obsidian."))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            .surface(.background)
        }
        .onAppear { store.reload(); if selection == nil { selection = filtered.first?.id } }
        .onChange(of: model.sessionsChanged) { _, _ in store.reload() }
    }

    private func entryList(_ items: [HistoryEntry]) -> some View {
        List(selection: $selection) {
            ForEach(groups(items), id: \.0) { g in
                Section(g.0) { ForEach(g.1) { EntryRow(entry: $0, query: query).tag($0.id) } }
            }
        }
        .listStyle(.sidebar)
        .amoledList()
    }

    private func groups(_ items: [HistoryEntry]) -> [(String, [HistoryEntry])] {
        guard sort == "newest" || sort == "oldest" else { return [("Results", items)] }
        let cal = Calendar.current
        var out: [(String, [HistoryEntry])] = []
        for e in items {
            let label = store.isPinned(e) ? "Pinned"
                : (cal.isDateInToday(e.date) ? "Today" : (cal.isDateInYesterday(e.date) ? "Yesterday"
                    : e.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())))
            if out.last?.0 == label { out[out.count - 1].1.append(e) } else { out.append((label, [e])) }
        }
        return out
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcripts, summaries and titles", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            Menu {
                Picker("Date", selection: $range) {
                    Text("Any time").tag("all"); Text("Today").tag("today"); Text("Last 7 days").tag("7"); Text("Last 30 days").tag("30")
                }
                Picker("Personality", selection: $personality) {
                    Text("Any personality").tag("any")
                    ForEach(Array(Set(store.entries.map { $0.note.personality })).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker("Length", selection: $lengthFilter) {
                    Text("Any length").tag("any"); Text("Under 2 min").tag("short"); Text("2–10 min").tag("medium"); Text("Over 10 min").tag("long")
                }
                Divider()
                ForEach(Self.flagNames, id: \.0) { f in
                    Toggle(isOn: Binding(get: { flags.contains(f.0) }, set: { if $0 { flags.insert(f.0) } else { flags.remove(f.0) } })) {
                        Label(f.1, systemImage: f.2)
                    }
                }
                Divider()
                Picker("Sort", selection: $sort) {
                    Text("Newest").tag("newest"); Text("Oldest").tag("oldest"); Text("Longest").tag("longest"); Text("Most tool use").tag("tools")
                }
                Button("Clear Filters") { range = "all"; personality = "any"; flags = []; lengthFilter = "any"; day = nil }
            } label: { Image(systemName: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                .menuIndicator(.hidden).fixedSize().help("Filters and sorting")
            Picker("Layout", selection: $layout) {
                Image(systemName: "list.bullet").tag("list").help("List")
                Image(systemName: "square.grid.2x2").tag("cards").help("Cards")
                Image(systemName: "calendar").tag("timeline").help("Timeline")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .padding(10)
    }
}

/// This week at a glance.
struct StatsHeader: View {
    let entries: [HistoryEntry]
    var body: some View {
        let week = entries.filter { $0.date > Date().addingTimeInterval(-7 * 86400) }
        let minutes = week.reduce(0) { $0 + $1.seconds } / 60
        var counts: [String: Int] = [:]
        week.flatMap(\.topics).forEach { counts[$0, default: 0] += 1 }
        let topTopics = counts.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        var pc: [String: Int] = [:]
        week.forEach { pc[$0.note.personality, default: 0] += 1 }
        let topPersona = pc.max { $0.value < $1.value }?.key
        return HStack(spacing: 14) {
            Stat(value: "\(week.count)", label: "this week")
            Stat(value: minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m", label: "talk time")
            if let topPersona { Stat(value: topPersona, label: "most used") }
            if !topTopics.isEmpty { Stat(value: topTopics.joined(separator: ", "), label: "top topics") }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.top, 10)
    }
    struct Stat: View {
        let value: String, label: String
        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.callout.weight(.semibold)).lineLimit(1)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Bold the search words in a preview.
func highlighted(_ s: String, _ query: String) -> AttributedString {
    var a = AttributedString(s)
    for w in query.lowercased().split(separator: " ") where w.count > 1 {
        var start = a.startIndex
        while let r = a[start...].range(of: String(w), options: .caseInsensitive) {
            a[r].backgroundColor = .yellow.opacity(0.35)
            a[r].font = .callout.weight(.semibold)
            start = r.upperBound
        }
    }
    return a
}

struct Badges: View {
    let entry: HistoryEntry
    var body: some View {
        HStack(spacing: 5) {
            if entry.hasSources { Image(systemName: "link").help("Has sources") }
            if entry.hasFiles { Image(systemName: "doc").help("Has files") }
            if entry.usedTools { Image(systemName: "hammer").help("Used tools") }
            if entry.usedScreen { Image(systemName: "eye").help("Looked at the screen") }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}

struct EntryRow: View {
    let entry: HistoryEntry
    let query: String
    @ObservedObject private var store = HistoryStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if store.isPinned(entry) { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                Text(ProSpecs.all.first { $0.name == entry.note.personality }?.emoji ?? "💬")
                Text(store.title(entry)).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(entry.note.timeLabel).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(highlighted(entry.note.summary.isEmpty ? entry.firstLine : entry.note.summary, query))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Text("\(entry.note.duration) · \(entry.note.personality)").font(.caption2).foregroundStyle(.tertiary)
                ForEach(entry.topics, id: \.self) { Text("#\($0)").font(.caption2).foregroundStyle(.tint) }
                Spacer(minLength: 0)
                Badges(entry: entry)
            }
        }
        .padding(.vertical, 3)
    }
}

struct EntryCard: View {
    let entry: HistoryEntry
    let query: String
    let selected: Bool
    @ObservedObject private var store = HistoryStore.shared
    @Environment(\.airTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ProSpecs.all.first { $0.name == entry.note.personality }?.emoji ?? "💬").font(.title3)
                Spacer()
                if store.isPinned(entry) { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                Badges(entry: entry)
            }
            Text(store.title(entry)).font(.headline).lineLimit(2)
            Text(highlighted(entry.note.summary.isEmpty ? entry.firstLine : entry.note.summary, query))
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Spacer(minLength: 0)
            Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.note.duration)").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(height: 150)
        .panelBackground(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? theme.accent : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Timeline: the last five weeks as a calendar; dots show how many conversations a day had.
struct CalendarStrip: View {
    let entries: [HistoryEntry]
    @Binding var day: Date?
    @Environment(\.airTheme) private var theme
    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -34 - (cal.component(.weekday, from: today) - cal.firstWeekday + 7) % 7, to: today)!
        let days = (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }.filter { $0 <= today }
        var counts: [Date: Int] = [:]
        entries.forEach { counts[cal.startOfDay(for: $0.date), default: 0] += 1 }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(day.map { $0.formatted(date: .complete, time: .omitted) } ?? "Last five weeks").font(.caption.weight(.semibold))
                Spacer()
                if day != nil { Button("Show all") { day = nil }.buttonStyle(.link).font(.caption) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { d in
                    let n = counts[d] ?? 0
                    Button { day = (day == d ? nil : d) } label: {
                        VStack(spacing: 2) {
                            Text("\(cal.component(.day, from: d))").font(.caption2)
                            HStack(spacing: 1) {
                                ForEach(0..<min(n, 4), id: \.self) { _ in Circle().fill(theme.accent).frame(width: 4, height: 4) }
                            }
                            .frame(height: 4)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 3)
                        .background(day == d ? theme.accent.opacity(0.2) : (n > 0 ? Color.secondary.opacity(0.08) : .clear),
                                    in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .disabled(n == 0)
                    .help(n == 0 ? "" : "\(n) conversation\(n == 1 ? "" : "s")")
                }
            }
        }
        .padding(10)
    }
}

// MARK: - Detail

struct HistoryDetail: View {
    let entry: HistoryEntry
    let query: String
    let onDeleted: () -> Void
    @ObservedObject private var store = HistoryStore.shared
    @EnvironmentObject var web: WebController
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false
    @State private var error: String?

    struct Line: Identifiable { let id = UUID(); let time: String; let speaker: String; let text: String; let blocks: [DisplayBlock] }

    /// Transcript lines with the tables, diagrams and links saved after each reply.
    private var lines: [Line] {
        let text = (try? String(contentsOf: entry.note.url, encoding: .utf8)) ?? ""
        guard let start = text.range(of: "## Transcript") else { return [] }
        var body = String(text[start.upperBound...])
        if let end = body.range(of: "\n## ", options: [], range: body.index(after: body.startIndex)..<body.endIndex) { body = String(body[..<end.lowerBound]) }
        var out: [Line] = []
        var cur: (String, String, String)?
        var extra: [String] = []
        func flush() {
            guard let c = cur else { return }
            out.append(Line(time: c.0, speaker: c.1, text: c.2, blocks: Self.blocks(extra.joined(separator: "\n"))))
            extra = []
        }
        for raw in body.components(separatedBy: "\n") {
            if raw.hasPrefix("**["), let close = raw.range(of: "] "), let colon = raw.range(of: ":** ") {
                flush()
                cur = (String(raw[raw.index(raw.startIndex, offsetBy: 3)..<close.lowerBound]), String(raw[close.upperBound..<colon.lowerBound]),
                       String(raw[colon.upperBound...]))
            } else if cur != nil, !raw.hasPrefix(">") {
                extra.append(raw)
            }
        }
        flush()
        return out
    }

    static func blocks(_ s: String) -> [DisplayBlock] {
        var out: [DisplayBlock] = []
        var rest = s
        while let a = rest.range(of: "```") {
            let after = rest[a.upperBound...]
            guard let b = after.range(of: "```") else { break }
            let inner = String(after[..<b.lowerBound])
            let first = inner.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
            out.append(DisplayBlock(kind: first == "mermaid" ? "mermaid" : "code", body: inner.components(separatedBy: "\n").dropFirst().joined(separator: "\n")))
            rest = String(rest[..<a.lowerBound]) + String(after[b.upperBound...])
        }
        let table = rest.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
        if table.count >= 2 { out.append(DisplayBlock(kind: "table", body: table.joined(separator: "\n"))) }
        let md = rest.components(separatedBy: "\n").filter { let t = $0.trimmingCharacters(in: .whitespaces); return t.hasPrefix("- [") || t.hasPrefix("* [") }
        if !md.isEmpty { out.append(DisplayBlock(kind: "links", body: md.joined(separator: "\n"))) }
        return out
    }

    private var sections: (thinking: [String], sources: [(String, URL)]) {
        let text = (try? String(contentsOf: entry.note.url, encoding: .utf8)) ?? ""
        let thinking = text.components(separatedBy: "\n").filter { $0.hasPrefix("> **") }.map { String($0.dropFirst(2)) }
        var sources: [(String, URL)] = []
        if let r = text.range(of: "## Sources and web activity") {
            for line in text[r.upperBound...].components(separatedBy: "\n") where line.hasPrefix("- ") {
                if let o = line.range(of: "]("), let c = line.range(of: ")", range: o.upperBound..<line.endIndex),
                   let u = URL(string: String(line[o.upperBound..<c.lowerBound])), let ts = line.range(of: "[") {
                    sources.append((String(line[ts.upperBound..<o.lowerBound]), u))
                }
            }
        }
        return (thinking, sources)
    }

    var body: some View {
        let (thinking, sources) = sections
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if renaming {
                            TextField("Title", text: $newTitle).textFieldStyle(.roundedBorder).font(.title3)
                                .onSubmit { store.titles[entry.note.url.lastPathComponent] = newTitle; renaming = false }
                        } else {
                            Text(store.title(entry)).font(.title2.weight(.semibold)).textSelection(.enabled)
                        }
                        Text("\(entry.date.formatted(date: .complete, time: .shortened)) · \(entry.note.duration) · \(entry.note.personality) · \(entry.note.voiceName)\(entry.model.isEmpty ? "" : " · \(entry.model)")")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(entry.topics, id: \.self) { Chip(text: "#\($0)") }
                            Badges(entry: entry)
                        }
                    }
                    Spacer()
                    actions
                }
                if !entry.note.summary.isEmpty {
                    Text(entry.note.summary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .panelBackground(in: RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(lines) { l in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(l.time).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 40, alignment: .leading)
                                Text(l.speaker).font(.callout.weight(.semibold)).foregroundStyle(l.speaker == "You" ? .secondary : Color.accentColor)
                                    .frame(width: 40, alignment: .leading)
                                Text(highlighted(l.text, query)).textSelection(.enabled)
                            }
                            ForEach(l.blocks) { DisplayBlockView(block: $0).padding(.leading, 96) }
                        }
                    }
                }
                if !sources.isEmpty {
                    GroupBox("Sources") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(sources.enumerated()), id: \.offset) { _, s in Link(s.0.isEmpty ? s.1.host ?? s.1.absoluteString : s.0, destination: s.1) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !thinking.isEmpty {
                    DisclosureGroup("Thinking (\(thinking.count) steps)") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(thinking.enumerated()), id: \.offset) { _, t in
                                Text((try? AttributedString(markdown: t)) ?? AttributedString(t)).font(.caption).textSelection(.enabled)
                            }
                        }.padding(.top, 6)
                    }
                }
                if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            }
            .padding(20)
        }
        .confirmationDialog("Move this conversation to the vault's trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) {
                do { try store.trash(entry); onDeleted() } catch { self.error = error.localizedDescription }
            }
        } message: { Text("It moves to the .trash folder in your Air vault (Obsidian can restore it). Nothing is deleted for good.") }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button { store.togglePin(entry) } label: { Image(systemName: store.isPinned(entry) ? "pin.fill" : "pin") }
                .help(store.isPinned(entry) ? "Unpin" : "Pin")
            Button { newTitle = store.title(entry); renaming.toggle() } label: { Image(systemName: "pencil") }.help("Rename")
            Button { continueConversation() } label: { Image(systemName: "arrow.uturn.forward") }.help("Continue this conversation")
            Menu {
                Button("Open in Obsidian") { openInObsidian() }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.note.url]) }
                Divider()
                Button("Copy Transcript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n"), forType: .string)
                }
                Button("Export as Markdown…") { export() }
                Divider()
                Button("Move to Trash…", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden).fixedSize()
        }
        .buttonStyle(.borderless)
    }

    private func openInObsidian() {
        let vault = Vault.url.lastPathComponent
        let rel = entry.note.url.path.replacingOccurrences(of: Vault.url.path + "/", with: "")
        var c = URLComponents(string: "obsidian://open")!
        c.queryItems = [URLQueryItem(name: "vault", value: vault), URLQueryItem(name: "file", value: rel)]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    private func export() {
        let p = NSSavePanel()
        p.nameFieldStringValue = store.title(entry) + ".md"
        p.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if p.runModal() == .OK, let u = p.url { try? FileManager.default.copyItem(at: entry.note.url, to: u) }
    }

    /// Start a new conversation that picks up where this one left off (memory recall finds this note).
    private func continueConversation() {
        AppActions.showTalk()
        // The same conversation, in the same note, with its earlier turns as context.
        if web.live { web.stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (web.live ? 0.8 : 0)) {
            web.start(resume: entry.note.url.path)
        }
    }
}
