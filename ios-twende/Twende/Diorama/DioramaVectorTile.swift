import Foundation

/// Minimal bounded MVT reader for Mapbox Streets geometry and attributes; no rendering dependency.
nonisolated enum DioramaVectorTile {
    struct Feature: Sendable {
        let id: UInt64
        let type: UInt64
        let properties: [String: String]
        let paths: [[DV2]]
    }
    struct Layer: Sendable {
        let name: String
        let extent: Double
        let features: [Feature]
    }
    enum Failure: Error { case malformed }
    private struct Field {
        let number: Int
        let wire: Int
        var value: UInt64 = 0
        var bytes: [UInt8] = []
    }
    private struct Reader {
        let bytes: [UInt8]
        var offset: Int = 0
        mutating func uint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw Failure.malformed }
                let b = bytes[offset]; offset += 1
                guard shift != 63 || b <= 1 else { throw Failure.malformed }
                value |= UInt64(b & 127) << shift
                if b < 128 { return value }
            }
            throw Failure.malformed
        }
        mutating func fields() throws -> [Field] {
            var result: [Field] = []
            while offset < bytes.count {
                let key = try uint(), wire = Int(key & 7)
                guard key >> 3 > 0 else { throw Failure.malformed }
                var f = Field(number: Int(key >> 3), wire: wire)
                switch wire {
                case 0: f.value = try uint()
                case 1, 5:
                    let count = wire == 1 ? 8 : 4
                    guard offset + count <= bytes.count else { throw Failure.malformed }
                    for i in 0..<count { f.value |= UInt64(bytes[offset + i]) << (i * 8) }
                    offset += count
                case 2:
                    let length = try uint()
                    guard length <= UInt64(bytes.count - offset) else { throw Failure.malformed }
                    f.bytes = Array(bytes[offset..<(offset + Int(length))]); offset += Int(length)
                default: throw Failure.malformed
                }
                result.append(f)
            }
            return result
        }
    }
    private static func fields(_ bytes: [UInt8]) throws -> [Field] {
        var reader = Reader(bytes: bytes)
        return try reader.fields()
    }
    private static func packed(_ bytes: [UInt8]) throws -> [UInt64] {
        var reader = Reader(bytes: bytes), values: [UInt64] = []
        while reader.offset < bytes.count { values.append(try reader.uint()) }
        return values
    }
    private static func value(_ bytes: [UInt8]) throws -> String {
        guard let f = try fields(bytes).first else { return "" }
        switch f.number {
        case 1: return String(decoding: f.bytes, as: UTF8.self)
        case 2: return String(Float(bitPattern: UInt32(truncatingIfNeeded: f.value)))
        case 3: return String(Double(bitPattern: f.value))
        case 4: return String(Int64(bitPattern: f.value))
        case 5: return String(f.value)
        case 6: return String(Int64(bitPattern: f.value >> 1) ^ -Int64(f.value & 1))
        case 7: return f.value == 0 ? "false" : "true"
        default: return ""
        }
    }
    private static func geometry(_ commands: [UInt64]) throws -> [[DV2]] {
        var paths: [[DV2]] = [], current: [DV2] = []
        var x: Int64 = 0, y: Int64 = 0, i = 0
        while i < commands.count {
            let cmd = commands[i] & 7, count = commands[i] >> 3; i += 1
            guard count > 0, count <= 1_000_000 else { throw Failure.malformed }
            if cmd == 7 {
                guard count == 1 else { throw Failure.malformed }
                if !current.isEmpty { paths.append(current); current = [] }
                continue
            }
            guard cmd == 1 || cmd == 2, count <= UInt64((commands.count - i) / 2) else { throw Failure.malformed }
            for _ in 0..<Int(count) {
                if cmd == 1, !current.isEmpty { paths.append(current); current = [] }
                let dx = Int64(bitPattern: commands[i] >> 1) ^ -Int64(commands[i] & 1)
                let dy = Int64(bitPattern: commands[i + 1] >> 1) ^ -Int64(commands[i + 1] & 1)
                guard dx > -10_000_000, dx < 10_000_000, dy > -10_000_000, dy < 10_000_000 else { throw Failure.malformed }
                x += dx; y += dy; i += 2
                guard abs(x) < 10_000_000, abs(y) < 10_000_000 else { throw Failure.malformed }
                current.append(DV2(Double(x), Double(y)))
            }
        }
        if !current.isEmpty { paths.append(current) }
        return paths
    }
    static func decode(_ data: Data) throws -> [Layer] {
        guard data.count <= 12_000_000 else { throw Failure.malformed }
        var result: [Layer] = []
        for field in try fields(Array(data)) where field.number == 3 {
            let layer = try fields(field.bytes)
            let name = String(decoding: layer.first(where: { $0.number == 1 })?.bytes ?? [], as: UTF8.self)
            guard ["building", "road", "poi_label", "landuse", "landcover"].contains(name) else { continue }
            let extent = Double(layer.first(where: { $0.number == 5 })?.value ?? 4096)
            guard extent > 0 else { throw Failure.malformed }
            let keys = layer.filter { $0.number == 3 }.map { String(decoding: $0.bytes, as: UTF8.self) }
            let values = try layer.filter { $0.number == 4 }.map { try value($0.bytes) }
            var features: [Feature] = []
            for (index, raw) in layer.filter({ $0.number == 2 }).enumerated() {
                let fs = try fields(raw.bytes)
                let tags = try packed(fs.first(where: { $0.number == 2 })?.bytes ?? [])
                guard tags.count % 2 == 0 else { throw Failure.malformed }
                var props: [String: String] = [:]
                for i in stride(from: 0, to: tags.count, by: 2) {
                    guard tags[i] < keys.count, tags[i + 1] < values.count else { throw Failure.malformed }
                    props[keys[Int(tags[i])]] = values[Int(tags[i + 1])]
                }
                let commands = try packed(fs.first(where: { $0.number == 4 })?.bytes ?? [])
                features.append(Feature(id: fs.first(where: { $0.number == 1 })?.value ?? UInt64(index),
                    type: fs.first(where: { $0.number == 3 })?.value ?? 0, properties: props, paths: try geometry(commands)))
            }
            result.append(Layer(name: name, extent: extent, features: features))
        }
        return result
    }
}
