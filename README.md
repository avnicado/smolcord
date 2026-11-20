# smolcord

A terminal-UI Discord client for iOS 12, for direct messages only, built to a
hard budget of **under 1 MB per hour**.

```
[smolcord] ok  v42.1K ^3.2K  18.6K/hr  3 dm
```

The official Discord app is heavy because it downloads avatars, embeds,
attachment previews, guild metadata, presence streams and telemetry. On a
metered or capped connection that is unusable. smolcord does none of it.

The live data rate is in the status line at all times. It is not a debug
screen. The number is the product.

---

## Why it is small

Four levers, all applied at the source. No proxy, no relay, no server.

| Lever | Where | Effect |
|---|---|---|
| 1. `capabilities` bitfield | `Sources/Protocol/GatewayCapabilities.swift` | Shrinks READY at the server. `dedupe_user_objects` hoists every user object into one array; `prioritized_ready_payload` splits the rest out; `lazy_user_notes` and `user_settings_proto` drop whole fields. |
| 2. Opcode 37 bulk unsubscribe | `Sources/Protocol/Identify.swift` | **Measured: stops guild presence, not guild messages.** One message with every flag false took guild `PRESENCE_UPDATE` from 26 to 0, worth about 75 KB/hr, for 2 KB paid once. Guild `MESSAGE_CREATE` went 29 → 28, so it is not gated by these flags. Kept because it is cheap and real, but it is not the firehose killer the community docs describe. |
| 3. `client_state.guild_versions` | `Sources/Protocol/Identify.swift` | Versions are kept on disk and sent back on the next IDENTIFY. Discord omits guild data that has not changed, so every cold start after the first is cheaper. |
| 4. `zlib-stream` transport compression | `Sources/Transport/ZlibInflater.swift` | One inflate context for the whole connection, so repeated JSON structure compresses to almost nothing. Uses system `libz`; no vendored C library. |

On top of that:

* **No media, ever.** Attachments render as `[png 240K]`. Long-press copies the
  URL so you can decide outside the app. No avatars, no embeds, no previews.
* **No telemetry.** Nothing is reported anywhere.
* **Nothing is prefetched.** History is fetched when a conversation opens, and
  only when the 50-message disk cache cannot already serve it.
* **Foreground only.** A backgrounded smolcord costs zero bytes per hour.
* **RESUME over IDENTIFY.** Backgrounding closes the socket with code 4000,
  which keeps the session alive; coming back costs one small RESUME instead of
  a fresh IDENTIFY and the whole of READY. Discord holds a session for only a
  few minutes, so a long absence falls back to IDENTIFY automatically.

### Measured

From `make smoke` and one `make probe` run on a 16-guild account, 19 Nov 2026:

| Item | Measured |
|---|---|
| TLS handshake | 5.4 KB |
| `heartbeat_interval` | 41250 ms, so 87.3 heartbeats/hr |
| **READY** | **118.7 KB wire, 840 KB inflated** |
| READY_SUPPLEMENTAL | 7.7 KB wire, 54 KB inflated |
| **One fresh IDENTIFY** | **~131 KB.** With 176 KB/hr already spent, the remaining headroom covers about 6.5 of them. |
| Steady state after op 37 | **176 KB/hr**, 17% of budget |
| Guild `MESSAGE_CREATE` | 28 in 3.7 min, 3.9 KB of frames |
| Guild `PRESENCE_UPDATE` | 26 → 0 after op 37 |
| DM traffic in the sample | **zero.** Still a projection, not a measurement. |

**The result reframed the project.** The firehose is affordable. READY is not.

`make scan` breaks READY down, from the fixture the probe saved:

| Key | Inflated | Share |
|---|---|---|
| `guilds` | 708.8 KB | **84.4%** |
| `users` | 42.2 KB | 5.0% |
| `read_state` | 33.6 KB | 4.0% |
| `user_guild_settings` | 26.1 KB | 3.1% |
| `private_channels` | 9.2 KB | 1.1% |
| everything else | ~20 KB | 2.4% |

Inside `guilds`: channels 50%, roles 25%, emojis 15.5%. A DM-only client needs
none of it, and the server sends it anyway. Everything smolcord actually uses
is about 10% of READY.

So the three things that matter, in order:

