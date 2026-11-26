import AVFoundation
import AppKit
import EventKit
import SwiftUI
import ServiceManagement

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, voice, personality, brain, online, privacy, memory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .voice: return "Voice"
        case .personality: return "Personality"
        case .brain: return "Brain"
        case .online: return "Online"
        case .privacy: return "Privacy"
        case .memory: return "Memory"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .voice: return "waveform"
        case .personality: return "person.crop.circle"
        case .brain: return "cpu"
        case .online: return "globe"
        case .privacy: return "hand.raised"
        case .memory: return "brain.head.profile"
        }
    }
}

@MainActor
final class SettingsNav: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// The Settings window (⌘,): a sidebar of grouped native sections.
struct SettingsView: View {
    @EnvironmentObject var nav: SettingsNav
    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding(get: { nav.tab }, set: { if let t = $0 { nav.tab = t } })) { t in
                Label(t.title, systemImage: t.symbol).tag(t)
            }
            .amoledList()
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Group {
                switch nav.tab {
                case .general: GeneralSettings()
                case .appearance: AppearanceSettings()
                case .voice: VoiceSettings()
                case .personality: PersonalitySettings()
                case .brain: BrainSettings()
                case .online: OnlineSettings()
                case .privacy: PrivacySettings()
                case .memory: MemorySettings()
                }
            }
            .formStyle(.grouped)
            .amoledList()
            .navigationTitle(nav.tab.title)
        }
        .frame(minWidth: 680, minHeight: 500)
    }
}

struct AppearanceSettings: View {
    @AppStorage("airTheme") private var themeID = AirTheme.aurora.rawValue
    @AppStorage("airAppearanceMode") private var mode = AppearanceMode.system.rawValue
    @AppStorage("airBackground") private var background = "theme"
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(AirTheme.allCases) { t in
                        ThemeCard(theme: t, selected: themeID == t.rawValue) { themeID = t.rawValue }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } header: {
                Text("Theme")
            } footer: {
                Text("Colours the orb, buttons and logo. The Dock icon follows the theme while Air is open.")
            }
            OrbSettingsSection()
            IslandSettingsSection()
            Section {
                Picker("Background", selection: $background) {
                    Text("Theme default").tag("theme")
                    Text("AMOLED black (recommended)").tag("amoled")
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Background")
            } footer: {
                Text("AMOLED black: pure black window, panels and Island, no blur, high-contrast text. The particle orb glows best on it. Accents keep your theme's colours.")
            }
            Section("Light and dark") {
                Picker("Appearance", selection: $mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, _ in AppearanceMode.apply() }
            }
        }
    }
}

struct ThemeCard: View {
    let theme: AirTheme
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AirLogo(size: 84).environment(\.airTheme, theme)
                Text(theme.name).font(.headline)
                Text(theme.blurb).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    ForEach(Array(theme.colors.enumerated()), id: \.offset) { _, c in
                        Circle().fill(c).frame(width: 12, height: 12)
                    }
                }
            }
            .padding(12)
            .frame(width: 150)
            .background(selected ? theme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? theme.accent : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var prefs: Prefs
    @State private var loginTick = false
    @EnvironmentObject var model: ModelProcess
    var body: some View {
        Form {
            Section("Quick access") {
                Toggle("Global shortcut ⌃⌥Space to talk to Aria", isOn: $prefs.globalHotkey)
                Toggle("Show Air in the menu bar", isOn: $prefs.menuBarIcon)
            }
            Section {
                Toggle("Keep Air ready in the background", isOn: $prefs.keepReady)
                    .disabled(!prefs.menuBarIcon)
                if prefs.keepReady {
                    Stepper("Unload after \(Int(prefs.idleUnloadHours)) h idle", value: $prefs.idleUnloadHours, in: 1...24, step: 1)
                }
                Toggle("Open Air at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { NSLog("Air: login item: \(error.localizedDescription)") }
                        loginTick.toggle()
                    }))
                    .id(loginTick)
            } header: {
                Text("Start-up")
            } footer: {
                Text("With the window closed, Aria stays loaded in the menu bar so she answers at once (uses about 5 GB of memory). She unloads after the idle time, and loads again when you open Air or press ⌃⌥Space.")
            }
            Section {
                HStack(spacing: 14) {
                    AirLogo(size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Air").font(.title2.weight(.semibold))
                        Text("Aria, a private voice assistant that runs on this Mac.").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Keyboard") {
                ShortcutRow(keys: "Space", action: "Start talking · end your turn · interrupt Aria")
                ShortcutRow(keys: "Esc", action: "Cancel a pending action, or end the conversation")
                ShortcutRow(keys: "Return", action: "Confirm a pending action")
                ShortcutRow(keys: "⌘1  ⌘2", action: "Talk · History")
                ShortcutRow(keys: "⌘,", action: "Settings")
            }
            Section {
                Button("Show Welcome Again") { AppActions.showOnboarding() }
            }
            Section("Advanced") {
                LabeledContent("Python", value: model.pythonPath).textSelection(.enabled)
                HStack {
                    Button("Restart Aria") { model.restart(voice: prefs.voice, persona: prefs.persona, brain: prefs.brain) }
                    Button("Show Log") { NSWorkspace.shared.open(ModelProcess.logURL) }
                }
            }
        }
    }
}

