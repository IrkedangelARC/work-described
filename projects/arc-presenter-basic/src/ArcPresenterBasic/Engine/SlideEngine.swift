//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import PDFKit

@MainActor
@Observable
final class SlideEngine {
    private(set) var currentIndex: Int = 0
    private(set) var pageCount: Int = 0
    private(set) var isLoaded: Bool = false
    private(set) var isBlack: Bool = false
    private(set) var pdfDocument: PDFDocument?
    private(set) var fileName: String = ""
    private(set) var sourceURL: URL?

    var jumpText: String = ""

    var currentPage: Int { currentIndex + 1 }
    var hasNext: Bool { currentIndex < pageCount - 1 }
    var hasPrevious: Bool { currentIndex > 0 }
    var displayLabel: String { "\(currentPage) / \(pageCount)" }

    func loadPDF(url: URL) -> Bool {
        guard let document = PDFDocument(url: url) else { return false }
        pdfDocument = document
        pageCount = document.pageCount
        currentIndex = 0
        isBlack = false
        isLoaded = true
        fileName = url.lastPathComponent
        sourceURL = url
        jumpText = ""
        return true
    }

    func unload() {
        pdfDocument = nil
        pageCount = 0
        currentIndex = 0
        isBlack = false
        isLoaded = false
        fileName = ""
        sourceURL = nil
        jumpText = ""
    }

    func next() {
        guard hasNext else { return }
        currentIndex += 1
        isBlack = false
    }

    func previous() {
        guard hasPrevious else { return }
        currentIndex -= 1
        isBlack = false
    }

    func jumpTo(page: Int) {
        guard pageCount > 0 else { return }
        let clamped = max(1, min(page, pageCount))
        currentIndex = clamped - 1
        isBlack = false
    }

    func goToFirst() {
        currentIndex = 0
        isBlack = false
    }

    func goToLast() {
        guard pageCount > 0 else { return }
        currentIndex = pageCount - 1
        isBlack = false
    }

    func toggleBlack() {
        isBlack.toggle()
    }

    func commitJump() {
        guard let page = Int(jumpText) else {
            jumpText = ""
            return
        }
        jumpTo(page: page)
        jumpText = ""
    }
}
