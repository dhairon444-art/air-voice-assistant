import AppKit
import Combine
import SceneKit
import SwiftUI
import os

/// The orb: a sphere of tens of thousands of small glowing dots ("Nebula": cyan and blue at the top,
/// through purple and magenta, to red and orange at the bottom), brighter at the rim.
/// - Speaking: the surface pushes outward with Aria's voice; eight frequency bands act as soft,
///   overlapping lobes around the sphere (no seams).
/// - Listening: concentric ripples travel inward from the rim with your voice; a breathing pulse between words.
/// - Thinking: neural-like streams flow through and around the inside, with synapse sparks and a hue drift.
/// - Checking online: the dots stream off into a bright moon on a tilted orbit, revealing a darker flowing
///   core that the moon lights as it passes; they stream back when done.
/// - Muted: desaturated, still and dim.
/// Smooth by design: every value moves on a time-based critically damped spring, updated once per frame on
/// SceneKit's render loop (display-synced). 60 fps while idle or listening, 30 fps while the model generates;
/// paused when hidden; a still frame under Reduce Motion.
struct Orb3DView: NSViewRepresentable {
    let state: TalkState
    /// Not observed by SwiftUI: the scene subscribes to it directly, so audio ticks don't re-run views.
    let meter: AudioMeter
    var muted = false
    /// The highest frame rate (the orb drops to 30 while the model generates).
    var fps = 60
    /// The tiny Island orb uses fewer dots and no core.
    var tiny = false
    /// False holds a still frame (the Island does this while the main window, with its own orb, is visible).
    var animate = true
    @Environment(\.airTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("airOrbSensitivity") private var sensitivity = 1.0
    @AppStorage("airOrbDensity") private var density = "medium"
    @AppStorage("airOrbGlow") private var glow = 0.6
    @AppStorage("airOrbPalette") private var palette = "nebula"
    @AppStorage("airOrbShadow") private var shadowOn = true
    @AppStorage("airOrbShadowIntensity") private var shadowIntensity = 0.6
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> OrbScene { OrbScene() }

    func makeNSView(context: Context) -> SCNView {
        let v = OccludableSCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        v.scene = context.coordinator.scene
        if !UserDefaults.standard.bool(forKey: "AirOrbNoDelegate") { v.delegate = context.coordinator.animator }
        v.backgroundColor = .clear
        v.allowsCameraControl = false
        v.antialiasingMode = .none
        v.preferredFramesPerSecond = fps
        v.isJitteringEnabled = false
        v.setAccessibilityElement(false)
        v.showsStatistics = UserDefaults.standard.bool(forKey: "AirOrbStats")  // diagnostics only
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        // Full frame rate while idle or listening; 30 while tokens are generated (keeps the GPU for the model).
        let generating = state == .thinking || state == .speaking || state == .checking || state == .working
        let want = UserDefaults.standard.integer(forKey: "airOrbFPS") > 0 ? UserDefaults.standard.integer(forKey: "airOrbFPS")
            : (generating ? min(30, fps) : fps)
        if v.preferredFramesPerSecond != want { v.preferredFramesPerSecond = want }
        if let o = v as? OccludableSCNView { o.motion = animate && !reduceMotion }
        let count = tiny ? 1200 : (density == "low" ? 12_000 : density == "high" ? 40_000 : 24_000)
        context.coordinator.build(count: count, tiny: tiny)
        context.coordinator.setShadow(on: shadowOn && !tiny, intensity: shadowIntensity, light: scheme == .light)
        context.coordinator.configure(meter: meter, state: state, muted: muted, sensitivity: sensitivity, glow: glow,
                                      palette: palette == "theme" ? theme : nil, still: reduceMotion, live: animate)
    }
}

/// Pauses rendering whenever its window is hidden, minimised or fully covered.
final class OccludableSCNView: SCNView {
    var motion = true { didSet { if motion != oldValue { refresh() } } }
    private var token: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let token { NotificationCenter.default.removeObserver(token); self.token = nil }
        guard let w = window else {
            isPlaying = false
            rendersContinuously = false
            return
        }
        token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w,
                                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        let on = motion && (window?.occlusionState.contains(.visible) ?? false)
        if isPlaying != on { isPlaying = on }
        if rendersContinuously != on { rendersContinuously = on }
    }
}

