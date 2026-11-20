#!/usr/bin/env python3
"""
readyscan -- find out what is actually inside READY, and what can be cut.

The first probe run reframed the budget. The guild firehose turned out to be
cheap (about 65KB/hr in frames on a 16-guild account). READY turned out to cost
about 119KB on the wire and 920KB inflated, paid on every fresh IDENTIFY. At
that size, six or seven cold starts spend the entire hourly budget.

So the question is no longer "can we stop guild events". It is "how small can
READY get, and how often can we avoid paying for it".

This reads the fixture the probe saved and reports:

  * inflated bytes per top-level key, so we know what to attack
  * per-guild sub-key sizes, since guilds usually dominate
  * whether guilds carry a `version` field, which decides whether the
    client_state.guild_versions cache (lever 3) can work at all
  * which capability bits are already paying off

PRIVACY: this prints key names, counts and byte sizes. It never prints values.
The fixture contains your DM list, your friends and your servers.

    python3 -I tools/readyscan.py
    python3 -I tools/readyscan.py tools/fixtures/ready_supplemental.json
"""

import json
import os
import sys

DEFAULT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "fixtures", "ready.json")


def human(n):
    n = float(n)
    for unit in ("B", "KB", "MB"):
        if abs(n) < 1024.0 or unit == "MB":
            return "%dB" % n if unit == "B" else "%.1f%s" % (n, unit)
        n /= 1024.0


def sizeof(obj):
    """Inflated JSON bytes for a subtree, as the wire would carry it."""
    return len(json.dumps(obj, separators=(",", ":")).encode("utf-8"))


def describe(obj):
    if isinstance(obj, list):
        return "list[%d]" % len(obj)
    if isinstance(obj, dict):
        return "dict{%d}" % len(obj)
    return type(obj).__name__


def bar(fraction, width=28):
    filled = int(round(fraction * width))
    return "#" * filled + "." * (width - filled)


def scan_top_level(d, total):
    print("=== top-level keys by inflated size ===\n")
    rows = sorted(((k, sizeof(v), describe(v)) for k, v in d.items()),
                  key=lambda r: -r[1])
    print("  %-28s %10s %7s  %-10s %s"
          % ("key", "size", "share", "shape", ""))
    print("  " + "-" * 76)
    for key, size, shape in rows:
        share = size / total if total else 0
        print("  %-28s %10s %6.1f%%  %-10s %s"
              % (key[:28], human(size), share * 100, shape, bar(share)))
    return rows