struct ShortcutRow: View {
    let keys: String
    let action: String
    var body: some View {
        LabeledContent {
            Text(action).foregroundStyle(.secondary)
        } label: {
            Text(keys).font(.system(.body, design: .rounded).weight(.medium))
        }
    }
}

struct VoiceSettings: View {
    @EnvironmentObject var prefs: Prefs
    private var noiseNote: String {
        switch prefs.noiseMode {
        case "standard": return "Any sound loud enough counts as you talking. Fine in a quiet room."
        case "headphones": return "Nothing plays into the mic, so Aria reacts quickest. Use with headphones."
        default: return "Music or a TV in the room won't stop Aria. Speak clearly near the Mac to interrupt."
        }
    }
    var body: some View {
        Form {
            Section {
                ForEach(Voices.all, id: \.id) { v in
                    HStack {
                        ChoiceRow(title: v.name, subtitle: v.note, selected: prefs.voice == v.id) { prefs.voice = v.id }
                        PreviewButton(voice: v.id)
                    }
                }
            } footer: {
                Text("Kokoro voices, chosen by Kokoro's own quality grades. Previews need Aria to be running. Changes apply to the next conversation.")
            }
            Section {
                Picker("Background noise handling", selection: $prefs.noiseMode) {
                    Text("Standard").tag("standard")
                    Text("Music-tolerant").tag("music")
                    Text("Headphones").tag("headphones")
                }
                .pickerStyle(.radioGroup)
                Text(noiseNote).foregroundStyle(.secondary).font(.callout)
                LabeledContent("Interrupt sensitivity") {
                    HStack {
                        Text("Rarely").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $prefs.interruptSensitivity, in: 0...1)
                            .frame(maxWidth: 220)
                            .accessibilityValue("\(Int(prefs.interruptSensitivity * 100)) percent")
                        Text("Quickly").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Talking over Aria")
            } footer: {
                Text("Applies right away, even mid-conversation. Music-tolerant mode uses a small on-device speech detector (Silero VAD); nothing leaves your Mac.")
            }
        }
    }
}

struct PersonalitySettings: View {
    @EnvironmentObject var prefs: Prefs
    var body: some View {
        Form {
            Section {
                Picker("Personality", selection: $prefs.personality) {
                    ForEach(Personas.presets) { p in Text(p.name).tag(p.id) }
                    Text("Custom").tag(Personas.customID)
                }
                Text(Personas.preset(prefs.personality)?.summary ?? "Your own personality text.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: Binding(get: { prefs.text(for: prefs.personality) },
                                         set: { prefs.setText($0, for: prefs.personality) }))
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 300)
                    .accessibilityLabel("Personality text")
                HStack {
                    if prefs.isEdited(prefs.personality) {
                        Label("Edited", systemImage: "pencil").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Reset to Default") { prefs.reset(prefs.personality) }
                        .disabled(!prefs.isEdited(prefs.personality))
                }
            } header: {
                Text("Spec")
            } footer: {
                Text("Layered spec: identity, ranked values, rules for facts and honesty, anti-flattery rules, spoken style, memory and tool use, and examples. Changes apply from the next conversation.")
            }
        }
    }
}

