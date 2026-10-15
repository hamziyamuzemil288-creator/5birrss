#!/usr/bin/env python3
"""Fault-inject the new notification checks to prove they are not vacuous.

A check that passes on broken input is worse than no check: it is reported as
a safety net while providing none. Every mutation below reintroduces a real bug
of the kind this work is meant to prevent, runs the harness, and requires it to
go RED. Everything is restored afterwards, and the restore is verified.

Run: python3 tools/harness/fault_inject_notifications.py
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
HARNESS = ROOT / "tools/harness/static_checks.py"
MIGRATIONS = ROOT / "supabase/migrations"

# (label, file, find, replace, must_go_red)
MUTATIONS = [
    (
        "provider stops being notified when an order payment is verified",
        # __LAST__: 20260927000133 restates fn_notify_order_status_change, so a
        # mutation written into the 0088 copy changed nothing the harness reads
        # and this case reported MISS while proving nothing. Resolved through
        # the winning definition, like every other body mutation here.
        "__LAST__:fn_notify_order_status_change",
        "    PERFORM public.notify_user_once(\n"
        "      'order-payment-received:' || NEW.id::text,",
        "    PERFORM public.notify_user_once(\n"
        "      'order-payment-received-DISABLED:' || NEW.id::text,",
    ),
    (
        "driver stops being notified when a ride completes",
        "20260927000088_order_and_ride_receipts.sql",
        "    PERFORM public.notify_user_once(\n"
        "      'ride-completed-driver:' || NEW.id::text,",
        "    PERFORM public.notify_user_once(\n"
        "      'ride-completed-driver-DISABLED:' || NEW.id::text,",
    ),
    (
        "a message claims money was added to the driver's wallet",
        "20260927000088_order_and_ride_receipts.sql",
        "|| ', and the platform fee for this trip has been deducted from your wallet.'",
        "|| '. ETB ' || v_fare || ' added to your wallet.'",
    ),
    (
        "the no-status-change guard is dropped from the ride trigger",
        "20260927000088_order_and_ride_receipts.sql",
        "  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN\n"
        "    RETURN NEW;\n"
        "  END IF;\n\n"
        "  v_ref := jsonb_build_object('ride_id', NEW.id, 'status', NEW.status);",
        "  v_ref := jsonb_build_object('ride_id', NEW.id, 'status', NEW.status);",
    ),
    (
        "the dedupe check is dropped from notify_user_once (no idempotency)",
        "__LAST__:notify_user_once",
        "  IF EXISTS (\n"
        "    SELECT 1 FROM public.notifications\n"
        "     WHERE (data ->> 'idem_key') = p_idem_key\n"
        "  ) OR EXISTS (\n"
        "    SELECT 1 FROM public.notification_outbox\n"
        "     WHERE (data ->> 'idem_key') = p_idem_key\n"
        "  ) THEN\n"
        "    RETURN NULL;  -- already written by an earlier call\n"
        "  END IF;",
        "  -- dedupe check removed entirely",
    ),
    (
        "notify_user_once dedupes without taking a lock (concurrency race)",
        "__LAST__:notify_user_once",
        "  PERFORM pg_advisory_xact_lock(hashtext('notify:' || p_idem_key));",
        "  -- lock removed",
    ),
    (
        "notify_user_once can no longer be called by a client role",
        "__LAST__:notify_user_once",
        "REVOKE ALL ON FUNCTION public.notify_user_once(text, uuid, public.notification_type, text, text, jsonb)\n"
        "  FROM public, anon, authenticated;",
        "-- revoke removed",
    ),
    (
        "a notification failure is no longer swallowed (rolls back the payment)",
        "__LAST__:notify_user_once",
        "    RAISE WARNING 'notify_user_once(%) failed and was swallowed: %',\n"
        "      p_idem_key, SQLERRM;\n"
        "    RETURN NULL;",
        "    RETURN NULL;  -- failure no longer logged",
    ),
    (
        "the points conversion stops notifying",
        "20260927000089_points_conversion_notice.sql",
        "  PERFORM public.notify_user_once(\n"
        "    'points-convert:' || v_ledger_id::text,",
        "  PERFORM public.notify_user_once(\n"
        "    'points-convert-DISABLED:' || v_ledger_id::text,",
    ),
    (
        "the conversion message stops quoting the birr received",
        "20260927000089_points_conversion_notice.sql",
        "    'You converted ' || p_points::text || ' points to ETB ' || v_birr::text\n"
        "      || '. Your wallet balance is ETB ' || v_wallet.balance::text || '.',",
        "    'You converted ' || p_points::text || ' points.',",
    ),
    (
        "the conversion message stops quoting the points spent",
        "20260927000089_points_conversion_notice.sql",
        "    'You converted ' || p_points::text || ' points to ETB '",
        "    'Your points are now in your wallet at ETB '",
    ),
    (
        "the points conversion loses its advisory lock",
        "20260927000089_points_conversion_notice.sql",
        "  PERFORM pg_advisory_xact_lock(hashtext('points-conversion:' || v_user_id::text));",
        "  -- lock removed",
    ),
    (
        "the welcome stops being sent on provider approval",
        # __LAST__: 20260927000111 restates approve_provider, so the mutation
        # written into the 0087 copy changed nothing the harness reads and this
        # case reported MISS while proving nothing.
        "__LAST__:approve_provider",
        "  PERFORM public.notify_user_once(\n"
        "    'provider-approved:' || p_provider_id::text,",
        "  PERFORM public.notify_user_once(\n"
        "    'provider-approved-DISABLED:' || p_provider_id::text,",
    ),
    (
        "the welcome stops being sent on user approval",
        "20260927000087_welcome_on_approval.sql",
        "  PERFORM public.notify_user_once(\n"
        "    'user-approved:' || p_user_id::text,",
        "  PERFORM public.notify_user_once(\n"
        "    'user-approved-DISABLED:' || p_user_id::text,",
    ),
    (
        "approve_provider loses its staff-scope check (the historical regression)",
        "20260927000087_welcome_on_approval.sql",
        "       OR NOT public.staff_scope_allows_category(\n"
        "            (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id)) THEN",
        "       THEN",
    ),
    (
        "the notifications screen is deleted (nothing can read the messages)",
        None, None, None,
    ),
    (
        "an assertion is revoked from anon with no anon grant (the CI failure)",
        "__LAST__:assert_points_conversion_notifies",
        "GRANT EXECUTE ON FUNCTION public.assert_points_conversion_notifies()\n"
        "  TO anon, authenticated, service_role;",
        "REVOKE ALL ON FUNCTION public.assert_points_conversion_notifies()\n"
        "  FROM anon;",
    ),
    (
        "an assertion drops anon from its grant (PGRST202 in CI)",
        "__LAST__:assert_order_and_ride_receipts_are_sent",
        "GRANT EXECUTE ON FUNCTION public.assert_order_and_ride_receipts_are_sent()\n"
        "  TO anon, authenticated, service_role;",
        "GRANT EXECUTE ON FUNCTION public.assert_order_and_ride_receipts_are_sent()\n"
        "  TO authenticated, service_role;",
    ),
    (
        "the dedupe checks only notifications, not the client-path outbox",
        "20260927000092_dedupe_the_queue_and_fix_two_assertions.sql",
        "  ) OR EXISTS (\n"
        "    SELECT 1 FROM public.notification_outbox\n"
        "     WHERE (data ->> 'idem_key') = p_idem_key\n"
        "  ) THEN",
        "  ) THEN",
    ),
    (
        "the points assertion goes back to a whitespace-sensitive match",
        "20260927000092_dedupe_the_queue_and_fix_two_assertions.sql",
        "  IF position('points-convert:''||v_ledgerid' IN v_flat) = 0 THEN",
        "  IF position('points-convert:''||v_ledgerid' IN v_src) = 0 THEN",
    ),
    (
        "a declared source needle has a typo (v_ledgerid, the bug that shipped)",
        "__LAST__:assert_source_needles_match",
        "'points-convert:''||v_ledger_id',",
        "'points-convert:''||v_ledgerid',",
    ),
    (
        "a declared needle names a function that does not exist",
        "__LAST__:assert_source_needles_match",
        "    'fn_notify_ride_status_change',\n"
        "    'fn_notify_ride_status_change',\n",
        "    'fn_notify_ride_status_change',\n"
        "    'fn_notify_ride_status_typo',\n",
    ),
    (
        "the needle and target lists drift out of step",
        "__LAST__:assert_source_needles_match",
        "    'pg_advisory_xact_lock'\n  ];",
        "    'pg_advisory_xact_lock',\n    'extra_needle'\n  ];",
    ),
    (
        "a plpgsql FOREACH iterates with an array-typed loop variable",
        "20260927000095_needles_match_iterates_with_unnest.sql",
        "  FOR v_needle, v_target_fn IN\n"
        "    SELECT * FROM unnest(v_needles, v_targets)\n"
        "  LOOP",
        "  FOREACH v_targets IN ARRAY v_needles LOOP",
    ),
    (
        "no screen links to the notifications route (all entry points removed)",
        "__ALL_SCREEN_ENTRIES__",
        "'/admin-notifications'",
        "'/user/search'",
    ),
]


def run_harness() -> tuple[int, str]:
    proc = subprocess.run(
        [sys.executable, str(HARNESS)],
        capture_output=True, text=True, cwd=str(ROOT))
    return proc.returncode, proc.stdout + proc.stderr


def main() -> int:
    print("fault injection: every mutation must turn the harness RED\n")
    baseline_code, baseline_out = run_harness()
    if baseline_code != 0:
        print("baseline is already failing; fix that first:")
        print(baseline_out)
        return 2
    print("[ok] baseline green\n")

    saved: dict[pathlib.Path, str] = {}
    failures = 0

    for label, filename, find, replace in MUTATIONS:
        if filename == "__ALL_SCREEN_ENTRIES__":
            # Remove the entry point from every screen that has one, so the
            # check is exercised against "no screen links to the route" rather
            # than against one screen that happens to have two links.
            touched: list[tuple[pathlib.Path, str]] = []
            for dart in sorted((ROOT / "lib").rglob("*.dart")):
                if dart.name == "app_router.dart":
                    continue
                text = dart.read_text(encoding="utf-8")
                if find in text:
                    # Keep the original text with the file, and restore from
                    # that pair. An earlier version pushed Path -> text into
                    # the shared `saved` map and then called .write_text() on
                    # the str, which crashed mid-run and LEFT the mutation in
                    # the working tree. Restore must not be able to do that.
                    touched.append((dart, text))
                    dart.write_text(
                        text.replace(find, replace), encoding="utf-8")
            if not touched:
                print(f"[FAIL] {label}\n         no screen contains {find}")
                failures += 1
                continue
            try:
                code, _ = run_harness()
            finally:
                for dart, text in touched:
                    dart.write_text(text, encoding="utf-8")
                    if dart.read_text(encoding="utf-8") != text:
                        print(f"[FAIL] {label}: could not restore {dart.name}")
                        failures += 1
            red = code != 0
            print(f"[{'ok' if red else 'MISS'}] {label} "
                  f"({len(touched)} screens)"
                  f"{'' if red else '  <-- harness stayed GREEN'}")
            if not red:
                failures += 1
            continue

        if filename is None:
            target = ROOT / "lib/features/user/user_notifications_screen.dart"
        elif filename.startswith("__LAST__:"):
            # Resolve the migration that CURRENTLY defines this function.
            #
            # Hardcoding a filename rot silently: when a later migration
            # restates a function, mutating the older file changes nothing and
            # the mutation is reported as MISS even though the check is fine.
            # Five mutations went stale that way the moment 92 landed, which
            # reads as "the harness stopped working" rather than "these
            # mutations point at superseded text".
            import importlib.util
            spec = importlib.util.spec_from_file_location(
                "static_checks_mod", HARNESS)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            defined_at, _ = mod.last_migration_defining(filename.split(":", 1)[1])
            if defined_at is None:
                print(f"[FAIL] {label}\n         function "
                      f"{filename.split(':', 1)[1]} is defined nowhere")
                failures += 1
                continue
            target = defined_at
        elif filename.startswith("2026"):
            target = MIGRATIONS / filename
        else:
            target = ROOT / filename
        if not target.exists():
            print(f"[FAIL] {label}\n         target missing: {target}")
            failures += 1
            continue

        original = target.read_text(encoding="utf-8")
        if original not in saved:
            saved[target] = original

        if find is None:
            # Deletion: move the file aside entirely.
            backup = target.with_suffix(target.suffix + ".bak")
            target.rename(backup)
            try:
                code, _ = run_harness()
            finally:
                backup.rename(target)
            red = code != 0
            print(f"[{'ok' if red else 'MISS'}] {label}"
                  f"{'' if red else '  <-- harness stayed GREEN'}")
            if not red:
                failures += 1
            continue

        if find not in original:
            print(f"[FAIL] {label}\n         pattern not found in {target.name}")
            failures += 1
            continue

        target.write_text(original.replace(find, replace, 1), encoding="utf-8")
        try:
            code, out = run_harness()
        finally:
            target.write_text(saved[target], encoding="utf-8")

        red = code != 0
        detail = ""
        if red:
            for line in out.splitlines():
                if "money/approval notifications" in line:
                    detail = line.strip()
                    break
        print(f"[{'ok' if red else 'MISS'}] {label}"
              f"{'' if red else '  <-- harness stayed GREEN'}")
        if not red:
            failures += 1
        elif detail:
            print(f"         caught by: {detail}")

    # Confirm everything is back.
    final_code, final_out = run_harness()
    if final_code != 0:
        print("\nbaseline did not return to green after restoring:")
        print(final_out)
        return 1
    print("\n[ok] baseline restored and green")
    print(f"\n{len(MUTATIONS) - failures}/{len(MUTATIONS)} mutations caught")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
