import AppKit
import SwiftUI

/// Air's three colour themes (Settings › Appearance). Each one tints the controls, the orb and the
/// logo, and swaps the Dock icon while Air runs.
enum AirTheme: String, CaseIterable, Identifiable {
    case aurora, ember, lagoon
    var id: String { rawValue }

    var name: String {
        switch self {
        case .aurora: return "Aurora"
        case .ember: return "Ember"
        case .lagoon: return "Lagoon"
        }
    }
    var blurb: String {
        switch self {
        case .aurora: return "Cyan, violet and pink. The original."
        case .ember: return "Warm coral, amber and rose."
        case .lagoon: return "Calm green, teal and sky blue."
        }
    }
    /// Gradient stops, top-left to bottom-right (sRGB).
    var stops: [(Double, Double, Double)] {
        switch self {
        case .aurora: return [(0.22, 0.74, 0.97), (0.49, 0.36, 1.00), (0.96, 0.45, 0.71)]
        case .ember: return [(1.00, 0.72, 0.28), (0.98, 0.42, 0.33), (0.86, 0.25, 0.52)]
        case .lagoon: return [(0.38, 0.88, 0.55), (0.10, 0.70, 0.70), (0.20, 0.50, 0.95)]
        }
    }
    var colors: [Color] { stops.map { Color(.sRGB, red: $0.0, green: $0.1, blue: $0.2) } }
    var nsColors: [NSColor] { stops.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) } }
    /// The control tint: the middle stop, readable on light and dark backgrounds.
    var accent: Color { colors[1] }

    static var current: AirTheme { AirTheme(rawValue: UserDefaults.standard.string(forKey: "airTheme") ?? "") ?? .aurora }
}

private struct AirThemeKey: EnvironmentKey {
    static let defaultValue: AirTheme = .aurora
}

private struct AmoledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var airTheme: AirTheme {
        get { self[AirThemeKey.self] }
        set { self[AirThemeKey.self] = newValue }
    }
    /// AMOLED: pure black backgrounds, no vibrancy (Settings › Appearance › Background).
    var amoled: Bool {
        get { self[AmoledKey.self] }
        set { self[AmoledKey.self] = newValue }
    }
}

/// Applies the chosen theme to a window's views: the environment value plus the control tint.
struct Themed: ViewModifier {
    @AppStorage("airTheme") private var themeID = AirTheme.aurora.rawValue
    @AppStorage("airBackground") private var background = "theme"
    func body(content: Content) -> some View {
        let theme = AirTheme(rawValue: themeID) ?? .aurora
        let amoled = background == "amoled"
        content
            .environment(\.airTheme, theme)
            .environment(\.amoled, amoled)
            .tint(theme.accent)
            .background(amoled ? Color.black : Color.clear)
            .toolbarBackground(amoled ? AnyShapeStyle(Color.black) : AnyShapeStyle(.bar), for: .windowToolbar)
            .preferredColorScheme(amoled ? .dark : nil)
            .onChange(of: themeID) { _, _ in IconArt.applyDockIcon() }
            .onChange(of: background) { _, _ in AppearanceMode.apply() }
    }
}

extension View {
    /// Sidebars and lists: pure black, no vibrancy, under AMOLED.
    func amoledList() -> some View { modifier(AmoledList()) }
    /// Panels and cards: near-black under AMOLED instead of the system grey.
    func panelBackground<S: Shape>(in shape: S) -> some View { modifier(PanelBackground(shape: shape)) }
}

struct AmoledList: ViewModifier {
    @Environment(\.amoled) private var amoled
    func body(content: Content) -> some View {
        if amoled { content.scrollContentBackground(.hidden).background(Color.black) } else { content }
    }
}

struct PanelBackground<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.amoled) private var amoled
    func body(content: Content) -> some View {
        if amoled { content.background(Color(white: 0.055), in: shape) } else { content.background(.background.secondary, in: shape) }
    }
}

extension View {
    func airThemed() -> some View { modifier(Themed()) }
}

