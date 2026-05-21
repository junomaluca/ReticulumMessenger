// SPDX-License-Identifier: MIT
// ReticulumKit — RNSCrypto.swift
// Cryptographic primitives for the Reticulum protocol.
// Uses CryptoKit for modern operations and CommonCrypto for AES-CBC.

import Foundation
import CryptoKit
import CCommonCrypto

/// Cryptographic operations for the Reticulum Network Stack.
/// All methods are protocol-compatible with the Python reference implementation.
public enum RNSCrypto {

    // MARK: - Hashing

    /// Compute SHA-256 hash of the given data.
    public static func sha256(_ data: Data) -> Data {
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    /// Compute a truncated SHA-256 hash (first 16 bytes / 128 bits).
    /// Used for Reticulum addresses and destination hashes.
    public static func truncatedHash(_ data: Data) -> Data {
        sha256(data).prefix(RNS.truncatedHashLength)
    }

    /// Compute the truncated name hash used in destination addressing and announces.
    /// Returns the first 10 bytes (80 bits) of SHA-256, matching the Python reference
    /// Identity.NAME_HASH_LENGTH // 8.
    public static func nameHash(_ appName: String) -> Data {
        Data(sha256(Data(appName.utf8)).prefix(RNS.nameHashLength))
    }

    // MARK: - Key Generation

    /// Generate a new X25519 private key for key agreement.
    public static func generateX25519PrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    /// Generate a new Ed25519 private key for signing.
    public static func generateEd25519PrivateKey() -> Curve25519.Signing.PrivateKey {
        Curve25519.Signing.PrivateKey()
    }

    // MARK: - Key Agreement (X25519 / ECDH)

    /// Perform X25519 Diffie-Hellman key exchange.
    public static func x25519(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        publicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> Data {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return shared.withUnsafeBytes { Data($0) }
    }

    // MARK: - Key Derivation (HKDF)

    /// Derive a symmetric key using HKDF-SHA256.
    public static func hkdf(
        inputKeyMaterial: Data,
        salt: Data? = nil,
        info: Data = Data(),
        outputByteCount: Int = 32
    ) -> Data {
        let ikm = SymmetricKey(data: inputKeyMaterial)
        let derived: SymmetricKey
        if let salt = salt {
            derived = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm,
                salt: salt,
                info: info,
                outputByteCount: outputByteCount
            )
        } else {
            derived = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm,
                info: info,
                outputByteCount: outputByteCount
            )
        }
        return derived.withUnsafeBytes { Data($0) }
    }

    // MARK: - HMAC-SHA256

