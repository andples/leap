import XCTest
@testable import LeapCore

final class ArrangementTests: XCTestCase {
    private func apps(_ spec: [(String, Int)]) -> [AppInfo] {
        spec.map { AppInfo(id: $0.0, name: $0.0, uses: $0.1) }
    }

    func testRecentHomeRowThenAlphabetical() {
        // Current app is "Zed"; most recent others: Mail, Arc, Xcode, Notes, Books.
        let mru = apps([("Zed", 0), ("Mail", 0), ("Arc", 0), ("Xcode", 0), ("Notes", 0), ("Books", 0)])
        let a = Arranger.arrange(mru, ordering: .recent, primary: 3)
        XCTAssertEqual(a.slots.map { mru[$0].name }, ["Mail", "Arc", "Xcode", "Books", "Notes", "Zed"])
        // Tab goes previous app first (Mail), current app (Zed) last.
        XCTAssertEqual(a.cycle.map { mru[a.slots[$0]].name }, ["Mail", "Arc", "Xcode", "Notes", "Books", "Zed"])
    }

    func testUsageHomeRowExcludesCurrent() {
        let mru = apps([("Zed", 99), ("Mail", 1), ("Arc", 50), ("Xcode", 20), ("Notes", 20)])
        let a = Arranger.arrange(mru, ordering: .usage, primary: 2)
        XCTAssertEqual(a.slots.map { mru[$0].name }, ["Arc", "Xcode", "Mail", "Notes", "Zed"])
        XCTAssertEqual(mru[a.slots[a.cycle[0]]].name, "Mail") // quick ⌘Tab still goes to the previous app
    }

    func testRestIsStableAcrossRecencyChanges() {
        let names = ["A", "B", "C", "D", "E", "F", "G"]
        let first = apps(names.map { ($0, 0) })
        let shuffled = apps(["A", "B", "G", "E", "C", "F", "D"].map { ($0, 0) })
        let a = Arranger.arrange(first, ordering: .recent, primary: 2)
        let b = Arranger.arrange(shuffled, ordering: .recent, primary: 2)
        let restA = a.slots.dropFirst(2).map { first[$0].name }.filter { !["G", "E", "B", "C"].contains($0) }
        let restB = b.slots.dropFirst(2).map { shuffled[$0].name }.filter { !["G", "E", "B", "C"].contains($0) }
        XCTAssertEqual(restA, restB)
        XCTAssertEqual(restB, restB.sorted())
    }

    func testPureRecencyKeepsCurrentLast() {
        let mru = apps([("Zed", 0), ("Mail", 0), ("Arc", 0), ("Xcode", 0)])
        let a = Arranger.arrange(mru, ordering: .recent, primary: 2, stableRest: false)
        XCTAssertEqual(a.slots.map { mru[$0].name }, ["Mail", "Arc", "Xcode", "Zed"])
    }

    func testSingleApp() {
        let a = Arranger.arrange(apps([("Solo", 0)]), ordering: .usage, primary: 4)
        XCTAssertEqual(a.slots, [0])
        XCTAssertEqual(a.cycle, [0])
    }

    func testHomeCount() {
        XCTAssertEqual(HintGrid.plan(count: 9).homeCount, 3)
        XCTAssertEqual(HintGrid.plan(count: 2).homeCount, 2)
        XCTAssertEqual(HintGrid.plan(count: 40).homeCount, 4)
    }
}
