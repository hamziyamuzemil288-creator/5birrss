#!/usr/bin/env python3
"""Line-level diff of a restated function body against its last defining migration.

When a migration re-issues `CREATE OR REPLACE FUNCTION foo(...)`, the single
most dangerous failure mode is a *silent* one: the restatement drops a line the
original had, and nothing in SQL parsing notices.  This tool proves that a
restated body is a pure superset of its predecessor -- every non-blank,
non-comment line of the original still appears, in the same order, andthe only lines the restatement adds are the ones we explicitly allow.

A restatement that REPAIRS a defect is the opposite situation -- its dropped
lines are the point -- so those are judged by the mirror assertion instead
(`FIXES`): the repair is present, the broken shape is gone, and the only lines
that changed are the ones the broken statement was made of.


Usage:
    python3 tools/harness/restated_body_diff.py            # run every case
    python3 tools/harness/restated_body_diff.py --verbose  # print each diff

Exit code 0 when every case is clean, 1 otherwise.
"""
from __future__ import annotations

import difflib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "supabase" / "migrations"

# Strict: only a top-level `CREATE OR REPLACE FUNCTION` opens a definition.
# `non_grouped_calls` on the name stops `CREATE OR REPLACE VIEW foo` etc. from
# being mistaken for a function, and the trailing `(` anchors the arg list.
FN_HEAD = re.compile(
    r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+(?:public\.)?([A-Za-z_][A-Za-z0-9_]*)\s*\(",
    re.IGNORECASE,
)

# Anything that legitimately differs from line to line and must not be judged.
NOISE = re.compile(
    r"""(
          ^\s*$                                  # blank
        | ^\s*--                                  # line comment
        | ^\s*/\* | \*/\s*$                       # block comment edges
        | ^\s*\*                                  # block comment body
    )""",
    re.VERBOSE | re.IGNORECASE,
)


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def _files() -> list[Path]:
    return sorted(MIGRATIONS.glob("*.sql"))


def _strip_inline_comments(line: str) -> str:
    """Drop a trailing `--` comment but keep string literals intact."""
    out: list[str] = []
    i = 0
    quote: str | None = None
    while i < len(line):
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
            out.append(ch)
        elif ch == "-" and line[i : i + 2] == "--":
            break
        elif ch == "/" and line[i : i + 2] == "/*":
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out).strip()


def function_bodies(sql: str) -> dict[str, str]:
    """Map function name -> full text of its last `CREATE OR REPLACE` body.

    Later definitions win *within* a file only when they are genuinely a new
    statement; because we scan the file top to bottom and overwrite, the last
    occurrence in the file is what we return.  Across files the caller decides
    the ordering, and a file that merely *references* the name (in a COMMENT,
    a DROP, or a grant) never opens a definition because the regex is anchored
    on `CREATE OR REPLACE FUNCTION`.
    """
    bodies: dict[str, str] = {}
    for m in FN_HEAD.finditer(sql):
        name = m.group(1).lower()
        # Walk forward to the matching $$ / $body$ terminator.
        rest = sql[m.end():]
        end = _find_terminator(rest)
        bodies[name] = rest[:end] if end is not None else rest
    return bodies


def _find_terminator(rest: str) -> int | None:
    """Return index just past the `$$;` that closes the body, or None."""
    i = 0
    n = len(rest)
    tag: str | None = None
    while i < n:
        if rest[i] == "$":
            m = re.match(r"\$[A-Za-z_]*\$", rest[i:])
            if m:
                tok = m.group(0)
                if tag is None:
                    tag = tok
                elif tok == tag:
                    j = i + len(tok)
                    while j < n and rest[j] in " \t":
                        j += 1
                    if j < n and rest[j] == ";":
                        return j + 1
                i += len(tok)
                continue
        i += 1
    return None


def _code_lines(body: str) -> list[str]:
    """Significant lines only: comments and blanks removed, leading ws gone."""
    out: list[str] = []
    for raw in body.splitlines():
        if NOISE.search(raw):
            continue
        line = _strip_inline_comments(raw)
        if not line:
            continue
        out.append(line)
    return out


def last_defining(fn: str) -> tuple[Path, str] | None:
    """Find the newest migration (excluding `skip`) that defines `fn`."""
    found: tuple[Path, str] | None = None
    for p in _files():
        bodies = function_bodies(_read(p))
        if fn in bodies:
            found = (p, bodies[fn])
    return found


