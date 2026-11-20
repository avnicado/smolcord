#!/usr/bin/env python3
"""Offline tests for the transport stack. No token and no Discord needed.

These cover the three pieces that must behave identically in the Swift port:
the Z_SYNC_FLUSH message boundary, RFC 6455 frame encode/decode across all
three length forms, and the memory-BIO TLS plumbing.
"""
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
from gwlib import WebSocket, ZlibStream, Wire, ZLIB_SUFFIX  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print("  [%s] %s%s" % ("ok" if cond else "FAIL", name,
                           "" if cond else "  <- " + detail))


# ---------------------------------------------------------------- zlib stream

def test_zlib_single_message():
    co = zlib.compressobj()
    payload = b'{"op":11,"d":null}'
    blob = co.compress(payload) + co.flush(zlib.Z_SYNC_FLUSH)
    check("zlib: blob ends with Z_SYNC_FLUSH suffix", blob.endswith(ZLIB_SUFFIX))
    zs = ZlibStream()
    got = zs.feed(blob)
    check("zlib: single message inflates", got is not None and got[0] == payload,
          repr(got))
    check("zlib: reports compressed length", got and got[1] == len(blob))


def test_zlib_partial_then_complete():
    """A gateway message split across two WebSocket frames must buffer."""
    co = zlib.compressobj()
    payload = b'x' * 5000
    blob = co.compress(payload) + co.flush(zlib.Z_SYNC_FLUSH)
    zs = ZlibStream()
    half = len(blob) // 2
    check("zlib: partial feed returns None", zs.feed(blob[:half]) is None)
    got = zs.feed(blob[half:])
    check("zlib: completing feed inflates whole message",
          got is not None and got[0] == payload)
    check("zlib: compressed length spans both feeds", got and got[1] == len(blob))


def test_zlib_shared_context_across_messages():
    """The inflate context is per connection, not per message. Later messages
    depend on the earlier dictionary, so a fresh context would corrupt them."""
    co = zlib.compressobj()
    zs = ZlibStream()
    msgs = [b'{"t":"TYPING_START","d":{"user_id":"1"}}',
            b'{"t":"TYPING_START","d":{"user_id":"2"}}',
            b'{"t":"TYPING_START","d":{"user_id":"3"}}']
    sizes = []
    for m in msgs:
        blob = co.compress(m) + co.flush(zlib.Z_SYNC_FLUSH)
        sizes.append(len(blob))
        got = zs.feed(blob)
        if got is None or got[0] != m:
            check("zlib: shared context message round-trip", False, repr(got))
            return
    check("zlib: shared context round-trips 3 messages", True)
    # The point of a shared context: repeated structure gets cheaper.
    check("zlib: repeated structure compresses better over time",
          sizes[2] < sizes[0], "sizes=%r" % (sizes,))


# --------------------------------------------------------------- ws framing

class FakeWire:
    """Stands in for Wire. Records what was sent, replays what we queue."""

    def __init__(self):
        self.outbox = bytearray()
        self.inbox = bytearray()
        self.bytes_in = 0
        self.bytes_out = 0
        self.reads = 0
        self.writes = 0
        self.handshake_bytes_in = 0
        self.handshake_bytes_out = 0

    def send(self, data):
        self.outbox.extend(data)
        self.bytes_out += len(data)
        self.writes += 1

    def recv(self, timeout=None):
        if not self.inbox:
            return b""
        out = bytes(self.inbox)
        self.inbox.clear()
        self.bytes_in += len(out)
        self.reads += 1
        return out

    def close(self):
        pass

    def overhead_estimate(self):
        return 0


def server_frame(opcode, payload, fin=True):
    """Encode an unmasked server-to-client frame."""
    head = bytearray()
    head.append((0x80 if fin else 0x00) | opcode)
    n = len(payload)
    if n < 126:
        head.append(n)
    elif n < 65536:
        head.append(126)
        head.extend(struct.pack(">H", n))
    else:
        head.append(127)
        head.extend(struct.pack(">Q", n))
    return bytes(head) + payload


def make_ws():
    ws = WebSocket.__new__(WebSocket)
    ws.wire = FakeWire()
    ws._buf = bytearray()
    ws.frames_in = ws.frames_out = 0
    ws.frame_bytes_in = ws.frame_bytes_out = 0
    return ws


