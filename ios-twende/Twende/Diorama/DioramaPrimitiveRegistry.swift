import Foundation

/// Generation-local prototype pool. It is never shared across concurrent tile jobs.
/// Keys retain exact dimensions; no quantization, tessellation reduction or material substitution.
nonisolated final class DioramaPrimitiveRegistry: @unchecked Sendable {
    nonisolated struct Key: Hashable {
        let kind: String
        let parameters: [UInt64]
        let flags: [Int]
    }

    nonisolated struct Entry: Sendable {
        let prototype: DioramaPrototype
        let kind: String
        var placements: Int
    }

    private let firstID: Int
    private var lookup: [Key: Int] = [:]
    private(set) var entries: [Entry] = []

    init(firstID: Int) { self.firstID = firstID }

    func prototype(kind: String, parameters: [Double], flags: [Int], doubleSided: Bool,
                   build: (inout DioramaMesh) -> Void) -> DioramaPrototype {
        let key = Key(kind: kind, parameters: parameters.map { $0 == 0 ? 0 : $0.bitPattern },
                      flags: flags + [doubleSided ? 1 : 0])
        if let index = lookup[key] {
            entries[index].placements += 1
            return entries[index].prototype
        }
        var mesh = DioramaMesh()
        mesh.doubleSided = doubleSided
        build(&mesh)
        let prototype = DioramaPrototype(id: firstID + entries.count, full: mesh)
        lookup[key] = entries.count
        entries.append(Entry(prototype: prototype, kind: kind, placements: 1))
        return prototype
    }

    var prototypes: [DioramaPrototype] { entries.map(\.prototype) }

    /// Prototype/placement buffer savings against expanded primitives, excluding bin metadata and
    /// any extra prototype copy needed by a different shader category. Singletons are baked back.
    var report: [String] {
        let byKind = Dictionary(grouping: entries.filter { $0.placements > 1 }, by: \.kind)
        return byKind.keys.sorted().map { kind in
            let entries = byKind[kind] ?? []
            let placements = entries.reduce(0) { $0 + $1.placements }
            let removed = entries.reduce(0) { $0 + ($1.placements - 1) * $1.prototype.full.triangleCount }
            let gross = entries.reduce(0) { sum, entry in
                sum + (entry.placements - 1) * (entry.prototype.full.positions.count * MemoryLayout<BuildingRenderVertex>.stride + entry.prototype.full.indices.count * 4)
            }
            let net = gross - placements * MemoryLayout<DioramaInstanceData>.stride
            return "\(kind): \(placements) placements / \(entries.count) prototypes · \(removed) stored tris removed · \(String(format: "%.2f", Double(net) / 1_048_576)) MiB net"
        }
    }
}
