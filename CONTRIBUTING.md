# Contributing to Reticulum Messenger

Thank you for your interest in contributing! This project aims to bring Reticulum mesh networking to iOS, and every contribution helps make that a reality.

## Getting Started

### Prerequisites

- Xcode 15+ with Swift 5.9+
- macOS 14+ (Sonoma or later)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Basic familiarity with Swift and SwiftUI

### Setup

```bash
git clone https://github.com/YOUR_USERNAME/ReticulumMessenger.git
cd ReticulumMessenger
make setup  # Generates Xcode project and opens it
```

### Running Tests

```bash
make test                    # Package library tests
# Or in Xcode: ⌘U           # All tests
```

## Project Structure

The codebase has two main layers:

### Protocol Layer (`Packages/ReticulumKit/`)

The Swift Package containing the protocol implementation. This is where most of the "hard" networking and crypto work lives.

- **ReticulumKit** — The Reticulum Network Stack
  - `Cryptography/` — All crypto primitives (AES-CBC, Fernet, HKDF, X25519, Ed25519)
  - `Identity/` — Cryptographic identity generation and management
  - `Destination/` — Network endpoint addressing
  - `Packet/` — Wire-format packet encoding/decoding
  - `Interface/` — Network interface protocol and TCP implementation
  - `Transport/` — Path discovery and packet routing
  - `Link/` — Encrypted bidirectional communication channels

- **LXMFKit** — The LXMF Messaging Protocol
  - `Message/` — LXMF message types and serialization
  - `Router/` — Message delivery and peer discovery
  - `Serialization/` — MessagePack encoder/decoder

### App Layer (`ReticulumMessenger/`)

The iOS app built with SwiftUI.

- `App/` — App entry point and central state management
- `Models/` — UI-friendly data models
- `Services/` — Bridges between protocol layer and UI
- `Views/` — All SwiftUI views, organized by feature

## How to Contribute

### 1. Find Something to Work On

- Check the [Issues](../../issues) tab for open tasks
- Look for `good-first-issue` labels if you're new
- Check the roadmap in the README for planned features
- Found a bug? Open an issue first to discuss

### 2. Create a Branch

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/bug-description
```

### 3. Write Your Code

**Style guidelines:**

- Follow existing code style (Swift conventions, MARK comments, documentation)
- Use `SPDX-License-Identifier: MIT` at the top of new files
- Use Swift concurrency (async/await, actors) for concurrent code
- Keep dependencies to zero — use only Apple frameworks
- Write doc comments for public APIs

**Architecture guidelines:**

- Protocol code goes in the Swift Package, not the app
- UI code should not import `ReticulumKit` directly where possible — use the service layer
- Use actors for shared mutable state
- Make types `Sendable` where appropriate

### 4. Add Tests

- All protocol-level code should have unit tests
- Place tests in `Tests/ReticulumKitTests/` or `Tests/LXMFKitTests/`
- Test edge cases and error paths, not just happy paths
- Run `make test` before submitting

### 5. Submit a Pull Request

- Write a clear description of what your PR does and why
- Reference any related issues
- Keep PRs focused — one feature or fix per PR
- Be responsive to review feedback

## Coding Standards

### Swift Style

```swift
// Use clear, descriptive names
public func createDestination(appName: String, aspects: [String]) -> RNSDestination

// Document public APIs
/// Encrypt data so only this identity can decrypt it.
/// Uses ephemeral X25519 key exchange + Fernet encryption.
/// - Returns: Encrypted token prefixed with the ephemeral public key.
public func encrypt(_ plaintext: Data) throws -> Data

// Use MARK comments to organize files
// MARK: - Properties
// MARK: - Initialization
// MARK: - Public Methods
// MARK: - Private Helpers
```

### Error Handling

- Define specific error enums per module (e.g., `RNSCryptoError`, `RNSPacketError`)
- Conform to `LocalizedError` with descriptive messages
- Prefer throwing over optionals for recoverable errors
- Use `guard` for preconditions

### Concurrency

- Use actors for shared mutable state (see `RNSTransport`, `IdentityStorage`)
- Make types `Sendable` when they cross concurrency boundaries
- Use `@MainActor` for UI-related state
- Prefer structured concurrency (TaskGroup, async let) over unstructured

## Protocol Compatibility

**This is critical.** The whole point of this project is to interoperate with existing Reticulum networks. When implementing protocol features:

1. **Reference the Python implementation** — The authoritative source is [github.com/markqvist/Reticulum](https://github.com/markqvist/Reticulum)
2. **Test against real nodes** — Use the Reticulum Testnet to verify compatibility
3. **Document deviations** — If you intentionally differ from the reference, explain why
4. **Preserve wire format** — Packet encoding, crypto operations, and LXMF serialization must be byte-compatible

## Questions?

- Open a [Discussion](../../discussions) for general questions
- Open an [Issue](../../issues) for bugs or feature requests
- Check the [Reticulum documentation](https://markqvist.github.io/Reticulum/manual/) for protocol details

Thank you for contributing to decentralized communication!
