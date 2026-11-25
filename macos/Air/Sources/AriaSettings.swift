import Foundation
import SwiftUI

/// Aria's language model. Fast is the default and the fallback.
enum Brain: String, CaseIterable, Identifiable {
    case fast = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    case deeper = "mlx-community/Qwen3-8B-4bit"
    var id: String { rawValue }
    var label: String { self == .fast ? "Fast · Qwen3 4B" : "Deeper · Qwen3 8B" }
    var footer: String {
        self == .fast ? "About 1-2 s to the first word, about 30 tokens/s on this Mac."
                      : "About 2-3.5 s to the first word, about 15 tokens/s."
    }
    /// Hybrid models that can reason before answering ("Think first").
    var canThink: Bool { self != .fast }
}

/// The five best Kokoro voices, by Kokoro's own quality grades (VOICES.md).
enum Voices {
    static let all: [(id: String, name: String, note: String)] = [
        ("af_heart", "Heart", "warmest, highest-rated"),
        ("af_bella", "Bella", "bright, American"),
        ("af_nicole", "Nicole", "soft, made for headphones"),
        ("bf_emma", "Emma", "British"),
        ("af_sarah", "Sarah", "clear, American"),
    ]
    static let defaultVoice = "af_heart"
    /// Display name for a voice id, including voices from older sessions.
    static func name(_ id: String) -> String {
        if let v = all.first(where: { $0.id == id }) { return v.name }
        if id.isEmpty { return "Voice" }
        let parts = id.split(separator: "_")
        return parts.count == 2 ? parts[1].capitalized : id
    }
    static func valid(_ v: String?) -> String { all.contains { $0.id == v } ? v! : defaultVoice }
}

/// Personalities: layered specs (identity, ranked values, epistemic and anti-sycophancy rules,
/// spoken style, memory and tool rules, examples) shipped in Resources/personas.json. The owner
/// can edit each one in Settings; edits are stored per personality. "Custom" is free text.
struct Personality: Identifiable, Decodable {
    let id: String
    let name: String
    let summary: String
    let text: String
}

enum Personas {
    static let presets: [Personality] = {
        guard let url = Bundle.main.url(forResource: "personas", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Personality].self, from: data) else { return [] }
        return list
    }()
    static let defaultID = "analyst"
    static let customID = "custom"
    static let customStarter = "IDENTITY\nYou are Aria. Describe who Aria should be here.\n\nVALUES, IN ORDER\n1. Truth. 2. Usefulness. 3. Comfort.\n\nRULES\n- Correct me plainly when I'm wrong. Never flatter me."
    static func preset(_ id: String) -> Personality? { presets.first { $0.id == id } }
    static func name(_ id: String) -> String {
        if id == customID { return "Custom" }
        if let p = preset(id) { return p.name }
        return MainActor.assumeIsolated { Marketplace.shared.item(id)?.name } ?? id
    }
    /// Which personality a saved persona text came from (older notes store only the text).
    static func nameForText(_ text: String) -> String {
        if let p = presets.first(where: { $0.text == text }) { return p.name }
        if text.hasPrefix("IDENTITY") {
            for p in presets where text.contains(p.text.split(separator: "\n").dropFirst().first.map(String.init) ?? "\u{0}") {
                return p.name
            }
        }
        // Presets from earlier versions of Air
        if text.contains("warm, kind and encouraging") || text.contains("warm and curious companion") { return "Warm companion" }
        if text.contains("wise and friendly teacher") { return "Thoughtful teacher" }
        if text.contains("life coach") { return "Coach" }
        return text.isEmpty ? "" : "Custom"
    }
}

/// User settings, stored in UserDefaults.
@MainActor
final class Prefs: ObservableObject {
    private let d = UserDefaults.standard

