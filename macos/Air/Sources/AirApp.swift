import AVFoundation
import AppKit
import Combine
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = ModelProcess()
    let web = WebController()
    let prefs = Prefs()
    let ui = UIState()
    let settingsNav = SettingsNav()
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var assistantWindow: NSWindow?
    var island: IslandController?
    private var liveSub: Any?
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var keyMonitor: Any?
    private var signalSources: [DispatchSourceSignal] = []
    static var shared: AppDelegate!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        installSignalHandlers()
        AppearanceMode.apply()
        IconArt.applyDockIcon()
        ScreenLook.startTracking()
        web.onSessionEnded = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.model.noteSessionsChanged() }
            // "Try it" lasts one conversation: go back to the previous personality.
            if let self, Marketplace.shared.trying != nil {
                Marketplace.shared.trying = nil
                if let prev = UserDefaults.standard.string(forKey: "airTryPrevious") { self.prefs.personality = prev }
            }
        }
        AppActions.openSettings = { [weak self] tab in self?.showSettings(tab) }
        AppActions.showOnboarding = { [weak self] in self?.ui.showOnboarding = true; self?.showMain() }
        AppActions.showMarketplace = { [weak self] in self?.ui.tab = .personalities; self?.showMain() }
        AppActions.showTalk = { [weak self] in self?.showTalk() }
        AppActions.showAssistant = { [weak self] in self?.showAssistant(start: true) }
        web.onAssistantMode = { [weak self] in self?.showAssistant(start: true) }
        web.onCheckin = { kind, time in AssistantStore.shared.setCheckin(kind, time) }
        AssistantStore.shared.onCheckinDue = { [weak self] kind in
            self?.showAssistant(start: false)
            AssistantStore.shared.briefShown = kind
            Task { await AssistantStore.shared.reload() }
        }
        AssistantStore.shared.startCheckins()
        prefs.onUIPrefsChanged = { [weak self] in self?.applyQuickAccess() }

        let root = ContentView()
            .airThemed()
            .environmentObject(model).environmentObject(web).environmentObject(prefs).environmentObject(ui)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Air"
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: root)
        window.setFrameAutosaveName("AirMain")
        if !window.setFrameUsingName("AirMain") { window.center() }
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        AppearanceMode.apply()  // window colour for AMOLED, now that the window exists
        NSApp.activate(ignoringOtherApps: true)

        installKeyMonitor()
        applyQuickAccess()
        island = IslandController(web: web, prefs: prefs) { [weak self] in self?.showTalk() }
        ScreenWatch.shared.send = { [weak self] msg in self?.web.sendToEngine(msg) }
        // Always aware: the light screen context runs whenever a conversation is live; it stops with it.
        liveSub = web.$live.removeDuplicates().sink { live in
            Task { @MainActor in
                if live && ScreenWatch.mode == "always" { _ = ScreenWatch.shared.start() }
                if !live && ScreenWatch.shared.watching { _ = ScreenWatch.shared.stop() }
            }
        }
        if UserDefaults.standard.bool(forKey: "AirIslandDemo") { island?.demo = true; island?.refresh() }
        installKeepReady()

        let args = UserDefaults.standard
        if args.string(forKey: "AirDemo") == "loading" {
            model.demoLoading { [weak self] in self?.web.loadDemo("idle") }
        } else if let demo = args.string(forKey: "AirDemo") {
            web.loadDemo(demo)
            model.showDemoReady()
        } else {
            model.start(voice: prefs.voice, persona: prefs.persona, brain: prefs.brain)
        }
        if let tab = args.string(forKey: "AirSettings"), let t = SettingsTab(rawValue: tab) { showSettings(t) }
        if !args.bool(forKey: "airOnboarded") || args.bool(forKey: "AirShowOnboarding") {
            ui.showOnboarding = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { statusItem == nil }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Close any sheet or open panel first so nothing can veto quitting.
        for w in NSApp.windows { if let sheet = w.attachedSheet { w.endSheet(sheet) } }
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        web.webView.evaluateJavaScript("window.airStop && window.airStop()")
        model.stop()
    }

    // MARK: keep ready in the background

    private var idleTimer: Timer?
    private var lastActive = Date()
    private var unloaded = false
    private var activitySub: AnyCancellable?

    /// Keep Air ready: the engine stays loaded while the window is closed, until it has been idle for
    /// N hours (Settings > General). Off: closing the window unloads it. It comes back on open or hotkey.
    private func installKeepReady() {
        activitySub = web.$state.removeDuplicates().sink { [weak self] _ in self?.lastActive = Date() }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.prefs.keepReady, !self.web.live, self.statusItem != nil else { return }
                self.unloadEngine(reason: "window closed")
            }
        }
    }

    private func checkIdle() {
        guard prefs.keepReady, !unloaded, !web.live, !window.isVisible else { return }
        if Date().timeIntervalSince(lastActive) > prefs.idleUnloadHours * 3600 {
            unloadEngine(reason: "idle for \(Int(prefs.idleUnloadHours)) h")
        }
    }

    private func unloadEngine(reason: String) {
        guard !unloaded, UserDefaults.standard.string(forKey: "AirDemo") == nil else { return }
        web.unload()
        model.stop()
        unloaded = true
        NSLog("Air: engine unloaded (\(reason)) to free memory")
    }

    /// Reload after an unload (window opened, hotkey, menu).
    func wakeEngine() {
        lastActive = Date()
        guard unloaded else { return }
        unloaded = false
        model.start(voice: prefs.voice, persona: prefs.persona, brain: prefs.brain)
    }

    // MARK: windows

    func showMain() {
        wakeEngine()
        window.makeKeyAndOrderFront(nil)
        AppearanceMode.apply()  // window colour for AMOLED, now that the window exists
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings(_ tab: SettingsTab) {
        settingsNav.tab = tab
        if settingsWindow == nil {
            let view = SettingsView().airThemed()
                .environmentObject(settingsNav).environmentObject(prefs).environmentObject(model).environmentObject(web)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Settings"
            w.toolbarStyle = .unified
            w.contentView = NSHostingView(rootView: view)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("AirSettings")
            if !w.setFrameUsingName("AirSettings") { w.center() }
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Assistant mode in its own window (gold orb, tasks, filing). start: begin an assistant conversation,
    /// ending a Talk conversation first if one is live.
    func showAssistant(start: Bool) {
        wakeEngine()
        if assistantWindow == nil {
            let view = AssistantView().airThemed()
                .environmentObject(model).environmentObject(web).environmentObject(prefs).environmentObject(ui)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Assistant"
            w.toolbarStyle = .unified
            w.contentView = NSHostingView(rootView: view)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("AirAssistant")
            if !w.setFrameUsingName("AirAssistant") { w.center() }
            assistantWindow = w
        }
        assistantWindow?.makeKeyAndOrderFront(nil)
        AppearanceMode.apply()
        NSApp.activate(ignoringOtherApps: true)
        if start { web.switchMode("assistant") }
    }

    @objc func openAssistant() { showAssistant(start: web.live && web.mode != "assistant") }

    @objc func openSettingsMenu() { showSettings(settingsNav.tab) }
    @objc func showTalk() { ui.tab = .talk; showMain() }
    @objc func showHistory() { ui.tab = .history; showMain() }
    @objc func showPersonalities() { ui.tab = .personalities; showMain() }
    @objc func toggleTalking() { ui.tab = .talk; showMain(); web.toggle() }
    @objc func togglePause() { web.orbAction() }
    @objc func doneTalking() { web.endTurn() }
    @objc func interruptAria() { web.interrupt() }
    @objc func confirmAction() { if web.confirm != nil { web.answer(true) } }
    @objc func cancelAction() { if web.confirm != nil { web.answer(false) } }
    @objc func showWelcome() { AppActions.showOnboarding() }
    @objc func toggleMicMute() { web.toggleMicMute() }
    @objc func toggleScreenWatch() {
        if ScreenWatch.shared.watching { _ = ScreenWatch.shared.stop() } else { _ = ScreenWatch.shared.start() }
    }
    @objc func toggleVoiceMute() { web.toggleVoiceMute() }
    @objc func toggleThinking() { ui.tab = .talk; showMain(); prefs.showThinking.toggle() }
    @objc func pickPersonality(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { prefs.personality = id } }
    @objc func pickVoice(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { prefs.voice = id } }

    // MARK: keyboard on the Talk screen: Space, Esc, Return

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window, self.ui.tab == .talk, !self.ui.showOnboarding,
                  e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
            if e.window?.firstResponder is NSText { return e }  // typing in a text field
            switch Int(e.keyCode) {
            case kVK_Space:
                if self.web.confirm != nil { return e }
                self.web.primaryAction(); return nil
            case kVK_Escape:
                if self.web.confirm != nil { self.web.answer(false); return nil }
                if self.web.state == .speaking { self.web.interrupt(); return nil }
                if self.web.live { self.web.stop(); return nil }
                return e
            case kVK_Return:
                if self.web.confirm != nil { self.web.answer(true); return nil }
                return e
            default:
                return e
            }
        }
    }

    // MARK: global hotkey and menu bar icon

    private func applyQuickAccess() {
        if prefs.globalHotkey { registerHotKey() } else { unregisterHotKey() }
        if prefs.menuBarIcon { installStatusItem() } else if let s = statusItem {
            NSStatusBar.system.removeStatusItem(s); statusItem = nil
        }
    }

    private func registerHotKey() {
        guard hotKeyRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in AppDelegate.shared?.hotKeyPressed() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x41495231), id: 1)  // 'AIR1'
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregisterHotKey() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
    }

    /// ⌃⌥Space from anywhere: bring Air forward and start talking, then pause and resume (like the orb).
    func hotKeyPressed() {
        wakeEngine()
        // With the Island on, talking can happen with the main window hidden.
        if !IslandController.enabled || !web.engineReady {
            ui.tab = .talk
            showMain()
        }
        web.orbAction()
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Air")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        if web.live {
            menu.addItem(withTitle: web.paused ? "Resume" : "Pause", action: #selector(togglePause), keyEquivalent: "").target = self
            menu.addItem(withTitle: "End Conversation", action: #selector(toggleTalking), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Start Talking", action: #selector(toggleTalking), keyEquivalent: "").target = self
        }
        let ws = menu.addItem(withTitle: ScreenWatch.shared.watching ? "Stop Watching Screen" : "Watch My Screen",
                              action: #selector(toggleScreenWatch), keyEquivalent: "")
        ws.target = self
        ws.isEnabled = web.live
        let mm = menu.addItem(withTitle: "Mute Microphone", action: #selector(toggleMicMute), keyEquivalent: "")
        mm.target = self; mm.state = web.micMuted ? .on : .off
        let mv = menu.addItem(withTitle: "Mute Aria's Voice", action: #selector(toggleVoiceMute), keyEquivalent: "")
        mv.target = self; mv.state = web.voiceMuted ? .on : .off
        menu.addItem(.separator())
        let pItem = NSMenuItem(title: "Personality", action: nil, keyEquivalent: "")
        let pMenu = NSMenu()
        for p in Personas.presets + [Personality(id: Personas.customID, name: "Custom", summary: "", text: "")] {
            let it = NSMenuItem(title: p.name, action: #selector(pickPersonality(_:)), keyEquivalent: "")
            it.representedObject = p.id; it.target = self; it.state = prefs.personality == p.id ? .on : .off
            pMenu.addItem(it)
        }
        pItem.submenu = pMenu
        menu.addItem(pItem)
        let vItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let vMenu = NSMenu()
        for v in Voices.all {
            let it = NSMenuItem(title: "\(v.name) – \(v.note)", action: #selector(pickVoice(_:)), keyEquivalent: "")
            it.representedObject = v.id; it.target = self; it.state = prefs.voice == v.id ? .on : .off
            vMenu.addItem(it)
        }
        vItem.submenu = vMenu
        menu.addItem(vItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Air", action: #selector(showTalk), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Assistant Mode", action: #selector(openAssistant), keyEquivalent: "").target = self
        menu.addItem(withTitle: "History", action: #selector(showHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Air", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    // MARK: misc

    /// `kill <pid>` / logout: stop the child before exiting.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                NSApp.terminate(nil)
                // If something (a modal sheet or panel) holds up termination, don't hang: stop the
                // engine and exit anyway, and leave a note for diagnosis.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    FileHandle.standardError.write(Data("Air: terminate stalled (modal: \(NSApp.modalWindow?.title ?? "none"), windows: \(NSApp.windows.filter(\.isVisible).map { $0.title + ":" + String(describing: type(of: $0)) }))\n".utf8))
                    self?.model.stop()
                    exit(0)
                }
            }
            src.resume()
            signalSources.append(src)
        }
    }
}

@main
struct AirMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = buildMenu(delegate)
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor static func buildMenu(_ d: AppDelegate) -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = target
            return it
        }
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Air", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(item("Welcome to Air…", #selector(AppDelegate.showWelcome), "", target: d))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(AppDelegate.openSettingsMenu), ",", target: d))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Air", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Air", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let talkItem = NSMenuItem(); main.addItem(talkItem)
        let talk = NSMenu(title: "Conversation")
        talk.addItem(item("Start or End Conversation", #selector(AppDelegate.toggleTalking), "t", target: d))
        talk.addItem(item("Pause or Resume", #selector(AppDelegate.togglePause), "p", target: d))
        talk.addItem(item("Done Talking", #selector(AppDelegate.doneTalking), "d", target: d))
        talk.addItem(item("Interrupt Aria", #selector(AppDelegate.interruptAria), ".", target: d))
        talk.addItem(.separator())
        talk.addItem(item("Mute Microphone", #selector(AppDelegate.toggleMicMute), "m", [.command, .shift], target: d))
        talk.addItem(item("Mute Aria's Voice", #selector(AppDelegate.toggleVoiceMute), "v", [.command, .shift], target: d))
        talk.addItem(.separator())
        talk.addItem(item("Confirm Action", #selector(AppDelegate.confirmAction), "\r", target: d))
        talk.addItem(item("Cancel Action", #selector(AppDelegate.cancelAction), "\u{8}", target: d))
        talkItem.submenu = talk

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        view.addItem(item("Talk", #selector(AppDelegate.showTalk), "1", target: d))
        view.addItem(item("History", #selector(AppDelegate.showHistory), "2", target: d))
        view.addItem(item("Personalities", #selector(AppDelegate.showPersonalities), "3", target: d))
        view.addItem(item("Assistant Mode", #selector(AppDelegate.openAssistant), "a", [.command, .shift], target: d))
        view.addItem(.separator())
        view.addItem(item("Show Thinking", #selector(AppDelegate.toggleThinking), "t", [.command, .option], target: d))
        viewItem.submenu = view

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.windowsMenu = win
        return main
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Checkmarks for the toggles in the menus.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleMicMute): item.state = web.micMuted ? .on : .off
        case #selector(toggleVoiceMute): item.state = web.voiceMuted ? .on : .off
        case #selector(toggleThinking): item.state = prefs.showThinking ? .on : .off
        default: break
        }
        return true
    }
}