/// Runs on SceneKit's render loop, once per displayed frame: springs every value toward its latest
/// target with the real frame time (dt), then writes the shader arguments. Targets come from the main
/// thread under a lock, so audio arriving ~16 times a second still animates smoothly at 60 fps.
final class OrbAnimator: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    struct Targets {
        var level = 0.0, loud = 0.0
        var bands = [Double](repeating: 0, count: 8)
        var listen = 0.0, think = 0.0, check = 0.0
        var muted = 0.0, motion = 1.0, glow = 0.6, light = 0.0
        var moonSpeed = 1.2
    }
    private var lock = os_unfair_lock()
    private var targets = Targets()
    private var cur = Targets()
    private var vel = Targets()
    private var last: TimeInterval = 0
    let materials: [SCNMaterial]

    init(materials: [SCNMaterial]) { self.materials = materials }
    static let noWrites = UserDefaults.standard.bool(forKey: "AirOrbNoWrites")  // diagnostics

    func set(_ t: Targets) {
        os_unfair_lock_lock(&lock); targets = t; os_unfair_lock_unlock(&lock)
    }

    /// Critically damped spring: no overshoot, no jumps. omega sets how fast (rad/s).
    private func spring(_ x: inout Double, _ v: inout Double, _ target: Double, _ omega: Double, _ dt: Double) {
        let a = omega * omega * (target - x) - 2 * omega * v
        v += a * dt
        x += v * dt
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = last == 0 ? 1.0 / 60 : min(0.1, max(0.001, time - last))
        last = time
        os_unfair_lock_lock(&lock); let t = targets; os_unfair_lock_unlock(&lock)
        // Fast for audio (feels live), slower for states (cross-fades of about 0.6 s).
        let audio = 16.0, states = 7.5
        spring(&cur.level, &vel.level, t.level, audio, dt)
        spring(&cur.loud, &vel.loud, t.loud, 9, dt)
        for i in 0..<8 { spring(&cur.bands[i], &vel.bands[i], t.bands[i], audio, dt) }
        spring(&cur.listen, &vel.listen, t.listen, states, dt)
        spring(&cur.think, &vel.think, t.think, states, dt)
        spring(&cur.check, &vel.check, t.check, 6.0, dt)
        spring(&cur.muted, &vel.muted, t.muted, states, dt)
        spring(&cur.glow, &vel.glow, t.glow, states, dt)
        cur.motion = t.motion; cur.light = t.light; cur.moonSpeed = t.moonSpeed
        let b = cur.bands.map { max(0, $0) }
        let vals: [(String, SCNVector4)] = [
            ("b0", SCNVector4(b[0], b[1], b[2], b[3])), ("b1", SCNVector4(b[4], b[5], b[6], b[7])),
            ("s0", SCNVector4(max(0, cur.level), max(0, cur.loud), 0, 0)),
            ("s1", SCNVector4(min(1, max(0, cur.muted)), cur.motion, cur.glow, cur.light)),
            ("m0", SCNVector4(min(1, max(0, cur.listen)), min(1, max(0, cur.think)), min(1, max(0, cur.check)), cur.moonSpeed)),
        ]
        if Self.noWrites { return }
        for m in materials { for (k, v) in vals { m.setValue(v, forKey: k) } }
    }
}

@MainActor
final class OrbScene {
    let scene = SCNScene()
    private let holder = SCNNode()
    private var dots: SCNNode?
    private let material = SCNMaterial()
    private let coreMaterial = SCNMaterial()
    private let core = SCNNode()
    lazy var animator = OrbAnimator(materials: [material, coreMaterial])
    private var built = (count: 0, tiny: false)
    private var lastPalette: [SIMD3<Double>] = []
    private var coreHideWork: DispatchWorkItem?
    private var sub: AnyCancellable?
    private weak var meter: AudioMeter?
    private let halo = SCNNode()
    private var shadowCfg = (on: true, intensity: 0.6, light: false)
    private var cfg: (state: TalkState, muted: Bool, sensitivity: Double, glow: Double, palette: AirTheme?, still: Bool) =
        (.idle, false, 1, 0.6, nil, false)

    static let nebula: [SIMD3<Double>] = [[0.25, 0.85, 1.0], [0.30, 0.45, 1.0], [0.58, 0.28, 0.98], [0.92, 0.25, 0.62], [1.0, 0.48, 0.18]]

