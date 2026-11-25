import AppKit
import SceneKit
import SwiftUI

/// The orb: a sphere of tens of thousands of small glowing dots ("Nebula": cyan and blue at the top,
/// through purple and magenta, to red and orange at the bottom), brighter at the rim, slightly ragged
/// as if vibrating. The particles are the mesh: the surface displaces outward with the voice, each of
/// eight frequency bands moving its own region. Idle breathes and turns slowly; thinking swirls with
/// a slow colour drift; checking online sweeps a bright scanning band; muted goes desaturated, still
/// and dim. Loudness lifts brightness and saturation and shifts the hue.
///
/// Light by design: one SceneKit point-sprite draw with all motion in the vertex shader, capped at
/// 30 fps (15 in the Island), paused whenever the window is hidden, a still frame under Reduce Motion.
struct Orb3DView: NSViewRepresentable {
    let state: TalkState
    @ObservedObject var meter: AudioMeter
    var muted = false
    var fps = 30
    /// The tiny Island orb uses fewer dots.
    var tiny = false
    @Environment(\.airTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("airOrbSensitivity") private var sensitivity = 1.0
    @AppStorage("airOrbDensity") private var density = "medium"
    @AppStorage("airOrbGlow") private var glow = 0.6
    @AppStorage("airOrbPalette") private var palette = "nebula"

    func makeCoordinator() -> OrbScene { OrbScene() }

    func makeNSView(context: Context) -> SCNView {
        let v = OccludableSCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        v.scene = context.coordinator.scene
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
        if v.preferredFramesPerSecond != fps { v.preferredFramesPerSecond = fps }
        if let o = v as? OccludableSCNView { o.motion = !reduceMotion }
        let count = tiny ? 2500 : (density == "low" ? 12_000 : density == "high" ? 40_000 : 24_000)
        context.coordinator.build(count: count, tiny: tiny)
        context.coordinator.update(state: state, mic: meter.mic, out: meter.out, muted: muted, bands: meter.bands,
                                   sensitivity: sensitivity, glow: glow, palette: palette == "theme" ? theme : nil,
                                   still: reduceMotion)
    }
}

/// Pauses rendering whenever its window is hidden, minimised or fully covered.
final class OccludableSCNView: SCNView {
    var motion = true { didSet { if motion != oldValue { refresh() } } }
    private var token: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let token { NotificationCenter.default.removeObserver(token) }
        guard let w = window else { return }
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

@MainActor
final class OrbScene {
    let scene = SCNScene()
    private let holder = SCNNode()
    private var dots: SCNNode?
    private let material = SCNMaterial()
    private var built = (count: 0, tiny: false)
    private var level = 0.0
    private var smooth = [Double](repeating: 0, count: 8)
    private var warmth = 0.0
    private var lastPalette: [SIMD3<Double>] = []
    private var lastVec: [String: SIMD4<Double>] = [:]

    static let nebula: [SIMD3<Double>] = [[0.25, 0.85, 1.0], [0.30, 0.45, 1.0], [0.58, 0.28, 0.98], [0.92, 0.25, 0.62], [1.0, 0.48, 0.18]]

