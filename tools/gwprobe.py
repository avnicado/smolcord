#!/usr/bin/env python3
"""
gwprobe -- measure what a DM-only Discord client actually costs.

Built to settle one question: does op 37 (bulk guild unsubscribe) stop guild
MESSAGE_CREATE, or only typing and presence?

ANSWERED, 19 Nov 2026, on a 16-guild account. Op 37 stops guild PRESENCE_UPDATE
(26 -> 0) and does NOT stop guild MESSAGE_CREATE (29 -> 28). The community
documentation that describes subscriptions as gating all "non-stateful" events
was wrong on messages. It is per-session: a subscribed control session kept
receiving presence throughout.

That did not sink the design. Guild messages cost about 65 KB/hr in frames at
that guild count, and the measured steady rate was 176 KB/hr, 17% of budget.
The expensive thing turned out to be READY: 119 KB on the wire, 840 KB
inflated, paid on every IDENTIFY that cannot RESUME.

HOW IT RUNS

Two gateway sessions on the same token, at the same time:

    arm A   identify, then sit still. The control.
    arm B   identify, then unsubscribe from every guild.

Concurrent, not sequential. Both arms see the same guild traffic over the same
wall-clock window, which removes the "guilds happened to be quiet during arm B"
confound. A user account allows 50 sessions, so two is unremarkable. Arm B
waits for arm A's READY before identifying, because max_concurrency is 1.

The run stops on evidence, not on a clock: it ends once arm A has seen enough
guild messages to make arm B's silence mean something. On a busy account that
is one to three minutes.

WHAT COUNTS

The decision rests on the absolute rate against 1 MB/hr, never on a reduction
ratio. A ratio-based verdict got this wrong on the first real run: a 3%
reduction read as FAIL while the rate was 17% of budget.

The separate question of what op 37 changed is judged on guild-scoped
MESSAGE_CREATE, MESSAGE_UPDATE, MESSAGE_DELETE and TYPING_START.

Two kinds of guild-scoped event are deliberately excluded, because Discord
sends them for unsubscribed guilds on purpose:

  * PASSIVE_UPDATE_V2 and CHANNEL_UNREADS_UPDATE keep channel unreads current.
  * PRESENCE_UPDATE always arrives for friends, implicit relationships, and
    people we have an open DM with who share a server.

Both get their own row and their bytes count toward the hourly figure, but
neither decides the verdict. Judging on the presence of guild_id alone would
call a real success a failure.

The two arms are also counted over the SAME window, starting at arm B's op 37
plus a grace period. Arm A's raw total is larger, because it starts listening
several seconds earlier. Comparing raw totals lets a busy account satisfy the
stop condition before arm B has listened at all, and print a false PASS.

USAGE

    export DISCORD_TOKEN='...'
    python3 -I tools/gwprobe.py                  # concurrent, auto-stop
    python3 -I tools/gwprobe.py --cap-minutes 10 # wait longer for quiet guilds
    python3 -I tools/gwprobe.py --smoke          # no token; HELLO only
    python3 -I tools/gwprobe.py --arm A          # one arm, for debugging

The token is read from the environment only. It is never written to disk, never
printed, and is redacted from error text.

Captured READY payloads go to tools/fixtures/ (gitignored) for offline parser
tests. They contain your personal data. Do not commit or share them.
"""

import argparse
import json
import os
import random
import sys
import threading
import time
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwlib import WebSocket, ZlibStream, WireClosed  # noqa: E402

GATEWAY = "wss://gateway.discord.gg/?v=10&encoding=json&compress=zlib-stream"

# Capabilities bitfield. This is the value the official client sends, mirrored
# by discord.py-self's Capabilities.default(). A novel value is an anti-spam
# fingerprint, so we match rather than hand-pick a minimum.
#
#   1<<0  lazy_user_notes                      drop `notes` from READY
#   1<<2  versioned_read_states                cacheable read_state
#   1<<3  versioned_user_guild_settings        cacheable user_guild_settings
#   1<<4  dedupe_user_objects                  users hoisted to one array
#   1<<5  prioritized_ready_payload            split READY / READY_SUPPLEMENTAL
#   1<<6  multiple_guild_experiment_populations
#   1<<7  non_channel_read_states
#   1<<8  auth_token_refresh
#   1<<9  user_settings_proto                  drop user_settings
#   1<<10 client_state_v2                      enables guild_versions cache
#   1<<12 auto_call_connect
#   1<<14 passive_guild_update_v2              PASSIVE_UPDATE_V2, see below
CAPABILITIES = 22525

OP_DISPATCH = 0
OP_HEARTBEAT = 1
OP_IDENTIFY = 2
OP_RESUME = 6
OP_RECONNECT = 7
OP_INVALID_SESSION = 9
OP_HELLO = 10
OP_HEARTBEAT_ACK = 11
OP_BULK_GUILD_SUBSCRIBE = 37

# Close codes where retrying cannot help. 4004 is overwhelmingly the one a user
# will hit: the token is wrong, expired, or was rotated by a password change.
FATAL_CLOSE = {
    4004: "authentication failed -- the token is invalid, expired, or was "
          "rotated. Copy it again from a logged-in client.",
    4010: "invalid shard",
    4011: "sharding required",
    4012: "invalid API version",
    4013: "invalid intents -- user accounts must not send an intents field",
    4014: "disallowed intents",
}

# Events a guild subscription gates. These, and only these, decide the verdict.
DECISIVE = frozenset((
    "MESSAGE_CREATE", "MESSAGE_UPDATE", "MESSAGE_DELETE", "TYPING_START",
))

# Sent for unsubscribed guilds by design: Discord keeps channel unreads current
# passively. They carry guild_id but are not evidence of a live subscription.
PASSIVE = frozenset((
    "PASSIVE_UPDATE_V1", "PASSIVE_UPDATE_V2", "CHANNEL_UNREADS_UPDATE",
))

# Presence is NOT decisive, even though it carries guild_id. Discord always
# sends presence for friends, implicit relationships, and users we have an open
# DM with who share a server. Those legitimately survive op 37, so counting
# them as evidence would report a false PARTIAL and recommend the wrong fix.
# Tracked as its own cost row instead.
PRESENCE = frozenset(("PRESENCE_UPDATE",))