    @Published var voice: String { didSet { d.set(voice, forKey: "ariaVoice") } }
    @Published var brain: Brain { didSet { d.set(brain.rawValue, forKey: "ariaBrain") } }
    @Published var personality: String { didSet { d.set(personality, forKey: "ariaPersonality") } }
    /// Reason before answering (hidden from speech). Only for brains that can think.
    @Published var thinkFirst: Bool { didSet { d.set(thinkFirst, forKey: "ariaThinkFirst") } }
    /// Check facts online when the Mac is online (search queries only). On by default.
    @Published var factCheck: Bool { didSet { d.set(factCheck, forKey: "ariaFactCheck") } }
    /// Show Aria's reasoning and activity in a panel on the Talk screen (and the note). Remembered.
    @Published var showThinking: Bool { didSet { d.set(showThinking, forKey: "airShowThinking") } }
    /// Edited personality texts by id (only those the owner changed), plus the custom text.
    @Published private var edited: [String: String] { didSet { d.set(edited, forKey: "ariaPersonalityTexts") } }

    init() {
        voice = Voices.valid(d.string(forKey: "ariaVoice"))
        brain = Brain(rawValue: d.string(forKey: "ariaBrain") ?? "") ?? .fast
        var e = d.dictionary(forKey: "ariaPersonalityTexts") as? [String: String] ?? [:]
        // Migrate the single persona text from the previous version into "Custom" if the owner wrote one.
        if let old = d.string(forKey: "ariaPersona"), !old.hasPrefix("You enjoy having a good conversation. Your name is"),
           e[Personas.customID] == nil {
            e[Personas.customID] = old
        }
        edited = e
        personality = d.string(forKey: "ariaPersonality") ?? Personas.defaultID
        thinkFirst = d.object(forKey: "ariaThinkFirst") as? Bool ?? false
        factCheck = d.object(forKey: "ariaFactCheck") as? Bool ?? true
        showThinking = d.bool(forKey: "airShowThinking")
        // Leftovers from the earlier two-mode app (old mode, voice and persona keys).
        for old in ["ariaPersona", "persona", "voice", "mode"] { d.removeObject(forKey: old) }
    }

    func text(for id: String) -> String {
        if let t = edited[id] { return t }
        if id == Personas.customID { return Personas.customStarter }
        if let p = Personas.preset(id) { return p.text }
        return MainActor.assumeIsolated { Marketplace.shared.text(for: id) } ?? ""
    }
    func setText(_ t: String, for id: String) {
        if let p = Personas.preset(id), p.text == t { edited.removeValue(forKey: id) } else { edited[id] = t }
    }
    func isEdited(_ id: String) -> Bool { id != Personas.customID && edited[id] != nil }
    func reset(_ id: String) { edited.removeValue(forKey: id) }

    /// The text sent to the model.
    var persona: String { text(for: personality) }

    /// Settings the audio engine sends with each conversation.
    var engineConfig: [String: Any] {
        ["voice": voice, "persona": persona, "personality": personality,
         "personalityName": Personas.name(personality),
         "think": thinkFirst && brain.canThink, "web": factCheck, "showThinking": showThinking]
    }
    /// Changes whenever engineConfig would change (for onChange).
    var engineConfigKey: String {
        "\(voice)|\(personality)|\(persona.hashValue)|\(thinkFirst)|\(factCheck)|\(showThinking)|\(brain.rawValue)"
    }

    @Published var globalHotkey: Bool = UserDefaults.standard.object(forKey: "airGlobalHotkey") as? Bool ?? true {
        didSet { UserDefaults.standard.set(globalHotkey, forKey: "airGlobalHotkey"); onUIPrefsChanged?() }
    }
    @Published var menuBarIcon: Bool = UserDefaults.standard.object(forKey: "airMenuBarIcon") as? Bool ?? true {
        didSet { UserDefaults.standard.set(menuBarIcon, forKey: "airMenuBarIcon"); onUIPrefsChanged?() }
    }
    var onUIPrefsChanged: (() -> Void)?
}
