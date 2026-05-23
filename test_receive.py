#!/usr/bin/env python3
"""
Listen for LXMF messages from the phone app and decode any attachments.
Uses Sideband's identity so the phone can send to us.

Usage: python3 test_receive.py
"""

import os, sys, time

sys.path.insert(0, "/Users/patrickkann/.local/pipx/venvs/sbapp/lib/python3.13/site-packages")
import RNS
import LXMF
from RNS.vendor import umsgpack

IDENTITY_PATH = os.path.expanduser("~/.config/sideband/app_storage/primary_identity")
RNS_CONFIG_DIR = "/tmp/test-rns-config"
STORAGE_PATH = "/tmp/lxmf-recv-storage"
os.makedirs(STORAGE_PATH, exist_ok=True)

received = []

def on_delivery(message):
    ts = time.strftime("%H:%M:%S")
    content = message.content_as_string() if hasattr(message, 'content_as_string') else str(message.content)
    title = message.title_as_string() if hasattr(message, 'title_as_string') else str(message.title)
    src = message.source_hash.hex() if message.source_hash else "?"

    print(f"\n[{ts}] MESSAGE RECEIVED from {src[:16]}...")
    print(f"  Title: {title!r}")
    print(f"  Content: {content[:200]!r}")

    if message.fields:
        print(f"  Fields: {list(message.fields.keys())}")
        for field_id, value in message.fields.items():
            if field_id == LXMF.FIELD_IMAGE:
                if isinstance(value, list) and len(value) >= 2:
                    img_type = value[0]
                    img_data = value[1]
                    print(f"  FIELD_IMAGE: type={img_type}, size={len(img_data)} bytes")
                    # Save to disk
                    ext = img_type if isinstance(img_type, str) else "bin"
                    fname = f"/tmp/received_image.{ext}"
                    with open(fname, "wb") as f:
                        f.write(img_data if isinstance(img_data, bytes) else bytes(img_data))
                    print(f"    -> Saved to {fname}")
            elif field_id == LXMF.FIELD_AUDIO:
                if isinstance(value, list) and len(value) >= 2:
                    mode = value[0]
                    audio_data = value[1]
                    codec = "opus" if mode >= 16 else "codec2"
                    print(f"  FIELD_AUDIO: mode={mode} ({codec}), size={len(audio_data)} bytes")
            elif field_id == LXMF.FIELD_FILE_ATTACHMENTS:
                if isinstance(value, list):
                    for i, entry in enumerate(value):
                        if isinstance(entry, list) and len(entry) >= 2:
                            name = entry[0]
                            data = entry[1]
                            print(f"  FIELD_FILE[{i}]: name={name}, size={len(data)} bytes")
                            fname = f"/tmp/received_{name}"
                            with open(fname, "wb") as f:
                                f.write(data if isinstance(data, bytes) else bytes(data))
                            print(f"    -> Saved to {fname}")
            else:
                print(f"  Field 0x{field_id:02x}: {type(value).__name__}")
    else:
        print(f"  (no fields)")

    received.append(message)
    print(f"  Total received: {len(received)}")


def main():
    print("=" * 60)
    print("LXMF Receiver — waiting for messages from phone")
    print("=" * 60)

    reticulum = RNS.Reticulum(configdir=RNS_CONFIG_DIR)
    identity = RNS.Identity.from_file(IDENTITY_PATH)
    if not identity:
        print("ERROR: Could not load identity")
        sys.exit(1)

    router = LXMF.LXMRouter(identity=identity, storagepath=STORAGE_PATH)
    router.register_delivery_identity(identity)

    dest = list(router.delivery_destinations.values())[0]
    print(f"Listening on LXMF address: {dest.hash.hex()}")
    print(f"Identity: {identity.hash.hex()[:16]}...")
    print(f"\nAnnouncing...")
    router.announce(dest.hash)

    router.register_delivery_callback(on_delivery)

    print(f"Ready. Send a message from the phone app to: {dest.hash.hex()}")
    print(f"Press Ctrl+C to stop.\n")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print(f"\n\nStopped. Received {len(received)} messages total.")


if __name__ == "__main__":
    main()