1. **Do not reconnect.** Every fresh IDENTIFY costs 131 KB.
2. **RESUME when you can.** It skips READY entirely.
3. **`client_state.guild_versions`.** All 16 guilds carried a `version` field,
   so lever 3 has something to work with. Its effect is **not yet measured** —
   run `make probe-cached`.

---

## Status

| Phase | State |
|---|---|
| 0. Data-budget probe | **Run. Verdict: direct connection is viable at 176 KB/hr, 17% of budget.** See Measured above. |
| Transport (`WebSocketClient`, `ZlibInflater`, `ByteMeter`) | Written, with tests. The Python reference implementation passes 22/22. |
| Protocol (`Gateway`, `Identify`, `GatewayEvent`) | Written, with tests. |
| Model (`DMStore`, `Persistence`, `Keychain`, `REST`) | Written, with tests. |
| UI (`TermLogView`, `ChannelListVC`, `ConversationVC`, `StatusLine`) | Written. Never seen on a screen. |
| CI | `.github/workflows/ios-build.yml` is written and **has never run**. It is the first thing that will compile any of this. |

**No Swift in this repository has been compiled.** There is no Swift toolchain
on the machine it was written on. 53 Swift tests exist and none has ever
executed. Treat the first build as a real step with real errors to fix, not a
formality.

### How to compile it

Fastest path, no Mac needed: push this repo to GitHub. The workflow in
`.github/workflows/ios-build.yml` runs `xcodegen` and `xcodebuild` on a macOS
runner, builds for a device, runs the test bundle on a simulator, and uploads
the logs. The Python tests run first on a Linux runner so a trivial break costs
no macOS minutes.

On a Mac: `brew install xcodegen && make project && make build && make test`.

### Partial verification without a Mac

`Package.swift` builds a Linux-compatible subset so the portable logic can
actually be run, not just read:

```sh
make swift-test        # 40 of the 53 Swift tests
```

| Covered | Not covered |
|---|---|
| `GatewayEvent` wire-format parsing | all of `Sources/UI` (UIKit) |
| `Identify`, capabilities, close codes | `WebSocketClient` (Network) |
| `ZlibInflater` streaming and the `Z_SYNC_FLUSH` boundary | `Gateway`, `DMStore` (depend on the above) |
| `ByteMeter`, including the READY reclassification | `Keychain` (Security) |
| `Persistence` on-disk format and schema evolution | `REST` |
| `TextWrap` line breaking | |

A green run means the parsing, accounting, on-disk format and text layout are
correct. It says nothing about whether the app builds or runs. Only the Xcode
build answers that.

