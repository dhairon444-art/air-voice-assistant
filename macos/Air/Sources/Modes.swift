import Foundation
import SwiftUI

/// The two conversation modes. Only one mode's models are loaded at a time.
enum Mode: String, CaseIterable, Identifiable {
    case myra, aria
    var id: String { rawValue }

    var name: String { self == .myra ? "Myra" : "Aria" }
    var tagline: String {
        switch self {
        case .myra: return "Quick, full-duplex (PersonaPlex 7B). Only Myra's side is transcribed."
        case .aria: return "In-depth answers (speech recognition + language model + voice). Both sides are transcribed. Talk any time to interrupt."
        }
    }
    var modelDescription: String {
        switch self {
        case .myra: return "nvidia/personaplex-7b-v1 · 4-bit"
        case .aria:
            let llm = (UserDefaults.standard.string(forKey: "ariaBrain") ?? Brain.fast.rawValue).split(separator: "/").last ?? ""
            return "\(llm) · parakeet-tdt-0.6b-v2 · Kokoro-82M (mlx-community) · energy VAD"
        }
    }
    var script: String { self == .myra ? "quick_server.py" : "aria_server.py" }
    var pythonInfoKey: String { self == .myra ? "AirMyraPythonPath" : "AirAriaPythonPath" }
    var defaultPython: String {
        self == .myra ? NSHomeDirectory() + "/personaplex-mlx/.venv/bin/python"
                      : NSHomeDirectory() + "/Library/Application Support/Air/venv-smart/bin/python"
    }
    var defaultVoice: String { self == .myra ? "NATF2" : "af_heart" }
    var voices: [(id: String, label: String)] { self == .myra ? Voices.personaplex : Voices.kokoroFemale }
    var voiceFooter: String {
        self == .myra ? "NAT voices are natural recordings, VAR voices add variety. Changes apply to the next conversation."
                      : "Kokoro voices. Heart is the most natural; American (af) and British (bf) accents. Changes apply to the next conversation."
    }
}

/// Aria's language model. Fast is the default; Deeper is slower but a little more thorough.
enum Brain: String, CaseIterable, Identifiable {
    case fast = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    case deeper = "mlx-community/Qwen3-8B-4bit"
    var id: String { rawValue }
    var label: String { self == .fast ? "Fast · Qwen3 4B" : "Deeper · Qwen3 8B" }
    var footer: String {
        self == .fast ? "About 1-2 s to the first word, about 30 tokens/s on this Mac."
                      : "About 2-3.5 s to the first word, about 15 tokens/s. Restarts Aria when changed."
    }
}

enum Voices {
    static let personaplex: [(id: String, label: String)] = [
        ("NATF0", "Natural female 0"), ("NATF1", "Natural female 1"),
        ("NATF2", "Natural female 2"), ("NATF3", "Natural female 3"),
        ("NATM0", "Natural male 0"), ("NATM1", "Natural male 1"),
        ("NATM2", "Natural male 2"), ("NATM3", "Natural male 3"),
        ("VARF0", "Variety female 0"), ("VARF1", "Variety female 1"),
        ("VARF2", "Variety female 2"), ("VARF3", "Variety female 3"),
        ("VARF4", "Variety female 4"),
        ("VARM0", "Variety male 0"), ("VARM1", "Variety male 1"),
        ("VARM2", "Variety male 2"), ("VARM3", "Variety male 3"),
        ("VARM4", "Variety male 4"),
    ]
    static let kokoroFemale: [(id: String, label: String)] = [
        ("af_heart", "Heart (warm, American)"), ("af_bella", "Bella (American)"),
        ("af_nicole", "Nicole (soft, American)"), ("af_aoede", "Aoede (American)"),
        ("af_kore", "Kore (American)"), ("af_sarah", "Sarah (American)"),
        ("af_nova", "Nova (American)"), ("af_sky", "Sky (American)"),
        ("bf_emma", "Emma (British)"), ("bf_isabella", "Isabella (British)"),
    ]
}

/// Persona presets. `{name}` becomes the mode's name (Myra or Aria). Phrased the way NVIDIA's
/// PersonaPlex examples are ("You enjoy having a good conversation." + scenario + persona details).
enum Personas {
    static let templates: [(name: String, text: String)] = [
        ("Warm companion",
         "You enjoy having a good conversation. Your name is {name}, and you are a warm, kind and encouraging friend who is genuinely curious about the person you are talking to. Have a relaxed, friendly conversation. Give full, thoughtful answers of several sentences, explain things with examples, share your own view, and then ask a gentle follow-up question. Always be patient, supportive and positive; never sarcastic, dismissive or rude."),
        ("Thoughtful teacher",
         "You are a wise and friendly teacher. Answer questions or provide advice in a clear and engaging way. Your name is {name}. Explain ideas step by step with simple, everyday examples, check whether the explanation makes sense, and encourage curiosity with a follow-up question. Be patient and kind, never condescending."),
        ("Coach",
         "You enjoy having a good conversation. Your name is {name}, and you are an upbeat, supportive life coach. Help the person think through their goals and challenges. Listen carefully, reflect back what you heard, offer practical ideas in a few clear steps, and ask an encouraging question to keep them going. Be warm and motivating, never judgmental."),
    ]
    static let legacyMyra = "You are Myra, a warm and curious companion. Listen carefully, answer clearly and keep the conversation natural."

    static func presets(for mode: Mode) -> [(name: String, text: String)] {
        templates.map { ($0.name, $0.text.replacingOccurrences(of: "{name}", with: mode.name)) }
    }
    static func defaultText(for mode: Mode) -> String { presets(for: mode)[0].text }
    static func presetName(for text: String, mode: Mode) -> String {
        presets(for: mode).first { $0.text == text }?.name ?? "Custom"
    }
}

/// User settings, stored in UserDefaults; voice and persona are kept per mode.
@MainActor
final class Prefs: ObservableObject {
    private let d = UserDefaults.standard

    @Published var mode: Mode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var brain: Brain { didSet { d.set(brain.rawValue, forKey: "ariaBrain") } }
    @Published private var voices: [Mode: String]
    @Published private var personas: [Mode: String]

    init() {
        mode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .myra
        brain = Brain(rawValue: d.string(forKey: "ariaBrain") ?? "") ?? .fast
        var v: [Mode: String] = [:]
        var p: [Mode: String] = [:]
        for m in Mode.allCases {
            v[m] = d.string(forKey: Self.voiceKey(m)) ?? m.defaultVoice
            var text = d.string(forKey: Self.personaKey(m)) ?? Personas.defaultText(for: m)
            if text == Personas.legacyMyra { text = Personas.defaultText(for: m) }
            p[m] = text
        }
        voices = v
        personas = p
    }

    private static func voiceKey(_ m: Mode) -> String { m == .myra ? "voice" : "ariaVoice" }
    private static func personaKey(_ m: Mode) -> String { m == .myra ? "persona" : "ariaPersona" }

    var voice: String {
        get { voices[mode] ?? mode.defaultVoice }
        set { voices[mode] = newValue; d.set(newValue, forKey: Self.voiceKey(mode)) }
    }
    var persona: String {
        get { personas[mode] ?? Personas.defaultText(for: mode) }
        set { personas[mode] = newValue; d.set(newValue, forKey: Self.personaKey(mode)) }
    }
}
