import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// Screen and image capture for Aria's vision (on request only). The image goes to a private
/// temporary file that Aria's local model reads; it is deleted right after unless the owner asked
/// to save it. Screenshots never go online.
@MainActor
enum ScreenLook {
    static let defaultExcluded = ["1Password", "Keychain Access", "Passwords", "Bitwarden", "Dashlane",
                                  "LastPass", "Enpass", "Proton Pass", "KeePassXC"]

    static var enabled: Bool { (UserDefaults.standard.object(forKey: "airVisionEnabled") == nil || UserDefaults.standard.bool(forKey: "airVisionEnabled")) }
    static var excludeMessages: Bool { (UserDefaults.standard.object(forKey: "airVisionExcludeMessages") == nil || UserDefaults.standard.bool(forKey: "airVisionExcludeMessages")) }
    static var excludedNames: [String] {
        let custom = UserDefaults.standard.string(forKey: "airVisionExcluded") ?? defaultExcluded.joined(separator: ", ")
        var names = custom.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if excludeMessages { names.append("Messages") }
        return names
    }

    static func isExcluded(name: String?, bundleID: String?) -> Bool {
        let n = (name ?? "").lowercased()
        let b = (bundleID ?? "").lowercased()
        if b.contains("password") || b.contains("keychain") || b.contains("1password") || b.contains("bitwarden") { return true }
        return excludedNames.contains { !$0.isEmpty && n == $0.lowercased() }
    }

    struct Front { let pid: pid_t; let app: String; let title: String; let windowID: CGWindowID }

    /// The app the owner was last using other than Air (talking to Air often makes Air frontmost).
    private static var lastOther: NSRunningApplication?
    private static var observer: NSObjectProtocol?

