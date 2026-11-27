import Foundation
import SwiftUI

/// Aria's brains by role. The talker is the voice everyone hears (chat and simple actions); the thinker
/// sits behind it for deep answers, research and multi-step plans; the heavy brain loads only on demand.
/// The router is fixed (bge-small on the CPU, the talker breaks ties), so it is shown as info, not a choice.
enum ModelRole: String, CaseIterable, Identifiable {
    case talker, thinker, heavy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .talker: return "Talker"
        case .thinker: return "Thinker"
        case .heavy: return "Heavy brain"
        }
    }
    var footer: String {
        switch self {
        case .talker: return "The voice you hear: conversation and simple actions, fast."
        case .thinker: return "Deep answers, research and multi-step plans. It works behind the talker and speaks in the same voice."
        case .heavy: return "Loaded only for deep tasks, and Aria asks before loading it."
        }
    }
    var key: String { "airModel." + rawValue }
}

struct AriaModel: Identifiable, Hashable {
    let id: String          // Hugging Face repo
    let name: String
    let diskGB: Double      // weights
    let ramGB: Double       // loaded, with its working cache
    let roles: Set<ModelRole>
    let note: String

    var installed: Bool { AriaModels.isInstalled(id) }
}

enum AriaModels {
    /// Measured on this Mac (M4, 24 GB) where noted in the release notes; RAM includes a working KV cache.
    static let all: [AriaModel] = [
        AriaModel(id: "mlx-community/gemma-4-e4b-it-4bit", name: "Gemma 4 E4B", diskGB: 4.8, ramGB: 5.6,
                  roles: [.talker], note: "Conversational and quick"),
        AriaModel(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit", name: "Qwen3 4B", diskGB: 2.1, ramGB: 2.9,
                  roles: [.talker], note: "Lightest; fastest first word"),
        AriaModel(id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3 8B", diskGB: 4.3, ramGB: 4.9,
                  roles: [.thinker, .talker], note: "Reliable tools; can reason first"),
        AriaModel(id: "mlx-community/Qwen3.5-9B-4bit", name: "Qwen3.5 9B", diskGB: 5.5, ramGB: 5.3,
                  roles: [.thinker], note: "Stronger answers; also sees images"),
        AriaModel(id: "mlx-community/Qwen3-14B-4bit", name: "Qwen3 14B", diskGB: 8.3, ramGB: 9.4,
                  roles: [.heavy], note: "On demand; slow next to speech"),
        AriaModel(id: "mlx-community/Qwen3-30B-A3B-3bit", name: "Qwen3 30B-A3B (3-bit)", diskGB: 13.4, ramGB: 14.5,
                  roles: [.heavy], note: "MoE; on demand only"),
        AriaModel(id: "mlx-community/gemma-4-26B-A4B-it-heretic-4bit", name: "Gemma 4 26B Heretic", diskGB: 15, ramGB: 16.5,
                  roles: [.heavy], note: "Big; on demand only"),
    ]
    static let defaults: [ModelRole: String] = [
        .talker: "mlx-community/gemma-4-e4b-it-4bit",
        .thinker: "mlx-community/Qwen3.5-9B-4bit",
        .heavy: "",
    ]
    /// Speech recognition, the voice and the router, plus macOS headroom are counted separately.
    static let pipelineGB = 2.2
    static let budgetGB = 24.0
    /// Keep this much for macOS and the owner's other apps.
    static let headroomGB = 6.0

    static func model(_ id: String) -> AriaModel? { all.first { $0.id == id } }
    static func choices(for role: ModelRole) -> [AriaModel] { all.filter { $0.roles.contains(role) && $0.installed } }

    static func isInstalled(_ repo: String) -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--" + repo.replacingOccurrences(of: "/", with: "--") + "/snapshots")
        let snaps = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return !snaps.isEmpty
    }

    struct Preset: Identifiable {
        let id: String
        let name: String
        let talker: String
        let thinker: String
        let heavy: String
        let note: String
    }
    static let presets: [Preset] = [
        Preset(id: "light", name: "Light", talker: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
               thinker: "mlx-community/Qwen3-8B-4bit", heavy: "", note: "Qwen3 4B + Qwen3 8B"),
        Preset(id: "balanced", name: "Balanced", talker: "mlx-community/gemma-4-e4b-it-4bit",
               thinker: "mlx-community/Qwen3-8B-4bit", heavy: "", note: "Gemma 4 E4B + Qwen3 8B"),
        Preset(id: "best", name: "Best", talker: "mlx-community/gemma-4-e4b-it-4bit",
               thinker: "mlx-community/Qwen3.5-9B-4bit", heavy: "mlx-community/gemma-4-26B-A4B-it-heretic-4bit",
               note: "Gemma 4 E4B + Qwen3.5 9B, Gemma 26B on demand"),
    ]

    /// The short label on the Talk screen's brain chip: "E4B + 8B".
    static func short(_ id: String) -> String {
        guard let m = model(id) else { return id.split(separator: "/").last.map(String.init) ?? id }
        return m.name.split(separator: " ").last.map(String.init) ?? m.name
    }

    static func chipText() -> String {
        let t = ModelProcess.voiceTalker()
        let k = ModelProcess.thinkerArgs()
        return k.count >= 2 ? "\(short(t)) + \(short(k[1]))" : short(t)
    }

    static func chipHelp() -> String {
        let t = ModelProcess.voiceTalker()
        let k = ModelProcess.thinkerArgs()
        return "talker \(model(t)?.name ?? t)" + (k.count >= 2 ? ", thinker \(model(k[1])?.name ?? k[1])" : ", no thinker")
    }

    /// Memory for the always-loaded part (talker + thinker + pipeline). The heavy brain is checked when it loads.
    static func residentGB(talker: String, thinker: String) -> Double {
        (model(talker)?.ramGB ?? 0) + (thinker.isEmpty || thinker == talker ? 0 : (model(thinker)?.ramGB ?? 0)) + pipelineGB
    }
}

extension Prefs {
    func model(for role: ModelRole) -> String {
        UserDefaults.standard.string(forKey: role.key) ?? AriaModels.defaults[role] ?? ""
    }
}
