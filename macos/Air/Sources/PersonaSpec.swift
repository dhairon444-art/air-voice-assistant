import Foundation

/// A personality as its own compact character (see tools/professionals.py): role, expertise, focus,
/// frameworks, tone, phrases, do's and don'ts, examples, and per-personality defaults. It compiles to a
/// short, distinct prompt; Air's core rules stay a separate fixed block in the engine.
struct PersonaSpec: Codable, Identifiable, Hashable {
    struct Tone: Codable, Hashable {
        var formal = 0.5, warmth = 0.5, detail = 0.5, bold = 0.5, playful = 0.3
    }
    var id: String
    var name: String
    var emoji: String
    var category: String
    var role: String
    var expertise: String
    var focus: [String]
    var frameworks: [String]
    var tone: Tone
    var phrases: [String]
    var dos: [String]
    var donts: [String]
    var examples: [[String]]          // [[user, aria], ...]
    var voice: String
    var brain: String                 // fast | deeper
    var temperature: Double
    var web: Bool
    var length: String                // short | medium | long
    var rich: String                  // rarely | sometimes | often
    var disclaimer: String
    var sentences: String
    var asks_questions: Bool
    var text: String?

    static func blank(name: String = "") -> PersonaSpec {
        PersonaSpec(id: "my-\(UUID().uuidString.prefix(8).lowercased())", name: name, emoji: "✨", category: "Mine",
                    role: "", expertise: "", focus: [], frameworks: [], tone: Tone(), phrases: [], dos: [], donts: [],
                    examples: [], voice: "af_heart", brain: "fast", temperature: 0.6, web: true, length: "medium",
                    rich: "sometimes", disclaimer: "", sentences: "short to medium", asks_questions: true, text: nil)
    }

    /// The same compiler as tools/professionals.py: the personality's own terms, no shared template.
    func compiled() -> String {
        func pick(_ v: Double, _ lo: String, _ mid: String, _ hi: String) -> String { v < 0.34 ? lo : (v < 0.67 ? mid : hi) }
        let toneWords = [
            pick(tone.formal, "Casual and plain-spoken.", "Natural and clear.", "Formal and precise."),
            pick(tone.warmth, "Blunt; no cushioning.", "Friendly but direct.", "Warm and encouraging."),
            pick(tone.detail, "Brief: get to the point.", "Enough detail to be useful.", "Thorough: explain the why."),
            pick(tone.bold, "Cautious; flag risks.", "Balanced.", "Bold; give a clear call."),
            pick(tone.playful, "Serious.", "A light touch.", "Playful, with humour."),
        ].joined(separator: " ")
        var lines = ["You are Aria, speaking as \(name): \(role.isEmpty ? name : role)."]
        if !expertise.isEmpty || !focus.isEmpty {
            lines.append("Expertise: \(expertise)." + (focus.isEmpty ? "" : " You keep coming back to: \(focus.joined(separator: ", "))."))
        }
        if !frameworks.isEmpty { lines.append("How you think: \(frameworks.joined(separator: ", ")).") }
        lines.append("How you sound: \(toneWords) Sentences: \(sentences)." + (asks_questions ? " Ask a question back when it helps." : ""))
        if !phrases.isEmpty { lines.append("Phrases you naturally use: " + phrases.map { "\"\($0)\"" }.joined(separator: "; ") + ".") }
        if !dos.isEmpty { lines.append("Always: " + dos.joined(separator: "; ") + ".") }
        if !donts.isEmpty { lines.append("Never: " + donts.joined(separator: "; ") + ".") }
        let len = ["short": "usually one to three sentences", "medium": "usually three to five sentences",
                   "long": "longer, structured explanations when the question deserves it"][length] ?? "usually three to five sentences"
        let r = ["rarely": "rarely", "sometimes": "only when they clearly help", "often": "readily, for comparisons, steps and numbers"][rich] ?? "only when they clearly help"
        lines.append("Answers: \(len). Tables or diagrams on screen: \(r).")
        if !disclaimer.isEmpty { lines.append("When it matters, say briefly: \(disclaimer)") }
        let ex = examples.filter { $0.count == 2 }.map { "User: \($0[0])\nAria: \($0[1])" }.joined(separator: "\n")
        if !ex.isEmpty { lines.append("Your voice, for example (tone only; not facts about this user):\n" + ex) }
        return (id == "frenchtutor" ? "LANGUAGE: fr\n" : "") + lines.joined(separator: "\n")
    }
}

/// Air's own personalities and the Professionals, from the bundled professionals.json.
enum ProSpecs {
    static let builtInIDs = ["analyst", "sparring", "mentor", "freespirit", "frenchtutor", "jyotish"]
    static let all: [PersonaSpec] = {
        struct File: Codable { var items: [PersonaSpec] }
        guard let url = Bundle.main.url(forResource: "professionals", withExtension: "json"),
              let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) else { return [] }
        return f.items
    }()
    static var builtIns: [PersonaSpec] { builtInIDs.compactMap { id in all.first { $0.id == id } } }
    static var professionals: [PersonaSpec] { all.filter { !builtInIDs.contains($0.id) } }
    static func spec(_ id: String) -> PersonaSpec? { all.first { $0.id == id } }
}
