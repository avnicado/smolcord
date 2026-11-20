#!/usr/bin/env python3
"""
Synthetic tests for gwprobe's verdict logic. No token, no network.

The verdict is the part of the probe that can be confidently wrong. A real run
exercises one scenario; these exercise the ones that matter, including the two
that previously produced a false PASS:

  * arm A's events all arrived before arm B finished unsubscribing
  * op 37 muted the whole account, which looks identical to quiet guilds

Arms are built by hand and never started, so nothing connects anywhere.
"""
import io
import os
import sys
import threading
import time
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import gwprobe  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print("  [%s] %s%s" % ("ok" if cond else "FAIL", name,
                           "" if cond else "  <- " + detail))


def make_arm(label, unsubscribe=False):
    arm = gwprobe.Arm(label, "token", unsubscribe, threading.Event())
    return arm


def build(a_times, b_decisive, unsub_offset=2.0, window=120.0,
          a_guilds=5, b_guilds=5, b_passive=0, b_presence=0,
          a_presence=0, b_frame_bytes=5_000, b_frames=50,
          b_connect=130_000):
    """Construct a finished pair of arms.

    a_times are offsets in seconds from arm A's window start at which arm A
    received a decisive guild event.
    """
    t0 = time.monotonic() - window
    arm_a = make_arm("A")
    arm_b = make_arm("B", unsubscribe=True)

    arm_a.window_start = t0
    arm_a.window_end = t0 + window
    arm_a.base_in = arm_a.base_out = 0
    arm_a.end_in, arm_a.end_out = 50_000, 5_000
    arm_a.guild_count = a_guilds
    arm_a.decisive_times = [t0 + off for off in a_times]
    arm_a.decisive_guild = len(a_times)
    arm_a.presence_guild = a_presence
    arm_a.window_frame_bytes = 8_000
    arm_a.window_frames = 60
    arm_a.handshake_bytes = 5_400

    arm_b.window_start = t0 + unsub_offset
    arm_b.window_end = t0 + window
    arm_b.base_in = arm_b.base_out = 0
    arm_b.end_in, arm_b.end_out = 20_000, 4_000
    arm_b.guild_count = b_guilds
    arm_b.unsub_at = t0 + unsub_offset
    arm_b.unsub_bytes = 4_000
    arm_b.decisive_guild = b_decisive
    arm_b.passive_guild = b_passive
    arm_b.presence_guild = b_presence
    # The rate basis: measured frame bytes inside the window.
    arm_b.window_frame_bytes = b_frame_bytes
    arm_b.window_frames = b_frames
    arm_b.handshake_bytes = 5_400
    arm_b.ready_wire = b_connect - 5_400
    if b_decisive:
        arm_b.events["MESSAGE_CREATE"]["count"] = b_decisive
        arm_b.events["MESSAGE_CREATE"]["guild"] = b_decisive
    return arm_a, arm_b


def run_verdict(arm_a, arm_b, min_events=10):
    buf = io.StringIO()
    with redirect_stdout(buf):
        code = gwprobe.verdict(arm_a, arm_b, min_events)
    return code, buf.getvalue()


# --------------------------------------------------------------- the bug fix

def test_events_before_unsubscribe_do_not_count():
    """The regression that mattered.

    On a busy account arm A can hit the target before arm B has finished
    unsubscribing. Arm B then shows zero because it was not listening yet. That
    must never read as a confident answer to question 1.
    """
    arm_a, arm_b = build([0.05 * i for i in range(40)], b_decisive=0)
    code, out = run_verdict(arm_a, arm_b)
    check("early arm A events do not answer question 1",
          "INCONCLUSIVE on question 1" in out, out)
    check("an inconclusive control returns a retry code", code == 2,
          "exit %d" % code)
    check("the report explains the shared-window shortfall",
          "before arm B" in out, out)


def test_shared_window_events_give_a_clear_answer():
    arm_a, arm_b = build([20.0 + 3.0 * i for i in range(30)], b_decisive=0)
    code, out = run_verdict(arm_a, arm_b)
    check("real shared-window traffic with a silent arm B passes", code == 0,
          "exit %d\n%s" % (code, out))
    check("question 1 reports silencing", "SILENCES guild messages" in out, out)


# ------------------------------------------- the real-run shape: op 37 partial

