import AppKit
import PDFKit
import CoreServices
import EventKit
import Foundation

/// Runs the tools Aria asks for. Everything is local; nothing here deletes files.
/// The Python server decides which calls need a spoken "yes" before they reach this runner.
/// macOS asks for Calendar, Reminders and Automation permission the first time a tool needs it.
@MainActor
final class ToolRunner {
    static let shared = ToolRunner()
    private let store = EKEventStore()
    private let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()
    private let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private let spoken: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM, h:mm a"
        return f
    }()

    typealias Result = [String: Any]

    func run(name: String, args: [String: Any]) async -> Result {
        do {
            switch name {
            // vision (capture only; the local model reads the file)
            case "capture_screen": return await ScreenLook.capture(scope: args["scope"] as? String ?? "screen")
            case "get_image": return await ScreenLook.image(source: args["source"] as? String ?? "clipboard",
                                                            path: args["path"] as? String ?? "")
            case "discard_capture": return ScreenLook.discard(path: args["path"] as? String ?? "", save: args["save"] as? Bool ?? false)
            // apps
            case "list_running_apps": return listApps()
            case "open_app": return try openApp(str(args, "name"))
            case "switch_to_app": return try switchTo(str(args, "name"))
            case "quit_app": return try quitApp(str(args, "name"))
            // calendar
            case "calendar_events": return try await events(args)
            case "create_event": return try await createEvent(args)
            case "move_event": return try await moveEvent(args)
            case "delete_event": return try await deleteEvent(args)
            // reminders
            case "reminder_lists": return try await reminderLists()
            case "list_reminders": return try await listReminders(args["list"] as? String)
            case "add_reminder": return try await addReminder(args)
            case "complete_reminder": return try await finishReminder(str(args, "reminder_id"), delete: false)
            case "delete_reminder": return try await finishReminder(str(args, "reminder_id"), delete: true)
            // vault
            case "search_conversations": return searchConversations(try str(args, "query"))
            case "read_conversation": return try readConversation(str(args, "which"))
            case "create_note": return try writeNote(str(args, "title"), str(args, "content"), append: false)
            case "append_to_note": return try writeNote(str(args, "title"), str(args, "content"), append: true)
            // files
            case "find_files": return try findFiles(str(args, "query"))
            case "read_file": return try readFile(str(args, "path"))
            case "read_browser_tabs": return try await browserTabs()
            case "switch_personality": return try await switchPersonality(str(args, "name"))
            case "open_file": return try openPath(str(args, "path"), reveal: false)
            case "reveal_in_finder": return try openPath(str(args, "path"), reveal: true)
            // system
            case "get_date_time":
                let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .short
                return ok(f.string(from: Date()))
            case "battery_status": return try battery()
            case "get_volume":
                let out = try await osa("set s to get volume settings\nreturn ((output volume of s) as text) & \",\" & ((output muted of s) as text)")
                let parts = out.split(separator: ",")
                return ok("Volume \(parts.first ?? "?")%\(parts.last == "true" ? ", muted" : "")",
                          ["volume": Int(parts.first ?? "") ?? -1, "muted": parts.last == "true"])
            case "set_volume":
                let level = max(0, min(100, Int((args["level"] as? Double) ?? Double(args["level"] as? Int ?? -1))))
                _ = try await osa("on run argv\nset volume output volume ((item 1 of argv) as integer)\nend run", ["\(level)"])
                return ok("Volume set to \(level)%")
            case "set_mute":
                let muted = (args["muted"] as? Bool) ?? true
                _ = try await osa("set volume output muted \(muted ? "true" : "false")")
                return ok(muted ? "Muted" : "Unmuted")
            // music
            case "music_now_playing":
                if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty {
                    return ok("Music is not open.")
                }
                try await ensureAutomation("com.apple.Music", "Music", launch: false)
                let out = try await osa("""
                if application "Music" is not running then return "Music is not open."
                tell application "Music"
                  if player state is playing then return "Playing " & name of current track & " by " & artist of current track
                  if player state is paused then return "Paused on " & name of current track & " by " & artist of current track
                  return "Nothing is playing."
                end tell
                """)
                return ok(out)
            case "music_control":
                let action = try str(args, "action")
                try await ensureAutomation("com.apple.Music", "Music", launch: action == "play")
                let cmd = ["play": "play", "pause": "pause", "next": "next track", "previous": "previous track"][action]
                guard let cmd else { throw ToolError("Unknown music action \(action)") }
                _ = try await osa("tell application \"Music\" to \(cmd)")
                return ok("Music: \(action)")
            // shortcuts
            case "list_shortcuts":
                let names = try await sh("/usr/bin/shortcuts", ["list"]).split(separator: "\n").map(String.init)
                return ok(names.isEmpty ? "No shortcuts found." : "\(names.count) shortcuts", ["shortcuts": Array(names.prefix(60))])
            case "run_shortcut":
                let n = try str(args, "name")
                var a = ["run", n]
                if let input = args["input"] as? String, !input.isEmpty {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("air-shortcut-input.txt")
                    try input.write(to: tmp, atomically: true, encoding: .utf8)
                    a += ["-i", tmp.path]
                }
                let out = try await sh("/usr/bin/shortcuts", a, timeout: 90)
                return ok("Ran \(n)" + (out.isEmpty ? "" : ": \(out.prefix(300))"))
            // mail / messages
            case "mail_unread":
                try await ensureAutomation("com.apple.mail", "Mail", launch: false)
                let out = try await osa("""
                tell application "Mail"
                  set n to unread count of inbox
                  set out to (n as text)
                  set msgs to (messages of inbox whose read status is false)
                  repeat with i from 1 to (count of msgs)
                    if i > 5 then exit repeat
                    set m to item i of msgs
                    set out to out & linefeed & (sender of m) & " | " & (subject of m)
                  end repeat
                  return out
                end tell
                """, timeout: 30)
                var lines = out.split(separator: "\n").map(String.init)
                let count = lines.isEmpty ? "0" : lines.removeFirst()
                return ok("\(count) unread emails", ["latest": lines])
            case "messages_unread":
                return fail("macOS doesn't let apps read unread iMessages without Full Disk Access, so I can't check that. The Messages app's badge shows the count.")
            case "send_email":
                try await ensureAutomation("com.apple.mail", "Mail", launch: true)
                _ = try await osa("""
                on run argv
                  tell application "Mail"
                    set m to make new outgoing message with properties {subject:(item 2 of argv), content:(item 3 of argv), visible:false}
                    tell m to make new to recipient at end of to recipients with properties {address:(item 1 of argv)}
                    send m
                  end tell
                end run
                """, [try str(args, "to"), try str(args, "subject"), try str(args, "body")], timeout: 30)
                return ok("Email sent to \(try str(args, "to"))")
            case "send_message":
                try await ensureAutomation("com.apple.MobileSMS", "Messages", launch: true)
                _ = try await osa("""
                on run argv
                  tell application "Messages"
                    set svc to 1st account whose service type = iMessage
                    send (item 2 of argv) to participant (item 1 of argv) of svc
                  end tell
                end run
                """, [try str(args, "to"), try str(args, "text")], timeout: 30)
                return ok("Message sent to \(try str(args, "to"))")
            default:
                return fail("Unknown tool \(name)")
            }
        } catch let e as ToolError {
            return fail(e.message)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    // MARK: helpers

    struct ToolError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    private func ok(_ summary: String, _ extra: Result = [:]) -> Result {
        var r: Result = ["ok": true, "summary": summary]
        r.merge(extra) { a, _ in a }
        return r
    }
    private func fail(_ msg: String) -> Result { ["ok": false, "error": msg] }

    private func str(_ a: [String: Any], _ k: String) throws -> String {
        if let s = a[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        if let n = a[k] as? NSNumber { return n.stringValue }
        throw ToolError("Missing \(k)")
    }

    /// Run AppleScript with arguments passed separately (no string splicing of user text).
    private func osa(_ script: String, _ argv: [String] = [], timeout: TimeInterval = 15) async throws -> String {
        do {
            return try await sh("/usr/bin/osascript", ["-e", script] + argv, timeout: timeout)
        } catch let e as ToolError where e.message.contains("-1743") || e.message.contains("Not authorized") {
            throw ToolError("Air isn't allowed to control that app yet. Allow it in System Settings, Privacy & Security, Automation, Air.")
        }
    }

    /// Apple Events permission for controlling another app, checked without blocking.
    /// If the user hasn't been asked yet, the dialog is shown in the background.
    private func ensureAutomation(_ bundleID: String, _ appName: String, launch: Bool) async throws {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        if !running {
            guard launch, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw ToolError("\(appName) isn't open. Ask me to open \(appName) first.")
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            for _ in 0..<50 where NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr:
            return
        case OSStatus(errAEEventNotPermitted):
            throw ToolError("Air isn't allowed to control \(appName). You can allow it in System Settings, Privacy & Security, Automation, Air.")
        case OSStatus(errAEEventWouldRequireUserConsent):
            DispatchQueue.global().async {
                _ = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
            }
            throw ToolError("I've asked macOS for permission to control \(appName). Please click OK in the dialog, then ask me again.")
        default:
            return  // e.g. still launching; let the script report any problem
        }
    }

    private func sh(_ exe: String, _ args: [String], timeout: TimeInterval = 15) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { cont.resume(throwing: ToolError(error.localizedDescription)); return }
                let deadline = Date().addingTimeInterval(timeout)
                while p.isRunning && Date() < deadline { usleep(20_000) }
                if p.isRunning { p.terminate(); cont.resume(throwing: ToolError("Timed out")); return }
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if p.terminationStatus != 0 { cont.resume(throwing: ToolError(e.isEmpty ? "Failed (\(p.terminationStatus))" : e)) }
                else { cont.resume(returning: o) }
            }
        }
    }

    // MARK: apps

    private func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    private func listApps() -> Result {
        let names = regularApps().compactMap(\.localizedName).sorted()
        return ok(names.joined(separator: ", "), ["apps": names])
    }

    private func findAppURL(_ name: String) -> URL? {
        let target = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var fuzzy: URL?
        for d in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
            for item in items where item.hasSuffix(".app") {
                let base = item.dropLast(4).lowercased()
                if base == target { return URL(fileURLWithPath: d).appendingPathComponent(item) }
                if fuzzy == nil && base.contains(target) { fuzzy = URL(fileURLWithPath: d).appendingPathComponent(item) }
            }
        }
        return fuzzy
    }

    private func runningApp(_ name: String) -> NSRunningApplication? {
        let t = name.lowercased()
        return regularApps().first { $0.localizedName?.lowercased() == t }
            ?? regularApps().first { $0.localizedName?.lowercased().contains(t) == true }
    }

    private func openApp(_ name: String) throws -> Result {
        guard let url = findAppURL(name) else { throw ToolError("I couldn't find an app called \(name).") }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return ok("Opened \(url.deletingPathExtension().lastPathComponent)")
    }

    private func switchTo(_ name: String) throws -> Result {
        if let app = runningApp(name) {
            app.activate()
            return ok("Switched to \(app.localizedName ?? name)")
        }
        return try openApp(name)
    }

    private func quitApp(_ name: String) throws -> Result {
        guard let app = runningApp(name) else { throw ToolError("\(name) isn't running.") }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { throw ToolError("I can't quit Air from inside a conversation.") }
        app.terminate()
        return ok("Asked \(app.localizedName ?? name) to quit")
    }

    // MARK: calendar & reminders

    private func access(_ type: EKEntityType) async throws {
        let status = EKEventStore.authorizationStatus(for: type)
        if status == .fullAccess { return }
        if status == .denied || status == .restricted || status == .writeOnly {
            throw ToolError("Air doesn't have access to your \(type == .event ? "calendar" : "reminders"). Allow it in System Settings, Privacy & Security, \(type == .event ? "Calendars" : "Reminders").")
        }
        // First use: show the macOS dialog without blocking the conversation.
        let s = store
        Task { @MainActor in
            _ = type == .event ? try? await s.requestFullAccessToEvents() : try? await s.requestFullAccessToReminders()
        }
        throw ToolError("I've asked macOS for access to your \(type == .event ? "calendar" : "reminders"). Please click Allow in the dialog, then ask me again.")
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: String(s.prefix(16))) ?? day.date(from: String(s.prefix(10)))
    }

    private func eventItem(_ e: EKEvent) -> Result {
        ["id": e.eventIdentifier ?? "", "title": e.title ?? "(no title)",
         "start": iso.string(from: e.startDate), "end": iso.string(from: e.endDate),
         "all_day": e.isAllDay, "calendar": e.calendar?.title ?? "", "location": e.location ?? ""]
    }

    private func events(_ a: [String: Any]) async throws -> Result {
        try await access(.event)
        let start = Calendar.current.startOfDay(for: parseDate(a["date"] as? String) ?? Date())
        let days = max(1, min(31, (a["days"] as? Int) ?? 1))
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let evs = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
        let items = evs.prefix(40).map(eventItem)
        let desc = evs.prefix(8).map { "\($0.title ?? "") \($0.isAllDay ? "(all day)" : spoken.string(from: $0.startDate))" }
        return ok(evs.isEmpty ? "No events." : "\(evs.count) events: " + desc.joined(separator: "; "), ["events": Array(items)])
    }

    private func createEvent(_ a: [String: Any]) async throws -> Result {
        try await access(.event)
        guard let start = parseDate(a["start"] as? String) else { throw ToolError("I need a start date and time.") }
        let e = EKEvent(eventStore: store)
        e.title = try str(a, "title")
        e.startDate = start
        e.endDate = start.addingTimeInterval(Double((a["duration_minutes"] as? Int) ?? 60) * 60)
        e.location = a["location"] as? String
        if let cal = a["calendar"] as? String,
           let c = store.calendars(for: .event).first(where: { $0.title.lowercased() == cal.lowercased() && $0.allowsContentModifications }) {
            e.calendar = c
        } else {
            e.calendar = store.defaultCalendarForNewEvents
        }
        try store.save(e, span: .thisEvent, commit: true)
        return ok("Added \(e.title ?? "") on \(spoken.string(from: start))", ["event": eventItem(e)])
    }

    private func moveEvent(_ a: [String: Any]) async throws -> Result {
        try await access(.event)
        guard let e = store.event(withIdentifier: try str(a, "event_id")) else { throw ToolError("I couldn't find that event.") }
        guard let start = parseDate(a["new_start"] as? String) else { throw ToolError("I need the new start time.") }
        let length = e.endDate.timeIntervalSince(e.startDate)
        e.startDate = start
        e.endDate = start.addingTimeInterval(length)
        try store.save(e, span: .thisEvent, commit: true)
        return ok("Moved \(e.title ?? "") to \(spoken.string(from: start))")
    }

    private func deleteEvent(_ a: [String: Any]) async throws -> Result {
        try await access(.event)
        guard let e = store.event(withIdentifier: try str(a, "event_id")) else { throw ToolError("I couldn't find that event.") }
        let title = e.title ?? ""
        try store.remove(e, span: .thisEvent, commit: true)
        return ok("Deleted \(title)")
    }

    private func reminderLists() async throws -> Result {
        try await access(.reminder)
        let names = store.calendars(for: .reminder).map(\.title)
        return ok(names.joined(separator: ", "), ["lists": names])
    }

    private func listReminders(_ list: String?) async throws -> Result {
        try await access(.reminder)
        var cals = store.calendars(for: .reminder)
        if let list, !list.isEmpty { cals = cals.filter { $0.title.lowercased() == list.lowercased() } }
        if cals.isEmpty { throw ToolError("I couldn't find a list called \(list ?? "").") }
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
        let items: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: pred) { cont.resume(returning: $0 ?? []) }
        }
        let out: [Result] = items.prefix(40).map { r in
            var d: Result = ["id": r.calendarItemIdentifier, "title": r.title ?? "", "list": r.calendar?.title ?? ""]
            if let due = r.dueDateComponents?.date { d["due"] = iso.string(from: due) }
            return d
        }
        return ok(items.isEmpty ? "No open reminders." : "\(items.count) open reminders: " +
                  items.prefix(8).compactMap(\.title).joined(separator: "; "), ["reminders": out])
    }

    private func addReminder(_ a: [String: Any]) async throws -> Result {
        try await access(.reminder)
        let r = EKReminder(eventStore: store)
        r.title = try str(a, "title")
        if let list = a["list"] as? String,
           let c = store.calendars(for: .reminder).first(where: { $0.title.lowercased() == list.lowercased() }) {
            r.calendar = c
        } else {
            r.calendar = store.defaultCalendarForNewReminders()
        }
        if let due = parseDate(a["due"] as? String) {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(r, commit: true)
        return ok("Added reminder \(r.title ?? "") to \(r.calendar?.title ?? "Reminders")",
                  ["reminder": ["id": r.calendarItemIdentifier, "title": r.title ?? ""]])
    }

    private func finishReminder(_ id: String, delete: Bool) async throws -> Result {
        try await access(.reminder)
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { throw ToolError("I couldn't find that reminder.") }
        let title = r.title ?? ""
        if delete {
            try store.remove(r, commit: true)
            return ok("Deleted reminder \(title)")
        }
        r.isCompleted = true
        try store.save(r, commit: true)
        return ok("Marked \(title) as done")
    }

    // MARK: Air vault

    private func searchConversations(_ query: String) -> Result {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 }
        var hits: [Result] = []
        for note in SessionNote.all() {
            guard let text = try? String(contentsOf: note.url, encoding: .utf8) else { continue }
            let lower = text.lowercased()
            let matched = words.isEmpty ? lower.contains(query.lowercased()) : words.allSatisfy { lower.contains($0) }
            guard matched, let r = lower.range(of: words.first ?? query.lowercased()) else { continue }
            let from = text.index(r.lowerBound, offsetBy: -120, limitedBy: text.startIndex) ?? text.startIndex
            let to = text.index(r.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
            hits.append(["note": note.url.deletingPathExtension().lastPathComponent, "when": note.title,
                         "mode": note.mode, "snippet": String(text[from..<to]).replacingOccurrences(of: "\n", with: " ")])
            if hits.count >= 5 { break }
        }
        return ok(hits.isEmpty ? "No past conversations mention that." : "Found \(hits.count) conversations", ["matches": hits])
    }

    private func readConversation(_ which: String) throws -> Result {
        let notes = SessionNote.all()
        let w = which.lowercased()
        guard let note = notes.first(where: { $0.url.lastPathComponent.lowercased().hasPrefix(w) })
                ?? notes.first(where: { $0.url.lastPathComponent.lowercased().contains(w) || $0.title.lowercased().contains(w) })
        else { throw ToolError("I couldn't find a conversation for \(which).") }
        let lines = note.transcript().map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        return ok("Conversation from \(note.title) (\(note.mode))", ["transcript": String(lines.prefix(3500))])
    }

    private func writeNote(_ title: String, _ content: String, append: Bool) throws -> Result {
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { throw ToolError("The note needs a title.") }
        let dir = Vault.url.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe + ".md")
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        if FileManager.default.fileExists(atPath: url.path) {
            guard append else { throw ToolError("A note called \(safe) already exists. I can add to it instead.") }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(Data("\n- \(stamp): \(content)\n".utf8))
            return ok("Added to \(safe)")
        }
        let body = "---\ncreated: \(day.string(from: Date()))\ntags: [air, note]\n---\n# \(safe)\n\n"
            + (append ? "- \(stamp): \(content)\n" : "\(content)\n") + "\n_Written by Aria in Air, \(stamp)._\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        return ok("Created the note \(safe) in your Air vault")
    }

    // MARK: files & system

    private func mdfind(_ args: [String]) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", NSHomeDirectory()] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private func findFiles(_ query: String) throws -> Result {
        // File names first, then documents whose text mentions the words (e.g. "resume" -> CV.pdf).
        var all = try mdfind(["-name", query])
        if all.count < 5 {
            let words = query.split(separator: " ").map { "kMDItemTextContent == \"*\($0.replacingOccurrences(of: "\"", with: ""))*\"cd" }
            let docs = try mdfind([words.joined(separator: " && ") + " && kMDItemContentTypeTree == \"public.content\""])
            all += docs.filter { !all.contains($0) }.prefix(20)
        }
        // Documents the user made come first: skip code, dependencies, caches and app data.
        let docExt: Set<String> = ["pdf", "docx", "doc", "pages", "rtf", "txt", "md", "odt", "key", "pptx", "numbers",
                                   "xlsx", "csv", "png", "jpg", "jpeg", "heic"]
        let codeExt: Set<String> = ["js", "ts", "py", "swift", "json", "map", "h", "m", "c", "cpp", "rb", "go", "rs", "java",
                                    "css", "scss", "lock", "pyc", "plist", "log"]
        func junk(_ p: String) -> Bool {
            let iCloud = p.contains("/Library/Mobile Documents/")
            return p.contains("/node_modules/") || p.contains("/.") || p.contains("/site-packages/") ||
                (p.contains("/Library/") && !iCloud) || p.contains(".app/") || p.contains("/build/") ||
                codeExt.contains((p as NSString).pathExtension.lowercased())
        }
        func score(_ p: String) -> Int {
            let ext = (p as NSString).pathExtension.lowercased()
            let name = (p as NSString).lastPathComponent.lowercased()
            var s = docExt.contains(ext) ? 3 : 0
            if query.split(separator: " ").allSatisfy({ name.contains($0.lowercased()) }) { s += 2 }
            if p.contains("/Documents/") || p.contains("/Desktop/") || p.contains("/Downloads/") || p.contains("Mobile Documents") { s += 1 }
            return s
        }
        let clean = all.filter { !junk($0) }
        let ranked = clean.enumerated().sorted { (score($0.element), -$0.offset) > (score($1.element), -$1.offset) }.map(\.element)
        let top = Array(ranked.prefix(10))
        if top.isEmpty && !all.isEmpty { return ok("Only app or code files match \(query); no documents.") }
        return ok(top.isEmpty ? "Nothing found for \(query)." : "Found \(all.count) items; top: " +
                  top.prefix(5).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "), ["paths": top])
    }

    /// Switch to a built-in or installed personality by (fuzzy) name, mid-conversation.
    @MainActor private func switchPersonality(_ name: String) throws -> Result {
        let key = name.lowercased().replacingOccurrences(of: "the ", with: "").filter { $0.isLetter }
        let market = Marketplace.shared
        let choices: [(id: String, name: String)] = Personas.presets.map { ($0.id, $0.name) } +
            market.installedPersonalities.map { ($0.id, $0.name) }
        let hit = choices.first { $0.name.lowercased().filter(\.isLetter) == key } ??
            choices.first { !key.isEmpty && $0.name.lowercased().filter(\.isLetter).contains(key) }
        guard let hit, let prefs = AppDelegate.shared?.prefs else {
            throw ToolError("I don't have a personality called \(name). Installed: " + choices.map(\.name).joined(separator: ", ") + ".")
        }
        prefs.personality = hit.id
        market.markUsed(hit.id)
        return ok("Switched to \(hit.name)", ["name": hit.name, "persona": prefs.persona])
    }

    /// Read a local document's text (read-only): PDF, Word, RTF, ODT, HTML, Pages (via its preview),
    /// and plain text formats such as txt, md, csv and json.
    private func readFile(_ path: String) throws -> Result {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("That file doesn't exist. Use find_files to locate it first.") }
        let ext = url.pathExtension.lowercased()
        var text: String?
        switch ext {
        case "pdf":
            text = PDFDocument(url: url)?.string
        case "pages", "key", "numbers":
            // iWork files carry a PDF preview inside the package.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-p", url.path, "QuickLook/Preview.pdf"]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                text = PDFDocument(data: data)?.string
            }
            if text == nil, let pdf = PDFDocument(url: url.appendingPathComponent("QuickLook/Preview.pdf")) { text = pdf.string }
            if text == nil { throw ToolError("I can't read this \(ext) file's text. If you export it as PDF or Word, I can read that.") }
        case "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive":
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        case "xlsx", "xls":
            throw ToolError("I can't read spreadsheets directly yet. I can open it for you, or read it if you save it as CSV.")
        default:
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            throw ToolError("That file has no readable text (it may be a scanned image).")
        }
        let clean = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        let limit = 3200
        return ok("Read \(url.lastPathComponent) (\(clean.count) characters)",
                  ["name": url.lastPathComponent, "path": url.path, "text": String(clean.prefix(limit)),
                   "truncated": clean.count > limit])
    }

    /// Open tabs (title and URL) in Safari and Chromium-style browsers that are running; the active
    /// tab of the frontmost (or most recently used) browser comes first.
    private func browserTabs() async throws -> Result {
        let browsers: [(id: String, name: String, safari: Bool)] = [
            ("com.apple.Safari", "Safari", true), ("com.google.Chrome", "Chrome", false),
            ("company.thebrowser.Browser", "Arc", false), ("com.tabbit-ai.Tabbit", "Tabbit", false),
            ("com.brave.Browser", "Brave", false), ("com.microsoft.edgemac", "Edge", false),
        ]
        let running = browsers.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.id).isEmpty }
        guard !running.isEmpty else { throw ToolError("No supported browser is open (Safari, Chrome, Arc, Tabbit, Brave or Edge).") }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ScreenLook.targetApp()?.bundleIdentifier
        let ordered = running.sorted { a, _ in a.id == front }
        var tabs: [[String: Any]] = []
        var problems: [String] = []
        for b in ordered {
            do {
                try await ensureAutomation(b.id, b.name, launch: false)
            } catch {
                problems.append((error as? ToolError)?.message ?? error.localizedDescription); continue
            }
            let script = b.safari ? """
            set out to ""
            set sep to character id 9
            tell application id "\(b.id)"
              if (count of windows) is 0 then return ""
              set out to out & "ACTIVE" & sep & (name of current tab of front window) & sep & (URL of current tab of front window) & linefeed
              repeat with w in windows
                repeat with t in tabs of w
                  set out to out & "TAB" & sep & (name of t) & sep & (URL of t) & linefeed
                end repeat
              end repeat
            end tell
            return out
            """ : """
            set out to ""
            set sep to character id 9
            tell application id "\(b.id)"
              if (count of windows) is 0 then return ""
              set out to out & "ACTIVE" & sep & (title of active tab of front window) & sep & (URL of active tab of front window) & linefeed
              repeat with w in windows
                repeat with t in tabs of w
                  set out to out & "TAB" & sep & (title of t) & sep & (URL of t) & linefeed
                end repeat
              end repeat
            end tell
            return out
            """
            guard let out = try? await osa(script, timeout: 10) else { problems.append("I couldn't read \(b.name)'s tabs."); continue }
            var activeURL = ""
            for line in out.split(separator: "\n") {
                let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard f.count == 3 else { continue }
                if f[0] == "ACTIVE" { activeURL = f[2]; tabs.append(["browser": b.name, "title": f[1], "url": f[2], "active": true]) }
                else if f[2] != activeURL || !tabs.contains(where: { ($0["url"] as? String) == f[2] }) {
                    tabs.append(["browser": b.name, "title": f[1], "url": f[2]])
                }
            }
        }
        if tabs.isEmpty { throw ToolError(problems.first ?? "No open tabs found.") }
        let active = tabs.first { ($0["active"] as? Bool) == true }
        return ok("\(tabs.count) open tabs" + (active.map { "; active: \($0["title"] as? String ?? "")" } ?? ""),
                  ["tabs": Array(tabs.prefix(40)),
                   "note": "To see what's on a tab, call read_page with its url."])
    }

    private func openPath(_ path: String, reveal: Bool) throws -> Result {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("That file doesn't exist.") }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
        return ok("\(reveal ? "Showed" : "Opened") \(url.lastPathComponent)",
                  ["note": "This only shows it to the user. To answer questions about its content, call read_file with this path."])
    }

    private func battery() throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "batt"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let line = s.split(separator: "\n").first(where: { $0.contains("%") }) else { return ok("No battery found.") }
        let parts = line.split(separator: "\t").last?.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        return ok(parts.prefix(3).joined(separator: ", "))
    }
}
