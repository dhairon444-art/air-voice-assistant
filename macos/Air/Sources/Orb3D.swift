import AppKit
import SceneKit
import SwiftUI

/// The 3D orb: a glossy, glassy sphere with a soft inner glow whose surface flows with sound.
/// Listening follows your mic level, speaking follows Aria's voice, thinking swirls slowly,
/// checking online sweeps a shimmer band, muted goes dim and still. Colours follow the theme.
/// Light by design: SceneKit with runtime shader modifiers, capped at 30 fps (20 in the Island),
/// paused when the window is hidden, and a still render when Reduce Motion is on.
struct Orb3DView: NSViewRepresentable {
    let state: TalkState
    let mic: Double
    let out: Double
    var muted = false
    var fps = 30
    var bands: [Double] = []
    /// The spiky mesh shell (Settings › Appearance › Orb). Off in the tiny Island orb.
    var showMesh = true
    @AppStorage("airOrbMesh") private var meshOn = true
    @AppStorage("airOrbMeshStyle") private var meshStyle = "wireframe"
    @AppStorage("airOrbSensitivity") private var sensitivity = 1.0
    @Environment(\.airTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> OrbScene { OrbScene() }

    func makeNSView(context: Context) -> SCNView {
        let v = OccludableSCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        v.scene = context.coordinator.scene
        v.backgroundColor = .clear
        v.allowsCameraControl = false
        v.antialiasingMode = .multisampling4X
        v.preferredFramesPerSecond = fps
        v.rendersContinuously = !reduceMotion
        v.isPlaying = !reduceMotion
        v.isJitteringEnabled = false
        v.setAccessibilityElement(false)
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        v.preferredFramesPerSecond = fps
        if let o = v as? OccludableSCNView { o.motion = !reduceMotion }
        context.coordinator.update(state: state, mic: mic, out: out, muted: muted, theme: theme, still: reduceMotion)
        context.coordinator.setCloseUp(!showMesh)
        context.coordinator.updateMesh(on: showMesh && meshOn, style: meshStyle, bands: bands, sensitivity: sensitivity,
                                       state: state, muted: muted, theme: theme, still: reduceMotion)
    }
}

/// Pauses rendering whenever its window is hidden, minimised or fully covered.
final class OccludableSCNView: SCNView {
    var motion = true { didSet { refresh() } }
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
        let visible = window?.occlusionState.contains(.visible) ?? false
        isPlaying = motion && visible
        rendersContinuously = motion && visible
    }
}

@MainActor
final class OrbScene {
    let scene = SCNScene()
    private let node: SCNNode
    private let material = SCNMaterial()
    private var level = 0.0
    private var smooth = [Double](repeating: 0, count: 8)
    private var meshNodes: [String: SCNNode] = [:]
    private let meshMaterial = SCNMaterial()

