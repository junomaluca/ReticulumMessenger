// SPDX-License-Identifier: MIT
// ReticulumKitTests — CryptoTests.swift

import XCTest
@testable import ReticulumKit

final class CryptoTests: XCTestCase {

    func testSHA256() {
        let data = Data("hello world".utf8)
        let hash = RNSCrypto.sha256(data)
        XCTAssertEqual(hash.count, 32)

        // Known SHA-256 of "hello world"
        let expected = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        XCTAssertEqual(hash.map { String(format: "%02x", $0) }.joined(), expected)
    }

    func testTruncatedHash() {
        let data = Data("test".utf8)
        let hash = RNSCrypto.truncatedHash(data)
        XCTAssertEqual(hash.count, RNS.truncatedHashLength)
        XCTAssertEqual(hash.count, 16)
    }

    func testRandomBytes() {
        let bytes1 = RNSCrypto.randomBytes(count: 32)
        let bytes2 = RNSCrypto.randomBytes(count: 32)
        XCTAssertEqual(bytes1.count, 32)
        XCTAssertEqual(bytes2.count, 32)
        XCTAssertNotEqual(bytes1, bytes2) // Astronomically unlikely to be equal
    }

    func testHMACSHA256() {
        let key = RNSCrypto.randomBytes(count: 16)
        let data = Data("test message".utf8)
        let mac = RNSCrypto.hmacSHA256(key: key, data: data)
        XCTAssertEqual(mac.count, 32)

        // Verify HMAC
        XCTAssertTrue(RNSCrypto.verifyHMAC(key: key, data: data, mac: mac))

        // Wrong data should fail
        XCTAssertFalse(RNSCrypto.verifyHMAC(key: key, data: Data("wrong".utf8), mac: mac))

        // Wrong key should fail
        let wrongKey = RNSCrypto.randomBytes(count: 16)
        XCTAssertFalse(RNSCrypto.verifyHMAC(key: wrongKey, data: data, mac: mac))
    }

    func testAES128CBC() throws {
        let key = RNSCrypto.randomBytes(count: 16)
        let iv = RNSCrypto.randomBytes(count: 16)
        let plaintext = Data("Hello, Reticulum! This is a test message for AES.".utf8)

        let ciphertext = try RNSCrypto.aes128CBCEncrypt(key: key, iv: iv, plaintext: plaintext)
        XCTAssertNotEqual(ciphertext, plaintext)

        let decrypted = try RNSCrypto.aes128CBCDecrypt(key: key, iv: iv, ciphertext: ciphertext)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testAES128CBCEmptyData() throws {
        let key = RNSCrypto.randomBytes(count: 16)
        let iv = RNSCrypto.randomBytes(count: 16)
        let plaintext = Data()

        let ciphertext = try RNSCrypto.aes128CBCEncrypt(key: key, iv: iv, plaintext: plaintext)
        let decrypted = try RNSCrypto.aes128CBCDecrypt(key: key, iv: iv, ciphertext: ciphertext)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testFernetRoundTrip() throws {
        let key = RNSCrypto.randomBytes(count: 32)
        let plaintext = Data("Secret mesh message".utf8)

        let token = try RNSFernet.encrypt(plaintext: plaintext, key: key)
        XCTAssertTrue(token.count > plaintext.count) // Must be larger due to overhead

        let decrypted = try RNSFernet.decrypt(token: token, key: key)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testFernetWrongKey() throws {
        let key1 = RNSCrypto.randomBytes(count: 32)
        let key2 = RNSCrypto.randomBytes(count: 32)
        let plaintext = Data("Secret".utf8)

        let token = try RNSFernet.encrypt(plaintext: plaintext, key: key1)
        XCTAssertThrowsError(try RNSFernet.decrypt(token: token, key: key2))
    }

    func testFernetTamperedToken() throws {
        let key = RNSCrypto.randomBytes(count: 32)
        let plaintext = Data("Secret".utf8)

        var token = try RNSFernet.encrypt(plaintext: plaintext, key: key)
        // Tamper with a byte in the middle
        token[token.count / 2] ^= 0xFF
        XCTAssertThrowsError(try RNSFernet.decrypt(token: token, key: key))
    }

    func testHKDF() {
        let ikm = RNSCrypto.randomBytes(count: 32)
        let derived = RNSCrypto.hkdf(inputKeyMaterial: ikm, outputByteCount: 64)
        XCTAssertEqual(derived.count, 64)

        // Same input should produce same output
        let derived2 = RNSCrypto.hkdf(inputKeyMaterial: ikm, outputByteCount: 64)
        XCTAssertEqual(derived, derived2)
    }

    func testX25519KeyExchange() throws {
        let privA = RNSCrypto.generateX25519PrivateKey()
        let privB = RNSCrypto.generateX25519PrivateKey()

        let sharedAB = try RNSCrypto.x25519(privateKey: privA, publicKey: privB.publicKey)
        let sharedBA = try RNSCrypto.x25519(privateKey: privB, publicKey: privA.publicKey)

        XCTAssertEqual(sharedAB, sharedBA) // ECDH shared secret must be symmetric
    }

    func testEd25519SignVerify() throws {
        let privKey = RNSCrypto.generateEd25519PrivateKey()
        let message = Data("Sign this message".utf8)

        let signature = try RNSCrypto.sign(data: message, privateKey: privKey)
        XCTAssertEqual(signature.count, 64)

        XCTAssertTrue(RNSCrypto.verify(
            signature: signature,
            data: message,
            publicKey: privKey.publicKey
        ))

        // Wrong message should fail
        XCTAssertFalse(RNSCrypto.verify(
            signature: signature,
            data: Data("wrong".utf8),
            publicKey: privKey.publicKey
        ))
    }
}