    init() {
        scene.background.contents = NSColor.clear
        scene.rootNode.addChildNode(holder)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 30
        cam.position = SCNVector3(0, 0, 6.2)
        scene.rootNode.addChildNode(cam)

        material.lightingModel = .constant
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        material.isDoubleSided = true
        material.diffuse.contents = Self.dotImage()
        material.shaderModifiers = [.geometry: Self.geometry]

        // The core (revealed while checking online): a smooth sphere, hidden at scale 0 otherwise.
        coreMaterial.lightingModel = .constant
        coreMaterial.blendMode = .alpha
        coreMaterial.isDoubleSided = false
        coreMaterial.shaderModifiers = [.geometry: Self.coreGeometry]
        let coreGeo = Self.uvSphere(rings: 40, segments: 64)
        coreGeo.firstMaterial = coreMaterial
        core.geometry = coreGeo
        core.renderingOrder = -1
        core.isHidden = true
        holder.addChildNode(core)
        holder.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 48)), forKey: "spin")

        // Backdrop glow: a soft halo behind the orb, centred, in its own colours.
        let plane = SCNPlane(width: 3.1, height: 3.1)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = Self.softDisc()
        m.transparencyMode = .aOne
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
        m.isDoubleSided = true
        plane.firstMaterial = m
        halo.geometry = plane
        halo.position = SCNVector3(0, 0, -1.2)
        halo.renderingOrder = -10
        scene.rootNode.addChildNode(halo)
    }

    /// State and settings from SwiftUI; audio comes straight from the meter.
    func configure(meter: AudioMeter, state: TalkState, muted: Bool, sensitivity: Double, glow: Double,
                   palette: AirTheme?, still: Bool, live: Bool = true) {
        cfg = (state, muted, sensitivity, glow, palette, still)
        if live && !still {
            if self.meter !== meter || sub == nil {
                self.meter = meter
                sub = meter.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.push() }
            }
        } else {
            sub = nil
            self.meter = meter
        }
        push()
    }

    /// Hand the animator new targets (cheap; the render loop does the smoothing and shader writes).
    private func push() {
        let m = meter
        let state = cfg.state, still = cfg.still
        let mutedNow = cfg.muted && (state == .listening || state == .hearing)
        let raw = mutedNow ? 0 : (state == .speaking ? (m?.out ?? 0) : (state == .listening || state == .hearing ? (m?.mic ?? 0) : 0))
        var t = OrbAnimator.Targets()
        t.level = still ? 0 : min(1, raw * 5 * cfg.sensitivity)
        let b = m?.bands ?? []
        t.bands = (0..<8).map { i in (mutedNow || still || b.count != 8) ? 0 : min(1.5, b[i] * cfg.sensitivity) }
        t.loud = max(t.level, t.bands.reduce(0, +) / 8)
        t.listen = state == .listening || state == .hearing ? 1 : 0
        t.think = state == .thinking ? 1 : 0
        t.check = state == .checking || state == .working ? 1 : 0
        // The core costs a draw every frame: show it only around the checking state (it eases out over ~1 s).
        if t.check > 0 { coreHideWork?.cancel(); core.isHidden = built.tiny } else if !core.isHidden && coreHideWork == nil {
            let w = DispatchWorkItem { [weak self] in self?.core.isHidden = true; self?.coreHideWork = nil }
            coreHideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
        }
        t.muted = mutedNow ? 1 : 0
        t.motion = still ? 0 : 1
        t.glow = cfg.glow
        t.light = shadowCfg.light ? 1 : 0
        animator.set(t)

        let pal: [SIMD3<Double>]
        if let th = cfg.palette {
            let c = th.nsColors.map { $0.usingColorSpace(.sRGB) ?? $0 }.map { SIMD3(Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)) }
            pal = [c[0], (c[0] + c[1]) / 2, c[1], (c[1] + c[2]) / 2, c[2]]
        } else {
            pal = Self.nebula
        }
        if pal != lastPalette {
            lastPalette = pal
            for mat in [material, coreMaterial] {
                for (i, c) in pal.enumerated() { mat.setValue(SCNVector3(c.x, c.y, c.z), forKey: "p\(i)") }
            }
        }
        if shadowCfg.on {
            let k = shadowCfg.intensity * (mutedNow ? 0.35 : 1)
            let c = (pal[1] + pal[2] + pal[3]) / 3
            halo.geometry?.firstMaterial?.multiply.contents = NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
            halo.opacity = (shadowCfg.light ? 0.22 : 0.18 + 0.12 * t.loud) * k
        }
        if mutedNow || still { holder.removeAction(forKey: "spin") } else if holder.action(forKey: "spin") == nil {
            holder.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 48)), forKey: "spin")
        }
    }

    func setShadow(on: Bool, intensity: Double, light: Bool) {
        shadowCfg = (on, intensity, light)
        halo.isHidden = !on
        halo.geometry?.firstMaterial?.blendMode = light ? .alpha : .add
        material.blendMode = light ? .alpha : .add
    }

    /// A Fibonacci sphere; each dot gets a random seed (texcoord) for its own jitter and brightness.
    func build(count: Int, tiny: Bool) {
        guard built.count != count || built.tiny != tiny else { return }
        built = (count, tiny)
        dots?.removeFromParentNode()
        var pos = [SCNVector3](), seed = [CGPoint]()
        pos.reserveCapacity(count); seed.reserveCapacity(count)
        let golden = Double.pi * (3 - sqrt(5))
        for i in 0..<count {
            let y = 1 - (Double(i) + 0.5) / Double(count) * 2
            let r = sqrt(max(0, 1 - y * y)), th = golden * Double(i)
            pos.append(SCNVector3(cos(th) * r, y, sin(th) * r))
            seed.append(CGPoint(x: Double.random(in: 0...1), y: Double.random(in: 0...1)))
        }
        let el = SCNGeometryElement(indices: (0..<UInt32(count)).map { $0 }, primitiveType: .point)
        el.pointSize = 2.0
        el.minimumPointScreenSpaceRadius = tiny ? 0.8 : 0.9
        el.maximumPointScreenSpaceRadius = tiny ? 1.8 : 2.4
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: pos),
                                      SCNGeometrySource(textureCoordinates: seed), Self.whiteColors(count)], elements: [el])
        g.firstMaterial = material
        let n = SCNNode(geometry: g)
        holder.addChildNode(n)
        dots = n
    }

    static func uvSphere(rings: Int, segments: Int) -> SCNGeometry {
        var pos = [SCNVector3](), idx = [UInt32]()
        for r in 0...rings {
            let v = Double(r) / Double(rings), phi = v * .pi
            for sgm in 0...segments {
                let u = Double(sgm) / Double(segments), th = u * 2 * .pi
                pos.append(SCNVector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th)))
            }
        }
        let w = UInt32(segments + 1)
        for r in 0..<UInt32(rings) { for sgm in 0..<UInt32(segments) {
            let a = r * w + sgm, b = a + w
            idx += [a, b, a + 1, a + 1, b, b + 1]
        } }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: pos), whiteColors(pos.count)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    static func whiteColors(_ n: Int) -> SCNGeometrySource {
        let data = [Float](repeating: 1, count: n * 3).withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data, semantic: .color, vectorCount: n, usesFloatComponents: true,
                                 componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
    }

    static func softDisc() -> CGImage {
        let n = 256
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.45), CGColor(gray: 1, alpha: 0.12), CGColor(gray: 1, alpha: 0)]
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors as CFArray, locations: [0, 0.3, 0.65, 1])!
        let c = CGPoint(x: n / 2, y: n / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(n) / 2, options: [])
        return ctx.makeImage()!
    }

    /// A soft round dot for the point sprites (premultiplied; additive blending turns overlaps into glow).
    static func dotImage() -> CGImage {
        let n = 64
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.6), CGColor(gray: 1, alpha: 0)]
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors as CFArray, locations: [0, 0.35, 1])!
        let c = CGPoint(x: n / 2, y: n / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(n) / 2, options: [])
        return ctx.makeImage()!
    }

    static let geometry = """
    #pragma arguments
    float3 p0;
    float3 p1;
    float3 p2;
    float3 p3;
    float3 p4;
    float4 b0;
    float4 b1;
    float4 s0;
    float4 s1;
    float4 m0;
    #pragma body
    float level = s0.x;
    float loud = s0.y;
    float muted = s1.x;
    float motion = s1.y;
    float glow = s1.z;
    float lightMode = s1.w;
    float lm = m0.x;   // listening
    float tm = m0.y;   // thinking
    float cm = m0.z;   // checking online (moon + core)
    float t = scn_frame.time * motion;
    float3 p = normalize(_geometry.position.xyz);
    float2 sd = _geometry.texcoords[0];
    // THINKING: particles flow along curling paths around shifting axes (neural streams).
    float3 ax = normalize(float3(sin(p.y * 3.1 + t * 0.9), cos(p.z * 2.7 - t * 0.7), sin(p.x * 2.9 + t * 0.5)) + float3(0.001));
    float ang = tm * 1.1 * sin(t * 0.8 + dot(p, float3(1.7, 2.3, 1.1)));
    float cs = cos(ang), sn = sin(ang);
    p = p * cs + cross(ax, p) * sn + ax * dot(ax, p) * (1.0 - cs);
    // Frequency bands as eight soft, overlapping lobes around the sphere (slowly turning): no seam anywhere.
    float bands[8] = { b0.x, b0.y, b0.z, b0.w, b1.x, b1.y, b1.z, b1.w };
    float3 dirs[8] = { float3(0.58, 0.58, 0.58), float3(-0.58, 0.58, -0.58), float3(0.58, -0.58, -0.58), float3(-0.58, -0.58, 0.58),
                       float3(0.0, 1.0, 0.0), float3(0.0, -1.0, 0.0), float3(0.94, 0.0, -0.34), float3(-0.94, 0.0, 0.34) };
    float tr = t * 0.05;
    float3 pr = float3(p.x * cos(tr) - p.z * sin(tr), p.y, p.x * sin(tr) + p.z * cos(tr));
    float wsum = 0.0, e = 0.0;
    for (int k = 0; k < 8; k++) {
        float w = exp(3.0 * (dot(pr, dirs[k]) - 1.0));
        wsum += w;
        e += w * bands[k];
    }
    e /= max(wsum, 0.0001);
    float lat = p.y * 0.5 + 0.5;
    float n = 0.5 * sin(dot(p, float3(0.62, 0.48, -0.62)) * 4.3 + t * 0.9)
            + 0.3 * sin(dot(p, float3(-0.27, 0.86, 0.43)) * 5.1 - t * 0.7)
            + 0.2 * sin(dot(p, float3(0.75, -0.31, 0.58)) * 6.7 + t * 0.5);
    float n2 = sin(dot(p, float3(0.41, 0.73, 0.55)) * 13.0 - t * 2.3) * sin(dot(p, float3(-0.66, 0.2, 0.72)) * 11.0 + t * 1.9);
    float jitter = (sd.x - 0.5) * (0.035 + 0.12 * level) * (1.0 - muted);
    float breathe = 0.02 * sin(t * 1.1) * (1.0 - muted);
    // SPEAKING (default): the surface pushes outward with the voice and its frequency bands.
    float outward = (0.03 + 0.14 * level) * n + 0.05 * level * n2 + e * 0.22;
    // LISTENING: concentric ripples travelling inward from the rim, pulled in by the mic; a soft
    // breathing pulse between words.
    float3 vd = (scn_node.modelViewTransform * float4(p, 0.0)).xyz;
    float r = length(vd.xy);
    float ripple = 0.5 + 0.5 * sin(r * 14.0 + t * 6.0);
    float inward = -(0.045 + 0.22 * level) * ripple + 0.03 * sin(t * 2.2) * (1.0 - clamp(level * 4.0, 0.0, 1.0));
    float disp = breathe + jitter + mix(outward, inward, lm) * (1.0 - muted) + tm * 0.08 * n;
    float inner = mix(1.0, 0.45 + 0.55 * sd.y, tm * 0.55);   // thinking: some streams run through the inside
    float3 pos = p * (1.0 + disp) * inner;
    // CHECKING ONLINE: every dot streams off into a small bright moon orbiting on a tilted ring.
    float aM = t * 0.9 * m0.w;
    float3 M = float3(cos(aM) * 1.32, sin(aM) * 0.42, sin(aM) * 1.2);
    float ce = smoothstep(0.0, 1.0, clamp(cm * 1.5 - sd.x * 0.5, 0.0, 1.0));
    pos = mix(pos, M + p * (0.2 + 0.06 * sd.y), ce);
    _geometry.position.xyz = pos;
    float h = clamp(1.0 - lat + 0.08 * loud * sin(t + sd.y * 6.28) + tm * 0.18 * sin(t * 0.3 + p.x * 2.0), 0.0, 1.0) * 4.0;
    float3 c = h < 1.0 ? mix(p0, p1, h) : h < 2.0 ? mix(p1, p2, h - 1.0) : h < 3.0 ? mix(p2, p3, h - 2.0) : mix(p3, p4, h - 3.0);
    float3 vn = normalize((scn_node.modelViewTransform * float4(p, 0.0)).xyz);
    float rim = pow(1.0 - abs(vn.z), 2.2);
    float bright = (0.10 + 0.85 * rim) * (0.35 + glow * 0.6) * (1.0 + 0.8 * loud) * (0.55 + 0.9 * sd.y * sd.y);
    // Listening: the crests catch the light, strongest on the side facing you.
    bright *= 1.0 + lm * (0.5 + 1.2 * level) * (ripple - 0.4) * (0.4 + 0.6 * clamp(vd.z, 0.0, 1.0));
    // Thinking: occasional bright synapse sparks.
    float spark = tm * step(0.992, fract(sin(dot(sd, float2(12.9898, 78.233)) + floor(t * 2.5) * 7.31) * 43758.5453));
    bright *= 1.0 + spark * 6.0;
    // The moon shines brighter than anything else.
    bright = mix(bright, 0.035 + 0.06 * sd.y * sd.y + 0.12 * rim, ce);   // many dots overlap there: keep each dim
    float grey = dot(c, float3(0.3, 0.59, 0.11));
    c = mix(float3(grey), c, clamp(1.15 + 0.4 * loud, 0.0, 1.6) * (1.0 - 0.85 * muted));
    bright *= (1.0 - 0.55 * muted);
    if (lightMode > 0.5) {
        float a = clamp((0.18 + 0.8 * rim) * (0.6 + 0.6 * sd.y) * (1.0 - 0.5 * muted) + ce * 0.6, 0.0, 1.0);
        _geometry.color = float4(c * a, a);
    } else {
        _geometry.color = float4(c * bright, 1.0);
    }
    """

    // The core revealed while checking online: a smooth, slowly flowing sphere in darker Nebula shades,
    // lit by the moon as it orbits (the side facing the moon takes its colour).
    static let coreGeometry = """
    #pragma arguments
    float3 p0;
    float3 p1;
    float3 p2;
    float3 p3;
    float3 p4;
    float4 m0;
    float4 s1;
    #pragma body
    float t = scn_frame.time * s1.y;
    float cm = m0.z;
    float3 p = normalize(_geometry.position.xyz);
    float n = 0.5 * sin(dot(p, float3(0.62, 0.48, -0.62)) * 3.1 + t * 0.6) + 0.5 * sin(dot(p, float3(-0.27, 0.86, 0.43)) * 3.7 - t * 0.5);
    float3 q = p * (0.82 + 0.035 * n) * smoothstep(0.0, 1.0, cm);
    _geometry.position.xyz = q;
    _geometry.normal = p;
    float lat = p.y * 0.5 + 0.5;
    float h = clamp(1.0 - lat + 0.05 * n, 0.0, 1.0) * 4.0;
    float3 c = h < 1.0 ? mix(p0, p1, h) : h < 2.0 ? mix(p1, p2, h - 1.0) : h < 3.0 ? mix(p2, p3, h - 2.0) : mix(p3, p4, h - 3.0);
    float aM = t * 0.9 * m0.w;
    float3 M = float3(cos(aM) * 1.32, sin(aM) * 0.42, sin(aM) * 1.2);
    float3 L = normalize(M - q);
    float lit = pow(max(0.0, dot(p, L)), 2.0);
    float3 moonCol = mix(p0, p2, 0.4);
    float3 vn = normalize((scn_node.modelViewTransform * float4(p, 0.0)).xyz);
    float rim = pow(1.0 - abs(vn.z), 3.0);
    float3 col = c * 0.10 + moonCol * lit * 0.55 + c * rim * 0.18;
    _geometry.color = float4(col * cm, cm);
    """
}
