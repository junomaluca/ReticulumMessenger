#!/usr/bin/env python3
"""
Stress-test LXMF attachment sending/receiving with the iOS app.

Uses the system RNS config (which has the michmesh.net TCP hub) and
Sideband's identity to send LXMF messages with various attachment
types to the phone.

Usage: python3 test_attachments.py [--send-only | --check-only | --send-back]
"""

import os, sys, time, struct, subprocess, hashlib

sys.path.insert(0, "/Users/patrickkann/.local/pipx/venvs/sbapp/lib/python3.13/site-packages")
import RNS
import LXMF

SENDER_IDENTITY_PATH = os.path.expanduser("~/.config/sideband/app_storage/primary_identity")
PHONE_LXMF_HEX = "ada019b5f71019d58d775c98353afd26"
RNS_CONFIG_DIR = "/tmp/test-rns-config"

STORAGE_PATH = "/tmp/lxmf-test-storage"
os.makedirs(STORAGE_PATH, exist_ok=True)

DEVICE_ID = "EFD37176-1820-5E09-9A6A-930319E6FC76"


def make_minimal_jpeg(size_bytes=1000):
    header = bytes([
        0xFF, 0xD8, 0xFF, 0xE0,
        0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00,
        0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0xFF, 0xDB, 0x00, 0x43, 0x00,
    ] + [0x08] * 64 + [
        0xFF, 0xC0, 0x00, 0x0B, 0x08,
        0x00, 0x01, 0x00, 0x01,
        0x01, 0x01, 0x11, 0x00,
        0xFF, 0xC4, 0x00, 0x1F, 0x00,
        0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B,
        0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
        0x7B, 0x40,
    ])
    padding = bytes([0x00] * max(0, size_bytes - len(header) - 2))
    return header + padding + bytes([0xFF, 0xD9])


def make_png_1x1():
    import zlib
    def chunk(chunk_type, data):
        c = chunk_type + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    sig = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
    idat = chunk(b'IDAT', zlib.compress(b'\x00\xFF\x00\x00'))
    iend = chunk(b'IEND', b'')
    return sig + ihdr + idat + iend


def make_gif_1x1():
    return (b'GIF89a\x01\x00\x01\x00\x80\x01\x00'
            b'\xff\x00\x00\x00\x00\x00'
            b'!\xf9\x04\x01\x00\x00\x01\x00'
            b',\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02L\x01\x00;')


# ---- Test cases ----
# Each: (name, fields_dict, content_text, description)

