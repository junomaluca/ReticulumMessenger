// SPDX-License-Identifier: MIT
// ReticulumKitTests — IdentityTests.swift

import XCTest
@testable import ReticulumKit

final class IdentityTests: XCTestCase {

    func testIdentityGeneration() {
        let identity = RNSIdentity()
        XCTAssertEqual(identity.hash.count, RNS.truncatedHashLength)
        XCTAssertEqual(identity.publicKeyBytes.count, RNS.identityKeySize)
        XCTAssertTrue(identity.hasPrivateKeys)
    }

    func testIdentityHashDeterminism() {
        let identity = RNSIdentity()
        let hash1 = identity.hash
        let hash2 = identity.hash
        XCTAssertEqual(hash1, hash2)
    }

    func testIdentityUniqueness() {
        let id1 = RNSIdentity()
        let id2 = RNSIdentity()
        XCTAssertNotEqual(id1.hash, id2.hash)
    }

    func testIdentityFromPublicKey() throws {
        let original = RNSIdentity()
        let restored = try RNSIdentity(publicKeyBytes: original.publicKeyBytes)

        XCTAssertEqual(original.hash, restored.hash)
        XCTAssertFalse(restored.hasPrivateKeys)
    }

    func testIdentityFromPrivateKey() throws {
        let original = RNSIdentity()
        let keyData = try original.exportPrivateKeys()
        let restored = try RNSIdentity(privateKeyBytes: keyData)

        XCTAssertEqual(original.hash, restored.hash)
        XCTAssertTrue(restored.hasPrivateKeys)
    }

    func testSignAndVerify() throws {
        let identity = RNSIdentity()
        let message = Data("Hello mesh network".utf8)

        let signature = try identity.sign(message)
        XCTAssertTrue(identity.verify(signature: signature, for: message))
        XCTAssertFalse(identity.verify(signature: signature, for: Data("tampered".utf8)))
    }

    func testEncryptDecrypt() throws {
        let identity = RNSIdentity()
        let plaintext = Data("Secret message across the mesh".utf8)

        let ciphertext = try identity.encrypt(plaintext)
        XCTAssertNotEqual(ciphertext, plaintext)

        let decrypted = try identity.decrypt(ciphertext)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testEncryptForRemoteIdentity() throws {
        let sender = RNSIdentity()
        let receiver = RNSIdentity()

        // Sender encrypts to receiver's public key
        let receiverPub = try RNSIdentity(publicKeyBytes: receiver.publicKeyBytes)
        let plaintext = Data("Private message".utf8)
        let ciphertext = try receiverPub.encrypt(plaintext)

        // Receiver decrypts with private key
        let decrypted = try receiver.decrypt(ciphertext)
        XCTAssertEqual(decrypted, plaintext)

        // Sender cannot decrypt (different private key)
        XCTAssertThrowsError(try sender.decrypt(ciphertext))
    }

    func testPublicOnlyIdentityCannotSign() {
        let original = RNSIdentity()
        let pubOnly = try! RNSIdentity(publicKeyBytes: original.publicKeyBytes)

        XCTAssertThrowsError(try pubOnly.sign(Data("test".utf8)))
    }

    func testHexHash() {
        let identity = RNSIdentity()
        let hex = identity.hexHash
        XCTAssertEqual(hex.count, 32) // 16 bytes = 32 hex chars
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit })
    }

    func testEquality() {
        let id1 = RNSIdentity()
        let id2 = try! RNSIdentity(publicKeyBytes: id1.publicKeyBytes)
        XCTAssertEqual(id1, id2)

        let id3 = RNSIdentity()
        XCTAssertNotEqual(id1, id3)
    }
}