struct BrainSettings: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var web: WebController
    var body: some View {
        Form {
            Section {
                Picker("Brain", selection: $prefs.brain) {
                    ForEach(Brain.allCases) { b in Text(b.label).tag(b) }
                }
                .pickerStyle(.radioGroup)
                .disabled(web.live)
                Text(prefs.brain.footer).foregroundStyle(.secondary)
            } footer: {
                Text("Changing the brain restarts Aria (about 15 to 30 seconds). Larger models were tested and don't fit in 24 GB alongside speech.")
            }
            Section {
                Toggle("Show thinking", isOn: $prefs.showThinking)
            } footer: {
                Text("A panel on the Talk screen shows Aria's reasoning (never spoken) and what she did: what she heard, tool calls, searches, pages read, sources and memory. When on, it's also saved in the session note under a collapsed Thinking section.")
            }
            Section {
                Toggle("Think first", isOn: $prefs.thinkFirst).disabled(!prefs.brain.canThink)
            } footer: {
                Text(prefs.brain.canThink
                     ? "Aria reasons silently before answering and says \"Let me think.\" Adds about 10 to 15 seconds."
                     : "Needs the Deeper brain; the Fast brain can't reason first.")
            }
        }
    }
}

struct OnlineSettings: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var web: WebController
    var body: some View {
        Form {
            Section {
                Picker("Fact-check", selection: $prefs.factCheckChoice) {
                    Text("Smart").tag("smart")
                    Text("Always").tag("always")
                    Text("Off").tag("off")
                }
                .pickerStyle(.segmented)
                Text(prefs.factCheckChoice == "smart"
                     ? "Checks online only when it matters: recent or time-sensitive questions, claims that look doubtful, specific numbers or quotes, health, legal and money specifics, or when you ask (\"are you sure?\"). Chat, opinions, advice and well-known facts are answered straight away."
                     : prefs.factCheckChoice == "always" ? "Checks online for every factual question. Slower: about 3 to 4 seconds more on those turns."
                     : "Never checks online unless you ask Aria to look something up.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Status") {
                    Label(web.online ? "Online" : "Offline", systemImage: web.online ? "wifi" : "wifi.slash")
                        .foregroundStyle(web.online ? Color.secondary : Color.orange)
                }
            } footer: {
                Text("When the Mac is online, Aria checks facts on the web and says what an answer is based on. Only the search words leave the Mac, never the conversation or your profile. Offline, she answers from what she knows and says she couldn't verify. Sources appear as chips under her reply.")
            }
            Section("Tabs") {
                Stepper("Max tabs per request: \(prefs.maxTabs)", value: $prefs.maxTabs, in: 1...30)
                Stepper("Ask first above: \(prefs.confirmTabs) tabs", value: $prefs.confirmTabs, in: 1...30)
                Text("For research, Aria can open several sites at once (\"open LinkedIn, Seek and Indeed\", \"open the top 5 results\", \"open the sources\"), each in a new tab, in order.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SearchBackendSection()
            Section("Research") {
                Text("Ask Aria to research something (\"research whether…\", \"compare…\") and she plans a few searches, reads 5 to 10 pages at once, and answers with the sites she used, noting where they disagree. It takes about 20 to 30 seconds; say anything to interrupt. Ask for deep research for a longer written brief you can save. The sources and quotes are kept in the session note.")
                    .foregroundStyle(.secondary)
            }
            Section("Browser and exports") {
                Text("Aria can open links, read public pages, pull tables and video transcripts, and save them to Documents › Air Exports. She can't log in, fill in forms, buy, post or download files.")
                    .foregroundStyle(.secondary)
                Button("Open Air Exports Folder") {
                    let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Air Exports")
                    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(u)
                }
            }
        }
    }
}

/// Where web searches go. Stored in ~/Library/Application Support/Air/search.json (owner-only),
/// which the engine reads on every search, so changes apply at once.
struct SearchBackendSection: View {
    enum Backend: String, CaseIterable, Identifiable {
        case duckduckgo, searxng, brave
        var id: String { rawValue }
        var label: String {
            switch self {
            case .duckduckgo: return "DuckDuckGo (no key)"
            case .searxng: return "My SearXNG server"
            case .brave: return "Brave Search API"
            }
        }
    }
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Air/search.json")

    @State private var backend: Backend = .duckduckgo
    @State private var searxURL = ""
    @State private var braveKey = ""
    @State private var loaded = false

    var body: some View {
        Section {
            Picker("Search with", selection: $backend) {
                ForEach(Backend.allCases) { Text($0.label).tag($0) }
            }
            if backend == .searxng {
                TextField("SearXNG address", text: $searxURL, prompt: Text("http://localhost:8888"))
                    .textContentType(.URL)
            }
            if backend == .brave {
                SecureField("Brave API key", text: $braveKey)
            }
        } header: {
            Text("Search engine")
        } footer: {
            Text(backend == .duckduckgo
                 ? "The default. Wikipedia is used as one source among many. Reputable sites are preferred and every source shows its site."
                 : "If this backend fails, Aria falls back to DuckDuckGo. The key is stored only on this Mac, readable only by you.")
        }
        .onAppear(perform: load)
        .onChange(of: backend) { _, _ in save() }
        .onChange(of: searxURL) { _, _ in save() }
        .onChange(of: braveKey) { _, _ in save() }
    }

    private func load() {
        if let d = try? Data(contentsOf: Self.url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
            backend = Backend(rawValue: o["backend"] ?? "") ?? .duckduckgo
            searxURL = o["searxng_url"] ?? ""
            braveKey = o["brave_key"] ?? ""
        }
        DispatchQueue.main.async { loaded = true }
    }

    private func save() {
        guard loaded else { return }
        let o = ["backend": backend.rawValue, "searxng_url": searxURL.trimmingCharacters(in: .whitespaces),
                 "brave_key": braveKey.trimmingCharacters(in: .whitespaces)]
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Self.url.path, contents: d, attributes: [.posixPermissions: 0o600])
    }
}

