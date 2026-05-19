# Reticulum Messenger for iOS

**A native iOS client for the [Reticulum Network Stack](https://reticulum.network), bringing decentralized, encrypted mesh messaging to iPhone and iPad.**

Reticulum Messenger is the iOS counterpart to [Sideband](https://github.com/markqvist/Sideband) for Android. It implements the [LXMF](https://github.com/markqvist/lxmf) messaging protocol over Reticulum, enabling fully encrypted peer-to-peer communication that works over any medium — WiFi, cellular, LoRa, serial, or packet radio — with zero dependence on centralized infrastructure.

> **Status: Early Development (v0.1.0)**
> This is a working foundation seeking contributors. The core protocol architecture is in place and the app is functional, but many features need implementation and refinement. See [Contributing](#contributing) below.

---

## Why This Exists

There is currently no native iOS client for the Reticulum ecosystem. Android users have Sideband, and desktop/CLI users have NomadNet — but iOS users are left out. This project aims to change that with a clean, well-architected Swift implementation that:

- **Runs natively on iOS** using SwiftUI, CryptoKit, and the Network framework
- **Has zero external dependencies** — pure Swift and Apple frameworks only
- **Is protocol-compatible** with existing Reticulum networks and LXMF nodes
- **Is designed for contributors** with clean architecture and comprehensive documentation

## Features

### Implemented
- [x] Reticulum identity generation (Ed25519 + X25519 keypairs)
- [x] Reticulum packet encoding/decoding (wire-compatible format)
- [x] AES-128-CBC encryption with Fernet tokens (protocol-compatible)
- [x] TCP client interface with HDLC framing
- [x] LXMF message serialization via MessagePack
- [x] Identity persistence and management
- [x] Modern SwiftUI interface with conversations, messages, network status
- [x] Deterministic avatar generation from identity hashes
- [x] Auto-reconnection with exponential backoff

### Planned
- [ ] Full link establishment with proof verification
- [ ] LXMF propagation node support (store-and-forward)
- [ ] Resource transfers (file sharing)
- [ ] Group messaging
- [ ] UDP interface
- [ ] BLE interface (for local mesh without infrastructure)
- [ ] LoRa interface via serial (with compatible hardware)
- [ ] Background operation and push notifications
- [ ] QR code identity sharing
- [ ] Contact management with nicknames and notes
- [ ] Message search
- [ ] Voice messages
- [ ] NomadNet page rendering

## Architecture

The project is organized as a **Swift Package** containing the protocol libraries, and a separate **iOS app target** that consumes them:

```
ReticulumMessenger/
├── Packages/ReticulumKit/           # Protocol implementation (Swift Package)
│   ├── Sources/
│   │   ├── ReticulumKit/            # Reticulum Network Stack
│   │   │   ├── Cryptography/        # X25519, Ed25519, AES-CBC, Fernet, HKDF
│   │   │   ├── Identity/            # Cryptographic identity management
│   │   │   ├── Destination/         # Addressable network endpoints
│   │   │   ├── Packet/              # Wire-format packet encoding/decoding
│   │   │   ├── Interface/           # Network interface protocol + TCP
│   │   │   ├── Transport/           # Path management and packet routing
│   │   │   └── Link/               # Encrypted bidirectional links
│   │   └── LXMFKit/                # LXMF Messaging Protocol
│   │       ├── Message/             # LXMessage type and serialization
│   │       ├── Router/              # Message routing and peer discovery
│   │       └── Serialization/       # MessagePack encoder/decoder
│   └── Tests/
├── ReticulumMessenger/              # iOS App (SwiftUI)
│   ├── App/                         # App entry point and state management
│   ├── Models/                      # UI data models
│   ├── Services/                    # Messenger and storage services
│   └── Views/                       # SwiftUI views
│       ├── Conversations/           # Conversation list and creation
│       ├── Messages/                # Chat view with message bubbles
│       ├── Network/                 # Network status and interface config
│       ├── Settings/                # Identity, interfaces, about
│       └── Components/              # Reusable UI components
└── ReticulumMessengerTests/
```

### Design Principles

1. **Pure Swift** — No external dependencies. Only Apple frameworks (CryptoKit, Network, CommonCrypto, SwiftUI).
2. **Protocol-compatible** — Wire-format packets, crypto operations, and LXMF messages are compatible with the reference Python implementation.
3. **Library-first** — The protocol stack (`ReticulumKit` + `LXMFKit`) is a standalone Swift Package that can be used independently of the iOS app.
4. **Actor-based concurrency** — Transport, routing, and storage use Swift actors for thread safety.
5. **Contributor-friendly** — Each component has clear boundaries, making it easy to pick up and improve a specific area.

## Getting Started

### Prerequisites

- **Xcode 15+** (Swift 5.9+)
- **iOS 17.0+** deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for project generation

### Setup

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/ReticulumMessenger.git
cd ReticulumMessenger

# Generate the Xcode project and open it
make setup

# Or manually:
brew install xcodegen
xcodegen generate
open ReticulumMessenger.xcodeproj
```

### Running Tests

```bash
# Run the Swift Package tests
make test

# Or via Xcode: Product → Test (⌘U)
```

### Connecting to the Network

1. Build and run on a simulator or device
2. Go to the **Network** tab
3. Tap **+** to add an interface
4. Use the **Testnet** quick-fill button, or enter your own Reticulum node address
5. The app will connect and begin discovering peers

## Contributing

**This project needs you.** Whether you're experienced with Reticulum or new to mesh networking, there are meaningful ways to contribute:

### High-Impact Areas

| Area | Description | Difficulty |
|------|-------------|------------|
| **Link Establishment** | Complete the link handshake with full proof verification | Advanced |
| **Propagation Nodes** | Implement store-and-forward via LXMF propagation nodes | Advanced |
| **BLE Interface** | Bluetooth Low Energy interface for local mesh communication | Intermediate |
| **Resource Transfers** | File/data transfers over Reticulum links | Intermediate |
| **Background Mode** | Keep connections alive in background, handle push notifications | Intermediate |
| **QR Code Sharing** | Share/scan identity hashes via QR codes | Beginner |
| **Contact Management** | Persistent contacts with nicknames, notes, grouping | Beginner |
| **UI Polish** | Animations, haptics, accessibility, iPad layout | Beginner |
| **Protocol Testing** | Interoperability tests against the Python reference implementation | Intermediate |
| **Documentation** | Protocol documentation, code comments, user guide | Beginner |

### How to Contribute

1. **Fork** this repository
2. **Create a branch** for your feature (`git checkout -b feature/ble-interface`)
3. **Make your changes** with clear, well-documented code
4. **Add tests** for new functionality
5. **Submit a pull request** with a description of what you've done

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

### Good First Issues

Look for issues tagged `good-first-issue` — these are specifically chosen to be approachable for newcomers to the project.

## Protocol Reference

### Reticulum Packet Format

```
Type 1 (single address):
┌────────┬──────┬───────────────────┬─────────┬──────────┐
│ Header │ Hops │ Destination Hash  │ Context │ Data ... │
│ 1 byte │ 1 B  │ 16 bytes          │ 1 byte  │ variable │
└────────┴──────┴───────────────────┴─────────┴──────────┘

Type 2 (with transport):
┌────────┬──────┬──────────────┬───────────────────┬─────────┬──────────┐
│ Header │ Hops │ Transport ID │ Destination Hash  │ Context │ Data ... │
│ 1 byte │ 1 B  │ 16 bytes     │ 16 bytes          │ 1 byte  │ variable │
└────────┴──────┴──────────────┴───────────────────┴─────────┴──────────┘

Header byte: [HeaderType:2][PropType:2][DestType:2][PacketType:2]
```

### Identity

Each identity consists of:
- **Ed25519** signing keypair (authentication & signatures)
- **X25519** key agreement keypair (encryption & key exchange)
- **Identity hash** = `SHA-256(Ed25519_pub ‖ X25519_pub)[:16]`

### LXMF Message

Messages are MessagePack-encoded arrays:
```
[source_hash, destination_hash, method, {field_map}]
```

Field types: content (0x01), title (0x02), timestamp (0x03), attachments (0x04), source name (0x07), etc.

## Related Projects

- [Reticulum](https://github.com/markqvist/Reticulum) — The cryptography-based networking stack
- [LXMF](https://github.com/markqvist/lxmf) — Lightweight Extensible Message Format
- [Sideband](https://github.com/markqvist/Sideband) — Android LXMF client (our inspiration)
- [NomadNet](https://github.com/markqvist/NomadNet) — Terminal-based Reticulum client

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.

## Acknowledgments

- [Mark Qvist](https://github.com/markqvist) for creating Reticulum, LXMF, and Sideband
- The Reticulum community for building an alternative to centralized communication
- All contributors to this project