def test_messages_survive_but_budget_fits():
    """The shape of the first real run.

    Op 37 silenced guild presence (26 -> 0) but not guild messages (29 -> 28).
    The old logic called that FAIL and told the user to build a relay, when the
    measured rate was about 6% of the budget. The decision must come from the
    rate, never from the reduction ratio.
    """
    arm_a, arm_b = build([20.0 + 2.0 * i for i in range(30)], b_decisive=28,
                         a_presence=26, b_presence=0,
                         b_frame_bytes=5_300, b_frames=48)
    code, out = run_verdict(arm_a, arm_b)
    check("surviving guild messages do not force a FAIL", code == 0,
          "exit %d\n%s" % (code, out))
    check("question 1 states op 37 did not stop messages",
          "does NOT stop guild messages" in out, out)
    check("question 1 still credits the presence effect",
          "guild presence went" in out, out)
    check("the report redirects to the cold start",
          "cold start" in out, out)


def test_rate_over_budget_is_a_fail():
    arm_a, arm_b = build([20.0 + 2.0 * i for i in range(30)], b_decisive=28,
                         b_frame_bytes=2_000_000, b_frames=4_000)
    code, out = run_verdict(arm_a, arm_b)
    check("a rate above the budget is FAIL", code == 4,
          "exit %d\n%s" % (code, out))
    check("FAIL recommends the relay", "relay" in out, out)


def test_rate_near_budget_is_tight():
    # About 700KB/hr over a 2-minute window.
    arm_a, arm_b = build([20.0 + 2.0 * i for i in range(30)], b_decisive=28,
                         b_frame_bytes=23_000, b_frames=20)
    code, out = run_verdict(arm_a, arm_b)
    check("a rate between half and all of the budget is TIGHT", code == 3,
          "exit %d\n%s" % (code, out))
    check("TIGHT keeps the relay on the table", "relay" in out, out)


def test_cold_start_cost_is_reported():
    arm_a, arm_b = build([20.0 + 2.0 * i for i in range(30)], b_decisive=0,
                         b_connect=131_000, b_frame_bytes=5_300, b_frames=48)
    code, out = run_verdict(arm_a, arm_b)
    check("the cold-start cost is reported", "per fresh IDENTIFY" in out, out)
    check("cold starts per hour are spelled out",
          "cold starts/hr" in out, out)

    # The two costs are additive: cold starts draw on what the steady rate has
    # not already spent. Dividing the whole budget by the connect cost
    # overstates the allowance, which is what this originally printed.
    budget = 1024 * 1024
    naive = budget / 131_000.0
    import re
    m = re.search(r"that is ([0-9.]+) cold starts/hr", out)
    check("the cold-start allowance is printed", m is not None, out)
    if m:
        shown = float(m.group(1))
        check("cold starts are counted against headroom, not the whole budget",
              shown < naive * 0.95,
              "shown=%.1f naive=%.1f" % (shown, naive))
        check("headroom is stated alongside it", "headroom left" in out, out)


def test_zero_dms_is_disclosed():
    arm_a, arm_b = build([20.0 + 2.0 * i for i in range(30)], b_decisive=0)
    code, out = run_verdict(arm_a, arm_b)
    check("a sample with no DMs says the rate is incomplete",
          "zero DMs in this sample" in out, out)


# ----------------------------------------------------------- account-wide op37

def test_account_wide_is_not_reported_as_quiet():
    arm_a, arm_b = build([1.0 * i for i in range(25)], b_decisive=0,
                         unsub_offset=30.0)
    code, out = run_verdict(arm_a, arm_b)
    check("account-wide muting is detected", code == 5,
          "exit %d\n%s" % (code, out))
    check("account-wide report warns about the official client",
          "official client" in out, out)


# --------------------------------------------------------------- quiet guilds

def test_quiet_guilds_return_a_retry_code():
    arm_a, arm_b = build([30.0, 60.0], b_decisive=0)
    code, out = run_verdict(arm_a, arm_b)
    check("quiet guilds return a retry code", code == 2, "exit %d" % code)
    check("quiet report suggests a longer run", "probe-patient" in out, out)
    check("quiet report admits the rate underestimates",
          "underestimates a busy hour" in out, out)


def test_no_guilds_still_gives_a_budget_answer():
    """An account in no guilds has no firehose to miss, so a budget pass there
    is solid rather than provisional."""
    arm_a, arm_b = build([], b_decisive=0, a_guilds=0, b_guilds=0)
    arm_b.unsub_at = None
    code, out = run_verdict(arm_a, arm_b)
    check("no guilds and no op 37 is INCONCLUSIVE", code == 1, "exit %d" % code)
    check("no-guilds report explains there is nothing to test",
          "nothing to test" in out or "no servers" in out, out)


