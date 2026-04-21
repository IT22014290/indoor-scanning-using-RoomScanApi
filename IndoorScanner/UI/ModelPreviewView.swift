import SwiftUI
import RealityKit
import RoomPlan
import simd

struct ModelPreviewView: View {
    @EnvironmentObject var appState: AppState
    @State private var showExportSheet = false
    @State private var stats = SceneStats()

    struct SceneStats {
        var triangles:   Int    = 0
        var floorAreaM2: Double = 0
        var elements:    Int    = 0
    }

    var body: some View {
        ZStack {
            RealityKitPreviewView(appState: appState, stats: $stats)
                .ignoresSafeArea()
            VStack { topBar; Spacer(); bottomBar }
        }
        .sheet(isPresented: $showExportSheet) { ExportView() }
    }

    // MARK: - HUD

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("3D Preview").font(.headline).foregroundColor(.white)
                Text("\(stats.triangles.formatted()) triangles · \(stats.elements) elements")
                    .font(.caption).foregroundColor(.secondary)
                Text(String(format: "Floor area: %.1f m²", stats.floorAreaM2))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "rotate.3d").foregroundColor(.secondary).font(.subheadline)
        }
        .padding(.horizontal).padding(.top, 60).padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    appState.multiRoomStitcher.reset()
                    appState.scannedRooms = []
                    appState.roomCount    = 0
                    appState.phase        = .scanning
                } label: {
                    Label("Rescan", systemImage: "arrow.counterclockwise")
                        .font(.subheadline).foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial).clipShape(Capsule())
                }
                Spacer()
                Button { showExportSheet = true } label: {
                    Text("Approve & Export")
                        .font(.headline).foregroundColor(.black)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(Color.white).clipShape(Capsule())
                }
            }
            .padding(.horizontal).padding(.vertical, 16).padding(.bottom, 32)
        }
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - RealityKit UIViewRepresentable

struct RealityKitPreviewView: UIViewRepresentable {
    let appState: AppState
    @Binding var stats: ModelPreviewView.SceneStats