def test_frame_length_forms():
    for n, label in ((5, "7-bit"), (200, "16-bit"), (70000, "64-bit")):
        ws = make_ws()
        payload = os.urandom(n)
        ws.wire.inbox.extend(server_frame(WebSocket.BINARY, payload))
        got = ws.recv_frame(timeout=1.0)
        ok = got is not None and got[1] == payload and got[0] == WebSocket.BINARY
        check("ws: decode %s length form (%d bytes)" % (label, n), ok,
              "got %r" % ((None if got is None else (got[0], len(got[1]))),))


def test_frame_split_across_reads():
    """TCP does not respect frame boundaries. One frame may arrive in pieces."""
    ws = make_ws()
    payload = os.urandom(900)
    frame = server_frame(WebSocket.BINARY, payload)
    # Deliver 1 byte, then the header remainder, then the body in two chunks.
    class Dribble(FakeWire):
        def __init__(self, data):
            FakeWire.__init__(self)
            self.chunks = [data[:1], data[1:4], data[4:500], data[500:]]
        def recv(self, timeout=None):
            if not self.chunks:
                return b""
            c = self.chunks.pop(0)
            self.bytes_in += len(c)
            self.reads += 1
            return c
    ws.wire = Dribble(frame)
    got = ws.recv_frame(timeout=1.0)
    check("ws: reassembles a frame split across 4 reads",
          got is not None and got[1] == payload)


def test_two_frames_one_read():
    """Two frames can arrive in a single read. The second must not be lost."""
    ws = make_ws()
    a, b = b'{"op":11}', b'{"op":1}'
    ws.wire.inbox.extend(server_frame(WebSocket.TEXT, a)
                         + server_frame(WebSocket.TEXT, b))
    g1 = ws.recv_frame(timeout=1.0)
    g2 = ws.recv_frame(timeout=1.0)
    check("ws: two frames in one read both decode",
          g1 and g1[1] == a and g2 and g2[1] == b)


def test_client_masking():
    """A client frame must be masked, and must decode back to the payload."""
    ws = make_ws()
    payload = b'{"op":2,"d":{"token":"redacted"}}'
    ws.send_text(payload.decode())
    raw = bytes(ws.wire.outbox)
    check("ws: client frame sets the mask bit", bool(raw[1] & 0x80))
    check("ws: client frame sets FIN and TEXT", raw[0] == 0x81)
    mask = raw[2:6]
    body = raw[6:]
    decoded = bytes(b ^ mask[i & 3] for i, b in enumerate(body))
    check("ws: masked body decodes to the original", decoded == payload)
    check("ws: mask is not all zeros (would defeat masking)", mask != b"\x00" * 4)


def test_incomplete_frame_returns_none():
    ws = make_ws()
    ws.wire.inbox.extend(server_frame(WebSocket.BINARY, b"abcdef")[:3])
    check("ws: truncated frame yields None, not garbage",
          ws.recv_frame(timeout=0.1) is None)


# ------------------------------------------------------------------- TLS wire

def test_tls_wire():
    """Exercise the memory-BIO plumbing against a real TLS server.

    This is the riskiest code in the stack: if the BIO pump is wrong the
    handshake hangs rather than failing loudly. example.com is used because it
    is a stable, content-free target. No personal data is sent.
    """
    try:
        w = Wire("example.com", 443, timeout=15.0)
    except Exception as exc:
        check("tls: handshake completes", False, "%s: %s" % (type(exc).__name__, exc))
        return
    check("tls: handshake completes", True)
    check("tls: handshake counted bytes both ways",
          w.handshake_bytes_out > 0 and w.handshake_bytes_in > 0,
          "out=%d in=%d" % (w.handshake_bytes_out, w.handshake_bytes_in))
    w.send(b"GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
    data = b""
    for _ in range(20):
        try:
            chunk = w.recv(timeout=10.0)
        except Exception:
            break
        if not chunk:
            break
        data += chunk
        if b"\r\n\r\n" in data:
            break
    check("tls: response received over the BIO pump", data.startswith(b"HTTP/1.1"),
          repr(data[:40]))
    check("tls: ciphertext exceeds plaintext (records counted)",
          w.bytes_in >= len(data), "wire=%d plain=%d" % (w.bytes_in, len(data)))
    w.close()


def main():
    print("zlib stream")
    test_zlib_single_message()
    test_zlib_partial_then_complete()
    test_zlib_shared_context_across_messages()
    print("websocket framing")
    test_frame_length_forms()
    test_frame_split_across_reads()
    test_two_frames_one_read()
    test_client_masking()
    test_incomplete_frame_returns_none()
    print("tls wire")
    test_tls_wire()
    print("\n%d passed, %d failed" % (len(PASS), len(FAIL)))
    if FAIL:
        print("failed: " + ", ".join(FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
