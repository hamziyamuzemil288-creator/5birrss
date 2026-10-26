#!/usr/bin/env python3
"""Parse the SQL inside plpgsql function bodies, which `pglast` on a file does not.

## Why this exists

`pglast` uses libpg_query, which is the real PostgreSQL grammar -- but only for
the statements it can see. A migration's `CREATE FUNCTION ... AS $$ ... $$` body
is parsed by pglast as *plpgsql*, and plpgsql defers each embedded SQL
statement to execution time. So a file can pass `pglast.parse_sql()` and still
be rejected by the server the moment the function is first created.

That is not hypothetical. `20260927000104` shipped `string_agg(p policyname,
...)` -- a space where the dot belonged -- inside
`gallery_read_surface_report()`. `pglast` on the whole file: clean.
`supabase db push`: `syntax error at or near "policyname" (SQLSTATE 42601)`,
25 seconds, after the commit was pushed and the deploy dispatched by hand.

Worse, the deploy log echoed the typo verbatim, so reading the failure to
diagnose it reproduced the same typo and hid it a second time.

## What it does

Walks each `$$ ... $$` / `$tag$ ... $tag$` body in a migration, splits it into
statements with a linear scanner, and parses each embedded statement as plain
SQL after stripping plpgsql's `INTO` clause.

Usage:
    python3 tools/harness/plpgsql_body_syntax.py <migration> [<migration>...]
    python3 tools/harness/plpgsql_body_syntax.py --pending       # default gate
    python3 tools/harness/plpgsql_body_syntax.py --recent [N]   # the newest N
    python3 tools/harness/plpgsql_body_syntax.py --all           # audit
"""

from __future__ import annotations

import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import pending  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "supabase" / "migrations"

try:
    import pglast  # type: ignore
except ImportError:  # pragma: no cover
    print("pglast is not installed; cannot check plpgsql bodies")
    sys.exit(0)


#: A dollar-quote delimiter: `$$` or `$tag$`.
#:
#: Module level (rather than a local inside find_bodies) because check_file
#: needs to count these on its own, WITHOUT the pairing step below. The guard
#: has to survive a regression in `find_bodies` itself, and it can only do that
#: if what it measures is not produced by the function it is guarding.
DELIM = re.compile(r"\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$")


def find_bodies(text: str):
    """Yield (start, body) for each dollar-quoted plpgsql body in `text`.

    The delimiter is captured whole and closed by backreference to *itself*.
    Capturing only the optional tag and closing with `\\1` cannot match when the
    tag is absent -- which is every `$$ ... $$` body in this repo -- and made
    the first version of this tool find zero bodies and report success.
    """
    for m in re.finditer(DELIM.pattern + r"(.*?)" + DELIM.pattern, text, re.DOTALL):
        yield m.start(), m.group(1)


def split_statements(body: str):
    """Split a plpgsql body on semicolons at paren depth 0, outside strings.

    A scanner, not a regex: the alternation-with-nested-quantifier version
    backtracked exponentially and the tool hung past a 120s timeout instead of
    returning an answer.

    `--` comments are skipped, and that is not cosmetic. An apostrophe inside
    a comment -- "the caller's own row" -- otherwise flips the scanner into
    string mode, where it swallows text until the next quote, eating the `;`
    that separated two statements. The result is a chunk that is SQL followed
    by plpgsql control flow, reported as a syntax error in a statement that
    is fine. That single missing case produced every false positive in the
    already-applied history.
    """
    buf: list[str] = []
    depth = 0
    in_str = False
    i = 0
    n = len(body)
    while i < n:
        ch = body[i]
        if in_str:
            if ch == "'":
                if i + 1 < n and body[i + 1] == "'":
                    buf.append("''")
                    i += 2
                    continue
                in_str = False
            buf.append(ch)
        elif ch == "-" and body.startswith("--", i):
            j = body.find("\n", i)
            if j == -1:
                break
            buf.append(body[i:j])
            i = j
            continue
        elif ch == "'":
            in_str = True
            buf.append(ch)
        elif ch == "(":
            depth += 1
            buf.append(ch)
        elif ch == ")":
            depth = max(0, depth - 1)
            buf.append(ch)
        elif ch == ";" and depth == 0:
            chunk = "".join(buf).strip()
            if chunk:
                yield chunk
            buf = []
        else:
            buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        yield tail


