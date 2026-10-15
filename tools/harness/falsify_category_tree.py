#!/usr/bin/env python3
"""Falsification for check_category_tree_and_weekly_rank_are_wired.

A check that has never been seen red is not yet a check. Every case below
reintroduces one real defect, runs the check, and requires it to go RED by the
assertion that names that defect. Nothing is written to disk: the check reads
file contents through the single `static_checks._read` helper, so overriding
that one function runs the real check against a patched string.

The cases are the ones a substring check is worst at:

  1. the weekly window is dropped, but the ORDER BY still exists -- the rail
     still ranks, it just ranks by career totals forever
  2. the ride half of the key keeps its shape and loses its completion time,
     so a category whose trade is rides never rises
  3. the permission guard is deleted from the write path
  4. the "mother must be top level" rule is deleted, so a third level can
     appear where no screen shows it
  5. the inheritance of the mother's classification is deleted, which makes
     every new row violate a CHECK constraint at insert time
  6. the client door stops calling the RPC, so the server half is unreachable
  7. the route disappears, so the screen the dashboard pushes is a 404

Each mutation lands on the file the check reads for that assertion, because a
mutation written into a superseded copy changes nothing and reports a false
green -- the defect that three notification falsifiers were found to have.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

MIG = "20261015000011_the_category_rank_is_this_week_too.sql"
SCREEN = "lib/features/admin/admin_categories_screen.dart"
ROUTER = "lib/routing/app_router.dart"


def _drop_the_window(text: str) -> str:
    """The window is still a window — it is just no longer a week."""
    return text.replace("v_window interval := interval '7 days';",
                        "v_window interval := interval '90 days';")


def _rename_the_window(text: str) -> str:
    """The declaration is gone under the name every predicate reads.

    Deliberately a RENAME rather than a deletion: a deleted declaration leaves
    the body unable to parse, which is a different failure from the one under
    test, and a check that greps for `v_window` as a substring is satisfied by
    `v_window2` — so the new name has to share no prefix with the old one.
    """
    return text.replace("v_window", "the_week")


def _drop_the_ride_time(text: str) -> str:
    return text.replace("AND r.updated_at >= now() - v_window",
                        "AND r.claimed_at IS NOT NULL")


def _drop_the_guard(text: str) -> str:
    return re.sub(
        r"IF NOT public\.is_admin\(\) THEN\s*\n\s*RAISE EXCEPTION "
        r"'INSUFFICIENT_PERMISSION';\s*\n\s*END IF;",
        "", text, flags=re.IGNORECASE)


def _drop_the_top_level_rule(text: str) -> str:
    return re.sub(
        r"IF v_parent\.parent_id IS NOT NULL THEN\s*\n\s*RAISE EXCEPTION "
        r"'PICK_A_TOP_LEVEL_CATEGORY_AS_THE_MOTHER';\s*\n\s*END IF;",
        "", text, flags=re.IGNORECASE)


def _drop_the_inheritance(text: str) -> str:
    return text.replace("v_parent.sector, v_parent.marketplace_sector,",
                        "'SERVICE', NULL,")


def _stop_calling_the_rpc(text: str) -> str:
    return text.replace("'admin_create_category'", "'admin_create_category_typo'")


def _drop_the_route(text: str) -> str:
    return text.replace("path: '/admin/categories',", "path: '/admin/category',")


# (label, filename, mutate, the assertion that must name it)
CASES: list[tuple[str, str, object, str]] = [
    ("the weekly window is dropped and the rail ranks by career totals",
     MIG, _drop_the_window, "no longer a week"),
    ("the ranking declares its window under a name no predicate reads",
     MIG, _rename_the_window, "no weekly window"),
    ("the ride half of the weekly key loses its completion time",
     MIG, _drop_the_ride_time, "never rises"),
    ("admin_create_category loses its permission guard",
     MIG, _drop_the_guard, "refuses nobody"),
    ("a sub-category is accepted as the mother",
     MIG, _drop_the_top_level_rule, "not top level"),
    ("the new row stops inheriting its mother's classification",
     MIG, _drop_the_inheritance, "CHECK constraint"),
    ("the screen stops calling the RPC",
     SCREEN, _stop_calling_the_rpc, "no longer calls the RPC"),
    ("the route disappears from the router",
     ROUTER, _drop_the_route, "does not register /admin/categories"),
]


def with_patches(patches: dict[str, str]) -> list[str]:
    real_read = sc._read

    def _read(path: Path) -> str:
        try:
            rel = str(path).replace("\\", "/")
        except Exception:
            rel = ""
        for suffix, text in patches.items():
            if rel.endswith(suffix):
                return text
        return real_read(path)

    sc._read = _read
    try:
        return sc.check_category_tree_and_weekly_rank_are_wired()
    finally:
        sc._read = real_read


def main() -> int:
    # The patch keys are the suffixes `with_patches` matches on, so they stay
    # as written above; only the READ has to know where each one lives.
    paths = {
        MIG: sc.MIGRATIONS / MIG,
        SCREEN: sc.ROOT / SCREEN,
        ROUTER: sc.ROOT / ROUTER,
    }
    real = {name: sc._read(path) for name, path in paths.items()}
    for name, text in real.items():
        if not text.strip():
            print("[FAIL] %s is empty -- there is nothing to falsify" % name)
            return 1

    failures = 0
    for label, filename, mutate, expect in CASES:
        patched = mutate(real[filename])
        if patched == real[filename]:
            print("[FAIL] the mutation for %r changed nothing -- the needle "
                  "is stale and this case would prove nothing" % label)
            failures += 1
            continue
        problems = with_patches({filename: patched})
        if not problems:
            print("[FAIL] the check stayed GREEN when %s" % label)
            failures += 1
            continue
        if not any(expect in p for p in problems):
            print("[FAIL] %s was detected, but not by the assertion that "
                  "names %r -- the check is passing for the wrong reason"
                  % (label, expect))
            for p in problems:
                print("         - " + p)
            failures += 1
            continue
        print("[ ok ] detected: %s" % label)
        for p in problems:
            if expect in p:
                print("         - " + p)

    real_problems = with_patches({})
    if real_problems:
        print("[FAIL] the real sources are still red")
        for p in real_problems:
            print("         - " + p)
        return 1
    print("[ ok ] the real sources are green")

    if failures:
        print("\nFALSIFICATION FAILED (%d case(s))" % failures)
        return 1
    print("\nFALSIFICATION PASSED (%d red cases, each green once repaired)"
          % len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
