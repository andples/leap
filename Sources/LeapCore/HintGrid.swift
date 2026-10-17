import Foundation

/// A physical key in the 4x4 right-hand block.
/// Rows top to bottom: 0 = 7 8 9 0, 1 = U I O P, 2 = J K L ;, 3 = M , . /  (QWERTY positions).
public struct KeyPos: Hashable, Sendable {
    public let row: Int
    public let col: Int
    public init(row: Int, col: Int) { self.row = row; self.col = col }
}

/// Where an item sits on screen and which key sequence selects it.
public struct Slot: Equatable, Sendable {
    public let row: Int
    public let col: Int
    public let keys: [KeyPos]
}

public struct GridPlan: Equatable, Sendable {
    public let rows: Int
    public let cols: Int
    /// One slot per item, in priority order (item i gets slots[i]).
    public let slots: [Slot]

    public static let empty = GridPlan(rows: 0, cols: 0, slots: [])

    /// Index of the slot displayed at (row, col), if any.
    public func index(row: Int, col: Int) -> Int? {
        slots.firstIndex { $0.row == row && $0.col == col }
    }
}

public enum MatchResult: Equatable, Sendable {
    case exact(Int)
    case prefix
    case none
}

public enum HintGrid {
    public static let size = 4
    /// Home row first, then top, bottom, numbers.
    public static let rowPriority = [2, 1, 3, 0]
    public static let keysByPriority: [KeyPos] =
        rowPriority.flatMap { r in (0..<size).map { KeyPos(row: r, col: $0) } }
    public static let maxItems = 16 * 16

    public static func plan(count: Int) -> GridPlan {
        let n = min(max(count, 0), maxItems)
        guard n > 0 else { return .empty }
        return n <= 16 ? spatialPlan(n) : sequencePlan(n)
    }

    /// Up to 16 items: the grid on screen mirrors the physical keys.
    private static func spatialPlan(_ n: Int) -> GridPlan {
        let rows = (n + size - 1) / size
        let cols = (n + rows - 1) / rows
        let used = Array(rowPriority.prefix(rows))
        let displayOrder = used.sorted()
        var slots: [Slot] = []
        for physRow in used {
            let displayRow = displayOrder.firstIndex(of: physRow)!
            for col in 0..<cols {
                slots.append(Slot(row: displayRow, col: col, keys: [KeyPos(row: physRow, col: col)]))
            }
        }
        return GridPlan(rows: rows, cols: cols, slots: Array(slots.prefix(n)))
    }

    /// More than 16 items: the lowest-priority keys become prefixes for two-key hints.
    private static func sequencePlan(_ n: Int) -> GridPlan {
        let keys = keysByPriority
        var prefixes = 1
        while (keys.count - prefixes) + keys.count * prefixes < n { prefixes += 1 }
        var labels: [[KeyPos]] = keys.prefix(keys.count - prefixes).map { [$0] }
        for p in keys.suffix(prefixes) {
            for k in keys { labels.append([p, k]) }
        }
        let cols = min(8, Int(ceil(sqrt(Double(n) * 1.6))))
        let rows = (n + cols - 1) / cols
        let slots = (0..<n).map { i in Slot(row: i / cols, col: i % cols, keys: labels[i]) }
        return GridPlan(rows: rows, cols: cols, slots: slots)
    }

    public static func match(_ typed: [KeyPos], in plan: GridPlan) -> MatchResult {
        guard !typed.isEmpty else { return .none }
        if let i = plan.slots.firstIndex(where: { $0.keys == typed }) { return .exact(i) }
        if plan.slots.contains(where: { $0.keys.starts(with: typed) }) { return .prefix }
        return .none
    }
}