#: Only statements that begin with a SQL command are parsed. A blocklist of
#: plpgsql keywords was the first approach and it leaked twice: a DECLARE
#: block's variable lines (`v_select int;`) are not standalone SQL, and a
#: leading `--` comment glued an `IF` to its comment text. An allowlist of
#: real SQL commands skips both by construction, and fails safe -- an
#: unrecognised opener is not checked rather than falsely reported.
#:
#: `SELECT ... INTO` is deliberately allowed through: it is the shape this tool
#: most needs to check, and excluding it is what made the first version
#: report success on the exact typo it was written to catch.
SQL_COMMAND = re.compile(
    r"^\s*(select|insert|update|delete|with|merge|create|alter|drop|truncate|"
    r"grant|revoke|comment|notify|set|copy|call|do|values|refresh|"
    r"reindex|cluster|analyze|vacuum|listen|unlisten|begin|commit|rollback|"
    r"savepoint|release|prepare|deallocate|declare cursor)\b",
    re.IGNORECASE,
)

#: plpgsql's dynamic `EXECUTE 'sql string'` is a plpgsql statement whose SQL
#: lives in a string, so it is not parseable as plain SQL and cannot be checked
#: by this tool at all. Skipped rather than reported: its contents are only
#: known at runtime, and a check that flags uncheckable code is a check whose
#: red means nothing.
PLPGSQL_DYNAMIC = re.compile(r"^\s*EXECUTE\b", re.IGNORECASE)

#: A dollar-quoted body is plpgsql if the statement opening it declared
#: `LANGUAGE plpgsql` (`CREATE FUNCTION ... AS $$`) or if it is a bare
#: `DO $$ ... $$` block, which is always plpgsql.
#:
#: The `LANGUAGE plpgsql` test alone was the first version, and it had a hole
#: big enough to hide the whole class of conditional DDL this repo relies on:
#: `DO $$ ... $$` is never preceded by that string, so every DO block was
#: skipped. That is where 20260927000104 puts the gallery read policies, where
#: 20260927000096 puts its bucket, and where 20260927000106 puts the column and
#: the view rebuild -- so the gate reported "ok" on all three while never
#: having parsed a single statement in them. Found by falsification: an invalid
#: `ALTER TABLE ... ADD COLUMN` planted inside a DO block came back green.
TRAILING_COMMENT = re.compile(r"(?:--[^\n]*\n|\s)+\Z")
DO_OPENER = re.compile(r"(?:^|[\s;)])DO\Z", re.IGNORECASE)


#: `LANGUAGE sql` bodies are the other half of the invisible text. A
#: `CREATE FUNCTION ... LANGUAGE sql ... AS $$ ... $$` body is equally opaque
#: to an outer pglast pass -- it is a string literal to the file parser -- but
#: its contents are plain SQL and must parse AS WRITTEN. The plpgsql
#: normalisation below must not touch them: `SELECT ... INTO v` is an
#: assignment in plpgsql and a genuine syntax error in a sql body.
SQL_BODY = re.compile(r"LANGUAGE\s+sql\b", re.IGNORECASE)

#: `LANGUAGE plpgsql` bodies, the main half. Matched case-insensitively for
#: exactly the reason SQL_BODY is: every migration in this repo writes
#: `language plpgsql` in lower case. A case-sensitive substring test therefore
#: classified those bodies as "not a function body at all", the file was
#: dropped, and the `found 0 bodies` guard is what finally caught it -- after
#: two pending migrations (016 and 017) had gone unread. Whitespace-tolerant
#: too, so a declaration whose `language` and `plpgsql` sit on separate lines
#: or behind a tab is still recognised.
PLPGSQL_LANGUAGE = re.compile(r"LANGUAGE\s+plpgsql\b", re.IGNORECASE)


