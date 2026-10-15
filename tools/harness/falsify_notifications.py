#!/usr/bin/env python3
"""Falsification for the two notification checks.

Case A is the important one, because it is a bug that was actually written,
committed and would have shipped: migration 0107 called
`insert_notification(..., 'RIDE_REQUESTED', ...)`, and `RIDE_REQUESTED` is not
a member of the `notification_type` enum. `insert_notification`'s second
parameter is typed as that enum, so the cast raised at RUN time and took the
whole ride request down with it.

It survived every check that existed. `pglast` parses an enum literal as an
ordinary string and validates nothing about it. The plpgsql gate only checks
that embedded statements parse. The existing notification assertions compared
against hand-typed needle lists. None of them asked whether a *value* exists.

Cases G and H are weaknesses in the new checks themselves, found by
falsifying them rather than by reading them.

Nothing writes to the repo: `static_checks._read` is overridden.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

_real_read = sc._read

FEES = "20260927000107_per_category_and_city_fees.sql"
TOLD = "20260927000114_the_other_side_is_told.sql"


def with_patches(patches: dict[str, str], fn):
    def _read(path: Path) -> str:
        try:
            rel = str(path).replace("\\", "/")
        except Exception:
            rel = ""
        for suffix, text in patches.items():
            if rel.endswith(suffix):
                return text
        return _real_read(path)

    sc._read = _read
    try:
        return fn()
    finally:
        sc._read = _real_read


def expect_red(label: str, patches: dict[str, str], fn) -> bool:
    problems = with_patches(patches, fn)
    if problems:
        print("[ ok ] %s -> caught" % label)
        for p in problems:
            print("         - " + p)
        return True
    print("[FAIL] %s -> stayed GREEN" % label)
    return False


def main() -> int:
    ok = True
    enum_check = sc.check_notification_types_exist
    told_check = sc.check_provider_is_told_about_work

    for name, fn in (("enum", enum_check), ("counterparty", told_check)):
        base = with_patches({}, fn)
        if base:
            print("[FAIL] the real sources are already red (%s):" % name)
            for p in base:
                print("         - " + p)
            return 1
    print("[ ok ] real sources are green")

    fees = sc._read(sc.MIGRATIONS / FEES)
    told = sc._read(sc.MIGRATIONS / TOLD)

    # A. THE BUG THAT WAS WRITTEN. A notification type that does not exist in
    #    the enum, which raises at run time and takes the ride request with it.
    ok &= expect_red(
        "A: a notification type that is not in the enum is written",
        {FEES: fees.replace("'RIDE_REQUEST', 'Ride requested'",
                            "'RIDE_REQUESTED', 'Ride requested'")},
        enum_check)

    # B. a new order stops reaching the provider.
    #    Patched through authoritative_patch, not the 0114 file: 0115 restates
    #    create_order_secure, so mutating the older copy changed nothing the
    #    check reads and this case went green while proving nothing.
    ok &= expect_red(
        "B: create_order_secure no longer tells the provider",
        sc.authoritative_patch(
            "create_order_secure", "    'ORDER_RECEIVED',", "    'APPROVAL',"),
        told_check)

    # C. a new ride stops reaching drivers -- the fan-out is emptied rather
    #    than the call removed, so the call site still looks correct.
    ok &= expect_red(
        "C: the driver fan-out is emptied but still called",
        {TOLD: told.replace(
            "    SELECT d.provider_id\n"
            "      FROM public.find_nearby_drivers(",
            "    SELECT d.provider_id\n"
            "      FROM public.find_nearby_drivers_disabled(")},
        told_check)

    # D. a claimed ride stops reaching the rider. Patched through
    #    authoritative_patch for the same reason as B: 20261006000005 restates
    #    claim_ride, so mutating the 0114 copy changed nothing the check reads
    #    -- the check reads the LAST definition, and this case went green while
    #    proving nothing until the patch was pointed at the winning file.
    ok &= expect_red(
        "D: claim_ride no longer tells the rider",
        sc.authoritative_patch("claim_ride", "'RIDE_CLAIMED',", "'RIDE_REQUEST',"),
        told_check)

    # E. a type is spelled correctly in the enum but misspelled at the call
    #    site, which is the shape A had and the shape a human makes when
    #    adding a notification by hand.
    ok &= expect_red(
        "E: a type is misspelled at one call site only",
        {TOLD: told.replace("'ORDER_RECEIVED',\n    'New order '",
                            "'ORDER_RECIEVED',\n    'New order '")},
        enum_check)

    # F. The type is the THIRD argument of notify_user_once, not the second.
    #    A positional bug here would read the idempotency key as the type and
    #    either miss a bad value or invent one.
    ok &= expect_red(
        "F: a bad type in notify_user_once (third-argument position)",
        {TOLD: told.replace(
            "  RETURN public.insert_notification(p_user_id, p_type, p_title, "
            "p_body, p_data);",
            "  RETURN public.insert_notification(p_user_id, 'NOPE', p_title, "
            "p_body, p_data);")},
        enum_check)

    # G. The first argument is routinely a parenthesised subquery, and a naive
    #    comma split would read whatever is inside it as the type. Both of
    #    these must be seen as CLEAN, which is the assertion.
    subquery_shaped = told.replace(
        "    (select pp.user_id from provider_profiles pp where pp.id = p_provider_id),",
        "    (select pp.user_id, 'APPROVAL' from provider_profiles pp "
        "where pp.id = p_provider_id),")
    if subquery_shaped == told:
        raise AssertionError("falsifier anchor missing: subquery recipient")
    probs = with_patches({TOLD: subquery_shaped}, enum_check)
    if probs:
        ok = False
        print("[FAIL] G: a literal inside the recipient subquery was mistaken "
              "for the type")
        for p in probs:
            print("         - " + p)
    else:
        print("[ ok ] G: a literal inside the recipient subquery is not "
              "mistaken for the type")

    # H. And the repo is full of GRANT EXECUTE and document VERIFIED, neither of
    #    which is a notification type. Asserted positively: a future loosening
    #    of the matcher shows up as a failure here rather than as noise
    #    someone learns to ignore.
    quiet = with_patches({}, enum_check)
    if quiet:
        ok = False
        print("[FAIL] H: the enum check fired on the real sources:")
        for p in quiet:
            print("         - " + p)
    else:
        print("[ ok ] H: the enum check is quiet on a repo full of GRANTs")

    if not ok:
        print("\nFALSIFICATION FAILED")
        return 1

    if with_patches({}, told_check) or with_patches({}, enum_check):
        print("\n[FAIL] the real sources went red")
        return 1
    print("\n[ ok ] real sources still green")
    print("FALSIFICATION PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
