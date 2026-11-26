//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcPresenter

/// The pure rules behind the PowerPoint park. Frames are top-left global, taken
/// from the measured workstation layout on 2026-09-16.
@MainActor
final class PowerPointSourceTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 2048, height: 1152)
    let program = CGRect(x: 2048, y: 216, width: 1920, height: 1280)
    let confidence = CGRect(x: -1920, y: 0, width: 1920, height: 1280)
    let label: (CGRect) -> String = { "\(Int($0.minX))" }

    func testAppleScriptBoundsMatchesTheMeasuredParkCommand() {
        XCTAssertEqual(PowerPointSource.appleScriptBounds(confidence), "{-1920, 0, 0, 1280}")
        XCTAssertEqual(PowerPointSource.appleScriptBounds(program), "{2048, 216, 3968, 1496}")
    }

    func testScriptWrapsTheBodyInATimeoutAndTargetsPowerPointByBundleID() {
        let s = PowerPointSource.script("go to next slide slideshow view of slide show window 1", timeout: 2)
        XCTAssertTrue(s.hasPrefix("with timeout of 2 seconds"))
        XCTAssertTrue(s.contains("tell application id \"com.microsoft.Powerpoint\""))
        XCTAssertTrue(s.hasSuffix("end timeout"))
    }

    func testWindowTitlesAsPowerPointReportsThem() {
        let base = "Sample_Deck"
        let doc = PowerPointSource.WindowInfo(title: base, frame: .zero)
        let show = PowerPointSource.WindowInfo(title: "PowerPoint Slide Show - [\(base)]", frame: .zero)
        let pv = PowerPointSource.WindowInfo(title: "PowerPoint Presenter View - [\(base)]", frame: .zero)
        XCTAssertTrue(PowerPointSource.isDocumentWindow(doc, base: base))
        XCTAssertFalse(PowerPointSource.isDocumentWindow(show, base: base))
        XCTAssertFalse(PowerPointSource.isDocumentWindow(pv, base: base))
        XCTAssertTrue(PowerPointSource.isShowWindow(show, base: base))
        XCTAssertFalse(PowerPointSource.isShowWindow(pv, base: base))
        XCTAssertTrue(PowerPointSource.isPresenterViewWindow(pv, base: base))
        XCTAssertFalse(PowerPointSource.isShowWindow(
            PowerPointSource.WindowInfo(title: "PowerPoint Slide Show - [Other Deck]", frame: .zero), base: base))
    }

    func testFramesMatchWithinTwoPoints() {
        XCTAssertTrue(PowerPointSource.framesMatch(program, program.offsetBy(dx: 1, dy: -1)))
        XCTAssertFalse(PowerPointSource.framesMatch(program, CGRect(x: 2048, y: 216, width: 2048, height: 1152)))
    }

    func testPresenterViewIsNeverSentToTheMainDisplayFrame() {
        XCTAssertNotNil(PowerPointSource.presenterViewRefusal(target: main, main: main))
        XCTAssertNil(PowerPointSource.presenterViewRefusal(target: confidence, main: main))
    }

    func testParkedCorrectlyHasNoProblems() {
        XCTAssertEqual(PowerPointSource.problems(show: program, presenterView: confidence,
                                                 program: program, confidence: confidence, name: label), [])
    }

    func testShowOnTheWrongDisplayIsReported() {
        let problems = PowerPointSource.problems(show: confidence, presenterView: main,
                                                 program: program, confidence: confidence, name: label)
        XCTAssertEqual(problems.count, 2)
        XCTAssertTrue(problems[0].contains("not the program display"))
    }

    func testLostPresenterViewTellsTheOperatorToRestartTheShow() {
        let problems = PowerPointSource.problems(show: program, presenterView: nil,
                                                 program: program, confidence: confidence, name: label)
        XCTAssertEqual(problems, ["Presenter View is not on screen. Restart the PowerPoint show to get it back"])
    }

    func testNoConfidenceDisplayMeansPresenterViewIsNotChecked() {
        XCTAssertEqual(PowerPointSource.problems(show: program, presenterView: main,
                                                 program: program, confidence: nil, name: label), [])
    }

    func testShowNotRunningIsReported() {
        let problems = PowerPointSource.problems(show: nil, presenterView: nil,
                                                 program: program, confidence: confidence, name: label)
        XCTAssertEqual(problems, ["The PowerPoint slide show is not running"])
    }

    func testOnlyMeasuredFormatsAreAccepted() {
        XCTAssertTrue(PowerPointSource.documentExtensions.contains("pptx"))
        XCTAssertFalse(PowerPointSource.documentExtensions.contains("ppsx"))
        XCTAssertFalse(PowerPointSource.documentExtensions.contains("key"))
    }
}