Needs a Swift toolchain. openSUSE has none in its repos, so either install one
with [swiftly](https://www.swift.org/install/linux/) into `$HOME`, or run the
official container:

```sh
podman run --rm -v "$PWD:/w:Z" -w /w swift:latest swift test
```

### Watch these on the first device run

Three classes of bug were found by reading rather than by compiling, and were
fixed, but none has been exercised. A compiler cannot catch any of them, so
they are the places to look if the first run misbehaves.

* **Reconnect storms.** `WebSocketClient.close` keeps a closed client alive for
  about a second so the peer can echo the close frame. During that second its
  callbacks are still live. `Gateway` guards every callback with a
  `generation` counter so a retired socket cannot feed the new connection's
  zlib context, stop the new socket's heartbeat, or trigger a third connection.
  Symptom if this is still wrong: the status line flickering between `conn` and
  `retry`, and the `c` counter climbing. Each spurious connection costs 131 KB.
* **Big layers on old GPUs.** A conversation of 200 wrapped messages is a few
  thousand points tall. As one view at 2× that exceeds the maximum texture size
  on an A7 or A8, and iOS gives no warning: the view just renders blank.
  `TermLogView` is a `UITableView` with one recycled view per row for exactly
  this reason, so nothing larger than the viewport is ever rasterised. If a long
  conversation renders blank anyway, this is where to look.
* **Observer ownership.** The store's observers are single closures, not lists.
  Each screen claims all of them in its own `viewWillAppear`, and no screen
  clears them on the way out, because the relative order of the incoming
  `viewWillAppear` and the outgoing `viewWillDisappear` during a pop is not
  guaranteed. Symptom if this is still wrong: the DM list's status line frozen
  at `off` after visiting a conversation.
* **Threading on `Persistence`.** `Gateway` calls back on its own serial queue
  while `DMStore` writes from main. Every path into `Persistence` is funnelled
  through main. Symptom if this is still wrong: a crash inside JSON encoding, or
  a store that loses writes.
* **Guild tracking across a RESUME.** A RESUME never replays READY, so the op 37
  unsubscribe has to be re-sent explicitly. It is driven by
  `SessionCache.knownGuildIDs`, kept separately from `guildVersions` because a
  guild only lands in that dictionary if its payload carried a `version` field.
  Symptom if this is still wrong: data use that is fine on a cold start and
  climbs after backgrounding and returning.

---

## Phase 0: the budget gate (run, and passed)

**Answered. Op 37 stops guild presence, not guild messages, and the budget fits
anyway at 17%.** The numbers are in Measured above.

The probe was built to settle one unverified fact: does opcode 37 stop guild
`MESSAGE_CREATE`, or only typing and presence? Discord's own docs do not say,
and the community docs said it stops messages. It does not. It is kept because
it is how you re-check on a different account, or after Discord changes
something.

`tools/gwprobe.py` runs on any machine with Python 3.7+. No Mac, no Xcode, no
Swift.

```sh
make smoke                     # no token: proves TLS, upgrade, zlib, framing
export DISCORD_TOKEN='...'
make probe                     # usually 1-3 minutes
```

It opens **two sessions on the same token at the same time**:

* **arm A** — identify, then sit still. The control.
* **arm B** — identify, then unsubscribe from every guild.

Concurrent, not sequential. Both arms see the same guild traffic over the same
wall-clock window, which removes the "guilds happened to be quiet during arm B"
confound and halves the wall time. A user account allows 50 sessions, so two is
unremarkable. Arm B waits for arm A's READY before identifying, because
`max_concurrency` is 1.

The run stops on evidence, not on a clock. It ends as soon as arm A has seen 30
guild messages, so a busy account finishes in a minute or two. `--cap-minutes`
is the hard stop, not the target.

### How it reaches a verdict

The verdict rests only on guild-scoped `MESSAGE_CREATE`, `MESSAGE_UPDATE`,
`MESSAGE_DELETE` and `TYPING_START`. Those are the events a subscription gates.

Two kinds of guild-scoped event are deliberately excluded, because Discord
sends them for unsubscribed guilds on purpose:

* `PASSIVE_UPDATE_V2` and `CHANNEL_UNREADS_UPDATE` keep channel unreads current.
* `PRESENCE_UPDATE` always arrives for friends, implicit relationships, and
  people you have an open DM with who share a server.

Both get their own row and their bytes count toward the hourly figure, but
neither decides the verdict. Judging on `guild_id` alone would call a real
success a failure.

Both arms are counted over the **same window**, beginning at arm B's op 37 plus
a 5-second grace period. Arm A's raw total is larger because it starts
listening several seconds earlier, and comparing raw totals would let a busy
account satisfy the stop condition before arm B had listened at all.

The probe answers two separate questions, and only the second decides
anything. The first real run is why: op 37 cut guild messages by 3%, which
ratio-based logic called FAIL and answered with "build a relay", while the
measured rate was 17% of budget. **The decision comes from the absolute rate
against 1 MB/hr, never from a reduction ratio.**

| Outcome | Exit | Meaning |
|---|---|---|
| **PASS** | 0 | The steady rate is under half the budget. Direct connection is viable. |
| **TIGHT** | 3 | Between half and all of the budget. Direct may work; keep the relay on the table. |
| **FAIL** (4) | The steady rate alone exceeds 1 MB/hr. Build the relay. |
| **ACCOUNT-WIDE** | 5 | Arm A went quiet too, so op 37 changed state for the whole account. It works, but smolcord would mute guild events in your official client while running. |
| **PROVISIONAL** | 2 | The budget fits, but the guilds were quiet, so the rate underestimates a busy hour. Retry with `make probe-patient`. |
| **ERROR** | 1 | An arm failed, never reached READY, or never sent op 37. |

A control that never fired is the easy way to fool yourself here, so the
INCONCLUSIVE case is a real outcome rather than an error.

It also reports whether op 37 is **per-session or per-account**, by watching
whether arm A goes quiet when arm B unsubscribes. Per-account would mean
smolcord mutes the official client while it runs. That case is easy to mistake
for quiet guilds, so it is called out as its own outcome rather than sending
you off on a pointless longer retry.

The probe measures ciphertext by driving TLS through `ssl.MemoryBIO`, so the
byte figures are what the carrier bills, not payload sizes. The hourly rate from
a short window is rough and labelled as such; the one-hour on-device run is the
acceptance test.

---

## Honest limitations

**This needs a user token.** Bot tokens cannot read your own DM conversations,
and no OAuth scope grants DM read access. A user-token client is a "self-bot"
under Discord's Terms of Service and **the account can be terminated.** There
is no compliant way to build this. The warning is on the login screen too.

**No notifications.** iOS kills background sockets. Real push would need a
relay server with an APNs certificate and a paid Apple account, which does not
fit "no server". The socket is open while the app is open.

**No App Store.** Xcode 26 officially supports deployment targets of iOS 15 and
up; lower targets still build, with a warning. App Store Connect requires an
iOS 13+ target since 9 September 2026, and iOS 15+ from April 2027. An iOS 12
target cannot be uploaded, and this app would not pass review anyway.
Distribution is sideload only.

**DMs only.** No servers, no voice, no video, no reactions, no threads, no
search, no file upload, no message editing.

---

## Building

iOS 12 removes a lot of modern Swift. These are hard constraints, and they
shape the whole codebase:

* No SwiftUI, no Combine (both iOS 13+)
* No `async`/`await` — Swift concurrency back-deploys only to iOS 13
* No `URLSessionWebSocketTask`, no `NWProtocolWebSocket` (both iOS 13+)
* `NWConnection` **is** available: Network.framework shipped in iOS 12.0

Hence the hand-rolled RFC 6455 layer over `NWConnection`. It removes every
dependency and puts an exact byte counter on the one path that decides whether
the app meets its only hard requirement.

The `.xcodeproj` is not checked in. It is a binary that conflicts on every merge
and encodes an Xcode version.

```sh
brew install xcodegen
make project
make build          # expect an "unsupported deployment target" warning
make test
```

Then, to install:

1. Open `smolcord.xcodeproj`, pick your team under Signing.
2. Build to a connected iOS 12 device.
3. With a free Apple ID the app expires after 7 days. A paid account gives a
   1-year profile.

---

## Layout

```
tools/gwlib.py          dependency-free TLS + WebSocket with byte accounting
tools/gwprobe.py        the Phase 0 measurement probe
Tests/test_gwlib.py     offline transport tests (22, passing)
Tests/test_verdict.py   synthetic verdict tests (54, passing)
Tests/Core/*.swift      40 tests, portable: run with `make swift-test`
Tests/App/*.swift       13 tests, need UIKit/Security: Xcode or CI only
Package.swift           the Linux-buildable subset
Packaging/CZlib/        zlib module map for SwiftPM (Xcode uses the bridging
                        header instead)

Sources/Support/        zlib bridging header
Sources/Transport/      WebSocketClient, ZlibInflater, ByteMeter
Sources/Protocol/       Gateway state machine, Identify, GatewayEvent
Sources/Model/          DMStore, Persistence, Keychain, REST
Sources/UI/             TermLogView (recycling log), TermView (small, bounded),
                        screens, StatusLine
Sources/App/            AppDelegate
.github/workflows/      the macOS build, which is what will first compile this
```

The UI talks only to `DMStore`. `DMStore` talks only to a `GatewayEvent`
stream. Nothing above the protocol layer knows whether the bytes came from
Discord directly or from a relay. That boundary is the migration path.

## Verifying the budget on device

The acceptance test is one hour in the foreground, under 1 MB, with real DM
traffic.

1. Log in, open a DM, send and receive.
2. Leave the app in the foreground for an hour.
3. Read the rate off the status line, then cross-check it against
   Settings → Cellular → smolcord.
4. Confirm a DM containing an attachment produces no network activity.
5. Kill and relaunch. The second cold start should be materially cheaper,
   which proves the `guild_versions` cache works.
