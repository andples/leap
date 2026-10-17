import Foundation

public enum Ordering: String, CaseIterable, Sendable {
    /// Home row holds the most recently used apps.
    case recent
    /// Home row holds the apps switched to most often, all time.
    case usage
}

public struct AppInfo: Equatable, Sendable {
    public let id: String
    public let name: String
    public let uses: Int
    public init(id: String, name: String, uses: Int) { self.id = id; self.name = name; self.uses = uses }
}

public struct Arrangement: Equatable, Sendable {
    /// Indices into the input, in slot order (item i goes in plan slot i).
    public let slots: [Int]
    /// Positions in `slots`, in Tab order: previous app first, current app last.
    public let cycle: [Int]
}

public enum Arranger {
    /// - Parameters:
    ///   - mru: apps most recent first; index 0 is the current app.
    ///   - primary: how many slots are on the home row.
    ///   - stableRest: sort the apps off the home row alphabetically so their keys stay put.
    public static func arrange(_ mru: [AppInfo], ordering: Ordering, primary: Int, stableRest: Bool = true) -> Arrangement {
        guard !mru.isEmpty else { return Arrangement(slots: [], cycle: []) }
        // The current app never takes a home-row key: switching to it is pointless.
        var ranked = Array(mru.indices.dropFirst())
        if ordering == .usage {
            ranked.sort { a, b in mru[a].uses != mru[b].uses ? mru[a].uses > mru[b].uses : a < b }
        }
        let home = Array(ranked.prefix(primary))
        let homeSet = Set(home)
        var rest = mru.indices.filter { !homeSet.contains($0) }
        if stableRest {
            rest.sort { a, b in
                let c = mru[a].name.localizedStandardCompare(mru[b].name)
                return c != .orderedSame ? c == .orderedAscending : mru[a].id < mru[b].id
            }
        } else if let current = rest.first, current == 0 {
            rest.append(rest.removeFirst())
        }
        let slots = home + rest
        var position = [Int](repeating: 0, count: mru.count)
        for (pos, i) in slots.enumerated() { position[i] = pos }
        let tabOrder = Array(mru.indices.dropFirst()) + [0]
        return Arrangement(slots: slots, cycle: tabOrder.map { position[$0] })
    }
}

extension GridPlan {
    /// Number of single-key slots on the home row.
    public var homeCount: Int {
        slots.filter { $0.keys.count == 1 && $0.keys[0].row == HintGrid.rowPriority[0] }.count
    }
}
