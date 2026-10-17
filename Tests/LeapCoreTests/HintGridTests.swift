import XCTest
@testable import LeapCore

final class HintGridTests: XCTestCase {
    func testShapes() {
        let expected: [Int: (Int, Int)] = [1: (1, 1), 3: (1, 3), 4: (1, 4), 5: (2, 3), 7: (2, 4),
                                           9: (3, 3), 10: (3, 4), 13: (4, 4), 16: (4, 4)]
        for (n, (r, c)) in expected {
            let p = HintGrid.plan(count: n)
            XCTAssertEqual(p.rows, r, "rows for \(n)")
            XCTAssertEqual(p.cols, c, "cols for \(n)")
            XCTAssertEqual(p.slots.count, n)
        }
    }

    func testHomeRowFirstAndDisplayMatchesPhysical() {
        let p = HintGrid.plan(count: 6) // home + top rows, 3 cols
        XCTAssertEqual(p.slots[0].keys, [KeyPos(row: 2, col: 0)])
        XCTAssertEqual(p.slots[0].row, 1) // home row is displayed below the top row
        XCTAssertEqual(p.slots[3].keys, [KeyPos(row: 1, col: 0)])
        XCTAssertEqual(p.slots[3].row, 0)
    }

    func testUniqueKeysAndCells() {
        for n in 1...HintGrid.maxItems {
            let p = HintGrid.plan(count: n)
            XCTAssertEqual(Set(p.slots.map { $0.keys }).count, n)
            XCTAssertEqual(Set(p.slots.map { [$0.row, $0.col] }).count, n)
            // No hint is a prefix of another.
            for a in p.slots where a.keys.count == 1 {
                XCTAssertFalse(p.slots.contains { $0.keys.count > 1 && $0.keys.first == a.keys.first })
            }
        }
    }

    func testMatch() {
        let p = HintGrid.plan(count: 20)
        XCTAssertEqual(HintGrid.match([p.slots[0].keys[0]], in: p), .exact(0))
        let two = p.slots[19].keys
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(HintGrid.match([two[0]], in: p), .prefix)
        XCTAssertEqual(HintGrid.match(two, in: p), .exact(19))
    }
}
