//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcZoom

/// Where the tiles go. The one thing in this app that can be wrong in a way nobody notices until a show.
final class TileLayoutTests: XCTestCase {
    private let hd = CGRect(x: 0, y: 0, width: 1280, height: 720)
    private let wide: CGFloat = 16.0 / 9.0

    func testFillLetterboxesAndCentres() {
        // Exactly 16:9 into exactly 16:9 is the whole thing.
        XCTAssertEqual(TileLayout.fill(hd, aspect: wide), hd)

        // A 16:9 tile in a 4:3 window: full width, bars top and bottom, centred.
        let squareish = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let r = TileLayout.fill(squareish, aspect: wide)
        XCTAssertEqual(r.width, 1000)
        XCTAssertEqual(r.height, 563, accuracy: 1)
        XCTAssertEqual(r.midY, 500, accuracy: 1)
        XCTAssertEqual(r.minX, 0)

        // A 16:9 tile in a tall window: full height, pillarboxed.
        let tall = CGRect(x: 0, y: 0, width: 400, height: 1000)
        let t = TileLayout.fill(tall, aspect: wide)
        XCTAssertEqual(t.width, 400)
        XCTAssertEqual(t.midX, 200, accuracy: 1)

        XCTAssertEqual(TileLayout.fill(.zero, aspect: wide), .zero, "no window, no tile")
    }

    func testGridCountAndNoOverlap() {
        for n in 1...8 {
            let rects = TileLayout.grid(count: n, in: hd, aspect: wide)
            XCTAssertEqual(rects.count, n, "\(n) participants means \(n) tiles")
            for r in rects {
                XCTAssertGreaterThan(r.width, 0)
                XCTAssertEqual(r.width / r.height, wide, accuracy: 0.02, "tiles keep their aspect")
                XCTAssertTrue(hd.insetBy(dx: -1, dy: -1).contains(r), "tile \(r) escaped the window")
            }
            for (i, a) in rects.enumerated() {
                for b in rects[(i + 1)...] {
                    XCTAssertFalse(a.insetBy(dx: 1, dy: 1).intersects(b.insetBy(dx: 1, dy: 1)), "tiles overlap")
                }
            }
        }
    }

    func testGridPicksTheGridThatMakesTilesBiggest() {
        // Two 16:9 tiles in a 16:9 window go side by side, not stacked: side by side is larger.
        let two = TileLayout.grid(count: 2, in: hd, aspect: wide)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two[0].minY, two[1].minY, accuracy: 1, "one row")
        XCTAssertLessThan(two[0].minX, two[1].minX)

        // Four go two by two.
        let four = TileLayout.grid(count: 4, in: hd, aspect: wide)
        XCTAssertEqual(Set(four.map { Int($0.minY) }).count, 2, "two rows")
        XCTAssertEqual(Set(four.map { Int($0.minX) }).count, 2, "two columns")

        // More people never means bigger tiles.
        let sizes = (1...6).map { TileLayout.grid(count: $0, in: hd, aspect: wide).first?.width ?? 0 }
        for (a, b) in zip(sizes, sizes.dropFirst()) { XCTAssertGreaterThanOrEqual(a, b) }
    }

    func testGridCentresAShortLastRow() {
        // Three tiles: two over one, and the lone one sits under the middle.
        let three = TileLayout.grid(count: 3, in: hd, aspect: wide)
        XCTAssertEqual(three.count, 3)
        let rows = Dictionary(grouping: three) { Int($0.minY) }
        guard rows.count == 2, let lastY = rows.keys.max(), let last = rows[lastY], last.count == 1,
              let firstRow = rows[rows.keys.min()!] else {
            return XCTFail("expected two rows of 2 and 1, got \(three)")
        }
        let rowMid = (firstRow.map(\.midX).min()! + firstRow.map(\.midX).max()!) / 2
        XCTAssertEqual(last[0].midX, rowMid, accuracy: 1, "the short row is centred under the one above")
    }

    func testStripIsOneCentredRow() {
        let band = CGRect(x: 0, y: 0, width: 1920, height: 200)
        let rects = TileLayout.strip(count: 3, in: band, aspect: wide)
        XCTAssertEqual(rects.count, 3)
        XCTAssertEqual(Set(rects.map { Int($0.minY) }).count, 1, "one row")
        for r in rects { XCTAssertLessThanOrEqual(r.height, band.height) }
        // Centred: the gap outside the tiles is the same each side.
        XCTAssertEqual(rects.first!.minX, band.maxX - rects.last!.maxX, accuracy: 1)
    }

    func testDegenerateInputsDoNotCrashOrReturnNonsense() {
        XCTAssertTrue(TileLayout.grid(count: 0, in: hd, aspect: wide).isEmpty)
        XCTAssertTrue(TileLayout.grid(count: -3, in: hd, aspect: wide).isEmpty)
        XCTAssertTrue(TileLayout.grid(count: 4, in: .zero, aspect: wide).isEmpty)
        XCTAssertTrue(TileLayout.grid(count: 4, in: hd, aspect: 0).isEmpty)
        XCTAssertTrue(TileLayout.strip(count: 4, in: CGRect(x: 0, y: 0, width: 10, height: 10), aspect: wide).isEmpty,
                      "a window too small for the tiles gets none, not negative ones")
    }
}