# Payloads paid once per connection. Excluded from the hourly rate, and from
# the frame count used to estimate per-frame overhead.
ONETIME_EVENTS = frozenset(("READY", "READY_SUPPLEMENTAL", "HELLO", "GUILD_CREATE"))

# Per-frame carrier overhead, matching Sources/Transport/ByteMeter.swift so the
# probe and the app report comparable numbers.
#   TLS 1.3 AEAD record: 5-byte header + 16-byte tag + 1-byte inner type
#   IPv4 + TCP headers, for the segment and the ACK it provokes
TLS_RECORD_OVERHEAD = 22
TCP_IP_OVERHEAD = 52 * 2

# Seconds after op 37 during which arm B ignores guild events. Anything already
# in flight can land before the server applies the unsubscribe.
GRACE_SECONDS = 5.0

FIXTURE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")

UPGRADE_HEADERS = {
    "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 12_5_7 like Mac OS X) "
                  "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
    "Origin": "https://discord.com",
    "Accept-Language": "en-US,en;q=0.9",
}


def redact(text, token):
    return text.replace(token, "<TOKEN>") if (token and token in text) else text


def human(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if abs(n) < 1024.0 or unit == "GB":
            return "%dB" % n if unit == "B" else "%.1f%s" % (n, unit)
        n /= 1024.0


def identify_payload(token, guild_versions=None):
    """Mirrors what Sources/Protocol/Identify.swift must send."""
    return {
        "op": OP_IDENTIFY,
        "d": {
            "token": token,
            "capabilities": CAPABILITIES,
            "properties": {
                "os": "iOS",
                "browser": "Discord iOS",
                "device": "iPhone",
                "system_locale": "en-US",
                "client_version": "189.0",
                "release_channel": "stable",
                "os_version": "12.5.7",
                "client_build_number": 394000,
                "client_event_source": None,
            },
            "presence": {
                "status": "invisible", "activities": [], "afk": False, "since": 0,
            },
            # Transport compression is on via the URL, so payload compression
            # must be off. Discord allows only one.
            "compress": False,
            "client_state": {"guild_versions": guild_versions or {}},
        },
    }


def unsubscribe_payload(guild_ids):
    subs = {
        gid: {
            "typing": False,
            "threads": False,
            "activities": False,
            "member_updates": False,
            "members": [],
            "channels": {},
        }
        for gid in guild_ids
    }
    return {"op": OP_BULK_GUILD_SUBSCRIBE, "d": {"subscriptions": subs}}


class Arm(threading.Thread):
    """One gateway session. Counts bytes per event type and classifies scope."""

    def __init__(self, label, token, unsubscribe, stop_event,
                 ready_event=None, wait_for=None, save_fixture=False):
        threading.Thread.__init__(self, name="arm-%s" % label, daemon=True)
        self.label = label
        self.token = token
        self.unsubscribe = unsubscribe
        self.stop_event = stop_event
        self.ready_event = ready_event
        self.wait_for = wait_for
        self.save_fixture = save_fixture

        # name -> {count, wire, inflated, guild, dm}
        self.events = defaultdict(lambda: {
            "count": 0, "wire": 0, "inflated": 0, "guild": 0, "dm": 0,
        })
        # Counters the verdict reads. Plain ints, written only by this thread.
        self.decisive_guild = 0
        self.decisive_guild_in_grace = 0
        self.passive_guild = 0
        self.presence_guild = 0
        self.dm_events = 0
        # Frame bytes and frame count inside the measurement window, excluding
        # one-time payloads. The hourly rate is built from these.
        #
        # An earlier version derived the rate from a ciphertext delta
        # (end_in - base_in). That was wrong: Wire.bytes_in grows in recv()
        # chunks of up to 64KB, so the read that completes READY can already
        # hold READY_SUPPLEMENTAL's bytes. The baseline then included bytes we
        # also subtracted as one-time, the steady figure went negative and
        # clamped to zero, and the printed rate was nothing but the overhead
        # term. Counting frames directly cannot drift that way.
        self.window_frame_bytes = 0
        self.window_frames = 0
        self.onetime_bytes = 0
        self.guild_count = 0
        self.ready_wire = 0
        self.ready_inflated = 0
        self.unsub_bytes = 0
        self.unsub_at = None
        self.late_guild_unsubs = 0

        # Monotonic timestamps of decisive guild events, for the before/after
        # check on whether subscriptions are per-session or per-account.
        self.decisive_times = []

        self.window_start = None
        self.window_end = None
        self.base_in = self.base_out = 0
        self.end_in = self.end_out = 0
        self.handshake_bytes = 0
        self.error = None
        self.close_code = None
        self.finished = threading.Event()
        self._ws = None

    # -- accounting ------------------------------------------------------

    def _record(self, name, wire, inflated, scope=None):
        e = self.events[name]
        e["count"] += 1
        e["wire"] += wire
        e["inflated"] += inflated
        if scope:
            e[scope] += 1
        if self.window_start is not None and name not in ONETIME_EVENTS:
            self.window_frame_bytes += wire
            self.window_frames += 1

    @property
    def elapsed(self):
        if self.window_start is None:
            return 0.0
        end = self.window_end or time.monotonic()
        return max(1e-6, end - self.window_start)

    @property
    def steady_bytes(self):
        """Frame bytes inside the window, excluding one-time payloads."""
        return self.window_frame_bytes

    @property
    def ciphertext_delta(self):
        """Measured ciphertext across the window. Reported as a cross-check.

        It overlaps the one-time payloads because of recv() read-ahead, so it is
        an upper bound, not the rate basis.
        """
        return ((self.end_in - self.base_in) + (self.end_out - self.base_out))

    def decisive_since(self, cutoff):
        """Decisive guild events from `cutoff` onward.

        The two arms do not start listening at the same moment: arm B only
        begins counting at unsub_at + GRACE_SECONDS, several seconds after arm
        A's READY. Comparing raw totals would let a busy account satisfy the
        stop condition before arm B had listened at all, and print a confident
        false PASS. Both sides must be counted over the same window.
        """
        if cutoff is None:
            return 0
        return sum(1 for t in self.decisive_times if t >= cutoff)

    @property
    def per_hour(self):
        """Projected billable bytes per hour, excluding connect cost."""
        if self.window_start is None:
            return 0.0
        overhead = self.window_frames * (TLS_RECORD_OVERHEAD + TCP_IP_OVERHEAD)
        return (self.window_frame_bytes + overhead) / self.elapsed * 3600.0

    @property
    def connect_cost(self):
        """Bytes for one fresh IDENTIFY: handshake, READY, READY_SUPPLEMENTAL.

        Paid on every connection that cannot RESUME. On the measured account
        this dwarfs the steady-state rate, so it is reported on its own.
        """
        return self.handshake_bytes + self.ready_wire

    # -- main loop -------------------------------------------------------

    def run(self):
        try:
            self._run()
        except WireClosed as exc:
            self.error = redact(str(exc), self.token)
        except Exception as exc:  # noqa: BLE001 - report, never crash the run
            self.error = "%s: %s" % (type(exc).__name__, redact(str(exc), self.token))
        finally:
            self.finished.set()

    def _run(self):
        if self.wait_for is not None:
            # max_concurrency is 1, so do not fire both IDENTIFYs together.
            # Give up if the other arm dies, rather than blocking the report.
            deadline = time.monotonic() + 30.0
            while not self.wait_for.wait(timeout=0.25):
                if self.stop_event.is_set():
                    self.error = "the other arm failed before this one started"
                    return
                if time.monotonic() > deadline:
                    break
            time.sleep(1.0)

        ws = WebSocket(GATEWAY, headers=UPGRADE_HEADERS)
        self._ws = ws
        self.handshake_bytes = (ws.wire.handshake_bytes_in
                                + ws.wire.handshake_bytes_out)
        inflater = ZlibStream()

        heartbeat_interval = None
        next_heartbeat = None
        seq = None
        guild_ids = set()
        pending_frames = []

        def send_json(obj):
            return ws.send_text(json.dumps(obj, separators=(",", ":")))

        try:
            while not self.stop_event.is_set():
                now = time.monotonic()
                timeout = 1.0
                if next_heartbeat is not None:
                    timeout = min(timeout, max(0.0, next_heartbeat - now))

                frame = ws.recv_frame(timeout=timeout)

                if frame is not None:
                    opcode, payload, wire_len, _fin = frame
                    if opcode == ws.CLOSE:
                        self.close_code = (int.from_bytes(payload[:2], "big")
                                           if len(payload) >= 2 else 0)
                        if self.close_code in FATAL_CLOSE:
                            self.error = "close %d: %s" % (
                                self.close_code, FATAL_CLOSE[self.close_code])
                            # Nothing will improve by waiting. Stop both arms.
                            self.stop_event.set()
                        break
                    if opcode == ws.PING:
                        ws.send_frame(ws.PONG, payload)
                        continue
                    if opcode not in (ws.TEXT, ws.BINARY, ws.CONT):
                        continue

                    pending_frames.append(wire_len)
                    result = inflater.feed(payload)
                    if result is None:
                        continue  # gateway message still arriving
                    data, _compressed = result
                    msg_wire = sum(pending_frames)
                    pending_frames = []

                    try:
                        msg = json.loads(data)
                    except ValueError:
                        continue

                    op = msg.get("op")
                    if msg.get("s") is not None:
                        seq = msg["s"]

                    if op == OP_HELLO:
                        heartbeat_interval = msg["d"]["heartbeat_interval"] / 1000.0
                        next_heartbeat = (time.monotonic()
                                          + heartbeat_interval * random.random())
                        self._record("HELLO", msg_wire, len(data))
                        send_json(identify_payload(self.token))
                        continue

                    if op == OP_HEARTBEAT_ACK:
                        self._record("HEARTBEAT_ACK", msg_wire, len(data))
                        continue

                    if op == OP_HEARTBEAT:
                        send_json({"op": OP_HEARTBEAT, "d": seq})
                        continue

                    if op == OP_INVALID_SESSION:
                        self.error = ("INVALID_SESSION: the token was rejected "
                                      "or the session is gone")
                        break

                    if op == OP_RECONNECT:
                        self.error = "gateway asked us to reconnect"
                        break

                    if op != OP_DISPATCH:
                        self._record("op:%s" % op, msg_wire, len(data))
                        continue

                    self._dispatch(msg, msg_wire, len(data), guild_ids, send_json)
                    continue

                now = time.monotonic()
                if next_heartbeat is not None and now >= next_heartbeat:
                    n = send_json({"op": OP_HEARTBEAT, "d": seq})
                    self._record("heartbeat(out)", n, 0)
                    next_heartbeat = now + heartbeat_interval
        finally:
            self.window_end = time.monotonic()
            self.end_in = ws.wire.bytes_in
            self.end_out = ws.wire.bytes_out
            if self.window_start is None:
                # READY never landed; nothing was measured.
                self.base_in, self.base_out = self.end_in, self.end_out
            ws.close()

    def _dispatch(self, msg, msg_wire, inflated, guild_ids, send_json):
        name = msg.get("t") or "UNKNOWN"
        d = msg.get("d") if isinstance(msg.get("d"), dict) else {}
        is_guild = bool(d.get("guild_id"))
        scope = ("guild" if is_guild else "dm") if d else None
        self._record(name, msg_wire, inflated, scope)

        if name in ("READY", "READY_SUPPLEMENTAL"):
            self.ready_wire += msg_wire
            self.ready_inflated += inflated
            if self.window_start is not None:
                # READY_SUPPLEMENTAL lands after the window opens, but is paid
                # once per connection.
                self.onetime_bytes += msg_wire
            if self.save_fixture:
                try:
                    path = os.path.join(FIXTURE_DIR, "%s.json" % name.lower())
                    with open(path, "w") as fh:
                        json.dump(msg, fh)
                except OSError:
                    pass
            if name == "READY":
                for g in d.get("guilds") or []:
                    gid = g.get("id") or (g.get("properties") or {}).get("id")
                    if gid:
                        guild_ids.add(str(gid))
                self.guild_count = len(guild_ids)
                if self.unsubscribe and guild_ids:
                    self.unsub_bytes = send_json(unsubscribe_payload(sorted(guild_ids)))
                    self.unsub_at = time.monotonic()
            if self.window_start is None:
                self.window_start = time.monotonic()
                # Steady state is a measured delta from here on, so the
                # one-time connect cost does not inflate the hourly figure.
                self.base_in = self._ws.wire.bytes_in
                self.base_out = self._ws.wire.bytes_out
                if self.ready_event is not None:
                    self.ready_event.set()
            return

        # Large accounts can list guilds as unavailable in READY and stream them
        # in later. Those guilds stay subscribed unless we unsubscribe again.
        if name == "GUILD_CREATE":
            gid = d.get("id") or (d.get("properties") or {}).get("id")
            if gid and str(gid) not in guild_ids:
                guild_ids.add(str(gid))
                self.guild_count = len(guild_ids)
                self.onetime_bytes += msg_wire
                if self.unsubscribe:
                    n = send_json(unsubscribe_payload([str(gid)]))
                    self.unsub_bytes += n
                    self.onetime_bytes += n
                    self.late_guild_unsubs += 1
            return

        if not is_guild:
            if name in DECISIVE:
                self.dm_events += 1
            return

        if name in PASSIVE:
            self.passive_guild += 1
            return

        if name in PRESENCE:
            self.presence_guild += 1
            return

        if name in DECISIVE:
            now = time.monotonic()
            if self.unsub_at is not None and now < self.unsub_at + GRACE_SECONDS:
                # Already in flight when op 37 was sent. Not evidence.
                self.decisive_guild_in_grace += 1
                return
            self.decisive_guild += 1
            self.decisive_times.append(now)


def comparison_cutoff(arm_b):
    """The moment both arms are genuinely listening on equal terms.

    Returns None until arm B has sent op 37 and its grace period has elapsed.
    Before that there is nothing to compare.
    """
    if arm_b.unsub_at is None:
        return None
    return arm_b.unsub_at + GRACE_SECONDS


def run_concurrent(token, cap_minutes, target_events, min_events, save_fixture):
    stop = threading.Event()
    a_ready = threading.Event()

    arm_a = Arm("A", token, unsubscribe=False, stop_event=stop,
                ready_event=a_ready, save_fixture=save_fixture)
    arm_b = Arm("B", token, unsubscribe=True, stop_event=stop,
                wait_for=a_ready, save_fixture=False)

    print("running both arms at once on one token.")
    print("  arm A  baseline, stays subscribed")
    print("  arm B  sends op 37 and unsubscribes from every guild")
    print("stopping once arm A has seen %d guild messages, or after %g min.\n"
          % (target_events, cap_minutes))

    arm_a.start()
    arm_b.start()

    deadline = time.monotonic() + cap_minutes * 60.0
    last_report = 0.0
    try:
        while time.monotonic() < deadline:
            if arm_a.finished.is_set() and arm_b.finished.is_set():
                break
            if arm_a.error or arm_b.error:
                break

            # Arm B only starts counting at unsub_at + grace, several seconds
            # after arm A's READY. Stopping on arm A's raw total would let a
            # busy account finish before arm B had listened at all, and print a
            # confident false PASS. Count arm A over arm B's window.
            cutoff = comparison_cutoff(arm_b)
            if cutoff is not None:
                comparable = arm_a.decisive_since(cutoff)
                if comparable >= target_events:
                    print("  arm A reached %d guild events inside arm B's "
                          "window; stopping." % comparable)
                    break

            now = time.monotonic()
            if now - last_report >= 15.0:
                last_report = now
                remaining = int(deadline - now)
                shared = arm_a.decisive_since(cutoff) if cutoff else 0
                state = "comparing" if cutoff else "arm B not yet unsubscribed"
                print("  %4ds left | %s | A: %3d guild (%d shared) | "
                      "B: %3d guild, %2d passive"
                      % (remaining, state, arm_a.decisive_guild, shared,
                         arm_b.decisive_guild, arm_b.passive_guild))
            time.sleep(0.5)
    except KeyboardInterrupt:
        print("\n  interrupted; reporting what we have.")

    stop.set()
    arm_a.finished.wait(timeout=10.0)
    arm_b.finished.wait(timeout=10.0)
    return arm_a, arm_b


def report_arm(arm):
    print("\n--- arm %s ---" % arm.label)
    if arm.error:
        print("  ERROR: %s" % arm.error)
    if arm.close_code:
        print("  closed with code %d" % arm.close_code)
    if arm.window_start is None:
        print("  READY never arrived; nothing measured.")
        return

    rows = sorted(arm.events.items(), key=lambda kv: -kv[1]["wire"])
    print("\n  %-26s %6s %10s %10s %6s %6s"
          % ("event", "count", "wire", "inflated", "guild", "dm"))
    print("  " + "-" * 70)
    for name, e in rows:
        if e["count"] == 0 and e["wire"] == 0:
            continue
        print("  %-26s %6d %10s %10s %6d %6d"
              % (name[:26], e["count"], human(e["wire"]), human(e["inflated"]),
                 e["guild"], e["dm"]))

    print("\n  window                  %.1f min" % (arm.elapsed / 60.0))
    print("  guilds seen             %d" % arm.guild_count)
    print("  connect cost (once)     %s handshake + %s READY"
          % (human(arm.handshake_bytes), human(arm.ready_wire)))
    if arm.unsub_bytes:
        print("  op 37 sent              %s%s"
              % (human(arm.unsub_bytes),
                 " (+%d late guilds)" % arm.late_guild_unsubs
                 if arm.late_guild_unsubs else ""))
    print("  guild events (decisive) %d" % arm.decisive_guild)
    if arm.decisive_guild_in_grace:
        print("    in-flight, ignored    %d (within %gs of op 37)"
              % (arm.decisive_guild_in_grace, GRACE_SECONDS))
    print("  guild events (passive)  %d  PASSIVE_UPDATE / CHANNEL_UNREADS"
          % arm.passive_guild)
    print("  guild presence          %d  (always sent for friends/open DMs)"
          % arm.presence_guild)
    print("  dm events               %d" % arm.dm_events)
    print("  in-window frame bytes   %s across %d frames"
          % (human(arm.window_frame_bytes), arm.window_frames))
    print("    ciphertext delta      %s (upper bound; overlaps READY via "
          "recv read-ahead)" % human(arm.ciphertext_delta))
    print("  >> ROUGH RATE           %s/hr  (short window; the one-hour "
          "on-device run is the real test)" % human(arm.per_hour))


def scope_analysis(arm_a, arm_b):
    """Is op 37 per-session, or per-account?

    If arm A goes quiet the moment arm B unsubscribes, op 37 changed state for
    the whole account rather than for one session. That matters twice over: it
    would mute the official client while smolcord runs, AND it makes arm A
    useless as a control, which otherwise looks identical to "guilds are quiet".
    """
    result = {"account_wide": False, "rate_before": 0.0, "rate_after": 0.0,
              "before": 0, "after": 0, "usable": False,
              "concurrent": None}

    # The strongest evidence needs no before/after reasoning at all.
    #
    # Both arms listen over an overlapping window. If arm A keeps receiving an
    # event type that arm B has none of, then arm B's op 37 changed arm B's
    # session only. This answers the question even when the rate comparison
    # cannot: on the first real run arm B unsubscribed 2s in, leaving no
    # "before" span to measure, while arm A took 26 guild presence events to
    # arm B's 0.
    if arm_a.presence_guild >= 4 and arm_b.presence_guild == 0:
        result["concurrent"] = "per-session"
    elif arm_a.presence_guild >= 4 and arm_b.presence_guild >= arm_a.presence_guild * 0.8:
        result["concurrent"] = "no effect on presence"
    if arm_b.unsub_at is None or arm_a.window_start is None:
        return result

    before = sum(1 for t in arm_a.decisive_times if t < arm_b.unsub_at)
    after = len(arm_a.decisive_times) - before
    span_before = max(1e-6, arm_b.unsub_at - arm_a.window_start)
    span_after = max(1e-6, (arm_a.window_end or time.monotonic()) - arm_b.unsub_at)

    result["before"] = before
    result["after"] = after
    result["rate_before"] = before / span_before * 60.0
    result["rate_after"] = after / span_after * 60.0
    # Need a few events and a few seconds each side before the comparison says
    # anything.
    result["usable"] = (before >= 4 and span_before >= 5.0 and span_after >= 5.0)
    if result["usable"] and result["rate_after"] < result["rate_before"] * 0.25:
        result["account_wide"] = True
    return result


def report_scope(scope):
    if not scope["usable"] and scope["concurrent"] is None:
        return
    print("\n=== scope check: is op 37 per-session or per-account? ===")
    if scope["concurrent"] == "per-session":
        print("  Arm A kept receiving guild presence while arm B received none,")
        print("  over the same window. op 37 is PER-SESSION: smolcord stays")
        print("  cheap without muting anything in your official client.")
        if not scope["usable"]:
            return
        print()
    elif scope["concurrent"] == "no effect on presence":
        print("  Both arms received guild presence at similar rates, so op 37")
        print("  did not take effect at all. Check that it was accepted.")
        if not scope["usable"]:
            return
        print()
    print("  arm A guild events/min before arm B unsubscribed: %.1f"
          % scope["rate_before"])
    print("  arm A guild events/min after:                     %.1f"
          % scope["rate_after"])
    if scope["account_wide"]:
        print("  Arm A went quiet too. op 37 looks ACCOUNT-WIDE: it would also")
        print("  mute the official client while smolcord is running.")
    else:
        print("  Arm A kept receiving. op 37 looks PER-SESSION, which is what")
        print("  we want: smolcord stays cheap without affecting other clients.")


def effect_table(arm_a, arm_b, cutoff):
    """What op 37 actually changed, per event type, over the shared window.

    A single reduction ratio hid the real result on the first real run: guild
    presence went from 26 to 0 while guild messages went from 29 to 28. One
    number cannot say that.
    """
    print("\n=== what op 37 changed (shared window, guild-scoped only) ===\n")
    names = sorted(set(arm_a.events) | set(arm_b.events))
    print("  %-26s %8s %8s   %s" % ("event", "arm A", "arm B", "effect"))
    print("  " + "-" * 66)
    rows = 0
    for name in names:
        a = arm_a.events.get(name, {}).get("guild", 0)
        b = arm_b.events.get(name, {}).get("guild", 0)
        if a == 0 and b == 0:
            continue
        rows += 1
        if a == 0:
            effect = "only in B"
        elif b == 0:
            effect = "SILENCED"
        else:
            effect = "%+.0f%%" % (100.0 * (float(b) / a - 1.0))
        print("  %-26s %8d %8d   %s" % (name[:26], a, b, effect))
    if rows == 0:
        print("  no guild-scoped events in either arm.")
    # Arm A's raw totals are shown; its shared-window count is in the verdict.
    print("\n  Arm A counts are whole-run totals. The verdict below uses only")
    print("  the shared window, which starts %gs after arm B's op 37."
          % GRACE_SECONDS)


def verdict(arm_a, arm_b, min_events, budget=1024 * 1024):
    print("\n=== verdict ===")

    if arm_a.error or arm_b.error:
        print("  INCONCLUSIVE: an arm failed.")
        for arm in (arm_a, arm_b):
            if arm.error:
                print("    arm %s: %s" % (arm.label, arm.error))
        return 1

    if arm_a.window_start is None or arm_b.window_start is None:
        print("  INCONCLUSIVE: an arm never reached READY.")
        return 1

    if arm_b.unsub_at is None:
        print("  INCONCLUSIVE: arm B never sent op 37.")
        if arm_b.guild_count == 0:
            print("  Arm B saw no guilds, so there was nothing to unsubscribe")
            print("  from. This account is in no servers: good for the budget,")
            print("  but it does not test op 37.")
        return 1

    cutoff = comparison_cutoff(arm_b)
    a = arm_a.decisive_since(cutoff)
    b = arm_b.decisive_guild
    scope = scope_analysis(arm_a, arm_b)

    # ---------------- question 1: what did op 37 do? ----------------
    print("\n  QUESTION 1 -- does op 37 stop guild events?\n")
    print("    shared window        %.1f min"
          % (max(0.0, (arm_a.window_end or time.monotonic()) - cutoff) / 60.0))
    print("    guild messages       arm A %d  ->  arm B %d" % (a, b))
    print("    guild presence       arm A %d  ->  arm B %d"
          % (arm_a.presence_guild, arm_b.presence_guild))
    print("    guild passive        arm A %d  ->  arm B %d"
          % (arm_a.passive_guild, arm_b.passive_guild))

    control_fired = a >= min_events
    if not control_fired and scope["account_wide"]:
        print("\n  ACCOUNT-WIDE: op 37 muted arm A as well (%.1f -> %.1f"
              % (scope["rate_before"], scope["rate_after"]))
        print("  guild events/min). One session's op 37 changed state for the")
        print("  whole account, so smolcord would mute guild events in the")
        print("  official client while it runs.")
        return 5

    if not control_fired:
        print("\n  Arm A saw only %d guild messages in the shared window, below"
              % a)
        print("  the %d needed to judge arm B's silence." % min_events)
        if arm_a.guild_count == 0:
            print("  This account is in no guilds: nothing to test.")
        elif arm_a.decisive_guild >= min_events:
            print("  Arm A saw %d overall, but most arrived before arm B"
                  % arm_a.decisive_guild)
            print("  finished unsubscribing. Retry.")
        else:
            print("  Retry with: make probe-patient")
        print("\n  INCONCLUSIVE on question 1.")
        q1 = None
    elif b == 0:
        print("\n  -> op 37 SILENCES guild messages.")
        q1 = "silenced"
    elif b < a * 0.5:
        print("\n  -> op 37 reduces guild messages by %.0f%%, but does not"
              % (100.0 * (1 - float(b) / a)))
        print("     silence them.")
        q1 = "partial"
    else:
        print("\n  -> op 37 does NOT stop guild messages.")
        if arm_a.presence_guild > 0 and arm_b.presence_guild == 0:
            print("     It did work: guild presence went %d -> 0. The flags"
                  % arm_a.presence_guild)
            print("     govern presence, typing and member updates. Message")
            print("     delivery is not gated by them.")
        q1 = "no effect on messages"

    # ---------------- question 2: does the budget fit? ----------------
    # This is the decision. A reduction ratio never was: what matters is the
    # absolute rate against 1MB/hr, plus the cold-start cost.
    print("\n  QUESTION 2 -- does the budget fit anyway?\n")
    rate = arm_b.per_hour
    print("    steady rate (arm B)  %s/hr  against a %s/hr budget"
          % (human(rate), human(budget)))
    print("      measured frames    %s in %.1f min"
          % (human(arm_b.window_frame_bytes), arm_b.elapsed / 60.0))
    print("      + per-frame TLS and TCP/IP overhead on %d frames"
          % arm_b.window_frames)
    print("    cold start           %s per fresh IDENTIFY"
          % human(arm_b.connect_cost))
    if arm_b.connect_cost > 0:
        # Against the headroom left after the steady rate, not the whole
        # budget: the two costs are additive.
        headroom_for_starts = max(0.0, budget - rate)
        if headroom_for_starts > 0:
            print("      with %s/hr of headroom left, that is %.1f cold "
                  "starts/hr" % (human(headroom_for_starts),
                                 headroom_for_starts / arm_b.connect_cost))
        else:
            print("      no headroom left for any cold start")
    if arm_b.dm_events == 0:
        print("    NOTE: zero DMs in this sample. Real DM traffic adds to the")
        print("    steady rate and is still a projection, not a measurement.")

    headroom = budget - rate
    if rate >= budget:
        print("\n  FAIL: the steady rate alone exceeds the budget.")
        print("  Build the relay. It holds the gateway connection and forwards")
        print("  only DM events. DMStore already sits behind an interface for")
        print("  this, so the UI does not change.")
        return 4

    if rate > budget * 0.5:
        print("\n  TIGHT: %s/hr leaves only %s/hr for DM traffic."
              % (human(rate), human(headroom)))
        print("  Direct may work, but a busy hour could break it. Keep the")
        print("  relay as a live option and confirm on device.")
        return 3

    print("\n  PASS on the budget: %s/hr is %.0f%% of it, leaving %s/hr for"
          % (human(rate), 100.0 * rate / budget, human(headroom)))
    print("  DM traffic. A direct phone-to-Discord connection is viable.")

    # A budget pass measured while the guilds were quiet is weak evidence: the
    # rate does not include the guild traffic a busy hour would bring. Report
    # the pass, but return INCONCLUSIVE so the run is repeated.
    #
    # The exception is an account in no guilds at all. There is no firehose to
    # miss, so the budget figure stands on its own.
    if q1 is None and arm_a.guild_count > 0:
        print("\n  ...but question 1 was inconclusive, so this rate was")
        print("  measured during quiet guilds and underestimates a busy hour.")
        print("  Treat it as provisional and run again: make probe-patient")
        return 2

    if q1 in ("no effect on messages", "partial"):
        print("\n  Note the shape of this result: op 37 did not stop guild")
        print("  messages, but those messages are cheap at this guild count.")
        print("  The cost that decides the budget is the cold start above, not")
        print("  the firehose. Prioritise RESUME and guild_versions over any")
        print("  further attempt to silence guilds.")
    if arm_b.passive_guild or arm_b.presence_guild:
        print("\n  The rate includes %d passive and %d presence events, both"
              % (arm_b.passive_guild, arm_b.presence_guild))
        print("  of which Discord sends for unsubscribed guilds by design.")
    return 0


def probe_identify(token, guild_versions, label, save_as=None):
    """One IDENTIFY. Measure READY, then disconnect.

    Returns a dict describing the cost and the shape of the payload. Used by
    --cached-identify to compare a cold IDENTIFY against one that sends
    client_state.guild_versions.
    """
    print("\n  [%s] connecting..." % label)
    ws = WebSocket(GATEWAY, headers=UPGRADE_HEADERS)
    inflater = ZlibStream()
    out = {
        "label": label,
        "handshake": ws.wire.handshake_bytes_in + ws.wire.handshake_bytes_out,
        "ready_wire": 0, "ready_inflated": 0,
        "supplemental_wire": 0, "supplemental_inflated": 0,
        "guilds": 0, "guilds_with_channels": 0, "guild_bytes": 0,
        "versions": {}, "data_modes": {}, "error": None,
    }
    pending = []
    seen_ready = False
    deadline = time.monotonic() + 45.0
    try:
        while time.monotonic() < deadline:
            frame = ws.recv_frame(timeout=5.0)
            if frame is None:
                continue
            opcode, payload, wire_len, _fin = frame
            if opcode == ws.CLOSE:
                code = int.from_bytes(payload[:2], "big") if len(payload) >= 2 else 0
                out["error"] = "closed %d: %s" % (code, FATAL_CLOSE.get(code, ""))
                return out
            if opcode == ws.PING:
                ws.send_frame(ws.PONG, payload)
                continue
            if opcode not in (ws.TEXT, ws.BINARY, ws.CONT):
                continue

            pending.append(wire_len)
            result = inflater.feed(payload)
            if result is None:
                continue
            data, _compressed = result
            msg_wire = sum(pending)
            pending = []
            msg = json.loads(data)
            op = msg.get("op")

            if op == OP_HELLO:
                ws.send_text(json.dumps(
                    identify_payload(token, guild_versions),
                    separators=(",", ":")))
                continue
            if op == OP_INVALID_SESSION:
                out["error"] = "INVALID_SESSION"
                return out
            if op != OP_DISPATCH:
                continue

            name = msg.get("t")
            d = msg.get("d") or {}
            if name == "READY":
                out["ready_wire"] = msg_wire
                out["ready_inflated"] = len(data)
                guilds = d.get("guilds") or []
                out["guilds"] = len(guilds)
                out["guild_bytes"] = len(json.dumps(
                    guilds, separators=(",", ":")).encode())
                for g in guilds:
                    if not isinstance(g, dict):
                        continue
                    props = g.get("properties") or {}
                    gid = g.get("id") or props.get("id")
                    ver = g.get("version", props.get("version"))
                    if gid and ver is not None:
                        out["versions"][str(gid)] = ver
                    # A stubbed guild has no channels array. That is the saving.
                    if g.get("channels"):
                        out["guilds_with_channels"] += 1
                    mode = g.get("data_mode")
                    if mode is not None:
                        out["data_modes"][str(mode)] = \
                            out["data_modes"].get(str(mode), 0) + 1
                if save_as:
                    try:
                        with open(os.path.join(FIXTURE_DIR, save_as), "w") as fh:
                            json.dump(msg, fh)
                    except OSError:
                        pass
                seen_ready = True
                continue
            if name == "READY_SUPPLEMENTAL":
                out["supplemental_wire"] = msg_wire
                out["supplemental_inflated"] = len(data)
                if seen_ready:
                    return out
    finally:
        ws.close()
    if not seen_ready:
        out["error"] = out["error"] or "READY never arrived"
    return out


def cached_identify(token):
    """Lever 3: does client_state.guild_versions shrink READY?

    Measures two IDENTIFYs in the same run rather than comparing against a
    remembered figure, so the two are directly comparable.

    This became the most valuable measurement after the first probe run: a
    fresh IDENTIFY cost about 131KB, and `guilds` was 84.4% of READY, none of
    which a DM client uses.
    """
    print("lever 3: measuring whether guild_versions shrinks READY")
    print("two IDENTIFYs, back to back, on one token.")
    print("  pass 1  client_state.guild_versions = {}")
    print("  pass 2  the versions pass 1 reported")

    cold = probe_identify(token, {}, "cold", save_as="ready.json")
    if cold["error"]:
        print("\n  pass 1 failed: %s" % cold["error"])
        return 1
    print("    READY %s wire, %s inflated, %d guilds (%d with channels)"
          % (human(cold["ready_wire"]), human(cold["ready_inflated"]),
             cold["guilds"], cold["guilds_with_channels"]))

    if not cold["versions"]:
        print("\n  pass 1 reported no guild versions, so there is nothing to")
        print("  send back. Lever 3 cannot work on this account.")
        return 3

    # max_concurrency is 1, and the first session is closing.
    time.sleep(3.0)

    warm = probe_identify(token, cold["versions"], "warm")
    if warm["error"]:
        print("\n  pass 2 failed: %s" % warm["error"])
        return 1
    print("    READY %s wire, %s inflated, %d guilds (%d with channels)"
          % (human(warm["ready_wire"]), human(warm["ready_inflated"]),
             warm["guilds"], warm["guilds_with_channels"]))

    print("\n=== lever 3 result ===\n")
    cold_total = cold["handshake"] + cold["ready_wire"] + cold["supplemental_wire"]
    warm_total = warm["handshake"] + warm["ready_wire"] + warm["supplemental_wire"]
    print("  %-22s %12s %12s" % ("", "cold", "with versions"))
    print("  " + "-" * 50)
    print("  %-22s %12s %12s" % ("READY wire",
                                 human(cold["ready_wire"]), human(warm["ready_wire"])))
    print("  %-22s %12s %12s" % ("READY inflated",
                                 human(cold["ready_inflated"]), human(warm["ready_inflated"])))
    print("  %-22s %12s %12s" % ("guilds payload",
                                 human(cold["guild_bytes"]), human(warm["guild_bytes"])))
    print("  %-22s %12d %12d" % ("guilds with channels",
                                 cold["guilds_with_channels"], warm["guilds_with_channels"]))
    print("  %-22s %12s %12s" % ("total connect cost",
                                 human(cold_total), human(warm_total)))
    if cold["data_modes"] or warm["data_modes"]:
        print("\n  data_mode counts: cold %r, warm %r"
              % (cold["data_modes"], warm["data_modes"]))

    if cold_total <= 0:
        return 1
    saving = 1.0 - float(warm_total) / cold_total
    print("\n  saving: %.0f%% of the connect cost (%s -> %s)"
          % (saving * 100, human(cold_total), human(warm_total)))

    budget = 1024 * 1024
    print("  cold starts per hour to spend the budget: %.1f -> %.1f"
          % (float(budget) / cold_total, float(budget) / warm_total))

    if saving > 0.5:
        print("\n  LEVER 3 WORKS. Persist guild_versions and send them on every")
        print("  IDENTIFY. This is already implemented in Identify.swift and")
        print("  Persistence.swift; it is now confirmed worth the disk space.")
        return 0
    if saving > 0.1:
        print("\n  PARTIAL. Some saving, less than half. Keep it; it costs one")
        print("  small dictionary on disk.")
        return 0
    print("\n  NOT HONORED. The guild data came back in full.")
    print("  Evidence: %d of %d guilds still carried a channels array."
          % (warm["guilds_with_channels"], warm["guilds"]))
    if warm["data_modes"]:
        print("  data_mode on the warm pass: %r" % warm["data_modes"])
    print()
    print("  This does NOT prove lever 3 is dead. We sent one payload shape:")
    print("    client_state: {guild_versions: {...}}")
    print("  The capability doc for client_state_v2 (1<<10) says it changes")
    print("  client_state in IDENTIFY, without saying to what. A different")
    print("  shape may be required. Same lesson as op 37: one shape tested is")
    print("  not a general result.")
    print()
    print("  Until that is settled, the only defence against the cold start is")
    print("  to avoid reconnecting. Keep the code; it is harmless.")
    return 3


def smoke():
    """Connect to the real gateway and read HELLO. No token, no identify."""
    print("smoke test: connecting to the live gateway, no token used")
    ws = WebSocket(GATEWAY, headers=UPGRADE_HEADERS)
    print("  upgrade accepted")
    print("  TLS handshake: %s out, %s in"
          % (human(ws.wire.handshake_bytes_out), human(ws.wire.handshake_bytes_in)))
    inflater = ZlibStream()
    deadline = time.monotonic() + 20.0
    try:
        while time.monotonic() < deadline:
            frame = ws.recv_frame(timeout=5.0)
            if frame is None:
                continue
            opcode, payload, wire_len, _fin = frame
            if opcode == ws.CLOSE:
                code = int.from_bytes(payload[:2], "big") if len(payload) >= 2 else 0
                print("  gateway closed early, code %d" % code)
                return 1
            if opcode not in (ws.TEXT, ws.BINARY, ws.CONT):
                continue
            result = inflater.feed(payload)
            if result is None:
                print("  partial message buffered (%d frame bytes), waiting" % wire_len)
                continue
            data, compressed_len = result
            msg = json.loads(data)
            print("  decoded op %s" % msg.get("op"))
            print("    compressed %s -> inflated %s (ratio %.2fx)"
                  % (human(compressed_len), human(len(data)),
                     len(data) / max(1, compressed_len)))
            if msg.get("op") == OP_HELLO:
                hb = msg["d"]["heartbeat_interval"]
                print("    heartbeat_interval = %d ms -> %.1f heartbeats/hr"
                      % (hb, 3600000.0 / hb))
                print("\n  SMOKE PASS: TLS, upgrade, zlib-stream and framing all work.")
                print("  Total on the wire for connect + HELLO: %s"
                      % human(ws.wire.bytes_in + ws.wire.bytes_out))
                return 0
    finally:
        ws.close()
    print("  SMOKE FAIL: no HELLO within 20s")
    return 1


def main():
    ap = argparse.ArgumentParser(
        description="Measure what a DM-only Discord client costs.")
    ap.add_argument("--smoke", action="store_true",
                    help="connect and read HELLO only; needs no token")
    ap.add_argument("--cap-minutes", type=float, default=5.0,
                    help="hard stop, even if the guilds stay quiet (default 5)")
    ap.add_argument("--target-events", type=int, default=30,
                    help="stop once arm A has seen this many guild events (default 30)")
    ap.add_argument("--min-events", type=int, default=10,
                    help="below this, the run is inconclusive (default 10)")
    ap.add_argument("--arm", choices=("A", "B"),
                    help="run a single arm instead, for debugging")
    ap.add_argument("--cached-identify", action="store_true",
                    help="lever 3: measure whether guild_versions shrinks READY")
    ap.add_argument("--no-fixture", action="store_true",
                    help="do not save READY payloads to tools/fixtures/")
    args = ap.parse_args()

    if args.smoke:
        return smoke()

    token = os.environ.get("DISCORD_TOKEN", "").strip()
    if not token:
        print("DISCORD_TOKEN is not set.\n\n"
              "  export DISCORD_TOKEN='...'\n\n"
              "The token is read from the environment only. It is never written\n"
              "to disk and never printed.", file=sys.stderr)
        return 2

    os.makedirs(FIXTURE_DIR, exist_ok=True)

    if args.cached_identify:
        return cached_identify(token)

    if args.arm:
        stop = threading.Event()
        arm = Arm(args.arm, token, unsubscribe=(args.arm == "B"),
                  stop_event=stop, save_fixture=not args.no_fixture)
        arm.start()
        try:
            arm.finished.wait(timeout=args.cap_minutes * 60.0)
        except KeyboardInterrupt:
            pass
        stop.set()
        arm.finished.wait(timeout=10.0)
        report_arm(arm)
        return 0 if not arm.error else 1

    arm_a, arm_b = run_concurrent(token, args.cap_minutes, args.target_events,
                                  args.min_events, not args.no_fixture)
    report_arm(arm_a)
    report_arm(arm_b)
    effect_table(arm_a, arm_b, comparison_cutoff(arm_b))
    report_scope(scope_analysis(arm_a, arm_b))
    return verdict(arm_a, arm_b, args.min_events)


if __name__ == "__main__":
    sys.exit(main())
