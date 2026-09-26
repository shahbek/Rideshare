import SceneKit
import UIKit

/// Studio-lit miniature with a geometry-projected alpha shadow on the road plane.
/// UIKit annotations sit outside Mapbox's 3D lighting; shadow pixels must carry their own alpha.
final class VehicleMiniatureScene {
    let scene: SCNScene = SCNScene()
    let camera: SCNNode = SCNNode()
    private let vehicle: SCNNode = SCNNode()
    private let sun: SCNNode = SCNNode()
    private let groundShadow: SCNNode = SCNNode()
    private let shadowMaterial: SCNMaterial = SCNMaterial()
    private var shadowDirection: Int = -1
    private var heading: Double = 0
    private(set) var tier: RideTier

    init(tier: RideTier) {
        self.tier = tier
        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = Self.studioEnvironment
        scene.lightingEnvironment.intensity = 0.7
        vehicle.addChildNode(ProceduralVehicleFactory.makeVehicle(for: tier))
        scene.rootNode.addChildNode(vehicle)

        let lens = SCNCamera()
        lens.usesOrthographicProjection = true
        lens.orthographicScale = 3.1
        lens.zNear = 0.1
        lens.zFar = 40
        lens.wantsHDR = true
        lens.wantsExposureAdaptation = false
        lens.exposureOffset = 0
        lens.bloomThreshold = 1.1
        lens.bloomIntensity = 0.9
        lens.bloomBlurRadius = 3
        camera.camera = lens
        scene.rootNode.addChildNode(camera)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 220
        scene.rootNode.addChildNode(ambient)

        let light = SCNLight()
        light.type = .directional
        light.intensity = 520
        // A deferred shadow pass cannot darken Mapbox's separate render target.
        light.castsShadow = false
        sun.light = light
        scene.rootNode.addChildNode(sun)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .omni
        fill.light?.intensity = 110
        fill.position = SCNVector3(4, 3, 5)
        scene.rootNode.addChildNode(fill)

        let ground = SCNPlane(width: VehicleGroundShadow.extent, height: VehicleGroundShadow.extent)
        shadowMaterial.lightingModel = .constant
        shadowMaterial.isDoubleSided = true
        shadowMaterial.blendMode = .alpha
        shadowMaterial.transparencyMode = .aOne
        shadowMaterial.diffuse.wrapS = .clamp
        shadowMaterial.diffuse.wrapT = .clamp
        shadowMaterial.diffuse.minificationFilter = .linear
        shadowMaterial.diffuse.magnificationFilter = .linear
        shadowMaterial.writesToDepthBuffer = false
        shadowMaterial.readsFromDepthBuffer = true
        ground.materials = [shadowMaterial]
        groundShadow.geometry = ground
        groundShadow.name = "geometry-ground-shadow"
        groundShadow.castsShadow = false
        groundShadow.renderingOrder = -10
        groundShadow.eulerAngles.x = -.pi / 2
        groundShadow.position.y = -0.008
        scene.rootNode.addChildNode(groundShadow)
        update(heading: 0, bearing: 0, pitch: 45)
    }

    func setTier(_ tier: RideTier) {
        guard tier != self.tier else { return }
        self.tier = tier
        vehicle.childNodes.forEach { $0.removeFromParentNode() }
        vehicle.addChildNode(ProceduralVehicleFactory.makeVehicle(for: tier))
        updateShadow(heading: heading, force: true)
    }

    /// Exposed for a shadow-on/off render regression, independent of lighting or antialiasing.
    func setGroundShadowVisible(_ visible: Bool) {
        groundShadow.isHidden = !visible
    }

    private func updateShadow(heading: Double, force: Bool = false) {
        let direction = VehicleGroundShadow.direction(for: heading)
        guard force || direction != shadowDirection else { return }
        shadowDirection = direction
        shadowMaterial.diffuse.contents = VehicleGroundShadow.image(for: tier, direction: direction)
    }

    func update(heading: Double, bearing: Double, pitch: Double) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        self.heading = heading
        vehicle.eulerAngles.y = Float(-(heading - bearing) * .pi / 180)
        groundShadow.eulerAngles = SCNVector3(-Float.pi / 2, vehicle.eulerAngles.y, 0)
        updateShadow(heading: heading)
        let elevation = Float((90 - min(max(pitch, 0), 75)) * .pi / 180)
        camera.position = SCNVector3(0, 8 * sin(elevation), 8 * cos(elevation))
        // Explicit Euler rotation also handles a straight-down camera without a degenerate look-at up vector.
        camera.eulerAngles = SCNVector3(-elevation, 0, 0)
        let azimuth = Float((bearing - 35) * .pi / 180)
        sun.position = SCNVector3(6 * sin(azimuth), VehicleGroundShadow.lightHeight, 6 * cos(azimuth))
        sun.look(at: SCNVector3Zero)
        SCNTransaction.commit()
    }

    /// A tiny procedural studio panorama supplies broad softbox reflections to paint, glass and metal.
    private static let studioEnvironment: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 512, height: 256), format: format).image { context in
            let cg = context.cgContext
            let colors = [UIColor(white: 0.95, alpha: 1).cgColor, UIColor(white: 0.50, alpha: 1).cgColor, UIColor(white: 0.18, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.5, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
            }
            UIColor(white: 1, alpha: 0.9).setFill()
            UIBezierPath(roundedRect: CGRect(x: 64, y: 18, width: 100, height: 86), cornerRadius: 18).fill()
            UIColor(white: 1, alpha: 0.65).setFill()
            UIBezierPath(roundedRect: CGRect(x: 345, y: 38, width: 28, height: 122), cornerRadius: 12).fill()
        }
    }()
}