    init() {
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 96
        material.lightingModel = .blinn
        material.specular.contents = NSColor(white: 1, alpha: 1)
        material.shininess = 0.55
        material.fresnelExponent = 2.2
        material.isDoubleSided = false
        material.shaderModifiers = [.geometry: Self.geometry, .surface: Self.surface]
        sphere.firstMaterial = material
        node = SCNNode(geometry: sphere)
        scene.rootNode.addChildNode(node)
        scene.background.contents = NSColor.clear

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 30
        cam.position = SCNVector3(0, 0, 6.4)
        scene.rootNode.addChildNode(cam)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 900
        key.position = SCNVector3(-2.5, 3, 4)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 380
        scene.rootNode.addChildNode(fill)

        let spin = SCNAction.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0.3, duration: 40))
        node.runAction(spin, forKey: "spin")
        update(state: .idle, mic: 0, out: 0, muted: false, theme: .aurora, still: false)
    }

    /// The shell: an icosphere a little larger than the orb, as lines or points. Its vertices spike
    /// outward with the voice: each of eight frequency bands drives its own region around the sphere,
    /// smoothed (fast attack, slow release) so it feels organic. Colour shifts with loudness and pitch.
    func updateMesh(on: Bool, style: String, bands: [Double], sensitivity: Double, state: TalkState, muted: Bool,
                    theme: AirTheme, still: Bool) {
        for (k, n) in meshNodes { n.isHidden = !on || k != style }
        guard on else { return }
        if meshNodes[style] == nil {
            let n = SCNNode(geometry: Self.icosphere(points: style == "particles"))
            n.geometry?.firstMaterial = meshMaterial
            meshMaterial.lightingModel = .constant
            meshMaterial.isDoubleSided = true
            meshMaterial.blendMode = .add
            meshMaterial.writesToDepthBuffer = false
            meshMaterial.shaderModifiers = [.geometry: Self.meshGeometry, .surface: Self.meshSurface]
            n.scale = SCNVector3(1.22, 1.22, 1.22)
            n.runAction(.repeatForever(.rotateBy(x: 0.2, y: -.pi * 2, z: 0, duration: 60)))
            node.parent?.addChildNode(n)
            meshNodes[style] = n
        }
        let active = !(muted && (state == .listening || state == .hearing)) && !still
        let b = bands.count == 8 ? bands : [Double](repeating: 0, count: 8)
        for i in 0..<8 {
            let target = active ? min(1.5, b[i] * sensitivity) : 0
            smooth[i] += (target - smooth[i]) * (target > smooth[i] ? 0.55 : 0.12)
        }
        meshMaterial.setValue(SCNVector4(smooth[0], smooth[1], smooth[2], smooth[3]), forKey: "b0")
        meshMaterial.setValue(SCNVector4(smooth[4], smooth[5], smooth[6], smooth[7]), forKey: "b1")
        let loud = smooth.reduce(0, +) / 8
        let pitch = loud > 0.01 ? smooth.enumerated().map { Double($0.offset) * $0.element }.reduce(0, +) / (smooth.reduce(0, +) * 7) : 0.5
        let c = theme.nsColors.map { $0.usingColorSpace(.sRGB) ?? $0 }
        meshMaterial.setValue(SCNVector3(c[0].redComponent, c[0].greenComponent, c[0].blueComponent), forKey: "c1")
        meshMaterial.setValue(SCNVector3(c[1].redComponent, c[1].greenComponent, c[1].blueComponent), forKey: "c2")
        meshMaterial.setValue(SCNVector3(c[2].redComponent, c[2].greenComponent, c[2].blueComponent), forKey: "c3")
        let tint: NSColor
        switch state {
        case .thinking: tint = .systemPurple
        case .checking, .working: tint = .systemTeal
        case .speaking: tint = .white
        default: tint = muted ? .systemRed : .systemGreen
        }
        let t = tint.usingColorSpace(.sRGB) ?? tint
        meshMaterial.setValue(SCNVector3(t.redComponent, t.greenComponent, t.blueComponent), forKey: "stateTint")
        meshMaterial.setValue(NSNumber(value: loud), forKey: "loud")
        meshMaterial.setValue(NSNumber(value: pitch), forKey: "pitch")
        meshMaterial.setValue(NSNumber(value: active ? 1.0 : 0.35), forKey: "alive")
    }

    /// Icosahedron subdivided three times (642 vertices): edges for wireframe, vertices for particles.
    static func icosphere(points: Bool) -> SCNGeometry {
        let t = (1.0 + sqrt(5.0)) / 2
        var v: [SIMD3<Double>] = [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t],
                                  [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]].map { simd_normalize($0) }
        var f: [(Int, Int, Int)] = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
                                    (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5),
                                    (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
        for _ in 0..<3 {
            var cache: [Int: Int] = [:]
            func mid(_ a: Int, _ b: Int) -> Int {
                let key = min(a, b) << 16 | max(a, b)
                if let i = cache[key] { return i }
                v.append(simd_normalize((v[a] + v[b]) / 2)); cache[key] = v.count - 1
                return v.count - 1
            }
            f = f.flatMap { (a, b, c) -> [(Int, Int, Int)] in
                let ab = mid(a, b), bc = mid(b, c), ca = mid(c, a)
                return [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
            }
        }
        let verts = v.map { SCNVector3($0.x, $0.y, $0.z) }
        let src = SCNGeometrySource(vertices: verts)
        let nrm = SCNGeometrySource(normals: verts)
        let element: SCNGeometryElement
        if points {
            element = SCNGeometryElement(indices: (0..<UInt32(verts.count)).map { $0 }, primitiveType: .point)
            element.pointSize = 3
            element.minimumPointScreenSpaceRadius = 1.2
            element.maximumPointScreenSpaceRadius = 3.5
        } else {
            var edges = Set<UInt64>()
            for (a, b, c) in f { for (x, y) in [(a, b), (b, c), (c, a)] { edges.insert(UInt64(min(x, y)) << 32 | UInt64(max(x, y))) } }
            element = SCNGeometryElement(indices: edges.flatMap { [UInt32($0 >> 32), UInt32($0 & 0xffffffff)] }, primitiveType: .line)
        }
        return SCNGeometry(sources: [src, nrm], elements: [element])
    }

    static let meshGeometry = """
    #pragma arguments
    float4 b0;
    float4 b1;
    float alive;
    #pragma body
    float3 p = normalize(_geometry.position.xyz);
    float ang = (atan2(p.z, p.x) / 6.28318 + 0.5) * 8.0;
    float lat = p.y * 0.5 + 0.5;
    float bands[8] = { b0.x, b0.y, b0.z, b0.w, b1.x, b1.y, b1.z, b1.w };
    int i0 = int(floor(ang)) % 8;
    int i1 = (i0 + 1) % 8;
    float e = mix(bands[i0], bands[i1], fract(ang));
    // Low pitches swell the lower half, high pitches the upper half; a fine ripple makes them spiky.
    float zone = mix(1.0 - lat, lat, float(i0) / 7.0) * 0.6 + 0.4;
    float spike = e * zone * (0.55 + 0.45 * sin(p.x * 23.0 + p.y * 17.0 + p.z * 29.0 + scn_frame.time * 2.0));
    float breathe = 0.015 * sin(scn_frame.time * 1.2 + p.y * 4.0) * alive;
    _geometry.position.xyz = p * (1.0 + breathe + spike * 0.55);
    """

    static let meshSurface = """
    #pragma arguments
    float3 c1;
    float3 c2;
    float3 c3;
    float3 stateTint;
    float loud;
    float pitch;
    float alive;
    #pragma body
    float3 col = mix(mix(c1, c2, clamp(pitch * 2.0, 0.0, 1.0)), c3, clamp(pitch * 2.0 - 1.0, 0.0, 1.0));
    col = mix(col, stateTint, 0.25);
    float bright = (0.28 + 1.1 * clamp(loud * 2.0, 0.0, 1.0)) * alive;
    _surface.diffuse = float4(0.0, 0.0, 0.0, 1.0);
    _surface.emission = float4(col * bright, 1.0);
    """

    func setCloseUp(_ on: Bool) {
        scene.rootNode.childNodes.first { $0.camera != nil }?.position = SCNVector3(0, 0, on ? 4.6 : 6.4)
    }

    func update(state: TalkState, mic: Double, out: Double, muted: Bool, theme: AirTheme, still: Bool) {
        let target: Double
        switch state {
        case .speaking: target = muted ? 0 : out
        case .listening, .hearing: target = muted ? 0 : mic
        default: target = 0
        }
        // Smooth the level so the surface flows instead of jittering.
        level += (min(1, target * 5) - level) * 0.35
        var swirl = 1.0, shimmer = 0.0, tintMix = 0.0, calm = 0.0
        var tint = NSColor.systemPurple
        switch state {
        case .thinking: swirl = 2.6; tintMix = 0.35; tint = .systemPurple
        case .checking: shimmer = 1; tintMix = 0.3; tint = .systemTeal
        case .working: shimmer = 0.7; tintMix = 0.3; tint = .systemBlue
        case .idle, .connecting: calm = 0.4
        default: break
        }
        let dim = muted && (state == .listening || state == .hearing) ? 1.0 : 0.0
        if still { swirl = 0; shimmer = 0 }
        let c = theme.nsColors.map { $0.usingColorSpace(.sRGB) ?? $0 }
        material.setValue(SCNVector3(c[0].redComponent, c[0].greenComponent, c[0].blueComponent), forKey: "c1")
        material.setValue(SCNVector3(c[1].redComponent, c[1].greenComponent, c[1].blueComponent), forKey: "c2")
        material.setValue(SCNVector3(c[2].redComponent, c[2].greenComponent, c[2].blueComponent), forKey: "c3")
        let t = tint.usingColorSpace(.sRGB) ?? tint
        material.setValue(SCNVector3(t.redComponent, t.greenComponent, t.blueComponent), forKey: "stateTint")
        material.setValue(NSNumber(value: tintMix), forKey: "tintMix")
        material.setValue(NSNumber(value: still ? 0 : level), forKey: "level")
        material.setValue(NSNumber(value: swirl), forKey: "swirl")
        material.setValue(NSNumber(value: shimmer), forKey: "shimmer")
        material.setValue(NSNumber(value: dim), forKey: "dim")
        material.setValue(NSNumber(value: dim > 0 ? 0.85 : calm), forKey: "flatness")
        if still || dim > 0 { node.removeAction(forKey: "spin") } else if node.action(forKey: "spin") == nil {
            node.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0.3, duration: 40)), forKey: "spin")
        }
    }

    // Vertex flow: layered moving waves along the normal, bigger with the sound level.
    static let geometry = """
    #pragma arguments
    float level;
    float swirl;
    float flatness;
    #pragma body
    float t = scn_frame.time;
    float3 p = _geometry.position.xyz;
    float n1 = sin(p.x * 3.1 + t * 1.2 * swirl) * sin(p.y * 3.6 - t * 1.0 * swirl) * sin(p.z * 2.8 + t * 0.8);
    float n2 = sin(p.x * 6.7 - t * 2.1) * sin(p.y * 5.9 + t * 1.8) * sin(p.z * 6.3 - t * 1.5);
    float d = (0.045 + level * 0.2) * n1 + (level * 0.09) * n2;
    _geometry.position.xyz += _geometry.normal * d * (1.0 - flatness);
    """

    // Colour: the theme gradient across the sphere, a fresnel rim glow, a soft inner light,
    // the state tint, and a sweeping shimmer band while checking online.
    static let surface = """
    #pragma arguments
    float3 c1;
    float3 c2;
    float3 c3;
    float3 stateTint;
    float tintMix;
    float shimmer;
    float dim;
    #pragma body
    float u = _surface.diffuseTexcoord.y;
    float w = _surface.diffuseTexcoord.x;
    // Gradient across the visible face (top-left to bottom-right), stirred by the turning surface.
    float diag = 0.5 - 0.5 * dot(_surface.normal, normalize(float3(-0.55, 0.65, 0.25)));
    float k = clamp(diag + 0.10 * sin(w * 12.566 + u * 6.0 + scn_frame.time * 0.4), 0.0, 1.0);
    float3 col = mix(mix(c1, c2, clamp(k * 2.0, 0.0, 1.0)), c3, clamp(k * 2.0 - 1.0, 0.0, 1.0));
    col = mix(col, stateTint, tintMix);
    float fres = pow(1.0 - clamp(dot(_surface.normal, _surface.view), 0.0, 1.0), 2.4);
    float band = shimmer * exp(-pow((u - fract(scn_frame.time * 0.45)) * 10.0, 2.0));
    float3 lit = col * (1.0 - dim * 0.65);
    _surface.diffuse = float4(lit * 0.75, 1.0);
    _surface.emission = float4(lit * (0.10 + 0.75 * fres) + float3(band * 0.6), 1.0);
    _surface.specular = float4(float3(0.9 - dim * 0.7), 1.0);
    """
}
