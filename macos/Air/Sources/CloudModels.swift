import Foundation
import Security
import SwiftUI

/// API keys live in the login Keychain only (never in defaults, files, logs or the repo).
enum Keychain {
    static let service = "com.air.cloud"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

enum CloudProvider: String, CaseIterable, Identifiable {
    case anthropic, google
    var id: String { rawValue }
    var name: String { self == .anthropic ? "Claude (Anthropic)" : "Gemini (Google)" }
    var short: String { self == .anthropic ? "Claude" : "Gemini" }
    var keyHelp: String { self == .anthropic ? "From console.anthropic.com, API keys" : "From aistudio.google.com, API keys" }
    var modelKey: String { "airCloud.\(rawValue).model" }
}

struct CloudModelInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Cloud brains for the heavy-brain role. Local is the default; Aria asks before each cloud use.
@MainActor
final class CloudStore: ObservableObject {
    static let shared = CloudStore()

    @Published private(set) var hasKey: [CloudProvider: Bool] = [:]
    @Published private(set) var models: [CloudProvider: [CloudModelInfo]] = [:]
    @Published private(set) var status: [CloudProvider: String] = [:]
    @Published private(set) var testing: CloudProvider?

    init() { for p in CloudProvider.allCases { hasKey[p] = Keychain.get(p.rawValue) != nil } }

    func saveKey(_ p: CloudProvider, _ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(p.rawValue, k)
        hasKey[p] = !k.isEmpty
        models[p] = nil
        status[p] = k.isEmpty ? "Key removed" : "Key saved in the Keychain"
    }

    func selectedModel(_ p: CloudProvider) -> String { UserDefaults.standard.string(forKey: p.modelKey) ?? "" }
    func select(_ p: CloudProvider, _ id: String) { UserDefaults.standard.set(id, forKey: p.modelKey); objectWillChange.send() }

    /// Lists the provider's models with the stored key: that is also the connection test.
    func test(_ p: CloudProvider) async {
        guard let key = Keychain.get(p.rawValue) else { status[p] = "No key"; return }
        testing = p
        defer { testing = nil }
        var req: URLRequest
        switch p {
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .google:
            req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                status[p] = code == 401 || code == 403 ? "The key was refused (\(code))" : "Couldn't connect (\(code))"
                return
            }
            var list: [CloudModelInfo] = []
            if p == .anthropic {
                for m in obj["data"] as? [[String: Any]] ?? [] {
                    if let id = m["id"] as? String { list.append(CloudModelInfo(id: id, name: m["display_name"] as? String ?? id)) }
                }
            } else {
                for m in obj["models"] as? [[String: Any]] ?? [] {
                    let methods = m["supportedGenerationMethods"] as? [String] ?? []
                    guard methods.contains("generateContent"), let n = m["name"] as? String, n.contains("gemini") else { continue }
                    let id = n.replacingOccurrences(of: "models/", with: "")
                    list.append(CloudModelInfo(id: id, name: m["displayName"] as? String ?? id))
                }
            }
            models[p] = list
            status[p] = "Connected: \(list.count) models"
            if selectedModel(p).isEmpty || !list.contains(where: { $0.id == selectedModel(p) }), let first = list.first {
                select(p, first.id)
            }
        } catch {
            status[p] = "Offline or unreachable"
        }
    }

    /// Rough cost of one heavy answer (about 8k tokens in, 1k out), from published per-million prices.
    /// Only models whose price is known here get an estimate.
    static func estimate(_ id: String) -> String? {
        let prices: [String: (Double, Double)] = [
            "claude-opus-5-5": (4, 20), "claude-sonnet-5-5": (2, 10), "claude-haiku-5-5": (0.10, 0.50),
            "claude-fable-5-2": (8, 40), "claude-opus-5": (5, 25), "claude-sonnet-5": (2, 10),
        ]
        guard let p = prices[id] else { return nil }
        let usd = 8_000 * p.0 / 1e6 + 1_000 * p.1 / 1e6
        return String(format: "about US$%.3f per answer", usd)
    }
}

/// Privacy limits for cloud use (default: nothing personal leaves the Mac).
enum CloudPolicy {
    static var allowProfile: Bool { UserDefaults.standard.bool(forKey: "airCloud.allowProfile") }
    static var allowScreens: Bool { UserDefaults.standard.bool(forKey: "airCloud.allowScreens") }
}

struct CloudModelsSection: View {
    @ObservedObject var store = CloudStore.shared
    @State private var drafts: [CloudProvider: String] = [:]
    @AppStorage("airCloud.allowProfile") private var allowProfile = false
    @AppStorage("airCloud.allowScreens") private var allowScreens = false

    var body: some View {
        Section {
            ForEach(CloudProvider.allCases) { p in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(p.name).font(.callout.weight(.semibold))
                        Spacer()
                        Label(store.hasKey[p] == true ? "Key set" : "No key",
                              systemImage: store.hasKey[p] == true ? "key.fill" : "key")
                            .font(.caption).foregroundStyle(store.hasKey[p] == true ? .green : .secondary)
                    }
                    HStack {
                        SecureField(store.hasKey[p] == true ? "Replace key" : "API key", text: Binding(
                            get: { drafts[p] ?? "" }, set: { drafts[p] = $0 }))
                            .textFieldStyle(.roundedBorder)
                        Button { store.saveKey(p, drafts[p] ?? ""); drafts[p] = "" } label: { Image(systemName: "tray.and.arrow.down") }
                            .help("Save in the Keychain").disabled((drafts[p] ?? "").isEmpty)
                        Button { Task { await store.test(p) } } label: {
                            if store.testing == p { ProgressView().controlSize(.small) } else { Image(systemName: "bolt.horizontal") }
                        }
                        .help("Test connection and fetch the model list").disabled(store.hasKey[p] != true)
                        if store.hasKey[p] == true {
                            Button { store.saveKey(p, "") } label: { Image(systemName: "trash") }.help("Remove the key")
                        }
                    }
                    if let list = store.models[p], !list.isEmpty {
                        Picker("Model", selection: Binding(get: { store.selectedModel(p) }, set: { store.select(p, $0) })) {
                            ForEach(list) { Text($0.name).tag($0.id) }
                        }
                        if let e = CloudStore.estimate(store.selectedModel(p)) {
                            Text(e).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(store.status[p] ?? p.keyHelp).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: { Text("Cloud models") } footer: {
            Text("Local is always the default. A cloud model can be the heavy brain; Aria asks before each use (\"Use Claude for this?\"), marks replies that used it, and falls back to local when offline. Keys stay in the Keychain.")
        }
        Section {
            Toggle("Allow sending my profile (Profile.md)", isOn: $allowProfile)
            Toggle("Allow sending screenshots and images", isOn: $allowScreens)
        } header: { Text("What may leave the Mac") } footer: {
            Text("Off by default: only the question and the conversation so far are sent.")
        }
    }
}