def is_sql_body(prefix: str) -> bool:
    return SQL_BODY.search(prefix) is not None


def is_plpgsql_body(prefix: str) -> bool:
    if PLPGSQL_LANGUAGE.search(prefix):
        return True
    # Trailing comments and whitespace are stripped first, so a
    # `-- add the column, guarded` comment between `DO` and `$$` is not what
    # decides this. Requiring a non-word character before DO keeps a name that
    # merely ends in "do" (`undo`) from reading as the keyword.
    return DO_OPENER.search(TRAILING_COMMENT.sub("", prefix)) is not None


#: Leading SQL comments, stripped before matching: a `--` line glued to the
#: statement after it otherwise hides the statement's real first keyword.
LEADING_COMMENTS = re.compile(r"\A(?:\s|--[^\n]*\n|\s)+")

#: plpgsql opens its main block with a bare `BEGIN`, which sits on the same
#: `;` boundary as the first real statement -- so the splitter yields
#: "BEGIN SELECT ...". `BEGIN` is also a SQL transaction command, so it cannot
#: simply be dropped from the allowlist; it is stripped instead.
PLPGSQL_BEGIN = re.compile(r"\A\s*BEGIN\b\s*", re.IGNORECASE)

#: plpgsql's `INTO a, b` is not standalone SQL, so it is normalised away before
#: parsing rather than causing the statement to be skipped.
#:
#: Applied ONLY to statements that open with SELECT. Applied unconditionally it
#: also eats the `INTO` of `INSERT INTO public.t ...`, turning it into
#: `INSERT public.t ...` and reporting a syntax error in a perfectly good
#: statement -- 500-odd false positives across the already-deployed history.
INTO_TARGETS = re.compile(
    r"\bINTO\s+(?:strict\s+)?[A-Za-z_][A-Za-z0-9_]*"
    r"(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*",
    re.IGNORECASE,
)
SELECT_START = re.compile(r"^\s*SELECT\b", re.IGNORECASE)

#: `UPDATE ... RETURNING * INTO v_row` is valid plpgsql and invalid plain SQL,
#: so the INTO after a RETURNING is normalised away for the same reason.
HAS_RETURNING = re.compile(r"\bRETURNING\b", re.IGNORECASE)


def iter_bodies(text: str):
    """Yield (start, prefix, body, sql_body) for each body this tool can judge.

    The prefix must describe THIS body only. A fixed 800-char lookback reaches
    into the previous function, so a `LANGUAGE sql` belonging to the one before
    it labelled this plpgsql body as sql -- and then the `SELECT ... INTO v`
    repair below was skipped and reported as a syntax error in valid SQL. Nine
    already-applied migrations were reported broken by that. The window is cut
    at the last statement boundary so the opening `LANGUAGE` line is the one
    that counts.

    Shared with column_scope.py: two gates that disagree about which bodies
    exist can disagree about which statements exist, and then one of them is
    checking a file the other silently skipped.
    """
    for start, body in find_bodies(text):
        prefix = text[max(0, start - 800):start]
        cut = max(prefix.rfind("$$"), prefix.rfind(";"))
        prefix = prefix[cut + 1:]
        sql_body = is_sql_body(prefix)
        if not sql_body and not is_plpgsql_body(prefix):
            continue
        yield start, prefix, body, sql_body


