# Reticulum Messenger for iOS

**A native iOS client for the [Reticulum Network Stack](https://reticulum.network), bringing decentralized, encrypted mesh messaging to iPhone and iPad.**

Reticulum Messenger is the iOS counterpart to [Sideband](https://github.com/markqvist/Sideband) for Android. It implements the [LXMF](https://github.com/markqvist/lxmf) messaging protocol over Reticulum, enabling fully encrypted peer-to-peer communication that works over any medium — WiFi, cellular, LoRa, serial, or packet radio — with zero dependence on centralized infrastructure.

> **Status: Active Development (v0.2.0)**
> The core protocol architecture is in place with a comprehensive feature set. Community contributions are welcome to refine, test, and extend functionality. See [Contributing](#contributing) below.

---

## Why This Exists

There is currently no native iOS client for the Reticulum ecosystem. Android users have Sideband, and desktop/CLI users have NomadNet — but iOS users are left out. This project aims to change that with a clean, well-architected Swift implementation that:

- **Runs natively on iOS** using SwiftUI, CryptoKit, and the Network framework
- **Has zero external dependencies** — pure Swift and Apple frameworks only
- **Is protocol-compatible** with existing Reticulum networks and LXMF nodes
- **Is designed for contributors** with clean architecture and comprehensive documentation

## Features

### Core Protocol
- [x] Reticulum identity generation (Ed25519 + X25519 keypairs)
- [x] Reticulum packet encoding/decoding (wire-compatible format)
- [x] AES-128-CBC encryption with Fernet tokens (protocol-compatible)
- [x] HKDF-SHA256 key derivation, HMAC-SHA256 authentication
- [x] Identity persistence and Keychain-ready storage
- [x] Auto-reconnection with exponential backoff

### Network Interfaces
- [x] TCP client interface with HDLC framing
- [x] UDP interface (unicast and broadcast)
- [x] RNode BLE interface — connect to LoRa radio hardware via Bluetooth
  - KISS protocol framing/deframing
  - Full radio configuration (frequency, bandwidth, SF, coding rate, TX power)
  - Quick presets: Long Range, Balanced, Fast
  - Real-time RSSI, SNR, battery monitoring
  - Firmware version detection

### Messaging (LXMF)
- [x] LXMF message serialization via MessagePack
- [x] Direct delivery and propagation node fallback
- [x] Delivery receipts and status tracking
- [x] Image attachments (photo picker)
- [x] File attachments (document picker)
- [x] Voice messages (audio recorder)
- [x] Peer discovery via network announces

### Mesh Features
- [x] Auto-announce — periodic presence broadcasting
- [x] Transport mode — act as a Reticulum packet relay
- [x] Propagation node mode — store-and-forward for offline peers
- [x] Announce stream — live view of network announce traffic
- [x] QR code identity sharing and scanning
- [x] Paper message support (lxm:// URI scheme)

### Location & Telemetry
- [x] Live mesh map — MapKit view showing peer positions
- [x] GPS location sharing (opt-in)
- [x] Device telemetry collection (battery, position)
- [x] Peer location tracking with stale-entry cleanup

### User Experience
- [x] Modern SwiftUI interface with tab navigation
- [x] Deterministic identicon avatars from identity hashes
- [x] Local notifications for incoming messages
- [x] Haptic feedback (send, receive, connect events)
- [x] Notification categories with quick reply
- [x] Unread badges on conversations and app icon
- [x] Conversation search
- [x] Swipe-to-delete conversations

### Planned
- [ ] Full link establishment with proof verification
- [ ] Group messaging
- [ ] End-to-end encrypted file transfers over links
- [ ] Contact management with nicknames and notes
- [ ] Message search within conversations
- [ ] NomadNet page rendering
- [ ] iPad split-view layout
- [ ] Interoperability test suite against Python reference

## Architecture

The project is organized as a **Swift Package** containing the protocol libraries, and a separate **iOS app target** that consumes them:

```
ReticulumMessenger/
├── Packages/ReticulumKit/           # Protocol implementation (Swift Package)
│   ├── Sources/
│   │   ├── CCommonCrypto/           # C wrapper for CommonCrypto (AES-CBC)
│   │   ├── ReticulumKit/            # Reticulum Network Stack
│   │   │   ├── Cryptography/        # X25519, Ed25519, AES-CBC, Fernet, HKDF
│   │   │   ├── Identity/            # Cryptographic identity management
│   │   │   ├── Destination/         # Addressable network endpoints
│   │   │   ├── Packet/              # Wire-format packet encoding/decoding
│   │   │   ├── Interface/           # TCP, UDP, RNode BLE, KISS protocol
│   │   │   ├── Transport/           # Path management and packet routing
│   │   │   └── Link/               # Encrypted bidirectional links & channels
│   │   └── LXMFKit/                # LXMF Messaging Protocol
│   │       ├── Message/             # LXMessage type and serialization
│   │       ├── Router/              # Message routing, peer discovery, propagation
│   │       └── Serialization/       # MessagePack encoder/decoder
│   └── Tests/
├── ReticulumMessenger/              # iOS App (SwiftUI)
│   ├── App/                         # App entry point and state management
│   ├── Models/                      # UI data models (Conversation, RNodeInfo, etc.)
│   ├── Services/                    # Messenger, storage, telemetry, notifications
│   └── Views/                       # SwiftUI views
│       ├── Conversations/           # Conversation list, new conversation, QR codes
│       ├── Messages/                # Chat view, bubbles, attachment picker
│       ├── Network/                 # Status, interface config, map, announce stream
│       ├── RNode/                   # RNode scanning, connection, configuration
│       ├── Settings/                # Identity, interfaces, mesh features, about
│       └── Components/              # Reusable UI components (avatar, status)
└── ReticulumMessengerTests/
```

### Design Principles

1. **Pure Swift** — No external dependencies. Only Apple frameworks (CryptoKit, Network, CommonCrypto, SwiftUI, MapKit, CoreBluetooth, CoreLocation).
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
git clone https://github.com/junomaluca/ReticulumMessenger.git
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

### Using an RNode

1. Go to **Settings → RNode Device**
2. Tap **Scan** to discover nearby RNode hardware
3. Select your device to connect via Bluetooth
4. Configure radio parameters or use a preset (Long Range / Balanced / Fast)
5. The RNode will appear as an interface in your network status

## Contributing

**This project needs you.** Whether you're experienced with Reticulum or new to mesh networking, there are meaningful ways to contribute:

### High-Impact Areas

| Area | Description | Difficulty |
|------|-------------|------------|
| **Link Establishment** | Complete the link handshake with full proof verification | Advanced |
| **Group Messaging** | Multi-party encrypted conversations | Advanced |
| **File Transfers** | End-to-end encrypted resource transfers over links | Intermediate |
| **Protocol Testing** | Interoperability tests against the Python reference | Intermediate |
| **Contact Management** | Persistent contacts with nicknames, notes, grouping | Beginner |
| **UI Polish** | Animations, accessibility, iPad split-view layout | Beginner |
| **Documentation** | Protocol documentation, code comments, user guide | Beginner |

### How to Contribute

1. **Fork** this repository
2. **Create a branch** for your feature (`git checkout -b feature/group-messaging`)
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
- [Sideband](https://github.com/markqvist/Sideband) — Android LXMF client
- [NomadNet](https://github.com/markqvist/NomadNet) — Terminal-based Reticulum client

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.

## Acknowledgments

- [Mark Qvist](https://github.com/markqvist) for creating Reticulum, LXMF, and Sideband
- The Reticulum community for building an alternative to centralized communication
- All contributors to this project
