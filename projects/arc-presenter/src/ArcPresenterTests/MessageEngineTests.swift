//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcPresenter

@MainActor
final class MessageEngineTests: XCTestCase {
    var messages: MessageEngine!

    override func setUp() {
        super.setUp()
        messages = MessageEngine()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertEqual(messages.currentMessage, "")
        XCTAssertFalse(messages.isShowingMessage)
        XCTAssertEqual(messages.draftMessage, "")
    }

    // MARK: - Send

    func testSendMessage() {
        messages.send("WRAP UP")
        XCTAssertEqual(messages.currentMessage, "WRAP UP")
        XCTAssertTrue(messages.isShowingMessage)
    }

    func testSendUppercases() {
        messages.send("slow down")
        XCTAssertEqual(messages.currentMessage, "SLOW DOWN")
    }

    func testSendClearsDraft() {
        messages.draftMessage = "hello"
        messages.send("test")
        XCTAssertEqual(messages.draftMessage, "")
    }

    func testSendEmptyIgnored() {
        messages.send("")
        XCTAssertFalse(messages.isShowingMessage)
        XCTAssertEqual(messages.currentMessage, "")
    }

    func testSendWhitespaceIgnored() {
        messages.send("   ")
        XCTAssertFalse(messages.isShowingMessage)
    }

    // MARK: - Send Draft

    func testSendDraft() {
        messages.draftMessage = "Q&A next"
        messages.sendDraft()
        XCTAssertEqual(messages.currentMessage, "Q&A NEXT")
        XCTAssertTrue(messages.isShowingMessage)
        XCTAssertEqual(messages.draftMessage, "")
    }

    func testSendEmptyDraftIgnored() {
        messages.draftMessage = ""
        messages.sendDraft()
        XCTAssertFalse(messages.isShowingMessage)
    }

    // MARK: - Clear

    func testClear() {
        messages.send("WRAP UP")
        messages.clear()
        XCTAssertEqual(messages.currentMessage, "")
        XCTAssertFalse(messages.isShowingMessage)
    }

    // MARK: - Quick Messages

    func testQuickMessagesNotEmpty() {
        XCTAssertFalse(MessageEngine.quickMessages.isEmpty)
    }

    func testQuickMessagesAreUppercase() {
        for msg in MessageEngine.quickMessages {
            XCTAssertEqual(msg, msg.uppercased(), "\(msg) should be uppercase")
        }
    }
}