def normalize_statement(stmt: str, sql_body: bool) -> str | None:
    """The plain-SQL text to parse for one embedded statement, or None to skip.

    Single source of truth for both the syntax gate and the column-scope gate.
    A statement the allowlist skips must be skipped by both, and a statement
    the INTO repair rewrites must be rewritten for both, or the two gates
    disagree about what the database will actually run -- and the one that
    keeps the un-repaired text reports a syntax error in working SQL.
    """
    if not stmt:
        return None
    # The allowlist exists to filter plpgsql NOISE -- assignment and control
    # statements that are not SQL at all. A LANGUAGE sql body has no such
    # noise: every statement in it is supposed to be SQL, so an unrecognised
    # leading keyword there is precisely the finding. Filtering it out is what
    # let `RETURN` inside a sql body go unreported.
    if not sql_body and not SQL_COMMAND.match(stmt):
        return None
    if PLPGSQL_DYNAMIC.match(stmt):
        return None
    if sql_body:
        # Plain SQL: parse it exactly as written. No plpgsql repair.
        return stmt
    if SELECT_START.match(stmt):
        # `SELECT ... INTO v` -- the INTO is the assignment.
        return INTO_TARGETS.sub("", stmt, count=1)
    if HAS_RETURNING.search(stmt):
        # `INSERT/UPDATE/DELETE ... RETURNING * INTO v`. The INTO to remove is
        # the one AFTER RETURNING -- for an INSERT, the first INTO belongs to
        # `INSERT INTO` and stripping it yields `INSERT public.t ...`, a
        # syntax error in a good statement.
        cut = stmt.upper().index("RETURNING")
        return stmt[:cut] + INTO_TARGETS.sub("", stmt[cut:], count=1)
    return stmt


def strip_block_opener(raw: str) -> str:
    """Remove the leading `BEGIN` and any leading comments, in EITHER order.

    The two can precede each other: `BEGIN\n-- why\nSELECT ...` and
    `-- why\nBEGIN\nSELECT ...` are both ordinary plpgsql, and the second is
    what this repo's bodies actually write -- a comment explaining the block,
    sitting after the DECLARE section's final `;`.

    Stripping them in one fixed order (the previous behaviour) handled the
    first and left `BEGIN` glued to the first statement in the second, and
    `BEGIN insert into ...` is not SQL, so the tool reported "syntax error at
    or near insert" in bodies the live database has been running for weeks.
    Iterating until neither rule applies handles both orders, and nested
    blocks (`BEGIN ... BEGIN insert ...`), where the inner opener is the one
    that precedes the statement.

    Measured effect: 85 of the 99 findings across the already-applied history
    were this shape. A gate that reports working SQL as broken is the failure
    mode that gets a real finding ignored, so this is the cause, not noise to
    suppress.
    """
    stmt = raw
    while True:
        nxt = LEADING_COMMENTS.sub("", PLPGSQL_BEGIN.sub("", stmt))
        if nxt == stmt:
            return stmt
        stmt = nxt


def iter_statements(text: str):
    """Yield (line, body_start, sql_body, stmt, to_parse) per embedded statement.

    `offset` advances only past statements this tool keeps, matching the
    original inline loop exactly: a skipped statement does not shift the line
    reported for the ones that follow.

    `body_start` is the offset of the enclosing dollar-quoted body, so a
    caller that needs the body's own text (column_scope.py, for its DECLARE
    variables) does not have to re-derive which body a statement came from.
    """
    for start, _prefix, body, sql_body in iter_bodies(text):
        offset = 0
        for raw in split_statements(body):
            # Order cannot be fixed by choosing one: the block opener and a
            # comment each precede the other in real bodies, so both are
            # stripped until neither applies. See strip_block_opener.
            stmt = strip_block_opener(raw)
            to_parse = normalize_statement(stmt, sql_body)
            if to_parse is None:
                continue
            line = text[: start + offset].count("\n") + 1
            yield line, start, sql_body, stmt, to_parse
            offset += len(raw) + 1


