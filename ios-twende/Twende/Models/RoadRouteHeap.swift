import Foundation

/// Minimum-cost queue for bounded road-graph traversal.
nonisolated struct RoadRouteHeap {
    struct Item { let node: Int; let cost: Double }
    private var items: [Item] = []
    mutating func push(node: Int, cost: Double) {
        items.append(Item(node: node, cost: cost))
        var index = items.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard items[index].cost < items[parent].cost else { break }
            items.swapAt(index, parent); index = parent
        }
    }
    mutating func pop() -> Item? {
        guard !items.isEmpty else { return nil }
        let first = items[0], last = items.removeLast()
        guard !items.isEmpty else { return first }
        items[0] = last
        var index: Int = 0
        while index * 2 + 1 < items.count {
            let left = index * 2 + 1, right = left + 1
            let child = right < items.count && items[right].cost < items[left].cost ? right : left
            guard items[child].cost < items[index].cost else { break }
            items.swapAt(index, child); index = child
        }
        return first
    }
}
