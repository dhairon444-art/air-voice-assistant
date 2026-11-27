import SwiftUI

/// A Kokoro voice from Resources/voices.json (built from Kokoro's VOICES.md).
struct CatalogVoice: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let language: String
    let code: String
    let accent: String
    let gender: String
    let grade: String
    let style: [String]
    let needs_pack: Bool
    var note: String { [accent, gender, style.first].compactMap { $0 }.joined(separator: ", ") }
}

enum VoiceCatalog {
    private struct File: Decodable { let voices: [CatalogVoice] }
    static let voices: [CatalogVoice] = {
        guard let u = Bundle.main.url(forResource: "voices", withExtension: "json"),
              let d = try? Data(contentsOf: u), let f = try? JSONDecoder().decode(File.self, from: d) else { return [] }
        return f.voices
    }()
    static func voice(_ id: String) -> CatalogVoice? { voices.first { $0.id == id } }
    static var added: [String] {
        get { UserDefaults.standard.stringArray(forKey: "airVoices.added") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "airVoices.added") }
    }
}

/// Marketplace > Voices: every Kokoro voice with tags, a preview, and Add / Remove (the files are
/// already on the Mac with the Kokoro model, so adding downloads nothing).
struct VoicesMarket: View {
    @EnvironmentObject var web: WebController
    @EnvironmentObject var prefs: Prefs
    @State private var added = Set(VoiceCatalog.added)
    @State private var language = "any"
    @State private var gender = "any"
    @State private var goodOnly = false

    private var languages: [String] { Array(Set(VoiceCatalog.voices.map(\.language))).sorted() }
    private var list: [CatalogVoice] {
        VoiceCatalog.voices.filter { v in
            (language == "any" || v.language == language) && (gender == "any" || v.gender == gender)
                && (!goodOnly || ["A", "A-", "B+", "B", "B-", "C+"].contains(v.grade))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("Language", selection: $language) {
                    Text("Any language").tag("any")
                    ForEach(languages, id: \.self) { Text($0).tag($0) }
                }.fixedSize()
                Picker("Gender", selection: $gender) {
                    Text("Any").tag("any"); Text("Female").tag("female"); Text("Male").tag("male")
                }.pickerStyle(.segmented).fixedSize()
                Toggle("Best quality only", isOn: $goodOnly).toggleStyle(.checkbox)
                Spacer()
                Text("\(list.count) voices").font(.caption).foregroundStyle(.secondary)
            }
            Text("Kokoro voices run on this Mac, next to Aria's brain, and the files are already installed: Add just puts a voice in the Voice picker. Grades are Kokoro's own (A is best). A voice speaks its own language; English text with a Spanish voice sounds Spanish.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 12)], spacing: 12) {
                ForEach(list) { v in card(v) }
            }
            Divider().padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice packs").font(.headline)
                Text("MeloTTS (English), Soprano and MOSS-TTS-Nano (with voices made from a short clip) are downloaded and being measured next to Aria's brain. They'll appear here once they're verified on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func card(_ v: CatalogVoice) -> some View {
        let isBuiltIn = Voices.builtIn.contains { $0.id == v.id }
        let on = isBuiltIn || added.contains(v.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(v.name).font(.callout.weight(.semibold))
                if !v.grade.isEmpty { Text(v.grade).font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                Spacer()
                Button { web.preview(v.id) } label: {
                    Image(systemName: web.previewing == v.id ? "stop.circle" : "play.circle")
                }
                .buttonStyle(.plain).disabled(v.needs_pack || !web.engineReady).help("Preview")
            }
            HStack(spacing: 4) {
                ForEach([v.language, v.gender.capitalized] + v.style, id: \.self) { t in
                    Text(t).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                }
            }
            HStack {
                if v.needs_pack {
                    Text("Needs a \(v.language) language pack (not installed)").font(.caption).foregroundStyle(.secondary)
                } else if isBuiltIn {
                    Text("Built in").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(on ? "Remove" : "Add") { toggle(v) }.controlSize(.small)
                }
                Spacer()
                if on && !v.needs_pack {
                    Button(prefs.voice == v.id ? "In use" : "Use") { prefs.voice = v.id }
                        .controlSize(.small).disabled(prefs.voice == v.id || web.live)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
        .opacity(v.needs_pack ? 0.55 : 1)
    }

    private func toggle(_ v: CatalogVoice) {
        if added.contains(v.id) {
            added.remove(v.id)
            if prefs.voice == v.id { prefs.voice = Voices.defaultVoice }
        } else {
            added.insert(v.id)
        }
        VoiceCatalog.added = VoiceCatalog.voices.map(\.id).filter { added.contains($0) }
    }
}