TEST_CASES = [
    # ===== BASELINE =====
    ("text_only_baseline", {}, "Hello from test harness!", "Plain text baseline"),
    ("empty_text", {}, "", "Empty content baseline"),
    ("unicode_text", {}, "Hello \U0001F30D\U0001F680 こんにちは مرحبا", "Unicode/emoji text"),

    # ===== FIELD_IMAGE (0x06) =====
    ("jpeg_1kb", {LXMF.FIELD_IMAGE: ["jpg", make_minimal_jpeg(1000)]}, "1KB JPEG", "Tiny JPEG via FIELD_IMAGE"),
    ("png_1x1", {LXMF.FIELD_IMAGE: ["png", make_png_1x1()]}, "PNG image", "1x1 PNG via FIELD_IMAGE"),
    ("gif_1x1", {LXMF.FIELD_IMAGE: ["gif", make_gif_1x1()]}, "GIF image", "1x1 GIF via FIELD_IMAGE"),
    ("jpeg_50kb", {LXMF.FIELD_IMAGE: ["jpg", make_minimal_jpeg(50_000)]}, "50KB JPEG", "Medium JPEG via FIELD_IMAGE"),
    ("jpeg_200kb", {LXMF.FIELD_IMAGE: ["jpg", make_minimal_jpeg(200_000)]}, "200KB JPEG", "Large JPEG via FIELD_IMAGE"),
    ("webp_image", {LXMF.FIELD_IMAGE: ["webp", os.urandom(500)]}, "WebP img", "Fake WebP via FIELD_IMAGE"),
    ("heic_image", {LXMF.FIELD_IMAGE: ["heic", os.urandom(500)]}, "HEIC img", "Fake HEIC via FIELD_IMAGE"),

    # ===== FIELD_AUDIO (0x07) =====
    ("opus_5kb", {LXMF.FIELD_AUDIO: [16, os.urandom(5000)]}, "Opus audio", "5KB Opus via FIELD_AUDIO"),
    ("codec2_2kb", {LXMF.FIELD_AUDIO: [0, os.urandom(2000)]}, "Codec2 audio", "2KB Codec2 via FIELD_AUDIO"),
    ("opus_mode17", {LXMF.FIELD_AUDIO: [17, os.urandom(3000)]}, "Opus m17", "Opus mode 17 via FIELD_AUDIO"),
    ("codec2_mode7", {LXMF.FIELD_AUDIO: [7, os.urandom(1000)]}, "C2 m7", "Codec2 mode 7 via FIELD_AUDIO"),

    # ===== FIELD_FILE_ATTACHMENTS (0x05) =====
    ("txt_file_100b", {LXMF.FIELD_FILE_ATTACHMENTS: [["hello.txt", b"Hello!\n" * 15]]}, "Text file", "100B txt file"),
    ("pdf_file_10kb", {LXMF.FIELD_FILE_ATTACHMENTS: [["document.pdf", b"%PDF-1.4 " + os.urandom(10000)]]}, "PDF file", "10KB fake PDF"),
    ("json_file", {LXMF.FIELD_FILE_ATTACHMENTS: [["config.json", b'{"key": "value", "num": 42}']]}, "JSON file", "Small JSON file"),
    ("bin_file_1kb", {LXMF.FIELD_FILE_ATTACHMENTS: [["data.bin", os.urandom(1000)]]}, "Binary file", "1KB binary blob"),
    ("csv_file", {LXMF.FIELD_FILE_ATTACHMENTS: [["data.csv", b"name,age,city\nAlice,30,NYC\nBob,25,LAX\n"]]}, "CSV file", "Small CSV"),
    ("zero_byte_file", {LXMF.FIELD_FILE_ATTACHMENTS: [["empty.txt", b""]]}, "Empty file", "0-byte file"),
    ("long_filename", {LXMF.FIELD_FILE_ATTACHMENTS: [["a" * 200 + ".txt", b"long name test"]]}, "Long name", "200-char filename"),
    ("special_chars_name", {LXMF.FIELD_FILE_ATTACHMENTS: [["my file (1) [v2].txt", b"special chars"]]}, "Special name", "Filename with spaces/parens/brackets"),

    # ===== MULTI-ATTACHMENT =====
    ("multi_file_2", {LXMF.FIELD_FILE_ATTACHMENTS: [["notes.txt", b"Notes\n"], ["data.bin", os.urandom(500)]]}, "Multi-file 2", "Two files in one message"),
    ("multi_file_5", {LXMF.FIELD_FILE_ATTACHMENTS: [
        ["file1.txt", b"File 1"],
        ["file2.txt", b"File 2"],
        ["file3.bin", os.urandom(100)],
        ["file4.json", b'{"n": 4}'],
        ["file5.csv", b"a,b\n1,2\n"],
    ]}, "Multi-file 5", "Five files in one message"),

    # ===== MIXED FIELDS =====
    # Image + file attachments in same message
    ("image_plus_file", {
        LXMF.FIELD_IMAGE: ["jpg", make_minimal_jpeg(2000)],
        LXMF.FIELD_FILE_ATTACHMENTS: [["readme.txt", b"See the image"]],
    }, "Image + file", "Image and file attachment together"),
    # Audio + file
    ("audio_plus_file", {
        LXMF.FIELD_AUDIO: [16, os.urandom(2000)],
        LXMF.FIELD_FILE_ATTACHMENTS: [["transcript.txt", b"Audio transcript"]],
    }, "Audio + file", "Audio and file attachment together"),

    # ===== SIZE STRESS =====
    ("file_50kb", {LXMF.FIELD_FILE_ATTACHMENTS: [["big50k.bin", os.urandom(50_000)]]}, "50KB file", "50KB binary file"),
    ("file_100kb", {LXMF.FIELD_FILE_ATTACHMENTS: [["big100k.bin", os.urandom(100_000)]]}, "100KB file", "100KB binary file"),
    ("file_250kb", {LXMF.FIELD_FILE_ATTACHMENTS: [["big250k.bin", os.urandom(250_000)]]}, "250KB file", "250KB binary file"),
]


