import AVFoundation
import AppKit
import EventKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, voice, personality, brain, online, privacy, memory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
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
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Group {
                switch nav.tab {
                case .general: GeneralSettings()
                case .voice: VoiceSettings()
                case .personality: PersonalitySettings()
                case .brain: BrainSettings()
                case .online: OnlineSettings()
                case .privacy: PrivacySettings()
                case .memory: MemorySettings()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(nav.tab.title)
        }
        .frame(minWidth: 680, minHeight: 500)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var model: ModelProcess
    var body: some View {
        Form {
            Section("Quick access") {
                Toggle("Global shortcut ⌃⌥Space to talk to Aria", isOn: $prefs.globalHotkey)
                Toggle("Show Air in the menu bar", isOn: $prefs.menuBarIcon)
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
                Toggle("Online fact-check", isOn: $prefs.factCheck)
                LabeledContent("Status") {
                    Label(web.online ? "Online" : "Offline", systemImage: web.online ? "wifi" : "wifi.slash")
                        .foregroundStyle(web.online ? Color.secondary : Color.orange)
                }
            } footer: {
                Text("When the Mac is online, Aria checks facts with DuckDuckGo and Wikipedia and says what an answer is based on. Only the search words leave the Mac, never the conversation or your profile. Offline, she answers from what she knows and says she couldn't verify. Sources appear as chips under her reply.")
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

struct PrivacySettings: View {
    @State private var tick = 0
    var body: some View {
        Form {
            Section("What stays on this Mac") {
                Label("Speech recognition, the language model and the voice all run locally.", systemImage: "lock.shield")
                Label("Conversations are saved only to your Air vault in Obsidian.", systemImage: "doc.text")
                Label("Online fact-check sends only search words or a link.", systemImage: "globe")
            }
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