def test_no_guilds_with_op37_sent_passes_on_budget():
    arm_a, arm_b = build([], b_decisive=0, a_guilds=0, b_guilds=0)
    code, out = run_verdict(arm_a, arm_b)
    check("an account with no guilds is not held to a retry", code == 0,
          "exit %d\n%s" % (code, out))


def test_passive_and_presence_do_not_cause_a_failure():
    arm_a, arm_b = build([20.0 + 2.0 * i for i in range(30)], b_decisive=0,
                         b_passive=55, b_presence=40)
    code, out = run_verdict(arm_a, arm_b)
    check("passive and presence events still allow a pass", code == 0,
          "exit %d\n%s" % (code, out))
    check("their cost is disclosed", "by design" in out, out)


# --------------------------------------------------------------- failure paths

def test_arm_error_is_inconclusive():
    arm_a, arm_b = build([20.0 + 2.0 * i for i in range(30)], b_decisive=0)
    arm_a.error = "close 4004: authentication failed"
    code, out = run_verdict(arm_a, arm_b)
    check("an arm error is INCONCLUSIVE", code == 1, "exit %d" % code)
    check("the error text is surfaced", "4004" in out, out)


def test_missing_op37_is_inconclusive():
    arm_a, arm_b = build([20.0 + 2.0 * i for i in range(30)], b_decisive=0)
    arm_b.unsub_at = None
    code, out = run_verdict(arm_a, arm_b)
    check("never sending op 37 is INCONCLUSIVE", code == 1, "exit %d" % code)


def test_no_ready_is_inconclusive():
    arm_a, arm_b = build([20.0], b_decisive=0)
    arm_b.window_start = None
    code, out = run_verdict(arm_a, arm_b)
    check("an arm without READY is INCONCLUSIVE", code == 1, "exit %d" % code)


# ------------------------------------------------------------- classification

def test_presence_is_not_decisive():
    check("PRESENCE_UPDATE is excluded from DECISIVE",
          "PRESENCE_UPDATE" not in gwprobe.DECISIVE,
          "presence always arrives for friends and open DMs")
    check("PRESENCE_UPDATE is tracked separately",
          "PRESENCE_UPDATE" in gwprobe.PRESENCE)


def test_passive_events_are_not_decisive():
    for name in ("PASSIVE_UPDATE_V2", "CHANNEL_UNREADS_UPDATE"):
        check("%s is excluded from DECISIVE" % name,
              name not in gwprobe.DECISIVE and name in gwprobe.PASSIVE)


def test_messages_and_typing_are_decisive():
    for name in ("MESSAGE_CREATE", "MESSAGE_UPDATE", "MESSAGE_DELETE", "TYPING_START"):
        check("%s decides the verdict" % name, name in gwprobe.DECISIVE)


# ------------------------------------------------------------------ accounting

def test_rate_comes_from_frame_bytes_not_a_ciphertext_delta():
    """The rate basis was changed after the first real run.

    Wire.bytes_in grows in recv() chunks of up to 64KB, so the read that
    completes READY can already hold READY_SUPPLEMENTAL's bytes. A baseline
    taken at READY then overlapped the one-time payload we also subtracted,
    the steady figure went negative, clamped to zero, and the printed rate was
    nothing but the overhead term. Frame counting cannot drift that way.
    """
    arm = make_arm("A")
    arm.window_start = time.monotonic() - 120.0
    arm.window_end = time.monotonic()
    # A ciphertext delta that overlaps READY must not influence the rate.
    arm.base_in = arm.base_out = 0
    arm.end_in, arm.end_out = 900_000, 5_000
    arm.window_frame_bytes = 5_000
    arm.window_frames = 50
    rate = arm.per_hour
    expected = (5_000 + 50 * (gwprobe.TLS_RECORD_OVERHEAD
                              + gwprobe.TCP_IP_OVERHEAD)) / 120.0 * 3600.0
    check("the rate is built from measured frame bytes",
          abs(rate - expected) < expected * 0.01,
          "got %s expected %s" % (gwprobe.human(rate), gwprobe.human(expected)))
    check("a huge ciphertext delta does not inflate the rate",
          rate < 400_000, gwprobe.human(rate))
    check("the ciphertext delta is still reported as a cross-check",
          arm.ciphertext_delta == 905_000, str(arm.ciphertext_delta))


