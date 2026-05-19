// SPDX-License-Identifier: MIT
// ReticulumMessengerTests — Basic app tests.

import XCTest

final class ReticulumMessengerTests: XCTestCase {

    func testStorageService() {
        let storage = StorageService()

        // Test display name persistence
        storage.saveDisplayName("TestUser")
        XCTAssertEqual(storage.loadDisplayName(), "TestUser")

        storage.saveDisplayName(nil)
        XCTAssertNil(storage.loadDisplayName())
    }

    func testConversationModel() {
        let peerHash = Data(repeating: 0xAB, count: 16)
        var conv = Conversation(peerHash: peerHash, displayName: "Alice")

        XCTAssertEqual(conv.resolvedName, "Alice")
        XCTAssertEqual(conv.unreadCount, 0)
        XCTAssertNil(conv.lastMessage)
        XCTAssertFalse(conv.isArchived)

        // Add a message
        let msg = ChatMessage(content: "Hello", isIncoming: true)
        conv.messages.append(msg)
        XCTAssertEqual(conv.unreadCount, 1)
        XCTAssertEqual(conv.lastMessage?.content, "Hello")
    }

    func testConversationWithoutDisplayName() {
        let peerHash = Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC] + Array(repeating: UInt8(0), count: 10))
        let conv = Conversation(peerHash: peerHash)

        // Should show truncated hash
        XCTAssertTrue(conv.resolvedName.starts(with: "12345678"))
    }

    func testChatMessageState() {
        let pending = ChatMessage(content: "test", isIncoming: false, state: .pending)
        XCTAssertEqual(pending.state, .pending)
        XCTAssertFalse(pending.isIncoming)

        let received = ChatMessage(content: "hi", isIncoming: true)
        XCTAssertTrue(received.isIncoming)
    }
}

// Import the app module for testing
@testable import ReticulumMessenger
