#!/usr/bin/env python3
"""Falsification for check_registration_notifications_are_wired.

A check that has never been seen red is not yet a check. This proves the
registration-notification check actually goes red on the exact defects it was
written for, and stays green on the real migration. Neither run edits the real
file on disk.

The defects, in the order the check is able to see them:

  1. the trigger never created            -- the original bug: approval_requests
                                            had no trigger at all
  2. the reviewer fan-out emptied         -- the recipient set is still NAMED,
                                            so a substring check would pass
  3. the reactivation notice deleted      -- the 0026 regression, restated
  4. a guard clause dropped in that same  -- the failure mode that deleted the
     restatement                            notice in the first place
  5. the enum value never written         -- a notice with no type

Every check in static_checks reads file contents through the single `_read`
helper, so overriding that one function runs the real check code against a
patched string. `last_migration_defining` and `function_body` also read through
it, so the patch reaches the "last definition" walk as well -- which is exactly
the walk that has to be honoured.

WHY EVERY DEFINING MIGRATION IS PATCHED, NOT ONE FILE:
The check reads the LAST definition in filename order, because that is the one
the live database runs. Two cases here used to patch only
`20260927000130_a_submission_tells_both_sides.sql`, whose
`on_registration_submitted()` was restated by
`20261014000000_self_service_registration_is_immediately_active.sql`. The
mutation landed nowhere, the check read the NEWER body, and both cases printed
"the check stayed GREEN" -- a harness defect that looked exactly like a real
coverage gap and proved nothing about the fan-out either way. The same trap hit
`falsify_notifications.py` case D when 20261006000005 restated `claim_ride`, and
it is silent, which is what makes it dangerous.

So each case now declares which function's AUTHORITATIVE body it must land on,
the mutation is applied to every migration that defines it, and a mutation that
changes nothing in the winning file is reported as a stale needle instead of
being allowed to pass quietly.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

MIG = sc.REGISTRATION_MIGRATION


def _drop_trigger(text: str) -> str:
    """The shipped state: the notice exists, nothing fires it.

    The CREATE TRIGGER statement is DELETED, not commented out. Commenting
    would be a no-op against the check, which strips comments before it looks
    -- `-- CREATE TRIGGER x` strips back to `CREATE TRIGGER x`, so a
    comment-based mutation tests nothing and this falsifier would have
    reported a false green.
    """
    return re.sub(
        r"CREATE\s+TRIGGER\s+trg_registration_submitted\b[\s\S]*?"
        r"EXECUTE\s+FUNCTION\s+public\.on_registration_submitted\(\)\s*;",
        "", text, flags=re.IGNORECASE)


def _empty_the_fanout(text: str) -> str:
    """The recipient set is still named; the loop that used it is gone.

    This is the case a substring check cannot see, and it is why the check
    requires the FOR as well as the call.
    """
    return re.sub(r"FOR\s+v_recipient\s+IN\s*\n\s*SELECT\s+r\.user_id\s+FROM\s+"
                  r"public\.registration_review_recipients\(\)\s*r\s*\n\s*LOOP"
                  r"[\s\S]*?\n\s*END\s+LOOP;",
                  "", text, flags=re.IGNORECASE)


def _unname_the_recipient_set(text: str) -> str:
    """The loop survives; the call that made it reach anybody is renamed.

    The mirror of the case above: a check that only looked for the FOR would
    pass this, which is why both are required.
    """
    return text.replace("registration_review_recipients()",
                        "some_other_recipient_set()")


def _drop_the_reactivation_notice(text: str) -> str:
    """0026's regression, restated: the account comes back silently."""
    return re.sub(
        r"PERFORM\s+public\.notify_user_safe\(\s*\n\s*'provider-reactivated:.*?"
        r"\n\s*\);",
        "", text, flags=re.IGNORECASE | re.DOTALL)


def _drop_a_guard_clause(text: str) -> str:
    """The city scope, gone -- the exact line 0111 added and 0026 lost.

    The whole statement is removed rather than a fragment, because the
    continuation is on the next line and a partial edit leaves text that no
    longer parses, which is a different failure from the one being tested.
    """
    return re.sub(
        r"\n\s*OR NOT public\.staff_scope_allows_city\([\s\S]*?p_provider_id\)\)",
        "", text, count=1, flags=re.IGNORECASE)