def pull_phone_log():
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    dest = "/tmp/inbound-fields.log"
    try:
        subprocess.run([
            "xcrun", "devicectl", "device", "copy", "from",
            "--device", DEVICE_ID,
            "--source", "Documents/inbound-fields.log",
            "--destination", dest,
            "--domain-type", "appDataContainer",
            "--domain-identifier", "com.reticulummessenger.app",
        ], env=env, capture_output=True, timeout=15)
        if os.path.exists(dest):
            with open(dest) as f:
                return f.read()
    except Exception as e:
        print(f"  (Could not pull log: {e})")
    return None


def send_tests():
    print("=" * 70)
    print("LXMF Attachment Stress Test Harness")
    print(f"  {len(TEST_CASES)} test cases")
    print("=" * 70)

    reticulum = RNS.Reticulum(configdir=RNS_CONFIG_DIR)
    sender_identity = RNS.Identity.from_file(SENDER_IDENTITY_PATH)
    if not sender_identity:
        print("ERROR: Could not load sender identity")
        sys.exit(1)

    phone_dest_hash = bytes.fromhex(PHONE_LXMF_HEX)

    router = LXMF.LXMRouter(identity=sender_identity, storagepath=STORAGE_PATH)
    router.register_delivery_identity(sender_identity)
    source_dest = list(router.delivery_destinations.values())[0]

    print(f"Sender:  {sender_identity.hash.hex()[:16]}...")
    print(f"Target:  {PHONE_LXMF_HEX}")
    print(f"Waiting 8s for transport + hub connection...")
    time.sleep(8)

    # Request path
    print("Requesting path...")
    if not RNS.Transport.has_path(phone_dest_hash):
        RNS.Transport.request_path(phone_dest_hash)
    for i in range(30):
        time.sleep(1)
        if RNS.Transport.has_path(phone_dest_hash):
            print(f"  Path found after {i+1}s")
            break
    else:
        print("  WARNING: No path after 30s, continuing anyway...")

    # Recall identity
    phone_identity = RNS.Identity.recall(phone_dest_hash)
    if not phone_identity:
        print("  Identity not cached, waiting 5s more...")
        time.sleep(5)
        phone_identity = RNS.Identity.recall(phone_dest_hash)
    if not phone_identity:
        print("ERROR: Cannot recall phone identity.")
        sys.exit(1)
    print(f"  Phone identity recalled OK")

    phone_dest = RNS.Destination(
        phone_identity, RNS.Destination.OUT, RNS.Destination.SINGLE,
        "lxmf", "delivery"
    )
    print(f"  Dest hash: {phone_dest.hash.hex()}")

    # Pull pre-test log
    print("\nPulling pre-test log from phone...")
    pre_log = pull_phone_log()
    pre_lines = len(pre_log.strip().split("\n")) if pre_log else 0
    print(f"  Pre-existing log lines: {pre_lines}")

    results = []
    for i, (name, fields, content, desc) in enumerate(TEST_CASES):
        print(f"\n[{i+1}/{len(TEST_CASES)}] {name}: {desc}")

        # Compute field sizes for reporting
        total_field_bytes = 0
        for k, v in fields.items():
            if isinstance(v, list):
                for item in v:
                    if isinstance(item, (bytes, bytearray)):
                        total_field_bytes += len(item)
                    elif isinstance(item, list):
                        for sub in item:
                            if isinstance(sub, (bytes, bytearray)):
                                total_field_bytes += len(sub)
        if total_field_bytes > 0:
            print(f"  Field payload: ~{total_field_bytes} bytes")

        try:
            lxm = LXMF.LXMessage(
                phone_dest, source_dest,
                content, title="",
                desired_method=LXMF.LXMessage.DIRECT,
                fields=fields if fields else None
            )
            holder = {"state": "PENDING", "t_start": time.time()}
            def mk(h):
                def sent(m): h["state"] = "SENT"; h["t_end"] = time.time()
                def fail(m): h["state"] = "FAILED"; h["t_end"] = time.time()
                return sent, fail
            s, f = mk(holder)
            lxm.register_delivery_callback(s)
            lxm.register_failed_callback(f)
            router.handle_outbound(lxm)

            # Wait up to 90s for large payloads
            timeout = 90 if total_field_bytes > 50000 else 45
            for _ in range(timeout * 2):
                if holder["state"] != "PENDING":
                    break
                time.sleep(0.5)

            elapsed = holder.get("t_end", time.time()) - holder["t_start"]
            print(f"  -> {holder['state']} ({elapsed:.1f}s)")
            results.append((name, holder["state"], elapsed, desc))
        except Exception as e:
            import traceback
            traceback.print_exc()
            results.append((name, f"ERROR: {e}", 0, desc))

        time.sleep(0.5)

    # Pull post-test log
    print("\n\nWaiting 5s then pulling post-test log...")
    time.sleep(5)
    post_log = pull_phone_log()
    if post_log:
        post_lines = post_log.strip().split("\n")
        new_lines = post_lines[pre_lines:]
        print(f"  New log entries: {len(new_lines)}")
        for line in new_lines:
            print(f"    {line[:250]}")

    # Summary
    print("\n" + "=" * 70)
    print("RESULTS SUMMARY")
    print("=" * 70)
    sent = 0
    failed = 0
    errors = 0
    for name, state, elapsed, desc in results:
        if "SENT" in str(state):
            ok = "PASS"
            sent += 1
        elif "FAIL" in str(state):
            ok = "FAIL"
            failed += 1
        else:
            ok = "ERR "
            errors += 1
        print(f"  [{ok}] {name:30s} {elapsed:6.1f}s  {desc}")

    print(f"\n  PASS: {sent}  FAIL: {failed}  ERROR: {errors}  TOTAL: {len(results)}")

    if failed > 0 or errors > 0:
        print("\n  FAILED/ERROR tests:")
        for name, state, elapsed, desc in results:
            if "SENT" not in str(state):
                print(f"    {name}: {state}")


