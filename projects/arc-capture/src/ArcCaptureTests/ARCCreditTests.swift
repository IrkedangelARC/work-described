import XCTest
import PDFKit
@testable import ArcCaptureTests

final class ARCCreditTests: XCTestCase {
    /// A PDF the app writes names the tool and the company, and leaves author and title alone.
    func testStampNamesTheToolAndLeavesTheAuthorAlone() throws {
        let image = NSImage(size: NSSize(width: 64, height: 36), flipped: false) { r in NSColor.black.setFill(); r.fill(); return true }
        let doc = PDFDocument(); doc.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        doc.documentAttributes = [PDFDocumentAttribute.authorAttribute: "A Presenter"]
        ARCCredit.stamp(doc)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arccredit-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(doc.write(to: url))
        let attrs = try XCTUnwrap(PDFDocument(url: url)?.documentAttributes)
        XCTAssertTrue((attrs[PDFDocumentAttribute.creatorAttribute] as? String ?? "").contains("ARC Capture"))
        XCTAssertTrue((attrs[PDFDocumentAttribute.creatorAttribute] as? String ?? "").contains("ARC Event Productions"))
        XCTAssertEqual(attrs[PDFDocumentAttribute.authorAttribute] as? String, "A Presenter")
    }

    /// The writer a real capture uses (PDFAssembler, Quartz) carries the credit too. The first
    /// version stamped only the PDFKit writers and a field capture came out with no credit (2026-11-25).
    func testTheCapturePDFWriterCarriesTheCredit() throws {
        let image = NSImage(size: NSSize(width: 64, height: 36), flipped: false) { r in NSColor.black.setFill(); r.fill(); return true }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arccredit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("p1.jpg")
        try XCTUnwrap(PDFAssembler.pageJPEG(from: image)).write(to: jpeg)
        let pdf = dir.appendingPathComponent("slides.pdf")
        try PDFAssembler.assemble(jpegFiles: [jpeg], to: pdf)
        let attrs = try XCTUnwrap(PDFDocument(url: pdf)?.documentAttributes)
        let creator = attrs[PDFDocumentAttribute.creatorAttribute] as? String ?? ""
        XCTAssertTrue(creator.contains("ARC Capture") && creator.contains("ARC Event Productions"), creator)
        XCTAssertNil(attrs[PDFDocumentAttribute.authorAttribute])
    }
}