def _drop_the_enum_value(text: str) -> str:
    """A notification with no type."""
    return text.replace("'REGISTRATION_RECEIVED'", "'SOME_TYPE_THAT_IS_NOT_THERE'")


# (label, mutate, the assertion that must name it, the function whose
#  authoritative body it must land on -- None means the registration migration
#  itself is where the mutated text lives, as for the trigger and the enum).
CASES: list[tuple[str, object, str, str | None]] = [
    ("the trigger is never created, so the notice never fires",
     _drop_trigger,
     "trg_registration_submitted",
     None),
    ("the reviewer fan-out is emptied but the recipient set is still named",
     _empty_the_fanout,
     "does not iterate the recipient set",
     "on_registration_submitted"),
    ("the recipient set is renamed out from under a loop that survives",
     _unname_the_recipient_set,
     "never calls registration_review_recipients",
     "on_registration_submitted"),
    ("unsuspend_provider reactivates an account without telling the person",
     _drop_the_reactivation_notice,
     "reactivates an account without telling the person",
     "unsuspend_provider"),
    ("unsuspend_provider loses a guard clause in the same restatement",
     _drop_a_guard_clause,
     "has lost its city scope",
     "unsuspend_provider"),
    ("the notification is written with a type that is not the enum member",
     _drop_the_enum_value,
     "REGISTRATION_RECEIVED",
     None),
]


def defining_migrations(fn: str) -> list[Path]:
    """Every migration that defines public.<fn>(), in apply order."""
    pattern = re.compile(
        r"FUNCTION\s+public\.%s\s*\(" % re.escape(fn), re.IGNORECASE)
    return [p for p in sc.migration_files() if pattern.search(sc._read(p))]


def patches_for(mutate, fn: str | None, real: str) -> dict[str, str]:
    """`{filename: mutated source}` for every file the mutation must cover.

    The registration migration always, plus every migration defining `fn` when
    a function is named. `real` is reused for MIG rather than re-read, so the
    caller's already-mutated copy is never double-applied.
    """
    names = {MIG}
    if fn is not None:
        names |= {p.name for p in defining_migrations(fn)}
    out: dict[str, str] = {}
    for name in names:
        text = real if name == MIG else sc._read(sc.MIGRATIONS / name)
        out[name] = mutate(text)
    return out


def winning_file(fn: str | None) -> str:
    """The migration whose text the check actually reads for this case."""
    if fn is None:
        return MIG
    path, _ = sc.last_migration_defining(fn)
    return path.name if path is not None else MIG


def with_patches(patches: dict[str, str], check):
    """Run the real check with the named migrations reading as their patch."""
    real_read = sc._read

    def _read(path: Path) -> str:
        try:
            name = Path(str(path).replace("\\", "/")).name
        except Exception:
            name = ""
        if name in patches:
            return patches[name]
        return real_read(path)

    sc._read = _read
    try:
        return check()
    finally:
        sc._read = real_read


def main() -> int:
    real = (sc.MIGRATIONS / MIG).read_text(encoding="utf-8")
    if not real.strip():
        print("[FAIL] %s is empty -- there is nothing to falsify" % MIG)
        return 1

    failures = 0
    for label, mutate, expect, fn in CASES:
        patches = patches_for(mutate, fn, real)
        winner = winning_file(fn)
        if patches.get(winner) == sc._read(sc.MIGRATIONS / winner):
            print("[FAIL] the mutation for %r changes nothing in %s, the "
                  "migration whose definition WINS -- the needle is stale, so "
                  "this case would have gone green while proving nothing"
                  % (label, winner))
            failures += 1
            continue

        problems = with_patches(
            patches, sc.check_registration_notifications_are_wired)
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

    real_problems = with_patches(
        {}, sc.check_registration_notifications_are_wired)
    if real_problems:
        print("[FAIL] the real %s is still red" % MIG)
        for p in real_problems:
            print("         - " + p)
        return 1
    print("[ ok ] the real %s is green" % MIG)

    if failures:
        print("\nFALSIFICATION FAILED (%d case(s))" % failures)
        return 1
    print("\nFALSIFICATION PASSED (%d red cases, each green once repaired)"
          % len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
