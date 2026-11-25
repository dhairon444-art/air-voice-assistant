import AVFoundation
import EventKit
import SwiftUI

/// First-launch welcome: microphone and headphones, voice and personality, optional permissions.
struct OnboardingView: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var ui: UIState
    @State private var step = 0
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var cal = EKEventStore.authorizationStatus(for: .event)
    @State private var rem = EKEventStore.authorizationStatus(for: .reminder)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Capsule().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: 28, height: 4)
                }
            }
            .padding(.top, 20)
            .accessibilityLabel("Step \(step + 1) of 3")

            Group {
                switch step {
                case 0: micStep
                case 1: choicesStep
                default: permissionsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36)

            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 2 {
                    Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Using Air") { finish() }.keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 560, height: 520)
    }

    private var micStep: some View {
        VStack(spacing: 16) {
            OrbView(state: .idle, mic: 0, out: 0).frame(width: 110, height: 110).accessibilityHidden(true)
            Text("Meet Aria").font(.largeTitle.weight(.semibold))
            Text("A voice assistant that runs entirely on this Mac. Talk naturally, pause when you're done, and interrupt her any time.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: mic == .authorized ? "checkmark.circle.fill" : "mic.circle")
                    .font(.title).foregroundStyle(mic == .authorized ? Color.green : Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Microphone").font(.headline)
                    Text(mic == .authorized ? "Allowed. Thank you." : "Needed so Aria can hear you.").foregroundStyle(.secondary)
                }
                Spacer()
                if mic != .authorized {
                    Button("Allow Microphone") {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            Task { @MainActor in mic = AVCaptureDevice.authorizationStatus(for: .audio) }
                        }
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            Label("Use headphones: Aria stops talking when she hears you, so through speakers she may interrupt herself.",
                  systemImage: "headphones")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var choicesStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose how Aria sounds and thinks").font(.title2.weight(.semibold))
            Text("Personality").font(.headline)
            ForEach(Personas.presets) { p in
                ChoiceRow(title: p.name, subtitle: p.summary, selected: prefs.personality == p.id) { prefs.personality = p.id }
            }
            Text("Voice").font(.headline).padding(.top, 6)
            HStack(spacing: 8) {
                ForEach(Voices.all, id: \.id) { v in
                    HStack(spacing: 4) {
                        Button(v.name) { prefs.voice = v.id }
                            .buttonStyle(.bordered)
                            .tint(prefs.voice == v.id ? .accentColor : nil)
                            .accessibilityAddTraits(prefs.voice == v.id ? .isSelected : [])
                        PreviewButton(voice: v.id)
                    }
                }
            }
            Text("You can change both on the Talk screen at any time.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Optional: let Aria help with your day").font(.title2.weight(.semibold))
            Text("Aria can read and, after you say yes, change your calendar and reminders. You can also allow these later; macOS asks the first time they're used.")
                .foregroundStyle(.secondary)
            permission("Calendar", "calendar", cal == .fullAccess) {
                Task { _ = try? await EKEventStore().requestFullAccessToEvents(); cal = EKEventStore.authorizationStatus(for: .event) }
            }
            permission("Reminders", "checklist", rem == .fullAccess) {
                Task { _ = try? await EKEventStore().requestFullAccessToReminders(); rem = EKEventStore.authorizationStatus(for: .reminder) }
            }
            HStack(spacing: 12) {
                Image(systemName: "rectangle.dashed.badge.record").font(.title2).foregroundStyle(.secondary).frame(width: 30)
                VStack(alignment: .leading) {
                    Text("Screen").font(.headline)
                    Text("Coming later: Aria will only look at your screen when you ask.").foregroundStyle(.secondary)
                }
            }
            Label("Shortcuts: Space to talk, Esc to stop, ⌃⌥Space from anywhere.", systemImage: "keyboard")
                .foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    private func permission(_ title: String, _ symbol: String, _ granted: Bool, _ ask: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
            Text(title).font(.headline)
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow…", action: ask)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "airOnboarded")
        ui.showOnboarding = false
    }
}
