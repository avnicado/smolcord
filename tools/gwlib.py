"""
Minimal, dependency-free WebSocket + TLS byte-accounting stack.

Why this exists instead of the `websockets` package:

  1. It counts *exact on-wire bytes*. TLS is driven through ssl.MemoryBIO so we
     see ciphertext length, including record framing and padding. A library that
     hands you decoded frames cannot tell you what the carrier actually billed.
  2. It is a line-by-line reference for the Swift port in Sources/Transport/.
     The frame reader, the mask writer and the Z_SYNC_FLUSH boundary detection
     are the three pieces that must behave identically on iOS 12, where
     NWProtocolWebSocket does not exist.
  3. Standard library only. Runs anywhere Python 3.7+ runs.

Not a general-purpose WebSocket client. It implements exactly what the Discord
gateway uses: a client-initiated TLS connection, text and binary data frames,
close, ping and pong. No extensions, no permessage-deflate (Discord does its
own compression at the application layer).
"""

import base64
import os
import socket
import ssl
import struct
import time
import zlib
from urllib.parse import urlparse

# A conservative MSS. Used only to estimate how many TCP segments a byte count
# implies, so we can add header overhead. The real path MTU is unknowable from
# userspace, and the estimate is reported separately from measured bytes.
ASSUMED_MSS = 1400

# TCP + IPv4 headers. A data segment carries this, and so does the pure ACK
# that comes back for it.
TCP_IP_HEADER = 52

ZLIB_SUFFIX = b"\x00\x00\xff\xff"


class WireClosed(Exception):
    pass