    init() {
        scene.background.contents = NSColor.clear
        scene.rootNode.addChildNode(holder)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 30
        cam.position = SCNVector3(0, 0, 5.4)
        scene.rootNode.addChildNode(cam)

        material.lightingModel = .constant
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        material.isDoubleSided = true
        material.diffuse.contents = Self.dotImage()
        material.shaderModifiers = [.geometry: Self.geometry]
        holder.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 48)), forKey: "spin")
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
        el.pointSize = tiny ? 2.0 : 2.0
        el.minimumPointScreenSpaceRadius = tiny ? 0.8 : 1.0
        el.maximumPointScreenSpaceRadius = tiny ? 1.8 : 2.4
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: pos),
                                      SCNGeometrySource(textureCoordinates: seed),
                                      Self.whiteColors(count)], elements: [el])
        g.firstMaterial = material
        let n = SCNNode(geometry: g)
        holder.addChildNode(n)
        dots = n
    }

    func update(state: TalkState, mic: Double, out: Double, muted: Bool, bands: [Double], sensitivity: Double,
                glow: Double, palette: AirTheme?, still: Bool) {
        let mutedNow = muted && (state == .listening || state == .hearing)
        let target: Double = mutedNow ? 0 : (state == .speaking ? out : (state == .listening || state == .hearing ? mic : 0))
        let goal = min(1, target * 5 * sensitivity)
        level += (goal - level) * (goal > level ? 0.5 : 0.15)
        let b = bands.count == 8 ? bands : [Double](repeating: 0, count: 8)
        for i in 0..<8 {
            let t = mutedNow || still ? 0 : min(1.5, b[i] * sensitivity)
            smooth[i] += (t - smooth[i]) * (t > smooth[i] ? 0.55 : 0.12)
        }
        let loud = max(level, smooth.reduce(0, +) / 8)
        warmth += (loud - warmth) * 0.2
        var swirl = 0.0, scan = 0.0
        switch state {
        case .thinking: swirl = 1
        case .checking, .working: scan = 1
        default: break
        }
        if still { swirl = 0; scan = 0 }
        let pal: [SIMD3<Double>]
        if let t = palette {
            let c = t.nsColors.map { $0.usingColorSpace(.sRGB) ?? $0 }.map { SIMD3(Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)) }
            pal = [c[0], (c[0] + c[1]) / 2, c[1], (c[1] + c[2]) / 2, c[2]]
        } else {
            pal = Self.nebula
        }
        // Few, packed writes, and only when something changed: each shader-argument write costs.
        if pal != lastPalette {
            lastPalette = pal
            for (i, c) in pal.enumerated() { material.setValue(SCNVector3(c.x, c.y, c.z), forKey: "p\(i)") }
        }
        let v0 = SIMD4(smooth[0], smooth[1], smooth[2], smooth[3])
        let v1 = SIMD4(smooth[4], smooth[5], smooth[6], smooth[7])
        let v2 = SIMD4(still ? 0 : level, warmth, swirl, scan)
        let v3 = SIMD4(mutedNow ? 1.0 : 0.0, still ? 0.0 : 1.0, glow, 0)
        for (k, v) in [("b0", v0), ("b1", v1), ("s0", v2), ("s1", v3)] {
            let prev = lastVec[k] ?? SIMD4(repeating: -1)
            if simd_reduce_max(simd_abs(prev - v)) > 0.004 {
                lastVec[k] = v
                material.setValue(SCNVector4(v.x, v.y, v.z, v.w), forKey: k)
            }
        }
        if mutedNow || still { holder.removeAction(forKey: "spin") } else if holder.action(forKey: "spin") == nil {
            holder.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 48)), forKey: "spin")
        }
    }

    /// A colour source (the shader writes the real colour; it needs the attribute to exist).
    static func whiteColors(_ n: Int) -> SCNGeometrySource {
        let data = [Float](repeating: 1, count: n * 3).withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data, semantic: .color, vectorCount: n, usesFloatComponents: true,
                                 componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
    }

    /// A soft round dot for the point sprites (additive blending turns overlaps into glow).
    static func dotImage() -> NSImage {
        let s = 32
        return NSImage(size: NSSize(width: s, height: s), flipped: false) { r in
            let g = NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(white: 1, alpha: 0.55), NSColor(white: 1, alpha: 0)],
                               atLocations: [0, 0.35, 1], colorSpace: .deviceRGB)!
            g.draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero)
            return true
        }
    }

    // Displacement, flow and colour, all on the GPU. The gradient follows height on the sphere
    // (the orb turns about its vertical axis, so the top stays cyan and the bottom orange).
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
    #pragma body
    float level = s0.x;
    float loud = s0.y;
    float swirl = s0.z;
    float scan = s0.w;
    float muted = s1.x;
    float motion = s1.y;
    float glow = s1.z;
    float t = scn_frame.time * motion;
    float3 p = normalize(_geometry.position.xyz);
    float2 sd = _geometry.texcoords[0];
    float a = swirl * 0.35 * sin(t * 0.6 + p.y * 3.0);
    float ca = cos(a), sa = sin(a);
    p = float3(p.x * ca - p.z * sa, p.y, p.x * sa + p.z * ca);
    float ang = (atan2(p.z, p.x) / 6.28318 + 0.5) * 8.0;
    float bands[8] = { b0.x, b0.y, b0.z, b0.w, b1.x, b1.y, b1.z, b1.w };
    int i0 = int(floor(ang)) % 8;
    float e = mix(bands[i0], bands[(i0 + 1) % 8], fract(ang));
    float lat = p.y * 0.5 + 0.5;
    float zone = mix(1.0 - lat, lat, float(i0) / 7.0) * 0.6 + 0.4;
    // Waves along skewed directions (not the axes), so the outline stays round, never boxy.
    float n = 0.5 * sin(dot(p, float3(0.62, 0.48, -0.62)) * 4.3 + t * 0.9)
            + 0.3 * sin(dot(p, float3(-0.27, 0.86, 0.43)) * 5.1 - t * 0.7)
            + 0.2 * sin(dot(p, float3(0.75, -0.31, 0.58)) * 6.7 + t * 0.5);
    float n2 = sin(dot(p, float3(0.41, 0.73, 0.55)) * 13.0 - t * 2.3) * sin(dot(p, float3(-0.66, 0.2, 0.72)) * 11.0 + t * 1.9);
    float jitter = (sd.x - 0.5) * (0.035 + 0.12 * level) * (1.0 - muted);
    float breathe = 0.02 * sin(t * 1.1) * (1.0 - muted);
    float disp = breathe + (0.03 + 0.14 * level) * n * (1.0 - muted) + 0.05 * level * n2 + e * zone * 0.2 + jitter;
    _geometry.position.xyz = p * (1.0 + disp);
    float h = clamp(1.0 - lat + 0.08 * loud * sin(t + sd.y * 6.28) + swirl * 0.12 * sin(t * 0.25 + p.x * 2.0), 0.0, 1.0) * 4.0;
    float3 c = h < 1.0 ? mix(p0, p1, h) : h < 2.0 ? mix(p1, p2, h - 1.0) : h < 3.0 ? mix(p2, p3, h - 2.0) : mix(p3, p4, h - 3.0);
    float3 vn = normalize((scn_node.modelViewTransform * float4(p, 0.0)).xyz);
    float rim = pow(1.0 - abs(vn.z), 2.2);
    float bright = (0.10 + 0.85 * rim) * (0.35 + glow * 0.6) * (1.0 + 0.8 * loud) * (0.55 + 0.9 * sd.y * sd.y);
    float band = scan * exp(-pow((lat - (1.0 - fract(t * 0.35))) * 26.0, 2.0));
    float grey = dot(c, float3(0.3, 0.59, 0.11));
    c = mix(float3(grey), c, clamp(1.15 + 0.4 * loud, 0.0, 1.6) * (1.0 - 0.85 * muted));
    bright *= (1.0 - 0.55 * muted);
    _geometry.color = float4(c * (bright + band * 1.4), 1.0);
    """
}