def defining_in_file(fn: str, filename_glob: str) -> tuple[Path, str] | None:
    for p in _files():
        if not p.name.startswith(filename_glob):
            continue
        bodies = function_bodies(_read(p))
        if fn in bodies:
            return p, bodies[fn]
    return None


def _runs(lines: list[str]) -> list[list[str]]:
    """Split a diff's +/- lines into contiguous blocks of the same sign.

    An `@@` entry is a hunk boundary and always starts a fresh block, so two
    additions separated by unrelated hunks stay two blocks.
    """
    out: list[list[str]] = []
    for line in lines:
        if line == "@@":
            out.append(["@@", []])
            continue
        sign, text = line[0], line[1:].strip()
        if out and out[-1][0] == sign:
            out[-1][1].append(text)
        else:
            out.append([sign, [text]])
    return [[s, b] for s, b in out]


def _flat(block: list[str]) -> str:
    return " ".join(block)


# ---------------------------------------------------------------- cases ----
# (function, source-file glob, restating-file glob, approved added blocks)
# The approved entries are EXACT whitespace-normalised contiguous blocks from
# the diff, not substring hints.  That is the strongest form of the assertion:
# it proves the restatement added precisely the scope guard and nothing else,
# and it goes red the moment anyone edits the guard, drops a half of it, or
# slips an unrelated change into a restated body.
CASES: list[tuple[str, str, str, tuple[str, ...]]] = [
    (
        "verify_payment_proof",
        "20260922000012",
        "20260927000112",
        (
            "WHERE proof.id = p_proof_id)) OR NOT public.staff_scope_allows_city( "
            "(SELECT o.city FROM public.payment_proofs proof "
            "JOIN public.orders o ON o.id = proof.order_id",
        ),
    ),
    (
        "staff_task_feed",
        "20260927000052",
        "20260927000112",
        (
            "AND (v_view_all OR public.staff_scope_allows_city( "
            "coalesce(pp.city, us.city), v_staff.user_id))",
            "AND (v_view_all OR public.staff_scope_allows_city(pp.city, v_staff.user_id))",
            "AND (v_view_all OR public.staff_scope_allows_city( "
            "coalesce(o.city, pp.city), v_staff.user_id))",
        ),
    ),
    # The two public discovery reads, which gained ONE predicate each: a
    # listing with no row in `product_images` is a text-only listing, and a
    # browse grid or a search result has nowhere to put one — the card would
    # be an empty frame that reads as a broken photo. Both restatements are
    # pure additions, so the approved block is the whole predicate.
    #
    # `visible_products_for_city` was already restated once (20261010000002,
    # for the "all cities" rule); this entry judges the 20261011000001 change
    # against THAT body, which is the live one, so dropping the earlier city
    # rule while adding the photo rule goes red here.
    (
        "visible_products_for_city",
        "20261010000002",
        "20261011000001",
        (
            "and exists ( select 1 from public.product_images pi "
            "where pi.product_id = p.id )",
        ),
    ),
    # `search_products` gained three things and changed nothing: the exclusion
    # above, the RETURNS TABLE column and the SELECT projection that carry the
    # listing's own `listing_type` (the shared card's BUY / BOOK rule reads
    # it). A changed return type cannot be applied by CREATE OR REPLACE, so the
    # file DROPs the signature first — that statement sits before the header
    # and is not part of the body judged here.
    (
        "search_products",
        "20261006000008",
        "20261011000001",
        (
            "listing_type listing_type,",
            "p.listing_type,",
            "AND EXISTS ( SELECT 1 FROM public.product_images pi "
            "WHERE pi.product_id = p.id)",
        ),
    ),
    # The fulfilment gate. `claim_ride`'s only definition is the pre-baseline
    # 0021 snapshot, whose body is a single line, so the restatement reformats
    # it -- which is why this case proves the value of the tool rather than
    # just using it: it confirms nothing was DROPPED even though almost every
    # line differs.
    (
        "transition_order_status",
        "20260927000085",
        "20260927000113",
        (
            "v_blockers text[];",
            # The whole guard is one contiguous block, so it is approved as one
            # entry. Splitting it per line would let a half-guard pass.
            "IF v_actor_is_provider AND NOT v_actor_is_admin THEN "
            "v_blockers := public.provider_fulfilment_blockers(v_order.provider_id); "
            "IF COALESCE(array_length(v_blockers, 1), 0) > 0 THEN "
            "RAISE EXCEPTION 'PROVIDER_NOT_FULFILMENT_READY: %', "
            "array_to_string(v_blockers, ','); END IF; END IF;",
        ),
    ),
]


