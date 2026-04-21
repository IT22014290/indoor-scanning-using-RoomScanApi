import SceneKit
import RoomPlan
import simd
import UIKit

/// Renders the RoomPlan structured model in real-time using SceneKit.
/// Matches the Apple RoomPlan aesthetic: beige walls, grey floor, grey furniture,
/// with floating dimension labels.
@MainActor
final class StructuredModelRenderer: NSObject, ObservableObject {

    let scene = SCNScene()
    private var rootNode: SCNNode { scene.rootNode }

    // Node containers by surface identifier
    private var wallNodes:   [UUID: SCNNode] = [:]
    private var floorNodes:  [UUID: SCNNode] = [:]
    private var objectNodes: [UUID: SCNNode] = [:]
    private var labelNodes:  [UUID: SCNNode] = [:]
    private var originGizmo: SCNNode?

    // MARK: - Palette
    private let wallColor    = UIColor(red: 0.90, green: 0.85, blue: 0.78, alpha: 1)
    private let floorColor   = UIColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1)
    private let objectColor  = UIColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1)
    private let unscanColor  = UIColor.systemYellow.withAlphaComponent(0.4)
    private let labelColor   = UIColor(white: 0.2, alpha: 0.85)
    private let labelTextColor = UIColor.white

    override init() {
        super.init()
        setupScene()
    }

    // MARK: - Public update API (called on every CapturedRoom update)

    func update(from room: CapturedRoom, qrTransform: simd_float4x4) {
        let qrInverse = simd_inverse(qrTransform)

        // Walls
        sync(surfaces: room.walls,
             nodeDict: &wallNodes,
             color: wallColor,
             qrInverse: qrInverse,
             labelPrefix: "")

        // Floors (iOS 17+; silently skipped on iOS 16 — synthesised at export time)
        if #available(iOS 17.0, *) {
            sync(surfaces: room.floors,
                 nodeDict: &floorNodes,
                 color: floorColor,
                 qrInverse: qrInverse,
                 labelPrefix: nil)
        }

        // Doors/windows as openings
        for surface in room.doors {
            let id = surface.identifier
            let node = wallNodes[id] ?? makeNode()
            let t = qrInverse * surface.transform
            apply(transform: t, dimensions: surface.dimensions,
                  color: UIColor(white: 0.7, alpha: 0.3), to: node)
            if wallNodes[id] == nil {
                rootNode.addChildNode(node)
                wallNodes[id] = node
            }
        }

        // Objects
        for object in room.objects {
            let id = object.identifier
            let node = objectNodes[id] ?? makeNode()
            let t = qrInverse * object.transform
            apply(transform: t, dimensions: object.dimensions, color: objectColor, to: node)
            if objectNodes[id] == nil {
                node.opacity = 0
                rootNode.addChildNode(node)
                objectNodes[id] = node
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.4
                node.opacity = 1
                SCNTransaction.commit()
            }
            updateLabel(for: id, text: dimensionLabel(object.dimensions), node: node)
        }

        removeStale(current: Set(room.walls.map { $0.identifier }),   dict: &wallNodes)
        if #available(iOS 17.0, *) {
            removeStale(current: Set(room.floors.map { $0.identifier }), dict: &floorNodes)
        }
        removeStale(current: Set(room.objects.map { $0.identifier }), dict: &objectNodes)
    }

    // MARK: - QR origin gizmo

    func showOriginGizmo(at transform: simd_float4x4) {
        originGizmo?.removeFromParentNode()
        let gizmo = SCNNode()

        func axis(color: UIColor, direction: simd_float3) -> SCNNode {
            let cyl = SCNCylinder(radius: 0.02, height: 0.5)
            cyl.firstMaterial?.diffuse.contents = color
            cyl.firstMaterial?.lightingModel = .constant
            let n = SCNNode(geometry: cyl)
            n.simdPosition = direction * 0.25
            n.simdLocalRotate(by: simd_quatf(from: simd_float3(0,1,0), to: direction))
            return n
        }

        gizmo.addChildNode(axis(color: .red,   direction: simd_float3(1,0,0)))
        gizmo.addChildNode(axis(color: .green, direction: simd_float3(0,1,0)))
        gizmo.addChildNode(axis(color: .blue,  direction: simd_float3(0,0,1)))

        let label = textNode("QR Origin", size: 0.08, color: .white)
        label.simdPosition = simd_float3(0, 0.6, 0)
        gizmo.addChildNode(label)

        gizmo.simdTransform = transform
        rootNode.addChildNode(gizmo)
        originGizmo = gizmo
    }

    // MARK: - Private helpers

    private func setupScene() {
        scene.background.contents = UIColor(white: 0.12, alpha: 1)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 800
        rootNode.addChildNode(ambient)

        let directional = SCNNode()
        directional.light = SCNLight()
        directional.light?.type = .directional
        directional.light?.intensity = 1200
        directional.light?.castsShadow = true
        directional.simdPosition = simd_float3(5, 10, 5)
        directional.simdLook(at: .zero)
        rootNode.addChildNode(directional)
    }

    private func sync(surfaces: [CapturedRoom.Surface],
                       nodeDict: inout [UUID: SCNNode],
                       color: UIColor,
                       qrInverse: simd_float4x4,
                       labelPrefix: String?) {
        for surface in surfaces {
            let id = surface.identifier
            let node = nodeDict[id] ?? makeNode()
            let t = qrInverse * surface.transform
            apply(transform: t, dimensions: surface.dimensions, color: color, to: node)
            if nodeDict[id] == nil {
                rootNode.addChildNode(node)
                nodeDict[id] = node
            }
            if let prefix = labelPrefix {
                let text = prefix + dimensionLabel(surface.dimensions)
                updateLabel(for: id, text: text, node: node)
            }
        }
    }

    private func makeNode() -> SCNNode {
        let node = SCNNode()
        return node
    }

    private func apply(transform: simd_float4x4,
                        dimensions: simd_float3,
                        color: UIColor,
                        to node: SCNNode) {
        if let box = node.geometry as? SCNBox {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.2
            box.width  = CGFloat(dimensions.x)
            box.height = CGFloat(dimensions.y)
            box.length = CGFloat(dimensions.z)
            node.simdTransform = transform
            SCNTransaction.commit()
        } else {
            let box = SCNBox(width: CGFloat(dimensions.x),
                             height: CGFloat(dimensions.y),
                             length: CGFloat(dimensions.z),
                             chamferRadius: 0.01)
            let mat = SCNMaterial()
            mat.diffuse.contents = color
            mat.lightingModel = .lambert
            box.materials = [mat]
            node.geometry = box
            node.simdTransform = transform
        }
    }

    private func updateLabel(for id: UUID, text: String, node: SCNNode) {
        if let existing = labelNodes[id] {
            (existing.geometry as? SCNText)?.string = text
        } else {
            let label = textNode(text, size: 0.06, color: labelTextColor)
            label.simdPosition = simd_float3(0, 0.1, 0)
            node.addChildNode(label)
            labelNodes[id] = label
        }
    }

    private func textNode(_ text: String, size: CGFloat, color: UIColor) -> SCNNode {
        let scnText = SCNText(string: text, extrusionDepth: 0.005)
        scnText.font = UIFont.systemFont(ofSize: size * 100, weight: .semibold)
        scnText.flatness = 0.1
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .constant
        scnText.materials = [mat]

        let node = SCNNode(geometry: scnText)
        // Centre the text
        let (min, max) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((max.x - min.x)/2, 0, 0)
        node.scale = SCNVector3(0.01, 0.01, 0.01)
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    private func dimensionLabel(_ dims: simd_float3) -> String {
        let w = Int(dims.x * 100)
        let h = Int(dims.y * 100)
        let d = Int(dims.z * 100)
        if d < 5 { return "\(w) × \(h) cm" }
        return "\(w) × \(h) × \(d) cm"
    }

    private func removeStale(current: Set<UUID>, dict: inout [UUID: SCNNode]) {
        for id in Set(dict.keys).subtracting(current) {
            dict[id]?.removeFromParentNode()
            labelNodes[id]?.removeFromParentNode()
            dict.removeValue(forKey: id)
            labelNodes.removeValue(forKey: id)
        }
    }
}