    /// Call once at launch so "this window" means the app the owner was in before Air.
    static func startTracking() {
        guard observer == nil else { return }
        let mine = getpid()
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != mine { lastOther = f }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != mine else { return }
            MainActor.assumeIsolated { lastOther = app }
        }
    }

    /// The app "this window" refers to: the frontmost app, or the last app used before Air.
    static func targetApp() -> NSRunningApplication? {
        let mine = getpid()
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != mine { return f }
        if let l = lastOther, !l.isTerminated { return l }
        return nil
    }

    /// The front normal window of the target app (or, failing that, the topmost window that isn't Air).
    static func frontWindow() -> Front? {
        let mine = getpid()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let target = targetApp()
        var fallback: Front?
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != mine,
                  let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            let b = w[kCGWindowBounds as String] as? [String: Any]
            if ((b?["Width"] as? Double) ?? 0) < 120 || ((b?["Height"] as? Double) ?? 0) < 80 { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            let f = Front(pid: pid, app: app?.localizedName ?? (w[kCGWindowOwnerName as String] as? String ?? ""),
                          title: w[kCGWindowName as String] as? String ?? "", windowID: id)
            if let target, pid == target.processIdentifier { return f }
            if fallback == nil { fallback = f }
        }
        // The target app has no visible window: still name it, so an excluded app is refused.
        if let target { return Front(pid: target.processIdentifier, app: target.localizedName ?? "", title: "", windowID: 0) }
        return fallback
    }

    static func capture(scope: String) async -> [String: Any] {
        guard enabled else { return ["ok": false, "error": "Screen vision is turned off in Settings, Privacy."] }
        if scope == "window", let f = frontWindow(),
           isExcluded(name: f.app, bundleID: NSRunningApplication(processIdentifier: f.pid)?.bundleIdentifier) {
            return ["ok": false, "refused": true,
                    "error": "That window belongs to \(f.app), which is on your excluded list, so I won't look at it."]
        }
        if !CGPreflightScreenCaptureAccess() {
            // Ask macOS only once; after that, explain where to turn it on (no repeated system prompts).
            if !UserDefaults.standard.bool(forKey: "airScreenRequested") {
                UserDefaults.standard.set(true, forKey: "airScreenRequested")
                CGRequestScreenCaptureAccess()
                return ["ok": false, "permission": "Screen Recording",
                        "error": "I've asked macOS for Screen Recording permission. Please allow Air in the dialog, then ask me again."]
            }
            return ["ok": false, "permission": "Screen Recording",
                    "error": "Air doesn't have Screen Recording permission. Turn it on in System Settings, Privacy & Security, Screen & System Audio Recording, Air; then ask me again."]
        }
        let front = frontWindow()
        let frontApp = front.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let filter: SCContentFilter
            var w = 1280.0, h = 800.0
            if scope == "window" {
                guard let front, let win = content.windows.first(where: { $0.windowID == front.windowID }) else {
                    return ["ok": false, "error": "I couldn't find the front window."]
                }
                if isExcluded(name: front.app, bundleID: frontApp?.bundleIdentifier) {
                    return ["ok": false, "refused": true,
                            "error": "That window belongs to \(front.app), which is on your excluded list, so I won't look at it."]
                }
                filter = SCContentFilter(desktopIndependentWindow: win)
                w = win.frame.width; h = win.frame.height
            } else {
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                    return ["ok": false, "error": "No display found."]
                }
                let hidden = content.applications.filter {
                    $0.processID == getpid() || isExcluded(name: $0.applicationName, bundleID: $0.bundleIdentifier)
                }
                filter = SCContentFilter(display: display, excludingApplications: hidden, exceptingWindows: [])
                w = Double(display.width); h = Double(display.height)
            }
            let cfg = SCStreamConfiguration()
            // At most 1280 px on the long edge (enough for the model, keeps memory and time low).
            let long = max(w, h, 1)
            let target = min(1280.0, long * 2)
            cfg.width = max(1, Int(w / long * target))
            cfg.height = max(1, Int(h / long * target))
            cfg.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let path = try writePNG(image)
            let excludedFront = scope != "window" && isExcluded(name: front?.app, bundleID: frontApp?.bundleIdentifier)
            return ["ok": true, "path": path, "source": scope,
                    "app": excludedFront ? "" : (front?.app ?? ""), "window": excludedFront ? "" : (front?.title ?? ""),
                    "ocr": ocr(image)]
        } catch {
            return ["ok": false, "error": "The screen capture failed: \(error.localizedDescription)"]
        }
    }

    static func image(source: String, path: String) async -> [String: Any] {
        guard enabled else { return ["ok": false, "error": "Image vision is turned off in Settings, Privacy."] }
        var cg: CGImage?
        var label = source
        switch source {
        case "clipboard":
            guard let img = NSImage(pasteboard: .general) else { return ["ok": false, "error": "There's no image on the clipboard."] }
            cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
            label = "clipboard image"
        case "finder":
            let script = "tell application \"Finder\" to get POSIX path of (item 1 of (get selection) as alias)"
            var err: NSDictionary?
            let out = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue
            guard let p = out else { return ["ok": false, "error": "I couldn't read the Finder selection. Select an image in Finder (Air may need Automation permission for Finder)."] }
            return await image(source: "file", path: p)
        default:
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let img = NSImage(contentsOf: url) else { return ["ok": false, "error": "I couldn't open that image file."] }
            cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
            label = url.lastPathComponent
        }
        guard let cg else { return ["ok": false, "error": "That image couldn't be read."] }
        do {
            let scaled = downscale(cg, maxEdge: 1280)
            return ["ok": true, "path": try writePNG(scaled), "source": label, "app": "", "window": label, "ocr": ocr(scaled)]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    /// Delete the temporary capture, or move it to Air Exports if the owner asked to save it.
    static func discard(path: String, save: Bool) -> [String: Any] {
        let src = URL(fileURLWithPath: path)
        guard src.path.hasPrefix(NSTemporaryDirectory()) || src.path.contains("/air-look-") else { return ["ok": false] }
        if save {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Air Exports")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
            var dst = dir.appendingPathComponent("Screenshot \(stamp).png")
            var n = 2
            while FileManager.default.fileExists(atPath: dst.path) {
                dst = dir.appendingPathComponent("Screenshot \(stamp) (\(n)).png"); n += 1
            }
            if (try? FileManager.default.moveItem(at: src, to: dst)) != nil { return ["ok": true, "saved": dst.path] }
        }
        try? FileManager.default.removeItem(at: src)
        return ["ok": true]
    }

    // MARK: helpers

    static func writePNG(_ image: CGImage) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("air-look-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Air", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't write the image."])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Air", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't write the image."])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
    }

    private static func downscale(_ img: CGImage, maxEdge: Int) -> CGImage {
        let w = img.width, h = img.height
        let s = min(1.0, Double(maxEdge) / Double(max(w, h)))
        guard s < 1, let ctx = CGContext(data: nil, width: Int(Double(w) * s), height: Int(Double(h) * s), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        return ctx.makeImage() ?? img
    }

    /// Apple Vision text recognition, on this Mac, as extra context for small text.
    nonisolated static func ocr(_ img: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: img).perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: "\n").prefix(2000))
    }
}