struct PrivacySettings: View {
    @State private var tick = 0
    var body: some View {
        Form {
            Section("What stays on this Mac") {
                Label("Speech recognition, the language model and the voice all run locally.", systemImage: "lock.shield")
                Label("Conversations are saved only to your Air vault in Obsidian.", systemImage: "doc.text")
                Label("Online fact-check sends only search words or a link.", systemImage: "globe")
            }
            VisionPrivacySection()
            ScreenAwarenessSection()
            Section("Permissions") {
                PermissionRow(title: "Microphone", status: Self.av(AVCaptureDevice.authorizationStatus(for: .audio)),
                              pane: "Privacy_Microphone") {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in tick += 1 } }
                }
                PermissionRow(title: "Calendar", status: Self.ek(EKEventStore.authorizationStatus(for: .event)),
                              pane: "Privacy_Calendars") {
                    Task { _ = try? await EKEventStore().requestFullAccessToEvents(); tick += 1 }
                }
                PermissionRow(title: "Reminders", status: Self.ek(EKEventStore.authorizationStatus(for: .reminder)),
                              pane: "Privacy_Reminders") {
                    Task { _ = try? await EKEventStore().requestFullAccessToReminders(); tick += 1 }
                }
                PermissionRow(title: "Screen Recording", status: CGPreflightScreenCaptureAccess() ? .allowed : .onFirstUse,
                              pane: "Privacy_ScreenCapture", request: nil)
                PermissionRow(title: "Automation (Music, Mail, Messages)", status: .onFirstUse, pane: "Privacy_Automation", request: nil)
            }
            .id(tick)
        }
    }
}

enum PermissionStatus { case allowed, notYet, denied, onFirstUse }

extension PrivacySettings {
    static func av(_ s: AVAuthorizationStatus) -> PermissionStatus {
        s == .authorized ? .allowed : (s == .notDetermined ? .notYet : .denied)
    }
    static func ek(_ s: EKAuthorizationStatus) -> PermissionStatus {
        s == .fullAccess ? .allowed : (s == .notDetermined ? .notYet : .denied)
    }
}