def test_onetime_events_stay_out_of_the_window():
    arm = make_arm("A")
    arm.window_start = time.monotonic() - 60.0
    for name in ("READY", "READY_SUPPLEMENTAL", "HELLO", "GUILD_CREATE"):
        arm._record(name, 100_000, 100_000)
    check("one-time events add nothing to the rate basis",
          arm.window_frame_bytes == 0 and arm.window_frames == 0,
          "bytes=%d frames=%d" % (arm.window_frame_bytes, arm.window_frames))
    arm._record("MESSAGE_CREATE", 500, 1_200, "guild")
    check("ordinary events do count toward the rate basis",
          arm.window_frame_bytes == 500 and arm.window_frames == 1)


def test_connect_cost_is_reported_separately():
    arm = make_arm("A")
    arm.handshake_bytes = 5_400
    arm.ready_wire = 126_300
    check("connect cost sums handshake and READY",
          arm.connect_cost == 131_700, str(arm.connect_cost))


def test_decisive_since_window():
    arm = make_arm("A")
    t0 = 1000.0
    arm.decisive_times = [t0 + 1, t0 + 2, t0 + 10, t0 + 20]
    check("decisive_since counts only from the cutoff",
          arm.decisive_since(t0 + 5) == 2,
          str(arm.decisive_since(t0 + 5)))
    check("decisive_since with no cutoff counts nothing",
          arm.decisive_since(None) == 0)


# ------------------------------------------------------------- scope evidence

def test_concurrent_presence_proves_per_session():
    """The strongest scope evidence needs no before/after reasoning.

    On the first real run arm B unsubscribed 2 seconds in, so there was no
    "before" span for the rate comparison and the scope check stayed silent.
    But arm A took 26 guild presence events to arm B's 0 over the same window,
    which settles it.
    """
    arm_a, arm_b = build([20.0 + 2.0 * i for i in range(30)], b_decisive=28,
                         a_presence=26, b_presence=0, unsub_offset=2.0)
    scope = gwprobe.scope_analysis(arm_a, arm_b)
    check("concurrent presence split proves per-session scope",
          scope["concurrent"] == "per-session", repr(scope))
    buf = io.StringIO()
    with redirect_stdout(buf):
        gwprobe.report_scope(scope)
    out = buf.getvalue()
    check("the scope report prints even without a before/after span",
          "PER-SESSION" in out, out or "(nothing printed)")
    check("the scope report reassures about the official client",
          "official client" in out, out)


def test_presence_unaffected_means_op37_did_nothing():
    arm_a, arm_b = build([20.0 + 2.0 * i for i in range(30)], b_decisive=28,
                         a_presence=26, b_presence=25)
    scope = gwprobe.scope_analysis(arm_a, arm_b)
    check("matching presence in both arms is flagged as no effect",
          scope["concurrent"] == "no effect on presence", repr(scope))


def test_no_presence_leaves_scope_unknown():
    arm_a, arm_b = build([20.0 + 2.0 * i for i in range(30)], b_decisive=0)
    scope = gwprobe.scope_analysis(arm_a, arm_b)
    check("without presence data the scope claim is withheld",
          scope["concurrent"] is None, repr(scope))



def main():
    print("the regression: arms must share a window")
    test_events_before_unsubscribe_do_not_count()
    test_shared_window_events_give_a_clear_answer()
    print("the real-run shape: messages survive, budget still fits")
    test_messages_survive_but_budget_fits()
    test_rate_over_budget_is_a_fail()
    test_rate_near_budget_is_tight()
    test_cold_start_cost_is_reported()
    test_zero_dms_is_disclosed()
    print("account-wide op 37")
    test_account_wide_is_not_reported_as_quiet()
    print("quiet guilds")
    test_quiet_guilds_return_a_retry_code()
    test_no_guilds_still_gives_a_budget_answer()
    test_no_guilds_with_op37_sent_passes_on_budget()
    test_passive_and_presence_do_not_cause_a_failure()
    print("failure paths")
    test_arm_error_is_inconclusive()
    test_missing_op37_is_inconclusive()
    test_no_ready_is_inconclusive()
    print("event classification")
    test_presence_is_not_decisive()
    test_passive_events_are_not_decisive()
    test_messages_and_typing_are_decisive()
    print("scope evidence")
    test_concurrent_presence_proves_per_session()
    test_presence_unaffected_means_op37_did_nothing()
    test_no_presence_leaves_scope_unknown()
    print("accounting")
    test_rate_comes_from_frame_bytes_not_a_ciphertext_delta()
    test_onetime_events_stay_out_of_the_window()
    test_connect_cost_is_reported_separately()
    test_decisive_since_window()

    print("\n%d passed, %d failed" % (len(PASS), len(FAIL)))
    if FAIL:
        print("failed: " + ", ".join(FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
