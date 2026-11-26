//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ARCShowFormat

/// A show.json written by a newer app must still open in an older one. `ItemKind` was a strict enum,
/// so an unfamiliar kind threw while decoding and Swift fails the WHOLE file, not the one item: a
/// fleet Mac would have refused to open the show folder on the day rather than read it imperfectly.
final class ItemKindToleranceTests: XCTestCase {

    /// Encode a real ShowSpec and then substitute one value, rather than hand-writing JSON. A literal
    /// fixture silently rots into "throws for an unrelated missing key", which is how the unknown-status
    /// test below first passed while proving nothing.
    private func json(replacing old: String, with new: String) throws -> Data {
        let spec = ShowSpec(name: "Show", items: [
            .init(id: "1.01", title: "A", source: "decks/1.01 A.pptx", kind: .powerpoint, status: .captured),
            .init(id: "1.02", title: "B", source: "", kind: .pdf, status: .ready)
        ])
        var text = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        guard let range = text.range(of: old) else {
            throw XCTSkip("the encoded form no longer contains \(old); the fixture needs updating")
        }
        text.replaceSubrange(range, with: new)
        return Data(text.utf8)
    }

    func testAnUnknownKindDecodesAsOtherAndDoesNotFailTheFile() throws {
        // "segment" is the timer-only kind the agenda work will add. Today's package has never heard
        // of it, and that is exactly the case this has to survive.
        let data = try json(replacing: "\"kind\":\"pdf\"", with: "\"kind\":\"segment\"")
        let spec = try JSONDecoder().decode(ShowSpec.self, from: data)
        XCTAssertEqual(spec.items.count, 2, "the whole file survived an unfamiliar kind")
        XCTAssertEqual(spec.items[0].kind, .powerpoint, "the items it does know are unaffected")
        XCTAssertEqual(spec.items[1].kind, .other)
    }

    func testKnownKindsStillDecodeAsThemselves() throws {
        for kind in ["powerpoint", "keynote", "googleSlides", "pdf", "image", "movie", "arcdeck"] {
            let data = try json(replacing: "\"kind\":\"pdf\"", with: "\"kind\":\"\(kind)\"")
            let spec = try JSONDecoder().decode(ShowSpec.self, from: data)
            XCTAssertEqual(spec.items[1].kind.rawValue, kind, "\(kind) no longer decodes as itself")
        }
    }

    func testOtherSurvivesARoundTrip() throws {
        let data = try json(replacing: "\"kind\":\"pdf\"", with: "\"kind\":\"segment\"")
        let once = try JSONDecoder().decode(ShowSpec.self, from: data)
        let twice = try JSONDecoder().decode(ShowSpec.self, from: try JSONEncoder().encode(once))
        XCTAssertEqual(twice.items[1].kind, .other)
        // Honest about the cost: an older app rewriting the file turns "segment" into "other". The
        // unfamiliar kind is not preserved, it is survived. Only shipping the writer's package keeps it.
        let text = String(decoding: try JSONEncoder().encode(once), as: UTF8.self)
        XCTAssertTrue(text.contains("\"kind\":\"other\""), "a re-write records what this build understood")
    }

    /// `ItemStatus` is the other strict enum in this file and has NO tolerance: an unknown status still
    /// fails the whole file. Pinned as a known gap so it is a decision rather than a surprise.
    func testAnUnknownStatusStillFailsTheWholeFile() throws {
        let data = try json(replacing: "\"status\":\"ready\"", with: "\"status\":\"parked\"")
        XCTAssertThrowsError(try JSONDecoder().decode(ShowSpec.self, from: data),
                             "if this stops throwing, ItemStatus gained tolerance and this test should assert that instead")
    }
}
