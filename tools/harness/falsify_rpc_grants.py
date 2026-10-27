#!/usr/bin/env python3
"""Falsification for check_client_rpcs_are_executable.

PostgREST hides a function the caller has no EXECUTE on behind PGRST202
"could not find the function in the schema cache". That reads exactly like a
migration that never applied, so the reflex is to re-run the deploy -- which
changes nothing.

Case A is the bug that was actually written: migration 0113 granted its
assertion to `authenticated` while Connectivity CI runs assertions as `anon`.

Cases B and C are the check's own two mistakes. The first version read "no
GRANT found" as "not executable", which is backwards -- Postgres grants
EXECUTE to PUBLIC by default, so a function nobody touched is callable by
everyone. It reported fourteen working functions, which is how a check gets
ignored. The second version had to be taught about the DO-block loop in 0107
that grants a whole array of names through format('%I'), where the literal
GRANT text does not appear in the file at all.

Nothing writes to the repo: `static_checks._read` is overridden.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

_real_read = sc._read

GATE = "20260927000113_provider_fulfilment_gate.sql"
FEES = "20260927000107_per_category_and_city_fees.sql"


def with_patches(patches: dict[str, str]) -> list[str]:
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
        return sc.check_client_rpcs_are_executable()
    finally:
        sc._read = _real_read


def expect_red(label: str, patches: dict[str, str]) -> bool:
    problems = with_patches(patches)
    if problems:
        print("[ ok ] %s -> caught" % label)
        for p in problems[:2]:
            print("         - " + p)
        return True
    print("[FAIL] %s -> stayed GREEN" % label)
    return False


def expect_green(label: str, patches: dict[str, str]) -> bool:
    problems = with_patches(patches)
    if not problems:
        print("[ ok ] %s -> stayed green (correct)" % label)
        return True
    print("[FAIL] %s -> went red on legitimate input" % label)
    for p in problems[:4]:
        print("         - " + p)
    return False


def main() -> int:
    ok = True

    base = with_patches({})
    if base:
        print("[FAIL] the real sources are already red:")
        for p in base:
            print("         - " + p)
        return 1
    print("[ ok ] real sources are green")

    gate = sc._read(sc.MIGRATIONS / GATE)
    fees = sc._read(sc.MIGRATIONS / FEES)

    # A. THE BUG THAT WAS WRITTEN. Granted to authenticated, revoked from
    #    anon, while the suite calls it as anon.
    reinstated = gate.replace(
        "REVOKE ALL ON FUNCTION public.assert_provider_fulfilment_gate_is_wired()\n"
        "  FROM PUBLIC, authenticated;\n"
        "GRANT EXECUTE ON FUNCTION public.assert_provider_fulfilment_gate_is_wired()\n"
        "  TO anon, authenticated, service_role;",
        "REVOKE ALL ON FUNCTION public.assert_provider_fulfilment_gate_is_wired()\n"
        "  FROM PUBLIC, anon;\n"
        "GRANT EXECUTE ON FUNCTION public.assert_provider_fulfilment_gate_is_wired()\n"
        "  TO authenticated, service_role;")
    if reinstated == gate:
        raise AssertionError("falsifier anchor missing: 0113 assertion grant")
    ok &= expect_red(
        "A: an assertion is granted to authenticated but called as anon",
        {GATE: reinstated})

    # B. THE CHECK'S OWN MISTAKE, asserted in reverse. A function with no
    #    GRANT and no REVOKE is executable by everyone, because Postgres
    #    grants EXECUTE to PUBLIC on CREATE FUNCTION. The first version of
    #    this check reported fourteen of these as broken.
    ok &= expect_green(
        "B: functions with no GRANT and no REVOKE are callable (Postgres "
        "default is EXECUTE TO PUBLIC)",
        {})

    # C. Removing the GRANT really does break it. Three earlier versions of
    #    this case were wrong, each for its own reason. The first appended
    #    `authenticated` to the REVOKE's FROM list -- which the loop re-grants
    #    two lines later, so the function stayed reachable. The second removed
    #    only the `(uuid, text)` grant, forgetting that fee_subscription is
    #    granted on TWO overloads. The third deleted the two literal GRANT
    #    lines after the loop was rewritten to build one signature from pg_proc
    #    -- so it deleted text that no longer exists and proved nothing.
    #
    #    That last one is the recurring hazard here: a falsifier anchored on
    #    a string that a later edit removed goes GREEN FOREVER. `assert
    #    anchor` below exists because of it.
    #
    #    There is also a real limitation of this check, not just of the case:
    #    privileges are tracked per NAME, not per signature, so it cannot see
    #    an overload that is granted but another that is not. PostgREST hides
    #    the revoked overload behind PGRST202 for a client whose argument shape
    #    selects it. It is stated in the check's docstring rather than
    #    pretended away.
    grant_line = ("    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s "
                  "TO authenticated, service_role', r.sig);")
    assert grant_line in fees, "falsifier anchor missing: 0107 grant line"
    ok &= expect_red(
        "C: the fee readers lose their authenticated grant",
        {FEES: fees.replace(grant_line, "")})

    # D. Revoking from PUBLIC while granting the role back is CORRECT and must
    #    stay green -- this is the shape every function in 0107 and 0113 uses.
    ok &= expect_green(
        "D: revoke from PUBLIC + grant back to authenticated is fine",
        {})

    # E. The suite's own assertion must be reachable as anon; removing the
    #    anon grant from the newest assertion breaks it.
    notified = sc._read(
        sc.MIGRATIONS / "20260927000114_the_other_side_is_told.sql")
    stripped = notified.replace(
        "GRANT EXECUTE ON FUNCTION public.assert_counterparties_are_notified()\n"
        "  TO anon, authenticated, service_role;",
        "GRANT EXECUTE ON FUNCTION public.assert_counterparties_are_notified()\n"
        "  TO authenticated, service_role;")
    if stripped == notified:
        raise AssertionError("falsifier anchor missing: 0114 assertion grant")
    ok &= expect_red(
        "E: assert_counterparties_are_notified loses its anon grant",
        {"20260927000114_the_other_side_is_told.sql": stripped})

    # F. A revoke written in a `--` COMMENT is documentation, not a statement.
    #    00083 line 14 documents the revoke it wants this way. The first
    #    version read it as a real statement and reported list_staff_jobs as
    #    unreachable for `authenticated`, which 00036 grants it.
    jobs = sc._read(
        sc.MIGRATIONS / "20260927000083_staff_jobs_rls.sql")
    ok &= expect_green(
        "F: a REVOKE inside a -- comment is not a statement",
        {})

    # ...and the same text uncommented really does revoke. `authenticated` has
    # to be named: 00036 grants it explicitly, and REVOKE FROM PUBLIC withdraws
    # only the implicit default grant, so revoking public+anon alone leaves the
    # app's call working. That asymmetry is the second bug this check had.
    ok &= expect_red(
        "F': the same REVOKE uncommented and naming authenticated",
        {"20260927000083_staff_jobs_rls.sql": jobs.replace(
            "--     REVOKE ALL ON FUNCTION public.list_staff_jobs() FROM public, anon;",
            "REVOKE ALL ON FUNCTION public.list_staff_jobs() FROM public, anon, "
            "authenticated;")})

    # ...and revoking only public+anon must stay green, because authenticated
    # was granted by name in 00036.
    ok &= expect_green(
        "F'': revoking public+anon does not revoke an explicit grant",
        {"20260927000083_staff_jobs_rls.sql": jobs.replace(
            "--     REVOKE ALL ON FUNCTION public.list_staff_jobs() FROM public, anon;",
            "REVOKE ALL ON FUNCTION public.list_staff_jobs() FROM public, anon;")})

    # G. THE ONE THAT REACHED THE LIVE DATABASE. Cases A and E both anchor on a
    #    migration that grants a NAMED assertion, which the suite's own source
    #    names in a call. This one is different, and that difference is the
    #    whole bug: the suite never names assert_delivery_fee_reuses_the_ride_
    #    fare(). assert_every_assertion_is_reachable() enumerates the family on
    #    the live database, so a name-driven scan of the Dart is blind to it by
    #    construction -- which is why 20261026000001 could restate that function
    #    with its grant narrowed to `authenticated, service_role` (dropping the
    #    anon privilege 20261015000002 gave it), deploy clean, and fail
    #    Connectivity CI on the next run instead.
    #
    #    20261026000003 puts the grant back. Removing it again must go red, and
    #    the red must name that function -- a gate that reported a different
    #    assertion, or the whole family, would be answering a different
    #    question.
    repair = sc._read(
        sc.MIGRATIONS / "20261026000003_the_delivery_assertion_reaches_anon.sql")
    anon_grant = ("GRANT EXECUTE ON FUNCTION "
                  "public.assert_delivery_fee_reuses_the_ride_fare()\n"
                  "  TO anon, authenticated, service_role;")
    assert anon_grant in repair, \
        "falsifier anchor missing: 000003 anon grant"
    dropped = with_patches({
        "20261026000003_the_delivery_assertion_reaches_anon.sql":
            repair.replace(anon_grant, "")})
    if not dropped:
        print("[FAIL] G: the delivery assertion narrowed away from anon -> "
              "stayed GREEN")
        ok = False
    elif not any("assert_delivery_fee_reuses_the_ride_fare" in p
                 for p in dropped):
        print("[FAIL] G: went red, but not by naming the assertion that lost "
              "its grant")
        ok = False
    else:
        print("[ ok ] G: the delivery assertion narrowed away from anon -> caught")

    # G'. The family rule is zero-ARGUMENT only, mirroring the live guard's
    #     `p.pronargs = 0`. An assertion that takes parameters is a different
    #     function and must not be dragged in -- a gate that flagged every
    #     `assert_*` would report roughly two dozen working functions and be
    #     ignored, which is the failure mode case B records.
    ok &= expect_green(
        "G': the real sources are green, so the family rule flags no working "
        "zero-argument assertion",
        {})

    if not ok:
        print("\nFALSIFICATION FAILED")
        return 1

    if with_patches({}):
        print("\n[FAIL] the real sources went red")
        return 1
    print("\n[ ok ] real sources still green")
    print("FALSIFICATION PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