def scan_guilds(d):
    guilds = d.get("guilds")
    if not isinstance(guilds, list) or not guilds:
        print("\n  no `guilds` array in this payload.")
        return
    total = sizeof(guilds)
    print("\n=== inside `guilds` (%d guilds, %s total) ===\n"
          % (len(guilds), human(total)))

    # Sum each sub-key across every guild, so we see what repeats.
    per_key = {}
    for g in guilds:
        if not isinstance(g, dict):
            continue
        for k, v in g.items():
            entry = per_key.setdefault(k, {"bytes": 0, "present": 0, "shape": describe(v)})
            entry["bytes"] += sizeof(v)
            entry["present"] += 1

    rows = sorted(per_key.items(), key=lambda kv: -kv[1]["bytes"])
    print("  %-28s %10s %7s  %8s %s"
          % ("sub-key (summed)", "size", "share", "in N", "shape"))
    print("  " + "-" * 76)
    for key, info in rows:
        share = info["bytes"] / total if total else 0
        print("  %-28s %10s %6.1f%%  %5d/%-3d %s"
              % (key[:28], human(info["bytes"]), share * 100,
                 info["present"], len(guilds), info["shape"]))

    biggest = max(guilds, key=sizeof)
    print("\n  largest single guild: %s" % human(sizeof(biggest)))
    print("  median guild:         %s"
          % human(sorted(sizeof(g) for g in guilds)[len(guilds) // 2]))

    # Does lever 3 have anything to work with?
    print("\n=== lever 3 check: can client_state.guild_versions work? ===\n")
    with_version = [g for g in guilds
                    if isinstance(g, dict) and
                    ("version" in g or "version" in (g.get("properties") or {}))]
    print("  guilds carrying a `version` field: %d of %d"
          % (len(with_version), len(guilds)))
    if not with_version:
        print("\n  NONE. The guild_versions cache cannot work as written: there")
        print("  are no versions to send back. Lever 3 is dead on this account,")
        print("  and every cold start pays full price for READY.")
    elif len(with_version) < len(guilds):
        print("\n  PARTIAL. Guilds without a version cannot be cached, so they")
        print("  are re-sent in full on every IDENTIFY. Potential saving is")
        print("  capped at the share that does carry one.")
    else:
        print("\n  All guilds carry a version. Lever 3 should cut most of this")
        print("  on the second and later IDENTIFYs. Worth measuring:")
        print("    python3 -I tools/gwprobe.py --cached-identify")
    # Where does the id live? This decides whether op 37 sees every guild.
    bare = sum(1 for g in guilds if isinstance(g, dict) and g.get("id"))
    nested = sum(1 for g in guilds if isinstance(g, dict)
                 and not g.get("id") and (g.get("properties") or {}).get("id"))
    print("\n  guild id location: %d bare `id`, %d under `properties.id`"
          % (bare, nested))
    if nested:
        print("  clientStateV2 nesting is in use, so GatewayEvent must read")
        print("  both shapes or op 37 misses guilds.")


def scan_capabilities(d):
    """Confirm the capability bits we paid for actually changed the payload."""
    print("\n=== capability bits: did they take effect? ===\n")
    checks = [
        ("dedupe_user_objects (1<<4)", "users" in d,
         "users hoisted into one array"),
        ("prioritized_ready_payload (1<<5)", "merged_presences" not in d,
         "presences moved to READY_SUPPLEMENTAL"),
        ("lazy_user_notes (1<<0)", "notes" not in d,
         "`notes` absent"),
        ("user_settings_proto (1<<9)", "user_settings" not in d,
         "legacy `user_settings` absent"),
        ("versioned_read_states (1<<2)", isinstance(d.get("read_state"), dict),
         "read_state is a versioned object"),
        ("versioned_user_guild_settings (1<<3)",
         isinstance(d.get("user_guild_settings"), dict),
         "user_guild_settings is a versioned object"),
    ]
    for label, ok, detail in checks:
        print("  [%s] %-34s %s" % ("ok" if ok else "??", label, detail))

    if isinstance(d.get("users"), list):
        users = d["users"]
        print("\n  `users` holds %d entries, %s" % (len(users), human(sizeof(users))))
        if users:
            keys = {}
            for u in users:
                if isinstance(u, dict):
                    for k in u:
                        keys[k] = keys.get(k, 0) + 1
            print("  fields present across users:")
            for k, n in sorted(keys.items(), key=lambda kv: -kv[1]):
                print("    %-24s in %d/%d" % (k, n, len(users)))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    if not os.path.exists(path):
        print("no fixture at %s\n\nRun the probe first:\n"
              "  export DISCORD_TOKEN='...'\n  make probe" % path,
              file=sys.stderr)
        return 2

    with open(path) as fh:
        payload = json.load(fh)

    # The probe saves the whole gateway message; the interesting part is `d`.
    d = payload.get("d") if isinstance(payload, dict) and "d" in payload else payload
    if not isinstance(d, dict):
        print("unexpected fixture shape: %s" % describe(d), file=sys.stderr)
        return 2

    on_disk = os.path.getsize(path)
    total = sizeof(d)
    print("fixture: %s" % path)
    print("  %s on disk, %s inflated in `d`, %d top-level keys\n"
          % (human(on_disk), human(total), len(d)))
    print("  Printing key names, counts and sizes only. No values.\n")

    rows = scan_top_level(d, total)
    scan_guilds(d)
    scan_capabilities(d)

    print("\n=== what to cut ===\n")
    cuttable = [(k, s) for k, s, _ in rows
                if k not in ("session_id", "resume_gateway_url", "user",
                             "users", "private_channels", "read_state",
                             "relationships", "v", "api_code_version")]
    saving = sum(s for _, s in cuttable)
    print("  A DM-only client needs: session_id, resume_gateway_url, user,")
    print("  users, private_channels, read_state, relationships.")
    print("  Everything else is %s of %s, or %.0f%% of READY."
          % (human(saving), human(total), 100.0 * saving / total if total else 0))
    print("\n  We cannot ask the server to omit most of it. What we CAN do:")
    print("    1. RESUME instead of IDENTIFY, which skips READY entirely.")
    print("    2. Send client_state.guild_versions, if the check above passed.")
    print("    3. Avoid reconnecting. Each fresh IDENTIFY costs the full price.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
