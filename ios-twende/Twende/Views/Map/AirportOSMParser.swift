import Foundation

/// Resolves complete ways from bundled OSM XML off the UI thread; unrelated city tags are discarded.
nonisolated final class AirportOSMParser: NSObject, XMLParserDelegate {
    private var nodes: [Int: [Double]] = [:]
    private var references: [Int] = []
    private var tags: [String: String] = [:]
    private var currentID: Int = 0
    private var currentKind: String = ""
    private var coordinate: [Double] = []
    private(set) var features: [AirportMapData.Feature] = []
    private(set) var points: [AirportMapData.Feature] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "node" || name == "way" {
            currentKind = name; currentID = Int(attributes["id"] ?? "") ?? 0
            tags.removeAll(keepingCapacity: true); references.removeAll(keepingCapacity: true)
            coordinate = []
            if name == "node", let lon = Double(attributes["lon"] ?? ""), let lat = Double(attributes["lat"] ?? ""), lon.isFinite, lat.isFinite {
                coordinate = [lon, lat]; nodes[currentID] = coordinate
            }
        } else if name == "nd", let id = Int(attributes["ref"] ?? "") { references.append(id) }
        else if name == "tag", let key = attributes["k"], let value = attributes["v"] { tags[key] = value }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == currentKind else { return }
        if name == "way", tags.keys.contains(where: { ["building", "aeroway", "highway", "barrier", "landuse", "landcover", "natural", "leisure", "amenity", "man_made"].contains($0) }) {
            let coordinates = references.compactMap { nodes[$0] }
            if coordinates.count == references.count, coordinates.count >= 2, coordinates.count <= 512 {
                features.append(.init(id: currentID, tags: tags, coordinates: coordinates))
            }
        } else if name == "node", coordinate.count == 2,
                  tags["natural"] == "tree" || tags["barrier"] != nil || tags["highway"] == "street_lamp" || tags["aeroway"] == "gate" {
            points.append(.init(id: currentID, tags: tags, coordinates: [coordinate]))
        }
        currentKind = ""
    }
}