struct VisionPrivacySection: View {
    @AppStorage("airVisionEnabled") private var enabled = true
    @AppStorage("airVisionExcludeMessages") private var excludeMessages = true
    @AppStorage("airVisionExcluded") private var excluded = ScreenLook.defaultExcluded.joined(separator: ", ")
    var body: some View {
        Section {
            Toggle("Let Aria look at the screen or an image when I ask", isOn: $enabled)
            Toggle("Never look at Messages", isOn: $excludeMessages).disabled(!enabled)
            VStack(alignment: .leading, spacing: 4) {
                Text("Never look at these apps")
                TextField("App names, separated by commas", text: $excluded, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
            }
            .disabled(!enabled)
        } header: {
            Text("Screen and images")
        } footer: {
            Text("Only on request, never in the background. A red \"Looking at your screen\" badge shows while Aria captures. Excluded apps are refused, or hidden from full-screen captures. Images are read by the local Qwen3.5 9B model (loaded only for these questions), never sent online, and deleted right after unless you say \"save this screenshot\". The note records only which app and window were looked at. Password fields show as dots on screen, so their contents are never captured.")
        }
    }
}

struct PermissionRow: View {
    let title: String
    let status: PermissionStatus
    let pane: String
    let request: (() -> Void)?
    var body: some View {
        LabeledContent(title) {
            HStack {
                switch status {
                case .allowed: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied: Label("Denied", systemImage: "xmark.circle").foregroundStyle(.orange)
                case .notYet: Text("Not yet").foregroundStyle(.secondary)
                case .onFirstUse: Text("Asked on first use").foregroundStyle(.secondary)
                }
                if status == .notYet, let request { Button("Allow…", action: request) }
                else if status != .allowed { Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                } }
            }
            .fixedSize()
        }
    }
}

struct MemorySettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Vault") { Text(Vault.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    Button("Open Profile.md") { Vault.open(Vault.url.appendingPathComponent("Profile.md")) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Vault.url.appendingPathComponent("Profile.md")])
                    }
                    Button("Open Air Index") { Vault.open(Vault.indexURL) }
                }
            } header: {
                Text("What Aria remembers")
            } footer: {
                Text("After each conversation Aria adds a summary to the note and new facts to Profile.md: goals, preferences, decisions, corrections and open threads. She never deletes lines there, so your edits win. At the start of a conversation she reads the profile and the three most recent summaries.")
            }
        }
    }
}

/// Settings › Appearance › Orb: the particle orb.
struct OrbSettingsSection: View {
    @AppStorage("airOrbSensitivity") private var sensitivity = 1.0
    @AppStorage("airOrbDensity") private var density = "medium"
    @AppStorage("airOrbGlow") private var glow = 0.6
    @AppStorage("airOrbPalette") private var palette = "nebula"
    @AppStorage("airOrbShadow") private var shadow = true
    @AppStorage("airOrbShadowIntensity") private var shadowIntensity = 0.6
    var body: some View {
        Section {
            LabeledContent("Sensitivity") {
                Slider(value: $sensitivity, in: 0.3...3.0) { Text("Sensitivity") } minimumValueLabel: {
                    Image(systemName: "speaker.wave.1")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3")
                }
            }
            Picker("Particle density", selection: $density) {
                Text("Low").tag("low"); Text("Medium").tag("medium"); Text("High").tag("high")
            }
            .pickerStyle(.segmented)
            LabeledContent("Glow") { Slider(value: $glow, in: 0...1) }
            Toggle("Orb backdrop glow", isOn: $shadow)
            LabeledContent("Glow intensity") { Slider(value: $shadowIntensity, in: 0...1) }
                .disabled(!shadow)
            Picker("Colours", selection: $palette) {
                Text("Nebula").tag("nebula")
                Text("Follow theme").tag("theme")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Orb")
        } footer: {
            Text("A sphere of glowing particles that moves with the voice being heard or spoken: different pitches move different parts of it, and loudness brightens it. Low density uses the least power. It holds still with Reduce Motion.")
        }
    }
}

/// Settings › Privacy › Screen awareness.
struct ScreenAwarenessSection: View {
    @AppStorage("airScreenAwareness") private var mode = "request"
    var body: some View {
        Section {
            Picker("Screen awareness", selection: $mode) {
                Text("Off").tag("off")
                Text("On request").tag("request")
                Text("Always aware").tag("always")
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("Live screen")
        } footer: {
            Text("On request: say “watch my screen” (or use the menu bar) and Aria keeps a light, text-only sense of the front window until you say “stop watching”. Always aware: this runs whenever a conversation is live, so “what's this?” just works; it pauses when the conversation ends or after 10 minutes without changes. Either way: excluded apps are never captured, only the window's text is read on this Mac, nothing goes online, frames are kept in memory only, and the session note records just “watched: app, window”.")
        }
    }
}
