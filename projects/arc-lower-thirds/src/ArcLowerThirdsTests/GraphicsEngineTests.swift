//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ARC_Lower_Thirds

final class GraphicsEngineTests: XCTestCase {

    private var engine: GraphicsEngine!

    override func setUp() {
        super.setUp()
        engine = GraphicsEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    func testInitialState() {
        XCTAssertEqual(engine.state, .idle)
        XCTAssertNil(engine.show)
        XCTAssertTrue(engine.graphics.isEmpty)
        XCTAssertFalse(engine.isOnAir)
        XCTAssertNil(engine.liveGraphic)
    }

    func testLoadShow() {
        let show = makeTestShow(graphicCount: 3)
        engine.loadShow(show)

        XCTAssertEqual(engine.state, .ready)
        XCTAssertEqual(engine.graphicCount, 3)
        XCTAssertEqual(engine.selectedIndex, 0)
        XCTAssertFalse(engine.isOnAir)
    }

    func testLoadEmptyShow() {
        let show = Show(name: "Empty")
        engine.loadShow(show)
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.graphicCount, 0)
    }

    func testNavigation() {
        let show = makeTestShow(graphicCount: 3)
        engine.loadShow(show)

        XCTAssertTrue(engine.hasNext)
        XCTAssertFalse(engine.hasPrevious)

        engine.next()
        XCTAssertEqual(engine.selectedIndex, 1)
        XCTAssertTrue(engine.hasPrevious)

        engine.next()
        XCTAssertEqual(engine.selectedIndex, 2)
        XCTAssertFalse(engine.hasNext)

        engine.previous()
        XCTAssertEqual(engine.selectedIndex, 1)
    }

    func testFire() {
        let show = makeTestShow(graphicCount: 2)
        engine.loadShow(show)

        engine.fire()

        // Synchronous: state and liveGraphic are set immediately
        XCTAssertEqual(engine.state, .live)
        XCTAssertNotNil(engine.liveGraphic)
        XCTAssertEqual(engine.liveGraphic?.line1, "Speaker 0")

        // isOnAir is deferred for animation staging — wait for it
        let exp = expectation(description: "isOnAir becomes true")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertTrue(self.engine.isOnAir)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testFireAtIndex() {
        let show = makeTestShow(graphicCount: 3)
        engine.loadShow(show)

        engine.fire(at: 2)
        XCTAssertEqual(engine.selectedIndex, 2)
        XCTAssertEqual(engine.liveGraphic?.line1, "Speaker 2")

        let exp = expectation(description: "isOnAir becomes true")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertTrue(self.engine.isOnAir)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testCutToBlack() {
        let show = makeTestShow(graphicCount: 2)
        engine.loadShow(show)

        engine.fire()
        let exp = expectation(description: "isOnAir becomes true")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertTrue(self.engine.isOnAir)
            self.engine.cutToBlack()
            XCTAssertFalse(self.engine.isOnAir)
            XCTAssertNil(self.engine.liveGraphic)
            XCTAssertEqual(self.engine.state, .preview)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testUnloadShow() {
        let show = makeTestShow(graphicCount: 2)
        engine.loadShow(show)
        engine.fire()

        engine.unloadShow()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertNil(engine.show)
        XCTAssertTrue(engine.graphics.isEmpty)
        XCTAssertFalse(engine.isOnAir)
    }

    // MARK: - Helpers

    private func makeTestShow(graphicCount: Int) -> Show {
        let show = Show(name: "Test Show")
        for i in 0..<graphicCount {
            let g = Graphic(
                line1: "Speaker \(i)",
                line2: "Title \(i)",
                sortOrder: i
            )
            g.show = show
            show.graphics.append(g)
        }
        return show
    }
}