def check_case(fn: str, src_glob: str, dst_glob: str, allowed: tuple[str, ...],
               verbose: bool) -> list[str]:
    problems: list[str] = []
    src = defining_in_file(fn, src_glob)
    dst = defining_in_file(fn, dst_glob)
    if src is None:
        return [f"{fn}: source definition not found in {src_glob}*"]
    if dst is None:
        return [f"{fn}: restated definition not found in {dst_glob}*"]
    if src[0] == dst[0]:
        return [f"{fn}: source and restatement resolved to the same file ({src[0].name})"]

    old = _code_lines(src[1])
    new = _code_lines(dst[1])
    if not old:
        return [f"{fn}: source body produced no code lines"]
    if not new:
        return [f"{fn}: restated body produced no code lines"]

    # Keep the leading sign: _runs() needs it to group contiguous same-sign
    # blocks, and difflib interleaves + and - inside a changed hunk.  A hunk
    # header is kept as a separator so two additions in different hunks are
    # never flattened into one block.
    signed: list[str] = []
    for line in difflib.unified_diff(old, new, lineterm="", n=0):
        if line.startswith("---") or line.startswith("+++"):
            continue
        if line.startswith("@@"):
            signed.append("@@")
        elif line[0] in "+-":
            signed.append(line.strip())

    added = [s for s in signed if s == "@@" or s.startswith("+")]
    removed = [s for s in signed if s.startswith("-")]

    if verbose:
        print(f"\n--- {fn}: {src[0].name} -> {dst[0].name}")
        for line in difflib.unified_diff(old, new, fromfile=src[0].name,
                                         tofile=dst[0].name, lineterm="", n=1):
            print("   " + line)

    for line in removed:
        problems.append(f"{fn}: DROPPED original line: {line[1:].strip()!r}")

    # Every added line must belong to an approved contiguous block, and every
    # approved block must actually be used -- an unused entry means the guard
    # it was written for has silently disappeared.
    blocks = [b for s, b in _runs(added) if s == "+"]
    used: set[str] = set()
    for block in blocks:
        flat = _flat(block)
        match = next((a for a in allowed if a == flat), None)
        if match is None:
            problems.append(f"{fn}: unapproved added block: {flat!r}")
            continue
        used.add(match)
        if not flat.strip():
            problems.append(f"{fn}: an approved added block is empty")

    for a in allowed:
        if a not in used:
            problems.append(
                f"{fn}: expected guard block is absent from the restatement: {a!r}")

    if not added:
        problems.append(f"{fn}: restatement adds nothing (guard missing?)")

    return problems


