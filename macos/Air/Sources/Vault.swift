import AppKit
import Foundation

/// The "Air" Obsidian vault and the session notes inside it.
enum Vault {
    static let name = "Air"
    /// The owner's vault, or a test vault given with `-AirVault <path>` (keeps tests out of real notes).
    static let url: URL = UserDefaults.standard.string(forKey: "AirVault").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Obsidian vaults/Air", isDirectory: true)
    static var sessionsURL: URL { url.appendingPathComponent("Sessions", isDirectory: true) }
    static var indexURL: URL { url.appendingPathComponent("Air Index.md") }

    /// obsidian:// link that opens a note in the Air vault.
    static func obsidianURL(for file: URL) -> URL? {
        var rel = file.path.replacingOccurrences(of: url.path + "/", with: "")
        if rel.hasSuffix(".md") { rel.removeLast(3) }
        var c = URLComponents()
        c.scheme = "obsidian"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "vault", value: name), URLQueryItem(name: "file", value: rel)]
        // URLComponents leaves "/" and spaces partly unescaped in some cases; Obsidian accepts %20 and %2F.
        c.percentEncodedQuery = c.queryItems!.map {
            "\($0.name)=\($0.value!.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~")))!)"
        }.joined(separator: "&")
        return c.url
    }

    /// True when Obsidian already knows the Air vault (read-only check of Obsidian's vault list).
    static var isRegisteredInObsidian: Bool {
        let cfg = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: cfg),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: Any] else { return false }
        let target = url.standardizedFileURL.path
        return vaults.values.contains { v in
            guard let path = (v as? [String: Any])?["path"] as? String else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.path == target
        }
    }

    @MainActor static func open(_ file: URL) {
        guard isRegisteredInObsidian else {
            let alert = NSAlert()
            alert.messageText = "Add the Air vault to Obsidian once"
            alert.informativeText = "In Obsidian choose Open another vault → Open folder as vault, then pick:\n\n\(url.path)\n\nAfter that, Open in Obsidian goes straight to the note."
            alert.addButton(withTitle: "Open Obsidian")
            alert.addButton(withTitle: "Show Folder in Finder")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(URL(string: "obsidian://choose-vault")!)
            case .alertSecondButtonReturn:
                NSWorkspace.shared.activateFileViewerSelecting([url])
            default: break
            }
            return
        }
        if let link = obsidianURL(for: file) {
            NSWorkspace.shared.open(link)
        }
    }
}

struct SessionNote: Identifiable, Hashable {
    let url: URL
    let date: Date?
    let title: String
    let start: String
    let end: String
    let duration: String
    let voice: String
    let persona: String
    let status: String
    let mode: String
    let summary: String
    let personality: String
    /// Lowercased note text, for search.
    let searchText: String
    var id: URL { url }

    var timeLabel: String { date?.formatted(date: .omitted, time: .shortened) ?? title }
    var voiceName: String { Voices.name(voice) }

    static func load(_ url: URL) -> SessionNote {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let fm = frontmatter(text)
        let stem = url.deletingPathExtension().lastPathComponent
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd HHmm"
        let date = parser.date(from: String(stem.prefix(15)))
        let title: String
        if let date {
            title = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
        } else {
            title = stem
        }
        return SessionNote(
            url: url, date: date, title: title,
            start: fm["start"] ?? "", end: fm["end"] ?? "",
            duration: fm["duration"] ?? "", voice: fm["voice"] ?? "",
            persona: fm["persona"] ?? "", status: fm["status"] ?? "",
            mode: fm["mode"] ?? "Aria",
            summary: fm["summary"] ?? "",
            personality: fm["personality"].flatMap { $0.isEmpty ? nil : $0 } ?? Personas.nameForText(fm["persona"] ?? ""),
            searchText: text.lowercased()
        )
    }

    static func frontmatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---\n") else { return [:] }
        let rest = text.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") else { return [:] }
        var out: [String: String] = [:]
        for line in rest[..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""),
               let data = value.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                value = decoded
            }
            out[key] = value
        }
        return out
    }

    /// Transcript lines ("**[mm:ss] Speaker:** text") from the note body.
    func transcript() -> [(time: String, speaker: String, text: String)] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var out: [(String, String, String)] = []
        for line in text.split(separator: "\n") where line.hasPrefix("**[") {
            guard let close = line.range(of: "] "), let colon = line.range(of: ":** ") else { continue }
            let time = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
            let speaker = String(line[close.upperBound..<colon.lowerBound])
            out.append((time, speaker, String(line[colon.upperBound...])))
        }
        return out
    }

    static func all() -> [SessionNote] {
        guard let e = FileManager.default.enumerator(at: Vault.sessionsURL, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var notes: [SessionNote] = []
        for case let u as URL in e where u.pathExtension == "md" {
            notes.append(load(u))
        }
        return notes.sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
    }
}