/// Light/dark: follow the system, or force one (Settings › Appearance).
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    @MainActor static func apply() {
        // The -AirAppearance launch argument (screenshots) wins over the saved choice.
        let forced = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["AirAppearance"] as? String
        let amoled = UserDefaults.standard.string(forKey: "airBackground") == "amoled"
        for w in NSApp.windows where !(w is NSPanel) { w.backgroundColor = amoled ? .black : .windowBackgroundColor }
        if amoled && forced == nil { NSApp.appearance = NSAppearance(named: .darkAqua); return }
        switch forced ?? UserDefaults.standard.string(forKey: "airAppearanceMode") ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

/// The Air logo: a glassy rounded square in the theme's gradient with a bold breeze mark. Drawn in
/// code, so the app icon (make_icon) and the in-app logo are the same artwork.
enum IconArt {
    static func draw(theme: AirTheme, size: CGFloat, inset fullBleed: Bool = false) {
        let s = size / 1024
        let inset: CGFloat = fullBleed ? 0 : 100 * s
        let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let radius = (fullBleed ? 230 : 185) * s
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let ctx = NSGraphicsContext.current!

        if !fullBleed {
            ctx.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 28 * s
            shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
            shadow.set()
            NSColor.white.setFill()
            shape.fill()
            ctx.restoreGraphicsState()
        }
        NSGradient(colors: theme.nsColors)!.draw(in: shape, angle: -55)

        ctx.saveGraphicsState()
        shape.addClip()
        // Glass: a soft light from the top left and a gentle shade at the bottom.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.42), NSColor.white.withAlphaComponent(0)])!
            .draw(fromCenter: NSPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY - rect.height * 0.12), radius: 0,
                  toCenter: NSPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY - rect.height * 0.12),
                  radius: rect.width * 0.75, options: [])
        NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.16)])!
            .draw(in: rect, angle: -90)

        // The mark: three flowing breeze strokes, large and centred.
        let w = rect.width, h = rect.height
        let strokes: [(y: CGFloat, amp: CGFloat, width: CGFloat, from: CGFloat, to: CGFloat, alpha: CGFloat, phase: CGFloat)] = [
            (0.66, 0.060, 0.085, 0.14, 0.86, 1.00, 0.0),
            (0.47, 0.070, 0.070, 0.10, 0.80, 0.88, 0.9),
            (0.30, 0.050, 0.055, 0.22, 0.90, 0.72, 1.8),
        ]
        for st in strokes {
            let path = NSBezierPath()
            let steps = 80
            for i in 0...steps {
                let u = CGFloat(i) / CGFloat(steps)
                let x = rect.minX + w * (st.from + (st.to - st.from) * u)
                let y = rect.minY + h * st.y + h * st.amp * sin(u * 2 * .pi * 1.05 + st.phase)
                if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
            }
            path.lineWidth = w * st.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            ctx.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            glow.shadowBlurRadius = 18 * s
            glow.shadowOffset = NSSize(width: 0, height: -6 * s)
            glow.set()
            NSColor.white.withAlphaComponent(st.alpha).setStroke()
            path.stroke()
            ctx.restoreGraphicsState()
        }
        ctx.restoreGraphicsState()
        // A thin bright rim for the glass edge.
        NSColor.white.withAlphaComponent(0.35).setStroke()
        shape.lineWidth = 3 * s
        shape.stroke()
    }

    static func image(theme: AirTheme, size: CGFloat, fullBleed: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            draw(theme: theme, size: size, inset: fullBleed)
            return true
        }
    }

    static func png(theme: AirTheme, size: Int) -> Data? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(theme: theme, size: CGFloat(size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// The bundle icon is Aurora; other themes show their own icon in the Dock while Air runs.
    @MainActor static func applyDockIcon() {
        let t = AirTheme.current
        NSApp.applicationIconImage = t == .aurora ? nil : image(theme: t, size: 512)
    }
}

/// The logo as a SwiftUI view.
struct AirLogo: View {
    var size: CGFloat = 96
    @Environment(\.airTheme) private var theme
    var body: some View {
        Image(nsImage: IconArt.image(theme: theme, size: size * 2))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("Air")
    }
}