class Wire:
    """A TLS stream that knows how many bytes it put on the wire.

    TLS runs over memory BIOs. We own the raw socket, so every read and write
    is counted before encryption hides the size, and after encryption adds to
    it. bytes_in / bytes_out are ciphertext totals: what the network saw.
    """

    def __init__(self, host, port=443, timeout=30.0):
        self.host = host
        self.bytes_in = 0
        self.bytes_out = 0
        self.reads = 0
        self.writes = 0
        self.opened_at = time.monotonic()
        self._eof = False

        self.raw = socket.create_connection((host, port), timeout=timeout)
        self.raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        ctx = ssl.create_default_context()
        self._inc = ssl.MemoryBIO()
        self._out = ssl.MemoryBIO()
        self.tls = ctx.wrap_bio(self._inc, self._out, server_hostname=host)
        self._handshake()
        self.handshake_bytes_in = self.bytes_in
        self.handshake_bytes_out = self.bytes_out

    # -- raw plumbing ----------------------------------------------------

    def _push(self):
        """Drain the outgoing BIO to the socket, counting ciphertext."""
        data = self._out.read()
        if data:
            self.raw.sendall(data)
            self.bytes_out += len(data)
            self.writes += 1

    def _pull(self, timeout):
        """Read ciphertext from the socket into the incoming BIO.

        Returns the byte count, or None on timeout. Raises WireClosed on EOF.
        """
        self.raw.settimeout(timeout)
        try:
            chunk = self.raw.recv(65536)
        except socket.timeout:
            return None
        except ssl.SSLWantReadError:
            return None
        if not chunk:
            self._eof = True
            self._inc.write_eof()
            raise WireClosed("peer closed the TCP connection")
        self.bytes_in += len(chunk)
        self.reads += 1
        self._inc.write(chunk)
        return len(chunk)

    def _handshake(self):
        while True:
            try:
                self.tls.do_handshake()
            except ssl.SSLWantReadError:
                self._push()
                self._pull(timeout=30.0)
                continue
            self._push()
            return

    # -- stream API ------------------------------------------------------

    def send(self, data):
        self.tls.write(data)
        self._push()

    def recv(self, timeout=None):
        """Return decrypted bytes, b'' on timeout, or raise WireClosed."""
        while True:
            try:
                out = self.tls.read(65536)
            except ssl.SSLWantReadError:
                if self._pull(timeout) is None:
                    return b""
                continue
            except ssl.SSLZeroReturnError:
                raise WireClosed("TLS closed cleanly")
            if out == b"":
                raise WireClosed("TLS returned EOF")
            return out

    def close(self):
        try:
            self.raw.close()
        except OSError:
            pass

    # -- accounting ------------------------------------------------------

    def overhead_estimate(self):
        """Estimated TCP/IP header bytes on top of the measured ciphertext.

        Each write becomes at least one segment and draws one ACK back; each
        read is at least one segment we must ACK. This is an estimate and is
        always reported as such.
        """
        seg_out = sum(
            max(1, -(-n // ASSUMED_MSS)) for n in (self.bytes_out,)
        )
        seg_in = max(1, -(-self.bytes_in // ASSUMED_MSS))
        # Every segment in either direction costs one header, plus one header
        # for the ACK it provokes.
        return (self.writes + seg_out + self.reads + seg_in) * TCP_IP_HEADER


class WebSocket:
    """RFC 6455 client over a Wire. Text, binary, ping, pong, close."""

    CONT = 0x0
    TEXT = 0x1
    BINARY = 0x2
    CLOSE = 0x8
    PING = 0x9
    PONG = 0xA

    def __init__(self, url, headers=None):
        u = urlparse(url)
        if u.scheme not in ("wss", "https"):
            raise ValueError("only wss is supported: %r" % url)
        port = u.port or 443
        path = u.path or "/"
        if u.query:
            path += "?" + u.query

        self.wire = Wire(u.hostname, port)
        self._buf = bytearray()
        self._handshake(u.hostname, port, path, headers or {})

        # Frame-level counters, separate from the Wire's ciphertext counters.
        self.frames_in = 0
        self.frames_out = 0
        self.frame_bytes_in = 0
        self.frame_bytes_out = 0

    def _handshake(self, host, port, path, headers):
        key = base64.b64encode(os.urandom(16)).decode()
        hostline = host if port == 443 else "%s:%d" % (host, port)
        lines = [
            "GET %s HTTP/1.1" % path,
            "Host: %s" % hostline,
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: %s" % key,
            "Sec-WebSocket-Version: 13",
        ]
        for k, v in headers.items():
            lines.append("%s: %s" % (k, v))
        req = ("\r\n".join(lines) + "\r\n\r\n").encode()
        self.wire.send(req)

        # Read until the end of the header block.
        while b"\r\n\r\n" not in self._buf:
            chunk = self.wire.recv(timeout=30.0)
            if not chunk:
                raise WireClosed("timed out during the WebSocket handshake")
            self._buf.extend(chunk)
        head, _, rest = bytes(self._buf).partition(b"\r\n\r\n")
        self._buf = bytearray(rest)
        status = head.split(b"\r\n", 1)[0]
        if b"101" not in status:
            raise WireClosed("upgrade refused: %s" % status.decode("latin1"))

    # -- frame I/O -------------------------------------------------------

    def _need(self, n, timeout):
        deadline = None if timeout is None else time.monotonic() + timeout
        while len(self._buf) < n:
            remaining = None
            if deadline is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
            chunk = self.wire.recv(timeout=remaining)
            if not chunk:
                return False
            self._buf.extend(chunk)
        return True

    def recv_frame(self, timeout=None):
        """Return (opcode, payload, wire_len) or None on timeout."""
        if not self._need(2, timeout):
            return None
        b0, b1 = self._buf[0], self._buf[1]
        opcode = b0 & 0x0F
        fin = bool(b0 & 0x80)
        masked = bool(b1 & 0x80)
        length = b1 & 0x7F
        offset = 2
        if length == 126:
            if not self._need(4, timeout):
                return None
            length = struct.unpack_from(">H", self._buf, 2)[0]
            offset = 4
        elif length == 127:
            if not self._need(10, timeout):
                return None
            length = struct.unpack_from(">Q", self._buf, 2)[0]
            offset = 10
        if masked:
            # A server must not mask. Handle it rather than corrupt the stream.
            if not self._need(offset + 4, timeout):
                return None
            mask = bytes(self._buf[offset:offset + 4])
            offset += 4
        else:
            mask = None
        if not self._need(offset + length, timeout):
            return None

        payload = bytes(self._buf[offset:offset + length])
        if mask:
            payload = bytes(b ^ mask[i & 3] for i, b in enumerate(payload))
        total = offset + length
        del self._buf[:total]

        self.frames_in += 1
        self.frame_bytes_in += total
        return (opcode, payload, total, fin)

    def send_frame(self, opcode, payload=b""):
        """Send one masked client frame. Discord messages never need splitting."""
        n = len(payload)
        head = bytearray()
        head.append(0x80 | opcode)
        if n < 126:
            head.append(0x80 | n)
        elif n < 65536:
            head.append(0x80 | 126)
            head.extend(struct.pack(">H", n))
        else:
            head.append(0x80 | 127)
            head.extend(struct.pack(">Q", n))
        mask = os.urandom(4)
        head.extend(mask)
        masked = bytes(b ^ mask[i & 3] for i, b in enumerate(payload))
        frame = bytes(head) + masked
        self.wire.send(frame)
        self.frames_out += 1
        self.frame_bytes_out += len(frame)
        return len(frame)

    def send_text(self, text):
        return self.send_frame(self.TEXT, text.encode("utf-8"))

    def close(self, code=1001):
        try:
            self.send_frame(self.CLOSE, struct.pack(">H", code))
        except (OSError, ssl.SSLError, WireClosed):
            pass
        self.wire.close()


class ZlibStream:
    """Discord's `zlib-stream` transport compression.

    One inflate context for the whole connection. Gateway messages are
    delimited by a 4-byte Z_SYNC_FLUSH suffix, so buffer compressed bytes
    until the suffix lands, then inflate.

    Returns (inflated_bytes, compressed_len) so the caller can attribute the
    on-wire cost to the specific event it carried. That attribution is the
    reason this is written out by hand rather than handed to a library.
    """

    def __init__(self):
        self._inflator = zlib.decompressobj()
        self._buf = bytearray()

    def feed(self, chunk):
        self._buf.extend(chunk)
        if len(self._buf) < 4 or bytes(self._buf[-4:]) != ZLIB_SUFFIX:
            return None
        compressed_len = len(self._buf)
        data = self._inflator.decompress(bytes(self._buf))
        self._buf.clear()
        return (data, compressed_len)
