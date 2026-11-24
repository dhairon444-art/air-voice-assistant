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

enum Voices {
    static let all: [(id: String, label: String)] = [
        ("af_heart", "Heart (warm, American)"), ("af_bella", "Bella (American)"),
        ("af_nicole", "Nicole (soft, American)"), ("af_aoede", "Aoede (American)"),
        ("af_kore", "Kore (American)"), ("af_sarah", "Sarah (American)"),
        ("af_nova", "Nova (American)"), ("af_sky", "Sky (American)"),
        ("bf_emma", "Emma (British)"), ("bf_isabella", "Isabella (British)"),
    ]
    static let defaultVoice = "af_heart"
}

/// Personality presets (rewritten as layered specs later in this round).
enum Personas {
    static let templates: [(name: String, text: String)] = [
        ("Warm companion",
         "You enjoy having a good conversation. Your name is Aria, and you are a warm, kind and encouraging friend who is genuinely curious about the person you are talking to. Have a relaxed, friendly conversation. Give full, thoughtful answers of several sentences, explain things with examples, share your own view, and then ask a gentle follow-up question. Always be patient, supportive and positive; never sarcastic, dismissive or rude."),
    ]
    static var defaultText: String { templates[0].text }
    static func presetName(for text: String) -> String {
        templates.first { $0.text == text }?.name ?? "Custom"
    }
}

/// User settings, stored in UserDefaults.
@MainActor
final class Prefs: ObservableObject {
    private let d = UserDefaults.standard

    @Published var voice: String { didSet { d.set(voice, forKey: "ariaVoice") } }
    @Published var brain: Brain { didSet { d.set(brain.rawValue, forKey: "ariaBrain") } }
    @Published var persona: String { didSet { d.set(persona, forKey: "ariaPersona") } }

    init() {
        voice = d.string(forKey: "ariaVoice") ?? Voices.defaultVoice
        brain = Brain(rawValue: d.string(forKey: "ariaBrain") ?? "") ?? .fast
        persona = d.string(forKey: "ariaPersona") ?? Personas.defaultText
    }
}