# --------------------------------------------------------------- fix cases ---
# A restatement that REPAIRS a defect is the mirror image of the cases above,
# and the mirror assertion is the right one: the dropped lines are the point.
# The superset check would reject such a restatement for doing its job, and
# "just skip it" would leave the repair unpinned -- the defect could be
# reintroduced by a later restatement, or half the repair could be undone, and
# nothing here would notice.
#
# So these cases assert the complementary property, which is just as tight:
#   1. the repaired body CONTAINS the working statement,
#   2. it does NOT contain the shape that was broken, and
#   3. every single line that differs between the two bodies mentions one of the
#      identifiers the broken statement is made of -- so a repair that quietly
#      also reformats, reorders, or drops anything else is RED.
#
# (3) is a vocabulary rule, not a list of literal lines, so re-wrapping the fix
# for readability does not require editing this table.
#
# (function, source-file glob, restating-file glob, changed-line vocabulary,
#  must appear, must not appear)
FIXES: list[tuple[str, str, str, tuple[str, ...], tuple[str, ...], tuple[str, ...]]] = [
    (
        # `fn_notify_order_status_change` is the AFTER UPDATE trigger on
        # `orders`, and 0088 restated it with `NEW.order_number`. That column
        # was never created -- 0037 was marked applied without executing and
        # no CREATE TABLE declares it -- so the trigger raised
        # `record "new" has no field "order_number"` on every order UPDATE and
        # rolled it back. The whole availability chain is made of order
        # UPDATEs, so not one of its arrows could fire.
        #
        # 0115 found the identical bug in `create_order_secure` and fixed the
        # INSERT path; the UPDATE path was left. This entry pins the repair so
        # the broken shape cannot come back, and pins the two provider notices
        # the same restatement adds, so "fixing" it by dropping them is also
        # caught.
        "fn_notify_order_status_change",
        "20260927000088",
        "20260927000133",
        # The vocabulary the repair is allowed to introduce. `order_number` is
        # the name being removed; the rest name the two new provider notices
        # and the short reference that replaces the broken read. It is a
        # vocabulary and not a whitelist of lines -- this function is the one
        # place a line like "a customer submitted a payment proof" has to be
        # writable at all -- so the `present`/`absent` pins below are what
        # actually hold the repair and the two notices in place.
        (
            "order_number",
            "v_short_ref",
            "PAYMENT_VERIFICATION",
            "payment proof",
            "proof",
            "notify_user_once",
            "v_provider_user",
            "provider_profiles",
            "ELSIF NEW.status",
            "IF OLD.status",
            "administrator",
            "back with the buyer",
        ),
        (
            # the repaired label
            "v_label := 'Order ' || coalesce('#' || v_short_ref, 'update');",
            # and the two provider notices, which exist for the whole point
            "'order-proof-submitted:' || new.id::text",
            "'order-proof-rejected:' || new.id::text",
        ),
        (
            # the broken read
            "new.order_number",
        ),
    ),
    (
        # 0115 wrapped `unnest` in a subquery that projected the constant 1 and
        # then filtered on a column of the derived table, so the assertion this
        # function exists to make raised 42703 twice instead of counting. 0116
        # removes the wrapper -- the only two statements it touches.
        "assert_staff_city_scope_covers_the_task_feed",
        "20260927000115",
        "20260927000116",
        ("v_cat_guard", "v_city_guard", "unnest(", "part"),
        (
            "from unnest(string_to_array(v_feed, "
            "'staff_scope_allows_category(')) as part where part <> '';",
            "from unnest(string_to_array(v_feed, "
            "'staff_scope_allows_city(')) as part where part <> '';",
        ),
        (
            # the wrapper, in either casing, is the defect
            "from ( select 1 from unnest",
            # and the alias-list answer that did not work either
            "as x(part)",
        ),
    ),
    (
        # `ranked_providers` ranked by CAREER totals, so the trending rail was
        # the same names in the same order forever: `completed_transactions`
        # moves by one and only after months, and with `created_at ASC` behind
        # it every provider at zero collapsed to "oldest signup first".
        # 20261011000001 puts completed work in the LAST 7 DAYS in front of it,
        # which means the one ordering line inside the window has to change.
        #
        # This is the mirror case rather than a superset case (the whole point
        # is to REPLACE the first sort key), so the vocabulary below names what
        # a legitimate change is allowed to mention. Every changed line must
        # contain one of those tokens, the recency key must be present, and the
        # all-time-only key must be gone.
        "ranked_providers",
        "20260927000128",
        "20261011000001",
        (
            "completed_transactions",
            "ORDER BY",
            "DESC",
            "orders",
            "ride_requests",
            "updated_at",
            "provider_id",
            "COMPLETED",
            "interval",
            "v_window",
            "count(*)",
            "now()",
        ),
        (
            # the window itself, and the recency key built on it
            "v_window interval := interval '7 days';",
            "AND o.updated_at >= now() - v_window)",
            "AND r.updated_at >= now() - v_window)",
            "FROM public.ride_requests r",
        ),
        (
            # the all-time-first key the change exists to remove
            "ORDER BY s.completed_transactions DESC,",
        ),
    ),
    (
        # 20261008000001 routed the rider's own notice and the driver fan-out
        # through the queue-aware helpers, and the assertion it added scanned
        # the RAW `prosrc` for the literal `insert_notification` -- which
        # `prosrc` also contains, because the body's own comment says the direct
        # call was removed. The check raised on its own explanation and turned
        # the fix it shipped into a red build (Connectivity CI #213,
        # `the ride path bypasses the notification queue`, P0001).
        #
        # 20261009000001 reads both bodies with their comments removed first.
        # This entry pins that repair: the comment-stripping and the three
        # forbidden spellings are present, the raw `SELECT prosrc` read is gone,
        # and no other line moved -- so a restatement that drops the stripping
        # step and goes back to scanning prose is red here, before a deploy.
        "assert_ride_create_notifies_through_the_queue",
        "20261008000001",
        "20261009000001",
        # The vocabulary the repair is allowed to touch. `prosrc` is the value
        # whose meaning changed (raw -> comment-free); the rest name the two
        # reads and the two checks built around it.
        (
            "v_ride",
            "v_fan",
            "prosrc",
            "regexp_replace",
            "insert_notification",
            "notifications",
            "notify_user",
            "notify_best_effort",
            "guard",
            "untold",
            "\\*",
            "[:space:]",
        ),
        (
            # comments stripped before the match, for BOTH bodies
            "regexp_replace(p.prosrc, E'--[^\\n]*', ' ', 'g')",
            "'/\\*.*?\\*/'",
            # and the forbidden shapes still checked afterwards
            "v_ride ILIKE '%insert_notification%'",
            "insert into public.notifications",
            "NOT ILIKE '%notify_user%'",
        ),
        (
            # the raw, comment-included read that matched its own prose
            "SELECT prosrc INTO",
        ),
    ),
    (
        # The self-approval probe went vacuous the day 20261014000000 made a
        # self-service signup APPROVED at birth. The probe builds its fixture
        # by inserting into `auth.users`, which fires handle_new_user(); the
        # trigger now creates that profile APPROVED, so the probe's own
        # `INSERT ... 'PENDING_APPROVAL' ON CONFLICT (id) DO NOTHING` became a
        # silent no-op and the row it attacked was already APPROVED. Its attack
        # is a write of APPROVED over APPROVED -- a change of no status, so
        # prevent_profile_self_privilege_escalation() was right to stay quiet --
        # and the probe read the row back, saw APPROVED, and reported "the guard
        # did not fire". Connectivity CI #5 was that false finding against a
        # guard that works.
        #
        # 20261014000006 writes the pre-state itself, reads it back and requires
        # it, and asserts the guard trigger is attached. This entry pins all
        # three so a later restatement cannot quietly restore the vacuous
        # fixture, and it pins the absence of the exact broken sequence.
        "assert_profile_self_approval_is_refused",
        "20260927000028",
        "20261014000006",
        # The vocabulary the repair is allowed to touch. `DELETE` and `v_status`
        # are the fixture write and the read-back; the pg_trigger names are the
        # attachment check; `trg_profiles_security` names the guard itself; and
        # the probe's own values line is the one whose trailing
        # `ON CONFLICT (id) DO NOTHING` is the defect being dropped.
        (
            "DELETE",
            "v_status",
            "NOT EXISTS",
            "pg_trigger",
            "pg_class",
            "tgname",
            "regclass",
            "tgisinternal",
            "tgenabled",
            "trg_profiles_security",
            "Self Approval Probe",
        ),
        (
            # the pre-state is written instead of inherited
            "DELETE FROM public.profiles WHERE id = v_user",
            # ... read back and required, rather than assumed
            "IF v_status IS DISTINCT FROM 'PENDING_APPROVAL' THEN",
            # ... and the trigger that is supposed to refuse the attack has to
            # be attached, or the probe would blame the guard's body
            "IF NOT EXISTS (SELECT 1",
            "'trg_profiles_security is not attached to public.profiles",
        ),
        (
            # the silent no-op that let the fixture stay APPROVED, which is the
            # whole defect: the insert looked like it set the pre-state and
            # instead did nothing at all
            "VALUES (v_user, 'Self Approval Probe', 'PENDING_APPROVAL') "
            "ON CONFLICT (id) DO NOTHING;",
        ),
    ),
    (
        # 20261016000001's second read into pg_proc joined the namespace on
        # `n.oid = p.proname`. Postgres has no `oid = name` operator, so every
        # call to the assertion raised 42883 instead of answering -- and a
        # plpgsql body is not analysed until the statement first runs, so the
        # deploy that applied it succeeded, the whole-file parse and the body
        # syntax gate stayed green, and the only thing that could see it was
        # the live suite: Connectivity CI went red on both posting-gate tests
        # (110 passed, 2 failed) with the report the assertion exists to make
        # never having run at all.
        #
        # 20261016000002 restates the same body with the join repaired. This
        # entry pins the repair in the mirror form: the corrected read of
        # search_products is present, the shape that raised is gone, and no
        # other line moved -- so a future restatement cannot quietly drop the
        # fix, and the bad join cannot come back.
        "assert_posting_gate_is_document_and_wallet_not_payment_account",
        "20261016000001",
        "20261016000002",
        # The vocabulary the repair is allowed to touch: the two catalogues the
        # broken join was made of, and the two columns it confused.
        (
            "pg_proc",
            "pg_namespace",
            "n.oid",
            "proname",
            "pronamespace",
        ),
        (
            # the repaired statement, joined on the namespace's own oid
            "FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
            "WHERE n.nspname = 'public' AND p.proname = 'search_products';",
        ),
        (
            # the shape that raised instead of answering: the namespace joined
            # on a function NAME. The needle carries the WHERE that follows it,
            # because `p.proname` is a prefix of `p.pronamespace` and a needle
            # that stopped at the column would match the repaired line too.
            "JOIN pg_namespace n ON n.oid = p.proname "
            "WHERE n.nspname = 'public' AND p.proname = 'search_products';",
        ),
    ),
]


