import Foundation
import Metal
import CoreLocation
import simd

/// Combines only selected packed chunks for one shadow/AO/bloom renderer. No float vertex expansion.
nonisolated enum AirportResidentAssembly {
    static func combine(device: MTLDevice, tileID: DioramaTileID, counts: SIMD3<Int>, chunkCount: Int,
                        rect: DioramaRect, nativeOnly: [[DV2]], load: (Int) throws -> DioramaResidentTile) throws -> DioramaResidentTile {
        func buffer(_ bytes: Int) throws -> MTLBuffer {
            guard let result = device.makeBuffer(length: max(16, bytes), options: .storageModeShared) else { throw DioramaTileArchive.ArchiveError.invalid }
            return result
        }
        func upload<T>(_ values: [T]) throws -> MTLBuffer {
            let result = try buffer(values.count * MemoryLayout<T>.stride)
            values.withUnsafeBytes { bytes in if let base = bytes.baseAddress { result.contents().copyMemory(from: base, byteCount: bytes.count) } }
            return result
        }
        let vertexCount = counts.x, indexCount = counts.y, instanceCount = counts.z
        var groundTexture: MTLTexture?
        let vertices = try buffer(vertexCount * MemoryLayout<DioramaPackedVertex>.stride)
        let indices = try buffer(indexCount * 4), instances = try buffer(instanceCount * MemoryLayout<DioramaInstanceData>.stride)
        var ranges: [DioramaRenderLayer.Range] = [], groups: [DioramaInstanceGroup] = []
        var paint: [Int: DioramaPaintTriangle] = [:], sources: [DioramaLight] = []
        var seenLights: Set<SIMD4<Float>> = []
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        var vBase = 0, iBase = 0, pBase = 0
        for item in 0..<chunkCount {
            try Task.checkCancellation()
            let tile = try load(item)
            guard tile.vertexCount <= vertexCount - vBase, tile.indexCount <= indexCount - iBase,
                  tile.instanceCount <= instanceCount - pBase else { throw DioramaTileArchive.ArchiveError.invalid }
            if groundTexture == nil { groundTexture = tile.groundTexture }
            vertices.contents().advanced(by: vBase * MemoryLayout<DioramaPackedVertex>.stride).copyMemory(from: tile.vertexBuffer.contents(), byteCount: tile.vertexCount * MemoryLayout<DioramaPackedVertex>.stride)
            let output = indices.contents().assumingMemoryBound(to: UInt32.self)
            for i in 0..<tile.indexCount { output[iBase + i] = tile.index(i) + UInt32(vBase) }
            instances.contents().advanced(by: pBase * MemoryLayout<DioramaInstanceData>.stride).copyMemory(from: tile.instanceBuffer.contents(), byteCount: tile.instanceCount * MemoryLayout<DioramaInstanceData>.stride)
            for r in tile.ranges {
                let bounds = DioramaRect(minX: Double(r.minimum.x), minY: Double(r.minimum.y), maxX: Double(r.maximum.x), maxY: Double(r.maximum.y))
                let masks = r.category == .buildings || r.category == .windowGlow ? nativeOnly.filter { DioramaRect.bounding($0).expanded(by: 1).intersects(bounds) } : []
                var runs: [(Int, Int)] = [], start: Int?
                for offset in stride(from: r.start, to: r.start + r.count - 2, by: 3) {
                    let p = (tile.position(Int(tile.index(offset))) + tile.position(Int(tile.index(offset + 1))) + tile.position(Int(tile.index(offset + 2)))) / 3
                    let point = DV2(Double(p.x), Double(p.y))
                    let blocked = masks.contains { DioramaPolygon.contains($0, point) || DioramaPolygon.distanceToRing($0, point) < 1 }
                    if blocked, let begin = start { runs.append((begin, offset - begin)); start = nil }
                    if !blocked && start == nil { start = offset }
                }
                if let start { runs.append((start, r.start + r.count - start)) }
                for (start, count) in runs {
                    ranges.append(.init(category: r.category, start: start + iBase, count: count, minimum: r.minimum, maximum: r.maximum, doubleSided: r.doubleSided, translucent: r.translucent))
                }
                if !runs.isEmpty { low = simd_min(low, r.minimum); high = simd_max(high, r.maximum) }
            }
            for g in tile.groups {
                groups.append(.init(category: g.category, fullStart: g.fullStart + iBase, fullCount: g.fullCount, lightStart: g.lightStart + iBase, lightCount: g.lightCount,
                    doubleSided: g.doubleSided, instances: g.instances, firstInstance: g.firstInstance + pBase, minimum: g.minimum, maximum: g.maximum))
                low = simd_min(low, g.minimum); high = simd_max(high, g.maximum)
            }
            let count = tile.paintBuffer.length / MemoryLayout<DioramaPaintTriangle>.stride
            let records = tile.paintBuffer.contents().assumingMemoryBound(to: DioramaPaintTriangle.self)
            for i in 0..<count {
                let t = records[i]
                guard [t.edge0, t.edge1, t.edge2, t.color].allSatisfy({ v in (0..<4).allSatisfy { v[$0].isFinite && abs(v[$0]) < 500_000 } }),
                      t.color.w >= -8, t.color.w <= 1, t.edge0.w >= 0, t.edge0.w < 100_000,
                      t.edge1.w >= 0, t.edge1.w < 500_000, t.edge1.w.rounded(.towardZero) == t.edge1.w,
                      let bounds = AirportSpatialPackage.paintBounds(t), [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy({ abs($0) < 10_000 }) else { throw DioramaTileArchive.ArchiveError.invalid }
                let ordinal = Int(t.edge1.w)
                if let previous = paint[ordinal] {
                    guard previous.edge0 == t.edge0, previous.edge1 == t.edge1, previous.edge2 == t.edge2, previous.color == t.color else { throw DioramaTileArchive.ArchiveError.invalid }
                } else { paint[ordinal] = t }
            }
            for light in tile.lightGrid.lights where seenLights.insert(light.position).inserted {
                sources.append(.init(position: DV3(Double(light.position.x), Double(light.position.y), Double(light.position.z)), color: SIMD3(light.color.x, light.color.y, light.color.z), radius: Double(light.position.w), intensity: light.color.w))
            }
            vBase += tile.vertexCount; iBase += tile.indexCount; pBase += tile.instanceCount
        }
        guard vBase == vertexCount, iBase == indexCount, pBase == instanceCount else { throw DioramaTileArchive.ArchiveError.invalid }
        let marks = AirportSpatialPackage.rebinned(paint.keys.sorted().compactMap { paint[$0] }, rect: rect)
        let summary = DioramaTileSummary(shorelineReport: [], optimizationReport: ["\(chunkCount) airport chunks in one shared effect renderer"], stageTimings: [], totalTriangles: indexCount / 3, totalInstances: instanceCount, totalBytes: vertices.length + indices.length + instances.length, generationSeconds: 0)
        let vertexValues = vertices.contents().assumingMemoryBound(to: DioramaPackedVertex.self)
        let indexValues = indices.contents().assumingMemoryBound(to: UInt32.self)
        let ground = DioramaGroundIndex(rect: rect, ranges: ranges, index: { indexValues[$0] }, position: { vertexValues[$0].position }, isGround: { vertexValues[$0].color.w == DioramaHalf.bits(9) })
        return DioramaResidentTile(tile: tileID, device: device, vertexBuffer: vertices, vertexCount: vertexCount, indexBuffer: indices, indexCount: indexCount,
            instanceBuffer: instances, instanceCount: instanceCount, ranges: ranges, groups: groups,
            lightGrid: DioramaLightGrid.build(sources, rect: rect, cells: 96, perCell: 16), paintBuffer: try upload(marks.triangles), paintTableBuffer: try upload(marks.table), paintIndexBuffer: try upload(marks.indices),
            groundTexture: groundTexture, waterHeight: 0, labels: [], poolBounds: nil, shadowBounds: low.x <= high.x ? (low, high) : nil, materialCounts: .zero, summary: summary, groundIndex: ground)
    }
}
