import SceneKit
import UIKit

/// Map-scale colour fields, not photographic materials. No grain, masonry, timber or tile textures.
enum BuildingSurfaces {
    static let glass = make("quiet blue-grey glazing", color: "#52646A", roughness: 0.40, metalness: 0.08)
    static let slate = make("muted slate roof", color: "#4C504F", roughness: 0.82)
    static let terracotta = make("natural terracotta roof", color: "#AD583D", roughness: 0.82)
    static let zinc = make("weathered zinc roof", color: "#81847E", roughness: 0.70, metalness: 0.05)
    static let membrane = make("light roof plane", color: "#B7B0A2", roughness: 0.85)

    static func make(_ name: String, color hex: String, roughness: CGFloat, metalness: CGFloat = 0) -> SCNMaterial {
        let material = SCNMaterial()
        material.name = name
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color(hex)
        material.roughness.contents = roughness
        material.metalness.contents = metalness
        material.isDoubleSided = true
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = true
        return material
    }

    static func color(_ hex: String) -> UIColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xE6EAED
        return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    private static var walls: [BuildingMaterialStyle: SCNMaterial] = [:]

    static func wall(_ style: BuildingMaterialStyle) -> SCNMaterial {
        if let existing = walls[style] { return existing }
        let material = make("\(style) smooth wall", color: style.wall, roughness: 0.85)
        walls[style] = material
        return material
    }

}