def check_log():
    print("Pulling inbound-fields.log from phone...")
    log = pull_phone_log()
    if log:
        lines = log.strip().split("\n")
        print(f"Total entries: {len(lines)}\n")
        for line in lines[-30:]:
            print(f"  {line[:300]}")
    else:
        print("No log file found")


def send_from_phone_test():
    """Listen for messages FROM the phone to verify outbound attachments."""
    print("=" * 70)
    print("LXMF Receive Test — listening for messages FROM the phone")
    print("=" * 70)

    reticulum = RNS.Reticulum(configdir=RNS_CONFIG_DIR)
    identity = RNS.Identity.from_file(SENDER_IDENTITY_PATH)

    router = LXMF.LXMRouter(identity=identity, storagepath=STORAGE_PATH)
    router.register_delivery_identity(identity)

    received = []

    def delivery_callback(message):
        src = message.source_hash.hex()[:16]
        content = message.content_as_string() if hasattr(message, 'content_as_string') else str(message.content)
        fields = message.fields if message.fields else {}

        att_info = []
        if LXMF.FIELD_IMAGE in fields:
            img = fields[LXMF.FIELD_IMAGE]
            att_info.append(f"IMAGE({img[0]}, {len(img[1])}B)")
        if LXMF.FIELD_AUDIO in fields:
            aud = fields[LXMF.FIELD_AUDIO]
            att_info.append(f"AUDIO(mode={aud[0]}, {len(aud[1])}B)")
        if LXMF.FIELD_FILE_ATTACHMENTS in fields:
            files = fields[LXMF.FIELD_FILE_ATTACHMENTS]
            for f in files:
                att_info.append(f"FILE({f[0]}, {len(f[1])}B)")

        entry = {
            "time": time.strftime("%H:%M:%S"),
            "from": src,
            "content": content[:100],
            "attachments": att_info,
            "field_keys": [hex(k) for k in fields.keys()] if fields else [],
        }
        received.append(entry)
        print(f"\n  [{entry['time']}] From {src}...")
        print(f"    Content: {entry['content']}")
        if att_info:
            print(f"    Attachments: {', '.join(att_info)}")
        print(f"    Fields: {entry['field_keys']}")

    router.register_delivery_callback(delivery_callback)

    my_hash = identity.hash.hex()
    print(f"Listening as: {my_hash[:16]}...")
    print("Send messages from the phone app to this address.")
    print("Press Ctrl+C to stop.\n")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print(f"\n\nReceived {len(received)} messages total.")
        for e in received:
            print(f"  [{e['time']}] {e['content'][:60]}  atts={e['attachments']}")


if __name__ == "__main__":
    if "--check-only" in sys.argv:
        check_log()
    elif "--send-back" in sys.argv:
        send_from_phone_test()
    else:
        send_tests()
