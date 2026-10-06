import Foundation

/// Bounded MVT reader for Mapbox Streets geometry and scalar properties. Coordinates stay tile-local.
nonisolated enum DioramaVectorTile {
    struct Feature: Sendable {
        let id: UInt64
        let layer: String
        let type: UInt64
        let properties: [String: String]
        let paths: [[DV2]]
        let extent: Double
    }
    enum Invalid: Error { case data }
    private struct Field {
        let number: Int
        let integer: UInt64
        let bytes: [UInt8]
        let wire: Int
    }
    private struct Reader {
        let bytes: [UInt8]
        var index: Int = 0
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { throw Invalid.data }
                let byte = bytes[index]; index += 1
                if shift == 63 && byte > 1 { throw Invalid.data }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            throw Invalid.data
        }
        mutating func fields() throws -> [Field] {
            var result: [Field] = []
            while index < bytes.count {
                let key = try varint(), wire = Int(key & 7)
                guard key >> 3 > 0 else { throw Invalid.data }
                var value: UInt64 = 0
                var payload: [UInt8] = []
                switch wire {
                case 0: value = try varint()
                case 1, 5:
                    let count = wire == 1 ? 8 : 4
                    guard count <= bytes.count - index else { throw Invalid.data }
                    for k in 0..<count { value |= UInt64(bytes[index + k]) << (k * 8) }
                    index += count
                case 2:
                    let count = try varint()
                    guard count <= UInt64(bytes.count - index) else { throw Invalid.data }
                    payload = Array(bytes[index..<(index + Int(count))]); index += Int(count)
                default: throw Invalid.data
                }
                result.append(Field(number: Int(key >> 3), integer: value, bytes: payload, wire: wire))
            }
            return result
        }
        mutating func packed() throws -> [UInt64] {
            var result: [UInt64] = []
            while index < bytes.count { result.append(try varint()) }
            return result
        }
    }
    private static func fields(_ bytes: [UInt8]) throws -> [Field] {
        var reader = Reader(bytes: bytes)
        return try reader.fields()
    }
    private static func packed(_ bytes: [UInt8]) throws -> [UInt64] {
        var reader = Reader(bytes: bytes)
        return try reader.packed()
    }
    private static func scalar(_ bytes: [UInt8]) throws -> String {
        guard let f = try fields(bytes).first else { return "" }
        switch f.number {
        case 1: return String(decoding: f.bytes, as: UTF8.self)
        case 2: return String(Float(bitPattern: UInt32(truncatingIfNeeded: f.integer)))
        case 3: return String(Double(bitPattern: f.integer))
        case 4: return String(Int64(bitPattern: f.integer))
        case 6: return String(Int64(f.integer >> 1) ^ -Int64(f.integer & 1))
        case 7: return f.integer == 0 ? "false" : "true"
        default: return String(f.integer)
        }
    }
    private static func geometry(_ commands: [UInt64]) throws -> [[DV2]] {
        var paths: [[DV2]] = [], path: [DV2] = []
        var x: Int64 = 0, y: Int64 = 0, i = 0
        while i < commands.count {
            let command = commands[i] & 7, count = commands[i] >> 3; i += 1
            guard count > 0, count < 1_000_000 else { throw Invalid.data }
            if command == 7 {
                if !path.isEmpty { paths.append(path); path = [] }
                continue
            }
            guard command == 1 || command == 2, count <= UInt64((commands.count - i) / 2) else { throw Invalid.data }
            for _ in 0..<Int(count) {
                if command == 1, !path.isEmpty { paths.append(path); path = [] }
                let dx = commands[i], dy = commands[i + 1]; i += 2
                let sx = Int64(dx >> 1) ^ -Int64(dx & 1), sy = Int64(dy >> 1) ^ -Int64(dy & 1)
                let nextX = x.addingReportingOverflow(sx), nextY = y.addingReportingOverflow(sy)
                guard !nextX.overflow, !nextY.overflow else { throw Invalid.data }
                x = nextX.partialValue; y = nextY.partialValue
                guard abs(Double(x)) < 1_000_000, abs(Double(y)) < 1_000_000 else { throw Invalid.data }
                path.append(DV2(Double(x), Double(y)))
            }
        }
        if !path.isEmpty { paths.append(path) }
        return paths
    }
    static func decode(_ data: Data) throws -> [Feature] {
        guard data.count <= 12_000_000 else { throw Invalid.data }
        var result: [Feature] = []
        for layerField in try fields(Array(data)) where layerField.number == 3 {
            let layer = try fields(layerField.bytes)
            let name = String(decoding: layer.first(where: { $0.number == 1 })?.bytes ?? [], as: UTF8.self)
            guard ["building", "road", "poi_label"].contains(name) else { continue }
            let extent = Double(layer.first(where: { $0.number == 5 })?.integer ?? 4096)
            guard extent > 0 else { throw Invalid.data }
            let keys = layer.filter { $0.number == 3 }.map { String(decoding: $0.bytes, as: UTF8.self) }
            let values = try layer.filter { $0.number == 4 }.map { try scalar($0.bytes) }
            for encoded in layer where encoded.number == 2 {
                let feature = try fields(encoded.bytes)
                func repeated(_ number: Int) throws -> [UInt64] {
                    try feature.filter { $0.number == number }.flatMap { field in
                        if field.wire == 0 { return [field.integer] }
                        guard field.wire == 2 else { throw Invalid.data }
                        return try packed(field.bytes)
                    }
                }
                let tags = try repeated(2)
                guard tags.count % 2 == 0 else { throw Invalid.data }
                var properties: [String: String] = [:]
                for j in stride(from: 0, to: tags.count, by: 2) {
                    guard tags[j] < keys.count, tags[j + 1] < values.count else { throw Invalid.data }
                    properties[keys[Int(tags[j])]] = values[Int(tags[j + 1])]
                }
                let commands = try repeated(4)
                result.append(Feature(id: feature.first(where: { $0.number == 1 })?.integer ?? UInt64(result.count),
                    layer: name, type: feature.first(where: { $0.number == 3 })?.integer ?? 0,
                    properties: properties, paths: try geometry(commands), extent: extent))
            }
        }
        return result
    }
}
