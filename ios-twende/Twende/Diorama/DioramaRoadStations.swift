import Foundation

/// Continuous signed arc length across two-way OSM splits. Branches deliberately reset the pattern;
/// reversing a source way never reverses dash phase at its connection.
nonisolated enum DioramaRoadStations {
    static func build(_ roads: [DioramaRoadFeature]) -> [UInt64: (offset: Double, direction: Double)] {
        var ends: [String: [(index: Int, atStart: Bool)]] = [:]
        func key(_ p: DV2) -> String { "\(Int64((p.x * 10).rounded())):\(Int64((p.y * 10).rounded()))" }
        for i in roads.indices {
            guard let a = roads[i].line.first, let b = roads[i].line.last else { continue }
            ends[key(a), default: []].append((i, true))
            ends[key(b), default: []].append((i, false))
        }
        let lengths = roads.map { DioramaPolygon.length($0.line) }
        var result: [UInt64: (offset: Double, direction: Double)] = [:]
        for root in roads.indices.sorted(by: { roads[$0].id < roads[$1].id }) where result[roads[root].id] == nil {
            result[roads[root].id] = (0, 1)
            var queue = [root]
            var cursor = 0
            while cursor < queue.count {
                let i = queue[cursor]; cursor += 1
                guard let station = result[roads[i].id], let first = roads[i].line.first, let last = roads[i].line.last else { continue }
                for atStart in [true, false] {
                    let peers = ends[key(atStart ? first : last)] ?? []
                    guard peers.count == 2, let peer = peers.first(where: { $0.index != i }) else { continue }
                    let j = peer.index
                    guard result[roads[j].id] == nil, roads[j].width == roads[i].width, roads[j].isPaved == roads[i].isPaved else { continue }
                    let atNode = station.offset + station.direction * (atStart ? 0 : lengths[i])
                    let away = atStart ? -station.direction : station.direction
                    let sign = peer.atStart ? away : -away
                    result[roads[j].id] = (atNode - sign * (peer.atStart ? 0 : lengths[j]), sign)
                    queue.append(j)
                }
            }
        }
        return result
    }
}