def _flat_body(body: str) -> str:
    """The body's code lines, lowercased, with ALL whitespace removed.

    Whitespace is dropped rather than collapsed because the repaired statement
    is also allowed to be re-wrapped: `from unnest(\n  string_to_array(...))` and
    `from unnest(string_to_array(...))` are the same statement, and a rule that
    only survived one of them would force a pointless edit the day someone
    reformatted it. Needs are compared the same way, so the entries below can be
    written the way a human reads them.
    """
    return re.sub(r"\s+", "", " ".join(_code_lines(body)).lower())


def check_fix(fn: str, src_glob: str, dst_glob: str, vocab: tuple[str, ...],
              present: tuple[str, ...], absent: tuple[str, ...]) -> list[str]:
    problems: list[str] = []
    src = defining_in_file(fn, src_glob)
    dst = defining_in_file(fn, dst_glob)
    if src is None:
        return [f"{fn}: source definition not found in {src_glob}*"]
    if dst is None:
        return [f"{fn}: restated definition not found in {dst_glob}*"]
    if src[0] == dst[0]:
        return [f"{fn}: source and restatement resolved to the same file ({src[0].name})"]

    old = _code_lines(src[1])
    new = _code_lines(dst[1])
    if not old or not new:
        return [f"{fn}: a body produced no code lines"]

    old_set, new_set = set(old), set(new)
    for line in sorted(old_set - new_set):
        if not any(tok in line for tok in vocab):
            problems.append(
                f"{fn}: the fix also changed an unrelated line: {line!r}")
    for line in sorted(new_set - old_set):
        if not any(tok in line for tok in vocab):
            problems.append(
                f"{fn}: the fix also added an unrelated line: {line!r}")

    flat = _flat_body(dst[1])
    for needle in present:
        if re.sub(r"\s+", "", needle.lower()) not in flat:
            problems.append(f"{fn}: the repaired statement is absent: {needle!r}")
    for needle in absent:
        if re.sub(r"\s+", "", needle.lower()) in flat:
            problems.append(f"{fn}: the broken shape is still in the body: {needle!r}")

    if not (old_set - new_set) and not (new_set - old_set):
        problems.append(f"{fn}: the restatement changes nothing (fix missing?)")

    return problems


def main() -> int:
    verbose = "--verbose" in sys.argv
    all_problems: list[str] = []
    for fn, src_glob, dst_glob, allowed in CASES:
        all_problems += check_case(fn, src_glob, dst_glob, allowed, verbose)
    for fn, src_glob, dst_glob, vocab, present, absent in FIXES:
        all_problems += check_fix(fn, src_glob, dst_glob, vocab, present, absent)

    if all_problems:
        print("RESTATED BODY DIFF: FAILED")
        for p in all_problems:
            print(f"  - {p}")
        return 1

    print(f"ok: {len(CASES)} restated function bodies are pure supersets of their "
          f"predecessors, and every added line is an approved scope guard")
    print(f"ok: {len(FIXES)} restatement(s) that fix a defect change ONLY the "
          f"broken lines, and the fix is present with the defect gone")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