    func makeCoordinator() -> Coordinator { Coordinator(appState: appState, stats: $stats) }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero,
                            cameraMode: .nonAR,
                            automaticallyConfigureSession: false)
        arView.environment.background = .color(UIColor(red: 0.07, green: 0.07, blue: 0.10, alpha: 1))
        arView.renderOptions = [.disableGroundingShadows, .disableMotionBlur, .disableFaceMesh]
        context.coordinator.setup(arView: arView)
        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {}

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        let appState: AppState
        @Binding var stats: ModelPreviewView.SceneStats

        weak var arView: ARView?

        // In iOS 18, PerspectiveCamera is an Entity subclass, not a Component.
        // Store as Entity so look(at:from:relativeTo:) is accessible.
        var cameraEntity: Entity?

        var displayLink: CADisplayLink?

        // Spherical camera orbit state
        var azimuth:   Float = Float.pi / 5
        var elevation: Float = Float.pi / 5
        var radius:    Float = 5.0
        var target:    SIMD3<Float> = .zero

        // Inertia velocities (decayed each display-link tick)
        var velAzimuth:   Float = 0
        var velElevation: Float = 0
        var velZoom:      Float = 0

        // Gesture bookkeeping
        var panFingerCount: Int     = 1
        var lastPinchScale: CGFloat = 1.0

        init(appState: AppState, stats: Binding<ModelPreviewView.SceneStats>) {
            self.appState = appState
            self._stats = stats
        }

        deinit { displayLink?.invalidate() }

        func setup(arView: ARView) {
            self.arView = arView
            setupCamera(in: arView)
            setupGestures(on: arView)
            startDisplayLink()
            loadContent(in: arView)
        }

        // MARK: Camera
        // iOS 18: PerspectiveCamera is an Entity subclass — add as child, not via components.set()

        private func setupCamera(in arView: ARView) {
            let cam = PerspectiveCamera()
            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(cam)
            arView.scene.addAnchor(anchor)
            cameraEntity = cam
            updateCamera()
        }

        func updateCamera() {
            let x = cos(elevation) * sin(azimuth) * radius + target.x
            let y = sin(elevation) * radius           + target.y
            let z = cos(elevation) * cos(azimuth) * radius + target.z
            cameraEntity?.look(at: target, from: SIMD3<Float>(x, y, z), relativeTo: nil)
        }

        // MARK: Inertia loop

        private func startDisplayLink() {
            let dl = CADisplayLink(target: self, selector: #selector(animationTick))
            dl.add(to: .main, forMode: .common)
            displayLink = dl
        }

        @objc func animationTick() {
            let damping: Float = 0.88
            velAzimuth   *= damping
            velElevation *= damping
            velZoom      *= damping

            let threshold: Float = 0.00015
            var dirty = false

            if abs(velAzimuth) > threshold {
                azimuth += velAzimuth; dirty = true
            }
            if abs(velElevation) > threshold {
                elevation = max(-Float.pi / 2 + 0.05,
                                min( Float.pi / 2 - 0.05, elevation + velElevation))
                dirty = true
            }
            if abs(velZoom) > threshold {
                radius = max(0.3, radius * (1 - velZoom)); dirty = true
            }
            if dirty { updateCamera() }
        }

        // MARK: Gestures

        private func setupGestures(on arView: ARView) {
            let pan   = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            pan.maximumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
            arView.addGestureRecognizer(pan)
            arView.addGestureRecognizer(pinch)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            if g.state == .began { panFingerCount = g.numberOfTouches }
            if g.numberOfTouches == 2 { panFingerCount = 2 }

            if g.state == .ended {
                if panFingerCount == 1 {
                    let vel = g.velocity(in: g.view)
                    velAzimuth   = -Float(vel.x) * 0.000025
                    velElevation =  Float(vel.y) * 0.000025
                }
                return
            }

            let t = g.translation(in: g.view)
            if panFingerCount >= 2 {
                let speed = radius * 0.0008
                let dx =  Float(t.x) * speed
                let dz = -Float(t.y) * speed
                target.x -= dx * cos(azimuth) + dz * sin(azimuth)
                target.z -= dx * sin(azimuth) - dz * cos(azimuth)
            } else {
                azimuth   -= Float(t.x) * 0.007
                elevation += Float(t.y) * 0.007
                elevation  = max(-Float.pi / 2 + 0.05, min(Float.pi / 2 - 0.05, elevation))
            }
            g.setTranslation(.zero, in: g.view)
            updateCamera()
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:  lastPinchScale = g.scale
            case .ended:
                let delta = Float(g.scale / lastPinchScale)
                velZoom = (1 - delta) * 0.04
            default:
                let delta = Float(g.scale / lastPinchScale)
                radius    = max(0.3, radius / delta)
                lastPinchScale = g.scale
                updateCamera()
            }
        }

        // MARK: Content loading (async, non-blocking)

        private func loadContent(in arView: ARView) {
            guard let usdzURL = appState.previewUsdzURL else {
                // Keep preview faithful to RoomPlan output: do not render fallback geometry.
                stats = ModelPreviewView.SceneStats(triangles: 0,
                                                    floorAreaM2: appState.totalFloorArea,
                                                    elements: 0)
                return
            }
            // Load on a background thread so main thread never blocks
            Task { [weak self] in
                guard let self else { return }
                let loaded: Entity? = await Task.detached(priority: .userInitiated) {
                    try? Entity.load(contentsOf: usdzURL)
                }.value
                if let entity = loaded {
                    self.normalizeAndPlace(entity, in: arView)
                    self.computeUsdzStats()
                } else {
                    // Keep preview faithful to RoomPlan output: avoid custom fallback render.
                    self.stats = ModelPreviewView.SceneStats(triangles: 0,
                                                             floorAreaM2: self.appState.totalFloorArea,
                                                             elements: 0)
                }
            }
        }

        // MARK: Normalization + placement

        private func normalizeAndPlace(_ entity: Entity, in arView: ARView) {
            let bounds  = entity.visualBounds(relativeTo: nil)
            let center  = (bounds.min + bounds.max) * 0.5
            let extents = bounds.max - bounds.min
            let maxDim  = max(max(extents.x, extents.y), max(extents.z, 0.5))

            entity.position -= center     // center at world origin
            target  = .zero
            radius  = maxDim * 1.8

            let lightAnchor = AnchorEntity(world: .zero)
            addLights(to: lightAnchor)
            addGroundPlane(y: -extents.y * 0.5 - 0.02, size: maxDim * 5, to: lightAnchor)
            arView.scene.addAnchor(lightAnchor)

            let modelAnchor = AnchorEntity(world: .zero)
            modelAnchor.addChild(entity)
            arView.scene.addAnchor(modelAnchor)

            updateCamera()
        }

        // MARK: Lighting
        // iOS 18: DirectionalLightComponent.shadow was removed; shadows disabled.

        private func addLights(to parent: Entity) {
            func make(_ color: UIColor, _ intensity: Float, from pos: SIMD3<Float>) -> Entity {
                let e = Entity()
                var c = DirectionalLightComponent()
                c.color            = color
                c.intensity        = intensity
                c.isRealWorldProxy = false
                e.components.set(c)
                e.look(at: .zero, from: pos, relativeTo: nil)
                return e
            }
            parent.addChild(make(.white,                          3500, from: [ 5, 12,  5]))
            parent.addChild(make(UIColor(white: 0.75, alpha: 1), 1500, from: [-4,  8, -4]))
            parent.addChild(make(UIColor(white: 0.50, alpha: 1),  600, from: [ 0,  2, -8]))
        }

        private func addGroundPlane(y: Float, size: Float, to parent: Entity) {
            let mesh = MeshResource.generatePlane(width: size, depth: size)
            var mat  = PhysicallyBasedMaterial()
            mat.baseColor = .init(tint: UIColor(white: 0.06, alpha: 1))
            mat.roughness = 0.95
            mat.metallic  = 0.0
            let plane = ModelEntity(mesh: mesh, materials: [mat])
            plane.position = [0, y, 0]
            parent.addChild(plane)
        }

        // MARK: Manual fallback — PBR boxes

        private func buildManualContent(in arView: ARView) {
            let rooms = appState.multiRoomStitcher.rooms
            guard !rooms.isEmpty else { return }

            var accum = BoundsAccumulator()
            var totalTris = 0, totalElems = 0, totalArea = 0.0
            var floorY: Float = 0

            outer: for entry in rooms {
                if #available(iOS 17.0, *), let f = entry.capturedRoom.floors.first {
                    floorY = (entry.qrRelativeTransform * f.transform).columns.3.y; break outer
                }
                if let w = entry.capturedRoom.walls.first {
                    floorY = (entry.qrRelativeTransform * w.transform).columns.3.y - w.dimensions.y / 2
                    break outer
                }
            }

            let modelAnchor = AnchorEntity(world: .zero)

            for entry in rooms {
                let room = entry.capturedRoom
                let toQR = entry.qrRelativeTransform

                for wall in room.walls {
                    let t = toQR * wall.transform
                    let d = SIMD3<Float>(wall.dimensions.x, wall.dimensions.y, max(wall.dimensions.z, 0.12))
                    modelAnchor.addChild(makePBR(d, color: UIColor(white: 0.92, alpha: 1), rough: 0.90, metal: 0.00, xf: t))
                    accum.expand(t: t, dims: d); totalTris += 12; totalElems += 1
                }

                if #available(iOS 17.0, *), !room.floors.isEmpty {
                    for floor in room.floors {
                        var t = toQR * floor.transform; t.columns.3.y = floorY
                        let d = SIMD3<Float>(floor.dimensions.x, 0.02, floor.dimensions.z)
                        modelAnchor.addChild(makePBR(d, color: UIColor(white: 0.48, alpha: 1), rough: 0.95, metal: 0.00, xf: t))
                        accum.expand(t: t, dims: d)
                        totalArea += Double(floor.dimensions.x * floor.dimensions.z)
                        totalTris += 12; totalElems += 1
                    }
                } else {
                    let pts = room.walls.map { (toQR * $0.transform).translation }
                    if !pts.isEmpty {
                        let xs = pts.map { $0.x }, zs = pts.map { $0.z }
                        let cx = (xs.max()! + xs.min()!) / 2, cz = (zs.max()! + zs.min()!) / 2
                        let fw = (xs.max()! - xs.min()!) + 0.5, fd = (zs.max()! - zs.min()!) + 0.5
                        var t = matrix_identity_float4x4
                        t.columns.3 = simd_float4(cx, floorY, cz, 1)
                        let d = SIMD3<Float>(fw, 0.02, fd)
                        modelAnchor.addChild(makePBR(d, color: UIColor(white: 0.48, alpha: 1), rough: 0.95, metal: 0.00, xf: t))
                        accum.expand(t: t, dims: d)
                        totalArea += Double(fw * fd); totalTris += 12; totalElems += 1
                    }
                }

                for door in room.doors {
                    let t = toQR * door.transform
                    modelAnchor.addChild(makePBR(SIMD3<Float>(door.dimensions.x, door.dimensions.y, 0.05),
                                                  color: UIColor(white: 0.65, alpha: 0.55), rough: 0.80, metal: 0.00, xf: t))
                }

                for window in room.windows {
                    let t = toQR * window.transform
                    modelAnchor.addChild(makePBR(SIMD3<Float>(window.dimensions.x, window.dimensions.y, 0.04),
                                                  color: UIColor(red: 0.7, green: 0.85, blue: 1.0, alpha: 0.5), rough: 0.10, metal: 0.10, xf: t))
                }

                for object in room.objects {
                    var t = toQR * object.transform
                    let d = SIMD3<Float>(max(object.dimensions.x, 0.08),
                                         max(object.dimensions.y, 0.08),
                                         max(object.dimensions.z, 0.08))
                    if abs(t.columns.3.y - (floorY + d.y / 2)) > 0.20 { t.columns.3.y = floorY + d.y / 2 }
                    modelAnchor.addChild(makePBR(d, color: colorForCategory(object.category), rough: 0.80, metal: 0.05, xf: t))
                    accum.expand(t: t, dims: d); totalTris += 12; totalElems += 1
                }
            }

            // Normalize: center geometry at world origin
            let center = accum.center
            let size   = accum.size
            modelAnchor.position -= center
            target = .zero
            radius = max(max(size.x, size.z) * 1.8, 1.0)

            let lightAnchor = AnchorEntity(world: .zero)
            addLights(to: lightAnchor)
            addGroundPlane(y: accum.mn.y - center.y - 0.02,
                           size: max(size.x, size.z) * 5,
                           to: lightAnchor)
            arView.scene.addAnchor(lightAnchor)
            arView.scene.addAnchor(modelAnchor)

            appState.triangleCount = totalTris
            if totalArea > 0 { appState.totalFloorArea = totalArea }
            stats = ModelPreviewView.SceneStats(triangles: totalTris,
                                                floorAreaM2: totalArea,
                                                elements: totalElems)
            updateCamera()
        }

        private func makePBR(_ dims: SIMD3<Float>, color: UIColor,
                              rough: Float, metal: Float,
                              xf: simd_float4x4) -> ModelEntity {
            let mesh = MeshResource.generateBox(size: dims, cornerRadius: 0.005)
            var mat  = PhysicallyBasedMaterial()
            mat.baseColor = .init(tint: color)
            mat.roughness = .init(floatLiteral: rough)
            mat.metallic  = .init(floatLiteral: metal)
            let entity = ModelEntity(mesh: mesh, materials: [mat])
            entity.transform = Transform(matrix: xf)
            return entity
        }

        private func computeUsdzStats() {
            let rooms = appState.multiRoomStitcher.rooms
            let elems = rooms.reduce(0) { $0 + $1.capturedRoom.walls.count + $1.capturedRoom.objects.count }
            stats = ModelPreviewView.SceneStats(triangles: elems * 12,
                                                floorAreaM2: appState.totalFloorArea,
                                                elements: elems)
        }

        // MARK: Category colours

        private func colorForCategory(_ cat: CapturedRoom.Object.Category) -> UIColor {
            switch cat {
            case .table:        return UIColor(red:0.88, green:0.88, blue:0.82, alpha:1)
            case .chair:        return UIColor(red:0.85, green:0.85, blue:0.80, alpha:1)
            case .sofa:         return UIColor(red:0.82, green:0.84, blue:0.88, alpha:1)
            case .storage:      return UIColor(red:0.86, green:0.86, blue:0.82, alpha:1)
            case .television:   return UIColor(red:0.72, green:0.72, blue:0.76, alpha:1)
            case .refrigerator: return UIColor(red:0.90, green:0.91, blue:0.92, alpha:1)
            case .washerDryer:  return UIColor(red:0.88, green:0.90, blue:0.92, alpha:1)
            case .toilet:       return UIColor(red:0.94, green:0.94, blue:0.96, alpha:1)
            case .bathtub:      return UIColor(red:0.92, green:0.93, blue:0.95, alpha:1)
            case .sink:         return UIColor(red:0.91, green:0.92, blue:0.94, alpha:1)
            case .stove:        return UIColor(red:0.80, green:0.80, blue:0.78, alpha:1)
            case .bed:          return UIColor(red:0.84, green:0.86, blue:0.90, alpha:1)
            case .fireplace:    return UIColor(red:0.76, green:0.74, blue:0.72, alpha:1)
            case .stairs:       return UIColor(red:0.87, green:0.85, blue:0.82, alpha:1)
            default:            return UIColor(white: 0.86, alpha: 1)
            }
        }
    }
}

// MARK: - Bounds accumulator

private struct BoundsAccumulator {
    var mn = simd_float3(repeating:  Float.infinity)
    var mx = simd_float3(repeating: -Float.infinity)

    mutating func expand(t: simd_float4x4, dims: simd_float3) {
        let p = t.translation
        let h = dims / 2
        for dx in [-h.x, h.x] {
            for dy in [-h.y, h.y] {
                for dz in [-h.z, h.z] {
                    let c = p + simd_float3(dx, dy, dz)
                    mn = simd_min(mn, c); mx = simd_max(mx, c)
                }
            }
        }
    }

    var center: simd_float3 { mn.x == .infinity ? .zero : (mn + mx) * 0.5 }
    var size:   simd_float3 { mn.x == .infinity ? simd_float3(4, 2.5, 4) : (mx - mn) }
}
