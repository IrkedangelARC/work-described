//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest

final class ShowPipelineTests: XCTestCase {
    typealias P = ShowPipeline

    func testTheRoadInOrder() {
        var f = P.Facts()
        XCTAssertEqual(P.next(f), .open)
        f.hasShow = true
        XCTAssertEqual(P.next(f), .assess)
        f.assessed = true; f.planned = 9; f.toBringIn = 9; f.holdingSlide = "0.00 Holding Slide"
        XCTAssertEqual(P.states(f)[.holding], .done)
        XCTAssertEqual(P.next(f), .sort, "nothing is copied or captured before the order is confirmed")
        XCTAssertEqual(P.states(f)[.capture], .todo)
        f.orderConfirmed = true
        XCTAssertEqual(P.next(f), .capture)
        XCTAssertEqual(P.buttonTitle(.capture, f), "CAPTURE 9 PRESENTATIONS, BUILD AND OPEN")
        XCTAssertEqual(P.chain(from: .capture), [.capture, .build, .present])
        f.toBringIn = 0; f.ready = 9
        XCTAssertEqual(P.next(f), .build)
        f.showDeckBuilt = true; f.showDeckCurrent = true
        XCTAssertEqual(P.next(f), .present)
        f.presented = true
        XCTAssertNil(P.next(f))
        XCTAssertTrue(P.Step.allCases.allSatisfy { P.states(f)[$0] == .done })
    }

    func testNoHoldingSlideIsSaidButDoesNotBlock() {
        var f = P.Facts(); f.hasShow = true; f.assessed = true; f.planned = 3; f.toBringIn = 3
        XCTAssertEqual(P.states(f)[.holding], .attention)
        XCTAssertEqual(P.next(f), .sort)
    }

    func testAnEmptyFolderStopsAtAssess() {
        var f = P.Facts(); f.hasShow = true; f.assessed = true; f.planned = 0
        XCTAssertEqual(P.states(f)[.assess], .attention)
        XCTAssertEqual(P.next(f), .assess)
    }

    func testAFailedCaptureStopsTheRoadAndALateFileReopensIt() {
        var f = P.Facts(); f.hasShow = true; f.assessed = true; f.planned = 9; f.orderConfirmed = true; f.ready = 8; f.failed = 1
        XCTAssertEqual(P.states(f)[.capture], .attention)
        XCTAssertEqual(P.states(f)[.build], .todo, "no show deck with a hole in it")
        XCTAssertEqual(P.next(f), .capture)
        XCTAssertEqual(P.buttonTitle(.capture, f), "RETRY 1 FAILED, BUILD AND OPEN")
        // All captured, deck built and open; then the client adds a talk.
        f.failed = 0; f.ready = 9; f.showDeckBuilt = true; f.showDeckCurrent = true; f.presented = true
        XCTAssertNil(P.next(f))
        f.planned = 10; f.orderChanged = true; f.toBringIn = 1; f.showDeckCurrent = false
        XCTAssertEqual(P.next(f), .sort)
        XCTAssertEqual(P.buttonTitle(.sort, f), "CONFIRM THE NEW RUN ORDER")
    }

    func testWhileSomethingRunsThereIsNothingToPress() {
        var f = P.Facts(); f.hasShow = true; f.assessed = true; f.planned = 2; f.orderConfirmed = true; f.pending = 2; f.running = .capture
        XCTAssertNil(P.next(f))
        XCTAssertEqual(P.states(f)[.capture], .running)
    }

    // MARK: AUTO CAPTURE

    private func ready() -> P.Facts { var f = P.Facts(); f.hasShow = true; f.assessed = true; f.planned = 8; f.orderConfirmed = true; f.ready = 8; f.showDeckBuilt = true; f.showDeckCurrent = true; f.presented = true; return f }

    func testAutoCaptureRunsOnlyArmedWithWorkAndIdleHands() {
        var f = ready()
        XCTAssertEqual(AutoCapture.decide(armed: true, facts: f, busy: false, idleSeconds: 999), .nothing, "nothing changed")
        f.pending = 1; f.showDeckCurrent = false                       // a talk came back changed
        XCTAssertEqual(AutoCapture.decide(armed: false, facts: f, busy: false, idleSeconds: 999), .nothing, "not armed: the TD presses")
        XCTAssertEqual(AutoCapture.decide(armed: true, facts: f, busy: false, idleSeconds: 12), .waitForIdle(48), "someone is at the Mac")
        XCTAssertEqual(AutoCapture.decide(armed: true, facts: f, busy: true, idleSeconds: 999), .nothing)
        XCTAssertEqual(AutoCapture.decide(armed: true, facts: f, busy: false, idleSeconds: 60), .run)
    }

    func testAutoCaptureNeverDecidesTheRunOrderOrRetriesAFailure() {
        var f = ready(); f.toBringIn = 1; f.orderChanged = true; f.showDeckCurrent = false
        guard case .needsTD = AutoCapture.decide(armed: true, facts: f, busy: false, idleSeconds: 999) else { return XCTFail("a new talk is the TD's call") }
        var g = ready(); g.ready = 7; g.failed = 1; g.showDeckCurrent = false
        guard case .needsTD = AutoCapture.decide(armed: true, facts: g, busy: false, idleSeconds: 999) else { return XCTFail("a failed capture is not retried on its own") }
        var h = P.Facts(); h.hasShow = true; h.assessed = true; h.planned = 3; h.toBringIn = 3
        XCTAssertEqual(AutoCapture.decide(armed: true, facts: h, busy: false, idleSeconds: 999), .nothing, "never before the order was confirmed once")
    }

    // MARK: Shape

    func testTheShowsShapeIsTheCommonOneAndTheOddOnesAreNamed() {
        let show = AspectCheck.showAspect([1.778, 1.777, 1.333, 1.78, 1.294])
        XCTAssertEqual(show ?? 0, 1.8, accuracy: 0.06)
        XCTAssertTrue(AspectCheck.differs(4.0 / 3.0, from: 16.0 / 9.0))
        XCTAssertFalse(AspectCheck.differs(1.77, from: 16.0 / 9.0))
        XCTAssertEqual(AspectCheck.name(4.0 / 3.0), "4:3"); XCTAssertEqual(AspectCheck.name(1.7778), "16:9"); XCTAssertEqual(AspectCheck.name(792.0 / 612.0), "LETTER")
        XCTAssertNil(AspectCheck.showAspect([]))
        XCTAssertEqual(AspectProbe.slideSize(inPresentationXML: #"<p:presentation><p:sldSz cx="12192000" cy="6858000"/></p:presentation>"#) ?? 0, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(AspectProbe.slideSize(inPresentationXML: #"<p:sldSz cx="9144000" cy="6858000" type="screen4x3"/>"#) ?? 0, 4.0 / 3.0, accuracy: 0.001)
        XCTAssertNil(AspectProbe.slideSize(inPresentationXML: "<p:presentation/>"))
    }
}