    /// Compute HMAC-SHA256 for the given data and key.
    public static func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }

    /// Verify an HMAC-SHA256 tag.
    public static func verifyHMAC(key: Data, data: Data, mac: Data) -> Bool {
        let expected = hmacSHA256(key: key, data: data)
        // Constant-time comparison
        guard expected.count == mac.count else { return false }
        var result: UInt8 = 0
        for (a, b) in zip(expected, mac) {
            result |= a ^ b
        }
        return result == 0
    }

    // MARK: - Signing (Ed25519)

    /// Sign data with an Ed25519 private key.
    public static func sign(
        data: Data,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        try privateKey.signature(for: data)
    }

    /// Verify an Ed25519 signature.
    public static func verify(
        signature: Data,
        data: Data,
        publicKey: Curve25519.Signing.PublicKey
    ) -> Bool {
        publicKey.isValidSignature(signature, for: data)
    }

    // MARK: - AES-128-CBC (via CommonCrypto)

    /// Encrypt data using AES-128-CBC with PKCS7 padding.
    public static func aes128CBCEncrypt(key: Data, iv: Data, plaintext: Data) throws -> Data {
        guard key.count == 16 else {
            throw RNSCryptoError.invalidKeySize
        }
        guard iv.count == 16 else {
            throw RNSCryptoError.invalidIVSize
        }

        let bufferSize = plaintext.count + kCCBlockSizeAES128
        var ciphertext = Data(count: bufferSize)
        var numBytesEncrypted: size_t = 0

        let status = ciphertext.withUnsafeMutableBytes { cipherBuf in
            key.withUnsafeBytes { keyBuf in
                iv.withUnsafeBytes { ivBuf in
                    plaintext.withUnsafeBytes { plainBuf in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            plainBuf.baseAddress, plaintext.count,
                            cipherBuf.baseAddress, bufferSize,
                            &numBytesEncrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw RNSCryptoError.encryptionFailed(status: Int(status))
        }

        ciphertext.removeSubrange(numBytesEncrypted..<ciphertext.count)
        return ciphertext
    }

    /// Decrypt data using AES-128-CBC with PKCS7 padding.
    public static func aes128CBCDecrypt(key: Data, iv: Data, ciphertext: Data) throws -> Data {
        guard key.count == 16 else {
            throw RNSCryptoError.invalidKeySize
        }
        guard iv.count == 16 else {
            throw RNSCryptoError.invalidIVSize
        }

        let bufferSize = ciphertext.count + kCCBlockSizeAES128
        var plaintext = Data(count: bufferSize)
        var numBytesDecrypted: size_t = 0

        let status = plaintext.withUnsafeMutableBytes { plainBuf in
            key.withUnsafeBytes { keyBuf in
                iv.withUnsafeBytes { ivBuf in
                    ciphertext.withUnsafeBytes { cipherBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            cipherBuf.baseAddress, ciphertext.count,
                            plainBuf.baseAddress, bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw RNSCryptoError.decryptionFailed(status: Int(status))
        }

        plaintext.removeSubrange(numBytesDecrypted..<plaintext.count)
        return plaintext
    }

    // MARK: - Random

    /// Generate cryptographically secure random bytes.
    public static func randomBytes(count: Int) -> Data {
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { buf in
            _ = CCRandomGenerateBytes(buf.baseAddress, count)
        }
        return bytes
    }
}

// MARK: - Fernet Token (Reticulum-compatible)

/// Fernet-style authenticated encryption as used by Reticulum.
/// Format: version(1) || timestamp(8) || IV(16) || ciphertext(variable) || HMAC(32)
public struct RNSFernet {

    private static let version: UInt8 = 0x80
    private static let versionSize = 1
    private static let timestampSize = 8
    private static let ivSize = 16
    private static let hmacSize = 32

    /// Encrypt and authenticate data using a 32-byte key.
    /// The key is split: first 16 bytes for HMAC signing, last 16 bytes for AES encryption.
    public static func encrypt(plaintext: Data, key: Data) throws -> Data {
        guard key.count == 32 else {
            throw RNSCryptoError.invalidKeySize
        }

        let signingKey = key.prefix(16)
        let encryptionKey = key.suffix(16)

        let iv = RNSCrypto.randomBytes(count: ivSize)

        let timestamp = UInt64(Date().timeIntervalSince1970)
        var timestampBytes = Data(count: timestampSize)
        for i in 0..<timestampSize {
            timestampBytes[timestampSize - 1 - i] = UInt8((timestamp >> (i * 8)) & 0xFF)
        }

        let ciphertext = try RNSCrypto.aes128CBCEncrypt(
            key: encryptionKey,
            iv: iv,
            plaintext: plaintext
        )

        // Token without HMAC: version || timestamp || IV || ciphertext
        var token = Data()
        token.append(version)
        token.append(timestampBytes)
        token.append(iv)
        token.append(ciphertext)

        // Compute HMAC over everything
        let hmac = RNSCrypto.hmacSHA256(key: signingKey, data: token)
        token.append(hmac)

        return token
    }

    /// Decrypt and verify a Fernet token using a 32-byte key.
    public static func decrypt(token: Data, key: Data) throws -> Data {
        guard key.count == 32 else {
            throw RNSCryptoError.invalidKeySize
        }
        guard token.count >= versionSize + timestampSize + ivSize + hmacSize else {
            throw RNSCryptoError.invalidToken
        }
        guard token[0] == version else {
            throw RNSCryptoError.invalidToken
        }

        let signingKey = key.prefix(16)
        let encryptionKey = key.suffix(16)

        let hmacOffset = token.count - hmacSize
        let tokenBody = token.prefix(hmacOffset)
        let receivedHMAC = token.suffix(hmacSize)

        guard RNSCrypto.verifyHMAC(key: signingKey, data: tokenBody, mac: receivedHMAC) else {
            throw RNSCryptoError.authenticationFailed
        }

        let ivStart = versionSize + timestampSize
        let iv = token[ivStart..<(ivStart + ivSize)]
        let ciphertext = token[(ivStart + ivSize)..<hmacOffset]

        return try RNSCrypto.aes128CBCDecrypt(
            key: encryptionKey,
            iv: Data(iv),
            ciphertext: Data(ciphertext)
        )
    }
}

// MARK: - Errors

public enum RNSCryptoError: Error, LocalizedError {
    case invalidKeySize
    case invalidIVSize
    case encryptionFailed(status: Int)
    case decryptionFailed(status: Int)
    case invalidToken
    case authenticationFailed
    case keyAgreementFailed
    case signingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidKeySize: return "Invalid key size"
        case .invalidIVSize: return "Invalid IV size"
        case .encryptionFailed(let s): return "Encryption failed with status \(s)"
        case .decryptionFailed(let s): return "Decryption failed with status \(s)"
        case .invalidToken: return "Invalid Fernet token"
        case .authenticationFailed: return "Token authentication failed"
        case .keyAgreementFailed: return "Key agreement failed"
        case .signingFailed: return "Signing failed"
        }
    }
}