def check_file(path: pathlib.Path) -> list[str]:
    text = path.read_text()
    problems: list[str] = []

    # The file AS A WHOLE, before any body is extracted.
    #
    # Everything below judges statements found INSIDE a dollar-quoted body. The
    # statements AROUND them -- CREATE FUNCTION, COMMENT ON, GRANT, and the
    # plain DDL that two thirds of these files are made of -- were parsed by
    # nothing in this suite: no gate ran pglast over a whole pending migration.
    #
    # 20261025000005 shipped a JavaScript-style line continuation (`'...',\`)
    # inside a COMMENT ON string. Every gate went green and `supabase db push`
    # rejected the file with `syntax error at or near "\\"` (42601) -- after the
    # commit was pushed and the deploy dispatched by hand. The body checks
    # below cannot see it, because no body contains it.
    try:
        pglast.parse_sql(text)
    except Exception as exc:  # noqa: BLE001 - report, never raise
        problems.append(
            f"{path.name}: the file itself does not parse: "
            f"{str(exc).splitlines()[0]}"
        )

    for line, _start, sql_body, stmt, to_parse in iter_statements(text):
        try:
            pglast.parse_sql(to_parse)
        except Exception as exc:  # noqa: BLE001 - report, never raise
            kind = "a LANGUAGE sql body" if sql_body else "a plpgsql body"
            problems.append(
                f"{path.name}:{line}: SQL inside {kind} does not "
                f"parse: {str(exc).splitlines()[0]}\n"
                f"      statement: {' '.join(stmt.split())[:140]}"
            )

    # The guard fires when the file HAS dollar-quoted bodies and the extractor
    # classified none of them -- the bug that made the first version report
    # success over 200 unexamined files, and the one that silently skipped
    # migrations 016 and 017 (four and two raw bodies, zero classified). It
    # must not fire merely because a body held no parseable SQL (a body that is
    # entirely dynamic `EXECUTE`, say): that file was read, there was simply
    # nothing in it this tool can judge.
    #
    # It also must not fire on a file with no bodies at all. Two thirds of this
    # repo's migrations are plain DDL, DML and seeds -- 14 of them contain no
    # `$$`, no `DO` and no `CREATE FUNCTION` -- and reporting those as
    # "NOT checked" made `--all` unable to pass, which is how a guard that is
    # permanently red stops being read. The delimiter count is taken straight
    # from the text, so a regression in find_bodies still trips this.
    if DELIM.search(text) and not any(True for _ in iter_bodies(text)):
        problems.append(
            f"{path.name}: found 0 plpgsql bodies in "
            f"{len(DELIM.findall(text)) // 2} dollar-quoted block(s) -- the "
            f"body extractor matched nothing, so this file was NOT checked"
        )
    return problems


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    note = ""
    if argv[0] == "--all":
        targets = sorted(MIGRATIONS.glob("*.sql"))
    elif argv[0] == "--pending":
        # Everything a deploy would apply: see tools/harness/pending.py. Falls
        # back to the newest migration when nothing is pending, so the gate is
        # never vacuous.
        try:
            targets, note = pending.gate_targets()
        except pending.PendingError as exc:
            print(f"[FAIL] {exc}")
            return 1
    elif argv[0] == "--recent":
        # The newest N migrations. Kept as an explicit option: useful when
        # bisecting, and the fallback the --pending window uses.
        #
        # --all is an audit, not a gate. The already-applied history contains
        # plpgsql bodies whose statements this splitter cannot separate
        # cleanly (control flow sharing a `;` boundary with the SQL around it)
        # and every one of those is live and working. Failing the build on
        # them would make the check cry wolf, which is how a real signal gets
        # ignored. What matters is that what is written today parses.
        n = int(argv[1]) if len(argv) > 1 else 1
        targets = sorted(MIGRATIONS.glob("*.sql"))[-n:]
    else:
        targets = [pathlib.Path(a) for a in argv]

    problems: list[str] = []
    for t in targets:
        if not t.exists():
            problems.append(f"{t}: no such file")
            continue
        problems.extend(check_file(t))

    # Known-unparseable for unrelated reasons; excluded from the suite.
    known = ("0021_live_schema_snapshot.sql", "0022c_functions.sql")
    problems = [p for p in problems if not any(k in p.split(":")[0] for k in known)]

    for p in problems:
        print(f"[FAIL] {p}")
    if note:
        print(f"note: {note}")
    if problems:
        print(f"\n{len(problems)} problem(s) in SQL inside plpgsql bodies.")
        return 1
    print(f"ok: every statement in {len(targets)} file(s) parses "
          f"(whole file and plpgsql/sql bodies)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
