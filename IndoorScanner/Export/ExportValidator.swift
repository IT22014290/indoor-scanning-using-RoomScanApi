import Foundation
import UIKit
import SceneKit
import simd

/// Validates the export bundle and renders a top-down orthographic thumbnail.
struct ExportValidator {

    struct ValidationResult {
        var isValid: Bool
        var warnings: [String]
        var triangleCount: Int
        var floorAreaM2: Double
    }

    // MARK: - Validation

    static func validate(mesh: MeshPostProcessor.ProcessedMesh,
                          bounds: BoundingBox3D) -> ValidationResult {
        var warnings = [String]()

        // Triangle budget
        let triCount = mesh.triangleCount
        if triCount > 500_000 {
            warnings.append("Triangle count \(triCount) exceeds 500K NavMesh budget")
        }

        // Floor flatness check
        let yRange = bounds.maxY - bounds.minY
        if yRange > 3.5 {
            warnings.append("Vertical range \(String(format: "%.1f", yRange))m is unusually large")
        }

        // Open mesh detection (each edge should appear in at most 2 triangles)
        let openEdges = findOpenEdges(mesh)
        if openEdges > 0 {
            warnings.append("Mesh has \(openEdges) open edges — may cause NavMesh gaps")
        }

        let area = Double(bounds.maxX - bounds.minX) * Double(bounds.maxZ - bounds.minZ)

        return ValidationResult(
            isValid: warnings.isEmpty,
            warnings: warnings,
            triangleCount: triCount,
            floorAreaM2: area
        )
    }

    // MARK: - Thumbnail renderer

    /// Renders a top-down orthographic view of the geometry as a PNG.
    static func renderThumbnail(geometry: MultiRoomStitcher.MergedGeometry,
                                  size: CGSize = CGSize(width: 1024, height: 768)) -> UIImage {
        let scene = SCNScene()
        let bounds = geometry.bounds

        // Walls
        for wall in geometry.walls {
            let node = boxNode(transform: wall.transform,
                               dims: wall.dimensions,
                               color: UIColor(red: 0.90, green: 0.85, blue: 0.78, alpha: 1))
            scene.rootNode.addChildNode(node)
        }

        // Floors
        for floor in geometry.floors {
            var t = floor.transform; t.columns.3.y = 0
            let node = boxNode(transform: t,
                               dims: simd_float3(floor.dimensions.x, 0.02, floor.dimensions.z),
                               color: UIColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1))
            scene.rootNode.addChildNode(node)
        }

        // Aisles
        for aisle in geometry.aisles {
            var t = aisle.transform; t.columns.3.y = 0.03
            let node = boxNode(transform: t,
                               dims: simd_float3(aisle.dimensions.x, 0.04, aisle.dimensions.z),
                               color: UIColor(red: 0.20, green: 0.75, blue: 0.35, alpha: 0.75))
            scene.rootNode.addChildNode(node)
        }

        // Objects
        for obj in geometry.objects {
            let node = boxNode(transform: obj.transform,
                               dims: obj.dimensions,
                               color: UIColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1))
            scene.rootNode.addChildNode(node)
        }

        // Camera — orthographic top-down
        let camNode = SCNNode()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        let sceneWidth  = Double(bounds.maxX - bounds.minX)
        let sceneDepth  = Double(bounds.maxZ - bounds.minZ)
        camera.orthographicScale = max(sceneWidth, sceneDepth) / 2.0 + 1.0
        camNode.camera = camera
        let cx = (bounds.minX + bounds.maxX) / 2
        let cz = (bounds.minZ + bounds.maxZ) / 2
        camNode.position = SCNVector3(cx, 20, cz)
        camNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(camNode)

        // Light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 1200
        scene.rootNode.addChildNode(ambientLight)

        // Render
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camNode

        let renderDesc = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return renderDesc
    }

    // MARK: - Private helpers

    private static func boxNode(transform: simd_float4x4,
                                 dims: simd_float3,
                                 color: UIColor) -> SCNNode {
        let box = SCNBox(width: CGFloat(dims.x),
                         height: CGFloat(dims.y),
                         length: CGFloat(dims.z),
                         chamferRadius: 0)
        box.firstMaterial?.diffuse.contents = color
        box.firstMaterial?.lightingModel = .lambert
        let node = SCNNode(geometry: box)
        node.simdTransform = transform
        return node
    }

    private static func findOpenEdges(_ mesh: MeshPostProcessor.ProcessedMesh) -> Int {
        var edgeCount = [String: Int]()
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let i0 = mesh.indices[i]
            let i1 = mesh.indices[i+1]
            let i2 = mesh.indices[i+2]
            for edge in [(min(i0,i1), max(i0,i1)),
                         (min(i1,i2), max(i1,i2)),
                         (min(i2,i0), max(i2,i0))] {
                let key = "\(edge.0)_\(edge.1)"
                edgeCount[key, default: 0] += 1
            }
        }
        return edgeCount.values.filter { $0 == 1 }.count
    }
}
