import AppKit
import ScreenCaptureKit

/// Live Screen: while on, every ~2.5 s it checks whether the front window changed (a tiny grayscale
/// thumbnail diff) and, only then, captures it and reads its text with Apple OCR on this Mac. The
/// engine gets a compact "what's on screen now" (app, window title, text) for the conversation; no
/// vision model is loaded unless asked. Excluded apps are never captured. Frames stay in memory only.
@MainActor
final class ScreenWatch: ObservableObject {
    static let shared = ScreenWatch()
    @Published private(set) var watching = false
    @Published private(set) var current: (app: String, title: String)?
    /// "On request" (default), "Always aware" (whenever a conversation is live) or "Off".
    static var mode: String { UserDefaults.standard.string(forKey: "airScreenAwareness") ?? "request" }

    var send: (([String: Any]) -> Void)?
    private var timer: Timer?
    private var lastThumb: [UInt8] = []
    private var lastChange = Date()
    private var busy = false
    private(set) var latestFrame: CGImage?

    func start() -> [String: Any] {
        guard Self.mode != "off" else { return ["ok": false, "error": "Screen awareness is off in Settings, Privacy."] }
        guard ScreenLook.enabled else { return ["ok": false, "error": "Screen vision is turned off in Settings, Privacy."] }
        guard CGPreflightScreenCaptureAccess() else {
            return ["ok": false, "permission": "Screen Recording",
                    "error": "Air doesn't have Screen Recording permission. Turn it on in System Settings, Privacy & Security, Screen & System Audio Recording, Air."]
        }
        if !watching {
            watching = true
            lastThumb = []
            lastChange = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.tick() }
            }
            Task { await tick() }
        }
        return ["ok": true, "summary": "Watching the screen (text only, on this Mac)"]
    }

    func stop() -> [String: Any] {
        timer?.invalidate(); timer = nil
        watching = false
        current = nil
        latestFrame = nil
        lastThumb = []
        send?(["type": "screen_context", "active": false])
        return ["ok": true, "summary": "Stopped watching the screen"]
    }

    private func tick() async {
        guard watching, !busy else { return }
        // Auto-pause after 10 minutes without any change.
        if Date().timeIntervalSince(lastChange) > 600 { _ = stop(); return }
        guard let front = ScreenLook.frontWindow(), front.windowID != 0 else { return }
        let app = NSRunningApplication(processIdentifier: front.pid)
        if ScreenLook.isExcluded(name: front.app, bundleID: app?.bundleIdentifier) {
            if current?.app != front.app {
                current = (front.app, "")
                send?(["type": "screen_context", "active": true, "app": front.app, "window": "", "text": "",
                       "excluded": true])
            }
            return
        }
        busy = true
        defer { busy = false }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let win = content.windows.first(where: { $0.windowID == front.windowID }) else { return }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        // 1) A tiny grayscale thumbnail: has anything changed?
        let small = SCStreamConfiguration()
        small.width = 48; small.height = 30; small.showsCursor = false
        guard let thumb = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: small) else { return }
        let px = Self.gray(thumb)
        let changed = lastThumb.count != px.count || zip(lastThumb, px).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } > px.count * 3
        if !changed && current?.title == front.title { return }
        lastThumb = px
        lastChange = Date()
        // 2) Changed: capture at reading size and OCR it, on this Mac.
        let cfg = SCStreamConfiguration()
        let long = max(win.frame.width, win.frame.height, 1)
        cfg.width = Int(win.frame.width / long * 1280); cfg.height = Int(win.frame.height / long * 1280)
        cfg.showsCursor = false
        guard let frame = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return }
        latestFrame = frame
        let text = await Task.detached { ScreenLook.ocr(frame) }.value
        current = (front.app, front.title)
        send?(["type": "screen_context", "active": true, "app": front.app, "window": front.title,
               "text": String(text.prefix(1500))])
    }

    /// The latest watched frame as a temporary file, for a vision question ("what's in this chart?").
    func latestFramePath() -> String? {
        guard let f = latestFrame else { return nil }
        return try? ScreenLook.writePNG(f)
    }

    private static func gray(_ img: CGImage) -> [UInt8] {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }
}
