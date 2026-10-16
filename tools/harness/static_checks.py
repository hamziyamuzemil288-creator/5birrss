#!/usr/bin/env python3
"""Static harnesses for Aliob.

THERE IS NO DART SDK AND NO DENO IN THE AUDIT ENVIRONMENT, and the live-DB
suite (tools/integration_test/connectivity_test.dart) needs credentials the
sandbox does not have. These checks read the source instead: they are the
machine-checkable half of what docs/ARCHITECTURE.md section 6 claims, the
half that needs no compiler, no network and no secrets.

They live under tools/harness/ and NOT under build/ because `.gitignore`
contains a bare `build/` line (it is the Flutter output directory). Anything
placed there is never committed, does not survive a clone, and disappears at
the end of every session -- which is exactly what happened to the previous
set of harnesses.

Each check prints one line and returns a problem list. The runner fails the
whole harness if any check reports a problem.

Run:  sh build/run_all.sh      (shim)
      sh tools/harness/run_all.sh
"""

from __future__ import annotations

import re
import subprocess
import sys
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "lib"
MIGRATIONS = ROOT / "supabase" / "migrations"
FUNCTIONS = ROOT / "supabase" / "functions"
DEPLOY_WORKFLOW = ROOT / ".github" / "workflows" / "deploy-supabase.yml"


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
_READ_CACHE: dict[str, str] = {}


def _read(path: Path) -> str:
    """Read a file, memoised.

    The FOREACH check resolves the last definition of every function in the
    schema, and last_migration_defining re-reads all 189 migrations each time.
    Uncached that is a few million reads per harness run, which pushed the
    fault injector past the shell's time limit. The injector edits files
    between runs, so the cache is keyed on path plus mtime and size.
    """
    try:
        st = path.stat()
    except OSError:
        return ""
    key = f"{path}:{st.st_mtime_ns}:{st.st_size}"
    if key not in _READ_CACHE:
        try:
            _READ_CACHE[key] = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            _READ_CACHE[key] = ""
    return _READ_CACHE[key]


def dart_sources() -> list[Path]:
    return sorted(LIB.rglob("*.dart"))


def migration_files() -> list[Path]:
    """Migrations in the order the database applies them (filename order)."""
    return sorted(p for p in MIGRATIONS.glob("*.sql"))


def last_migration_defining(name: str) -> tuple[Path | None, str]:
    """The highest-ordered migration that defines public.<name>().

    The live database has no CLI history for the early files, so filename
    order is the only ordering that exists; the last definition in that
    order is the one that is authoritative.
    """
    pattern = re.compile(
        r"FUNCTION\s+public\.%s\s*\(" % re.escape(name), re.IGNORECASE
    )
    found: list[Path] = []
    for path in migration_files():
        if pattern.search(_read(path)):
            found.append(path)
    if not found:
        return None, ""
    return found[-1], _read(found[-1])


def function_body(sql: str, name: str) -> str:
    """The body between the AS $$ ... $$; of public.<name>(), if present.

    Needed because a naive count of `verified_at = now()` over the whole
    FILE also counts the header comment that explains the invariant -- which
    is how a correct file would look like a broken one.

    COMMENTS ARE STRIPPED, for the same reason one level down. An inline
    comment inside the body naming a table or an expression is enough to
    satisfy a substring check about that table: deleting the real
    `EXISTS (SELECT 1 FROM notification_outbox ...)` while leaving the
    comment that explains it passed the check. A body check that prose can
    satisfy is not a body check.
    """
    m = re.search(
        r"FUNCTION\s+public\.%s\s*\([^)]*\).*?AS\s+\$\$(.*?)\$\$;" % re.escape(name),
        sql,
        re.IGNORECASE | re.DOTALL,
    )
    if not m:
        return ""
    body = m.group(1)
    body = re.sub(r"--[^\n]*", " ", body)
    body = re.sub(r"/\*.*?\*/", " ", body, flags=re.DOTALL)
    return body


def literal_calls(pattern: str, flags: int = re.DOTALL) -> dict[str, set[str]]:
    """Map every literal matched by `pattern` -> the files that contain it."""
    hits: dict[str, set[str]] = {}
    rx = re.compile(pattern, flags)
    for path in dart_sources():
        for m in rx.finditer(_read(path)):
            hits.setdefault(m.group(1), set()).add(
                str(path.relative_to(ROOT)).replace("\\", "/")
            )
    return hits


# ---------------------------------------------------------------------------
# 1. the signup OTP gate is a working toggle, on both sides
# ---------------------------------------------------------------------------
def check_signup_otp_contract() -> list[str]:
    """The load-bearing property of migrations 82 and 84.

    Registration works today only because the OTP gate is switched OFF. The
    three things that make that safe, and that a later edit could quietly
    break, are asserted here:

      * send-otp consults the toggle BEFORE it needs a mail provider, a
        captcha or a code -- so with the gate off it sends nothing and
        reports `skipped`, rather than failing registration with an opaque
        provider error.
      * verify_email_otp() completes a bypassed signup WITHOUT stamping
        verified_at, so switching the gate back on restores it for every
        address. Exactly one place may stamp it: the correct-code branch.
      * handle_new_user() still reads the toggle and still refuses an
        unverified signup when it is on.
      * the client asks the server whether to show the code screen at all,
        and fails closed (shows it) if the lookup fails.
    """
    problems: list[str] = []

    src = _read(FUNCTIONS / "send-otp" / "index.ts")
    if not src:
        return ["send-otp/index.ts is missing"]

    order = {
        "the signup_otp_required check": '"signup_otp_required"',
        "the mail provider lookup": "resolveProvider()",
        "the captcha check": 'admin.rpc("captcha_required")',
        "the code request": 'admin.rpc("request_email_otp"',
    }
    positions: dict[str, int] = {}
    for label, needle in order.items():
        pos = src.find(needle)
        if pos < 0:
            problems.append(f"send-otp: no {label} ({needle!r})")
        positions[label] = pos

    if not problems:
        sequence = [positions[label] for label in order]
        if sequence != sorted(sequence):
            problems.append(
                "send-otp: the signup_otp_required check is not the FIRST gate. "
                "With the toggle off it must return before any provider, "
                "captcha or code work, otherwise registration fails on a mail "
                "provider the owner has deliberately not configured. Order: "
                + " -> ".join(
                    f"{label}@{positions[label]}" for label in order
                )
            )

    if 'skipped: "email_verification_disabled"' not in src:
        problems.append(
            'send-otp: no `skipped: "email_verification_disabled"` response, '
            "so a switched-off gate is indistinguishable from a failure"
        )

    # --- verify_email_otp: the bypass must record nothing -----------------
    path, sql = last_migration_defining("verify_email_otp")
    if path is None:
        problems.append("no migration defines public.verify_email_otp()")
    else:
        body = function_body(sql, "verify_email_otp")
        if not body:
            problems.append(f"{path.name}: could not extract verify_email_otp body")
        else:
            if "signup_otp_required" not in body:
                problems.append(
                    f"{path.name}: verify_email_otp() no longer consults "
                    "signup_otp_required, so it cannot tell a switched-off "
                    "gate from a real verification"
                )
            stamps = len(re.findall(r"verified_at\s*=\s*now\(\)", body))
            if stamps != 1:
                problems.append(
                    f"{path.name}: verify_email_otp() stamps verified_at in "
                    f"{stamps} places; exactly the correct-code branch may (1). "
                    "0 means re-enabling the gate would not restore it; >1 "
                    "means the bypass records a verification and every address "
                    "that skipped the code stays exempt"
                )

    # --- handle_new_user: still a gate ------------------------------------
    path, sql = last_migration_defining("handle_new_user")
    if path is None:
        problems.append("no migration defines public.handle_new_user()")
    else:
        for token in ("signup_otp_required", "otp_verified_recently", "EMAIL_OTP_REQUIRED"):
            if token not in sql:
                problems.append(
                    f"{path.name}: handle_new_user() no longer references "
                    f"{token}, so the signup gate is not switchable back on"
                )

    # --- the guards that keep both properties honest ----------------------
    all_sql = "\n".join(_read(p) for p in migration_files())
    for guard in ("assert_signup_otp_toggle_is_consistent", "assert_otp_bypass_is_scoped"):
        if guard not in all_sql:
            problems.append(f"the source-level guard {guard}() is missing")

    # --- the client -------------------------------------------------------
    svc = _read(LIB / "core" / "services" / "otp_service.dart")
    if "rpc('signup_otp_required')" not in svc:
        problems.append(
            "otp_service.dart: isRequiredAtSignup() no longer asks the server "
            "(signup_otp_required), so the client is guessing"
        )
    if not re.search(r"catch\s*\(_\)\s*\{\s*return true;", svc):
        problems.append(
            "otp_service.dart: isRequiredAtSignup() does not fail closed "
            "(return true) when the lookup fails"
        )

    screen = _read(LIB / "features" / "auth" / "signup_screen.dart")
    if "'/otp-verify'" not in screen:
        problems.append("signup_screen.dart: no longer routes to /otp-verify")
    if not re.search(r"if\s*\(_otpRequired\)", screen):
        problems.append(
            "signup_screen.dart: /otp-verify is not gated on _otpRequired, so "
            "a build would demand a code whose email cannot be delivered"
        )
    # Part 1 of the rework: the CAPTCHA is ALWAYS on at signup, no longer
    # tied to the OTP toggle. The old coupling meant that switching the mail
    # gate off — the normal state, since send-otp returns `skipped` when no
    # mail provider is configured — also silently switched off the only
    # bot-throttle registration has. The screen loads it as true unconditionally
    # and the submit refuses without a completed challenge.
    if not re.search(r"_captchaRequired\s*=\s*true", screen):
        problems.append(
            "signup_screen.dart: the signup CAPTCHA is no longer always-on "
            "(Part 1) — `_captchaRequired = true` must be set while the "
            "screen loads its gates, independent of the OTP toggle"
        )
    if "_captchaRequired && _captchaId == null" not in screen:
        problems.append(
            "signup_screen.dart: _handleSubmit no longer refuses to submit "
            "without a completed security check, so the always-on challenge "
            "is cosmetic"
        )

    return problems


# ---------------------------------------------------------------------------
# 2. every RPC the client calls exists in a migration
# ---------------------------------------------------------------------------
def check_rpc_targets_exist() -> list[str]:
    """A `client.rpc('does_not_exist')` is a runtime 404 in one screen.

    Only literal names are checked; names passed through a variable (the
    generic invoker in supabase_service.dart) cannot be resolved statically
    and are reported as a count instead of silently ignored.
    """
    calls = literal_calls(r"\.rpc\(\s*'([^']+)'")
    all_sql = "\n".join(_read(p) for p in migration_files())
    problems = []
    for name in sorted(calls):
        if not re.search(
            r"FUNCTION\s+public\.%s\s*\(" % re.escape(name), all_sql, re.IGNORECASE
        ):
            problems.append(
                "no migration defines public.%s() -- called from %s"
                % (name, ", ".join(sorted(calls[name])))
            )
    return problems


# ---------------------------------------------------------------------------
# 3b. the client sends every body field a function REQUIRES
# ---------------------------------------------------------------------------
# An Edge Function's request contract lives in TypeScript; the caller's lives in
# Dart; nothing in either language checks the other. The admin "Delete user"
# button was dead for exactly this reason and nothing went red: the `user-admin`
# function requires `confirm` to equal the target id -- its second factor of
# intent against a mis-wired button -- and the client sent only
# {action, user_id}. Every press returned 400 confirmation_required, so the
# button could never have worked, and the UI reported the raw code.
#
# Scoped to REQUIRED fields only: a `body.X` that appears in an `if` guard
# which rejects the request with a named `error:` code. Reading every `body.X`
# a function touches would be wrong -- user-admin also reads `body.reason`,
# for a different action, and demanding it on every call would be a false
# positive that trains everyone to ignore this check.
REQUIRED_BODY_FIELD = re.compile(
    r"if\s*\(\s*\(?\s*body\.([a-z_][a-z0-9_]*)", re.IGNORECASE)


def check_edge_function_required_fields_are_sent() -> list[str]:
    problems: list[str] = []
    invoked = literal_calls(r"\.invoke\(\s*'([^']+)'")
    if not invoked:
        return ["no literal functions.invoke('...') calls found -- did the "
                "client move?"]

    found_any = 0
    for name in sorted(invoked):
        index = FUNCTIONS / name / "index.ts"
        if not index.is_file():
            continue  # check_edge_functions_deployed already reports this
        src = _strip_comments(_read(index))
        # literal_calls maps to paths RELATIVE to the repo root, not Path objects.
        dart = "".join(_strip_comments(_read(ROOT / p)) for p in invoked[name])

        required: set[str] = set()
        for m in REQUIRED_BODY_FIELD.finditer(src):
            # A guard only counts if it actually rejects the request. The
            # look-ahead is bounded so a dispatch `if (body.action === "x")`
            # is not mistaken for a requirement -- it opens a branch, and the
            # error inside that branch belongs to the branch, not the contract.
            window = src[m.end():m.end() + 260]
            if "return json(" in window and "error:" in window:
                required.add(m.group(1))

        for field in sorted(required):
            found_any += 1
            if not re.search(r"['\"]%s['\"]\s*:" % re.escape(field), dart):
                problems.append(
                    "supabase/functions/%s/index.ts rejects a request whose "
                    "body.%s is missing, but no caller in %s sends it -- the "
                    "call can only ever fail. Send '%s' from the Dart client."
                    % (name, field, ", ".join(sorted(invoked[name])), field))

    if not found_any:
        # Same rule as the plpgsql gate: a check that finds nothing to check
        # has stopped checking. A regex change that silently matches zero
        # guards would report green forever.
        problems.append(
            "no required body field was found in any Edge Function the app "
            "invokes -- the guard pattern has stopped matching and this check "
            "is now vacuous")
    return problems


# 3c. the connectivity suite calls each RPC through a helper that matches
# ---------------------------------------------------------------------------
# The suite has two ways to ask the database something: ok() for a boolean,
# rpcText()/rpcTextDiagnosed() for an explanatory string. Nothing checked that
# each function was asked through the right one, and the mismatch is silent in
# the worst way -- the call does not fail, it fails to be a CALL. The first
# live run of the provider photo surface reported
#
#   assert_provider_photo_surface_is_wired() could not run.
#   Diagnostic: returned bool (true), not a String
#
# which reads like the database refused to answer. It had answered: the
# assertion had already passed and returned true. The test was wrong, the
# database was right, and only a live run could tell them apart.
FN_DEFINITION = re.compile(
    r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?(\w+)\s*\("
    r".*?\)\s*RETURNS\s+(table|bool\w*|text|jsonb|json|void|int\w*|"
    r"numeric|bigint|uuid|date|timestamptz|setof\s+[\w\s]+?)\s"
    r"(?:LANGUAGE|AS\b|;)",
    re.IGNORECASE | re.DOTALL,
)
TEXT_RETURNS = {"text", "jsonb", "json"}
BOOL_RETURNS = {"bool", "boolean"}


def check_test_helper_matches_return_type() -> list[str]:
    """Every rpc the suite calls must be asked through the right helper."""
    conn = _strip_comments(_read(ROOT / "tools/integration_test"
                                        "/connectivity_test.dart"))
    if not conn:
        return ["tools/integration_test/connectivity_test.dart is missing"]

    # The last definition wins, so read migrations in version order and let
    # later files overwrite earlier ones -- a function restated post-baseline
    # is the one that is actually live.
    returns: dict[str, str] = {}
    for path in migration_files():
        for m in FN_DEFINITION.finditer(_strip_comments(_read(path))):
            returns[m.group(1).lower()] = m.group(2).lower()

    text_calls = set(re.findall(r"rpcText(?:Diagnosed)?\('([\w]+)'\)", conn))
    bool_calls = set(re.findall(r"\bok\('([\w]+)'\)", conn))
    if not text_calls and not bool_calls:
        return ["no rpc calls found in the connectivity suite -- either the "
                "helpers were renamed or this check has stopped checking"]

    problems: list[str] = []
    for name in sorted(text_calls):
        got = returns.get(name.lower())
        if got and got not in TEXT_RETURNS:
            problems.append(
                "the suite calls %s() through rpcText/rpcTextDiagnosed, which "
                "requires a String, but it RETURNS %s. The call does not fail "
                "outright -- the helper reports 'returned %s, not a String', "
                "which reads like the database refused to answer. Use ok()."
                % (name, got, got))
    for name in sorted(bool_calls):
        got = returns.get(name.lower())
        if got and got not in BOOL_RETURNS:
            problems.append(
                "the suite calls %s() through ok(), which requires a boolean, "
                "but it RETURNS %s. Use rpcText/rpcTextDiagnosed() so the CI "
                "log shows the live values it measured."
                % (name, got))
    return problems


# 3. every Edge Function the client invokes is deployed by the workflow
# ---------------------------------------------------------------------------
def check_edge_functions_deployed() -> list[str]:
    """ARCHITECTURE.md 5.6: a function in supabase/functions/ is NOT deployed
    unless deploy-supabase.yml has a step for it. "Change password" and
    "approve account deletion" both shipped calling a function that did not
    exist. This is the check that would have caught both.
    """
    problems: list[str] = []
    workflow = _read(DEPLOY_WORKFLOW)
    if not workflow:
        return [f"{DEPLOY_WORKFLOW.relative_to(ROOT)} is missing"]

    # generic invoker: functions.invoke(<variable>) cannot be resolved.
    invoked = literal_calls(r"\.invoke\(\s*'([^']+)'")
    if not invoked:
        problems.append("no literal functions.invoke('...') calls found -- did the client move?")

    for name in sorted(invoked):
        if not (FUNCTIONS / name / "index.ts").is_file():
            problems.append(
                "supabase/functions/%s/index.ts is missing -- invoked from %s"
                % (name, ", ".join(sorted(invoked[name])))
            )
        if not re.search(r"functions\s+deploy\s+%s\b" % re.escape(name), workflow):
            problems.append(
                "%s is called from the app but has no deploy step in "
                "deploy-supabase.yml -- it will not exist in production"
                % name
            )

    # ...and the other direction: a function on disk that never deploys.
    for directory in sorted(p for p in FUNCTIONS.iterdir() if p.is_dir()):
        if directory.name == "_shared":
            continue
        if not re.search(r"functions\s+deploy\s+%s\b" % re.escape(directory.name), workflow):
            problems.append(
                "supabase/functions/%s/ exists but deploy-supabase.yml never "
                "deploys it" % directory.name
            )
    problems.extend(_pre_auth_functions_must_skip_jwt(workflow))
    return problems


# Functions the client calls BEFORE it has a session. The gateway refuses an
# anonymous request to a function deployed with the default verify_jwt=true,
# so deploying one of these without --no-verify-jwt makes it permanently
# unreachable and every caller fails. login-gate shipped exactly that way: the
# workflow deployed it with verification ON while its own header says it "must
# run BEFORE the credential check is even attempted", so the gate never ran
# and no login in the app could complete.
#
# The list is here, in the harness, rather than inferred: inferring it from
# the function source would need to decide whether a given function is
# pre-auth, and that judgement belongs next to the thing that gets deployed.
PRE_AUTH_FUNCTIONS = {
    "login-gate": "CAPTCHA + lockout gate; runs before the credential check",
    "staff-login": "staff credential check; the caller has no session yet",
    "index-chunks": "unauthenticated repository indexing",
}


def _pre_auth_functions_must_skip_jwt(workflow: str) -> list[str]:
    problems: list[str] = []
    for name, why in sorted(PRE_AUTH_FUNCTIONS.items()):
        m = re.search(r"functions\s+deploy\s+%s\b([^\n]*)" % re.escape(name), workflow)
        if not m:
            # Already reported by the catalogue check above; not this check's
            # business to say it twice.
            continue
        if "--no-verify-jwt" not in m.group(1):
            problems.append(
                "%s is a pre-authentication endpoint (%s) but its deploy step "
                "does not pass --no-verify-jwt, so the gateway rejects every "
                "anonymous call with a 401 before the function body runs"
                % (name, why)
            )
    return problems


# ---------------------------------------------------------------------------
# 4. every route the app navigates to is a defined route
# ---------------------------------------------------------------------------
def _parse_dart_literal(text: str, i: int) -> tuple[str, int] | None:
    """Read the single-quoted Dart string starting at text[i] -> (value, end).

    Interpolations are copied verbatim on purpose. `${...}` may itself
    contain quotes and braces -- `/admin/providers/${p['id']}/wallet` -- so a
    regex over `'...'` truncates the path at the inner quote and invents a
    dead route that does not exist.
    """
    if i >= len(text) or text[i] != "'":
        return None
    i += 1
    out: list[str] = []
    while i < len(text):
        ch = text[i]
        if ch == "\\":
            out.append(text[i:i + 2])
            i += 2
            continue
        if ch == "'":
            return "".join(out), i + 1
        if ch == "$" and i + 1 < len(text) and text[i + 1] == "{":
            depth = 0
            out.append("${")
            i += 2
            while i < len(text):
                c = text[i]
                out.append(c)
                if c == "{":
                    depth += 1
                elif c == "}":
                    if depth == 0:
                        i += 1
                        break
                    depth -= 1
                i += 1
            continue
        out.append(ch)
        i += 1
    return None


NAV_RX = re.compile(
    r"(?:context\.(?:go|push|replace)|GoRouter\.of\(context\)\.(?:go|push))"
    r"(?:<[^>]*>)?\(\s*'"
)


def nav_targets() -> dict[str, set[str]]:
    """Every literal route the app navigates to -> the files that do it."""
    hits: dict[str, set[str]] = {}
    for path in dart_sources():
        text = _read(path)
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        for m in NAV_RX.finditer(text):
            parsed = _parse_dart_literal(text, m.end() - 1)
            if parsed:
                hits.setdefault(parsed[0], set()).add(rel)
    return hits


def _wildcard_nav(target: str) -> str:
    """`/user/orders/$orderId` -> `/user/orders/*` (and the same for ${...})."""
    target = target.split("?")[0].split("#")[0]
    out: list[str] = []
    i = 0
    while i < len(target):
        ch = target[i]
        if ch == "$" and i + 1 < len(target) and target[i + 1] == "{":
            depth = 1
            i += 2
            while i < len(target) and depth:
                if target[i] == "{":
                    depth += 1
                elif target[i] == "}":
                    depth -= 1
                i += 1
            out.append("*")
        elif ch == "$":
            i += 1
            while i < len(target) and (target[i].isalnum() or target[i] == "_"):
                i += 1
            out.append("*")
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def _segments(pattern: str) -> list[str]:
    return [s if not s.startswith(":") else "*" for s in pattern.split("/")]


def check_routes_resolve() -> list[str]:
    """A tap that navigates to an undefined path lands on the router's error
    page. The 2026-09-28 audit found 0 dead targets across 82 routes; this
    keeps it that way.

    Only the safe direction is asserted: every nav target must match a
    declared route. Unused routes are NOT reported, because many are
    legitimately reached only by redirect or deep link.
    """
    router = _read(LIB / "routing" / "app_router.dart")
    declared = re.findall(r"path:\s*['\"]([^'\"]*)['\"]", router)
    declared = [p for p in declared if p.startswith("/")]
    if not declared:
        return ["app_router.dart declares no absolute GoRoute paths"]

    patterns = [(_segments(p), p) for p in declared]
    problems: list[str] = []
    found = nav_targets()
    if not found:
        return ["no navigation calls found in lib/ -- did the router API change?"]
    for raw, files in sorted(found.items()):
        target = _wildcard_nav(raw)
        if ":" in target:
            # a path parameter built at runtime that we could not normalise
            continue
        seg = _segments(target)
        if not any(len(seg) == len(p) and
                   all(s == "*" or t == "*" or s == t for s, t in zip(seg, p))
                   for p, _ in patterns):
            problems.append(
                "no GoRoute matches %r -- navigated from %s"
                % (raw, ", ".join(sorted(files)))
            )
    return problems


# ---------------------------------------------------------------------------
# 5. both email gateways still work, including the free one
# ---------------------------------------------------------------------------
def check_email_provider_gateways() -> list[str]:
    """send-otp has two independent ways to send mail, and the second is the
    one that works on a free tier with no card (Brevo).

    Checked against Brevo's published contract (developers.brevo.com,
    "Send a transactional email"): POST /v3/smtp/email, the key in an
    `api-key` header, a `sender` object and a `to` array of objects, and
    exactly one of htmlContent / textContent / templateId. The two ways to
    lose email with no code change are also asserted, because both are
    silent: a provider pair that is only half-set reads as "not configured",
    and Resend wins whenever a leftover RESEND_API_KEY plus OTP_FROM_EMAIL
    are both present, so Brevo is never reached.
    """
    src = _read(FUNCTIONS / "send-otp" / "index.ts")
    if not src:
        return ["send-otp/index.ts is missing"]
    problems: list[str] = []

    for name in ("RESEND_API_KEY", "OTP_FROM_EMAIL", "BREVO_API_KEY", "BREVO_FROM_EMAIL"):
        if f'Deno.env.get("{name}")' not in src:
            problems.append(
                f"send-otp does not read {name}; that gateway is a Python-style "
                "guess about a secret nobody sets"
            )

    # Resend: Bearer token, from/to arrays, `text` body.
    for needle, why in (
        ('fetch("https://api.resend.com/emails"', "the Resend endpoint"),
        ("Authorization: `Bearer ${apiKey}`", "Resend's Bearer auth"),
        ("body: JSON.stringify({ from, to: [to], subject, text })", "Resend's payload shape"),
    ):
        if needle not in src:
            problems.append(f"send-otp: {why} changed or vanished ({needle!r})")

    # Brevo free tier: `api-key` header, sender object, to array, textContent.
    for needle, why in (
        ('fetch("https://api.brevo.com/v3/smtp/email"', "the Brevo endpoint"),
        ('"api-key": apiKey', "Brevo's api-key header"),
        ("sender: { email: from },", "Brevo's sender object"),
        ("to: [{ email: to }],", "Brevo's recipient array"),
        ("textContent: text,", "Brevo's text body (exactly one body type per request)"),
    ):
        if needle not in src:
            problems.append(f"send-otp: {why} changed or vanished ({needle!r})")

    if 'Deno.env.get("BREVO_FROM_EMAIL") ?? resendFrom' not in src:
        problems.append(
            "send-otp: BREVO_FROM_EMAIL no longer falls back to OTP_FROM_EMAIL, "
            "so a Brevo user who set only the shared sender address gets "
            "`email_provider_not_configured`"
        )

    # Precedence is a documented decision, not an accident: it has to stay
    # readable, because "why is Brevo not sending?" is answered by it.
    resend_at = src.find("RESEND_API_KEY")
    brevo_at = src.find("BREVO_API_KEY")
    if 0 <= brevo_at < resend_at:
        problems.append(
            "send-otp: Brevo is now tried before Resend, the opposite of what "
            "ARCHITECTURE.md documents"
        )
    if "email_provider_not_configured" not in src:
        problems.append(
            "send-otp: no email_provider_not_configured refusal -- an "
            "unconfigured provider must fail closed, not send silently"
        )

    return problems


# ---------------------------------------------------------------------------
# 6. every table/view the client queries is created by a migration
# ---------------------------------------------------------------------------
def check_data_targets_exist() -> list[str]:
    """A `.from('typo')` is a screen that renders "no data" forever.

    Storage buckets are excluded on purpose: they are reached through
    `storage.from('bucket-name')` and are hyphenated, which no table name in
    this schema is, so `.from('payment-proofs')` is the bucket and
    `.from('payment_proofs')` is the table.
    """
    all_sql = "\n".join(_read(p) for p in migration_files())
    defined = {
        m.group(1).lower()
        for m in re.finditer(
            r"CREATE\s+(?:OR\s+REPLACE\s+)?(?:TABLE|VIEW|MATERIALIZED\s+VIEW)\s+"
            r"(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?\"?([A-Za-z0-9_]+)\"?",
            all_sql,
            re.IGNORECASE,
        )
    }
    problems: list[str] = []
    targets = literal_calls(r"(?<!storage)\.from\(\s*'([^']+)'")
    checked = 0
    for name, files in sorted(targets.items()):
        if "-" in name:
            continue  # a storage bucket
        checked += 1
        if name.lower() not in defined:
            problems.append(
                "lib/ queries public.%s, which no migration creates (from %s)"
                % (name, ", ".join(sorted(files)))
            )
    if checked == 0:
        problems.append("no .from('...') targets found -- did the client change shape?")
    return problems


# ---------------------------------------------------------------------------
# 6b. every storage bucket lib/ uses is created by a migration the deploy
#     workflow actually executes
# ---------------------------------------------------------------------------
# The deploy workflow's `Baseline migration history` step marks every staged file
# whose version is below BASELINE as applied via `migration repair`, and its own
# comment says the step "never executes the files" -- the live database was built
# by pasting SQL into the editor. A bucket whose only creation statement lives in
# one of those files therefore exists only if somebody pasted it by hand.
#
# That is how the provider gallery shipped: `provider-gallery` is declared in
# 0017, its upload path is in provider_gallery_screen.dart, the RPC and the table
# are live -- and every upload failed with "Bucket not found" (404) because the
# bucket was never created. "It has a creation migration" and "it has a creation
# migration the pipeline runs" are different tests, and only the second one is
# about reality.
BASELINE = 20260919000000
BUCKET_CREATE_RX = re.compile(
    r"INSERT\s+INTO\s+storage\.buckets[^;]*;", re.IGNORECASE | re.DOTALL
)
BUCKET_ID_RX = re.compile(r"'([a-z0-9][a-z0-9-]*)'")


#: Buckets lib/ is known to use, so the check below cannot pass vacuously.
#: user-documents, payment-screenshots, payment-proofs, product-images,
#: provider-gallery and vehicle-images. The last one was added in migration 97
#: together with the first Dart code that writes it -- the bucket, the policy
#: and the upload path move together, or the check below is the thing that says
#: so.
EXPECTED_CLIENT_BUCKETS = 7


def dart_buckets() -> tuple[dict[str, set[str]], list[str]]:
    """Every bucket named in lib/, resolving a file's `_bucket` constant.

    `storage.from('provider-gallery')` is read directly; `storage.from(_bucket)`
    reads `static const _bucket = 'provider-gallery'` from the same file. The
    indirect form is not a nicety: the gallery uses it, so a check that only
    understood literals would have skipped the one path that was broken.
    """
    buckets: dict[str, set[str]] = {}
    unresolved: list[str] = []
    for path in dart_sources():
        src = _read(path)
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        consts = {
            m.group(1): m.group(2)
            for m in re.finditer(r"\bconst\s+([A-Za-z_]\w*)\s*=\s*'([^']+)'", src)
            if "ucket" in m.group(1)
        }
        # A non-const declaration means a runtime value, which is known to be
        # legitimate in two places: admin_history_screen derives the bucket from
        # a stored `bucket/path`, and photo_grid is handed one by its caller.
        # Those can only be checked by running the app, so they are skipped
        # rather than guessed at.
        runtime = set(
            re.findall(r"\b(?:final|var|late|String)\s+([A-Za-z_]\w*)\s*=", src)
        )
        for m in re.finditer(r"storage\s*\.\s*from\(([^)]*)\)", src):
            arg = m.group(1).strip()
            if re.fullmatch(r"'[^']+'", arg):
                buckets.setdefault(arg.strip("'"), set()).add(rel)
            elif re.fullmatch(r"[A-Za-z_]\w*", arg):
                if arg in consts:
                    buckets.setdefault(consts[arg], set()).add(rel)
                elif arg in runtime:
                    continue
                else:
                    unresolved.append(
                        "%s: storage.from(%s) is neither a literal nor a "
                        "constant nor a local variable, so which bucket it "
                        "targets cannot be checked" % (rel, arg)
                    )
            # Anything else -- a field, a getter, `item.bucket!` -- is dynamic
            # by design and cannot be resolved without running the app.
    return buckets, unresolved


def _buckets_created_by_the_pipeline() -> dict[str, list[str]]:
    """Bucket id -> the migrations at/after the baseline that create it."""
    created: dict[str, list[str]] = {}
    for path in migration_files():
        version = path.name.split("_", 1)[0]
        if not version.isdigit() or int(version) < BASELINE:
            continue
        for stmt in BUCKET_CREATE_RX.finditer(_read(path)):
            for name in BUCKET_ID_RX.findall(stmt.group(0)):
                created.setdefault(name, []).append(path.name)
    return created


def check_client_buckets_are_created() -> list[str]:
    buckets, problems = dart_buckets()
    created = _buckets_created_by_the_pipeline()
    for name, files in sorted(buckets.items()):
        if name not in created:
            problems.append(
                "lib/ writes to bucket %r (from %s), but no migration at or "
                "after the deploy baseline %d creates it. Older files are "
                "marked applied WITHOUT being executed, so this bucket exists "
                "only if it was pasted into the SQL editor by hand -- and when "
                "it was not, every upload to it fails with 'Bucket not found' "
                "(404). Add it to an INSERT INTO storage.buckets in a current "
                "migration."
                % (name, ", ".join(sorted(files)), BASELINE)
            )
    if len(buckets) < EXPECTED_CLIENT_BUCKETS:
        problems.append(
            "only %d storage bucket(s) were resolved from lib/, fewer than the "
            "%d the client is known to use. A check that reads no buckets "
            "cannot report a missing one -- if a bucket was genuinely removed, "
            "lower EXPECTED_CLIENT_BUCKETS in the same change."
            % (len(buckets), EXPECTED_CLIENT_BUCKETS)
        )
    return problems


# ---------------------------------------------------------------------------
# 6c. every income figure counts every fee the platform charges
# ---------------------------------------------------------------------------
# The three transaction types a fee is written on in wallet_transactions:
#
#   TRANSACTION_FEE  -- deduct_transaction_fee(): orders on STARTED, rides on
#                       COMPLETED
#   SUBSCRIPTION_FEE -- deduct_subscription_fee() and the monthly scheduler
#   RECHARGE         -- approve_wallet_recharge(), which withholds the one-time
#                       provider_registration_fee from the FIRST approved
#                       recharge and records it as platform_fee (gross = amount
#                       paid, net = amount - fee); every later recharge carries
#                       platform_fee = 0
#
# A reader that sums platform_fee while ignoring RECHARGE reports ETB 0.00 on a
# deployment whose providers are still activating -- which is where the admin
# income summary and the dashboard total both were, with no error and no empty
# state, just a confidently wrong number. These three constants and the
# transaction_type filters in lib/ move together.
FEE_TYPES = ("TRANSACTION_FEE", "SUBSCRIPTION_FEE", "RECHARGE")


#: Readers of wallet_transactions.platform_fee that build an income figure, so
#: the check cannot pass vacuously if they are renamed away.
EXPECTED_INCOME_READERS = 2

#: What "building an income figure" looks like: selecting the fee column on its
#: own, or folding/ reducing over it. Deliberately NOT "the file mentions
#: platform_fee" -- admin_transaction_history_screen.dart selects `*` and prints
#: each row's fee (the ledger browser, which already shows RECHARGE rows), and
#: flagging it would have been a false positive.
INCOME_READER_RX = re.compile(
    r"select\(\s*'platform_fee'"
    r"|fold\([^;]{0,200}platform_fee"
    r"|reduce\([^;]{0,200}platform_fee",
    re.DOTALL,
)


def check_income_readers_count_every_fee_type() -> list[str]:
    problems: list[str] = []
    readers = 0
    for path in dart_sources():
        src = _read(path)
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        if "from('wallet_transactions')" not in src or "platform_fee" not in src:
            continue
        if not INCOME_READER_RX.search(src):
            continue
        readers += 1
        # The transaction types this file names, taken from the filter argument
        # rather than from the whole file, so a UI category name cannot be
        # mistaken for a ledger type.
        named: set[str] = set()
        for m in re.finditer(
            r"transaction_type['\"]\s*,?\s*(.{0,160})", src, re.DOTALL
        ):
            named.update(re.findall(r"'([A-Z][A-Z_]{3,})'", m.group(1)))
        missing = [t for t in FEE_TYPES if t not in named]
        if missing:
            problems.append(
                "%s sums wallet_transactions.platform_fee but never queries "
                "transaction_type %s. The one-time activation fee is stored as "
                "platform_fee on a RECHARGE row (approve_wallet_recharge), so "
                "omitting it under-reports income: a deployment whose "
                "providers are still activating renders 0.00 while money has "
                "been collected." % (rel, ", ".join(missing))
            )
    if readers < EXPECTED_INCOME_READERS:
        problems.append(
            "only %d file(s) read wallet_transactions.platform_fee, fewer than "
            "the %d that build an income figure (the admin income summary and "
            "the admin dashboard). Those readers are the contract this check "
            "exists for; if one was genuinely removed, lower "
            "EXPECTED_INCOME_READERS in the same change."
            % (readers, EXPECTED_INCOME_READERS)
        )
    return problems


# ---------------------------------------------------------------------------
# 6d. the activation fee is written where an income reader can see it
# ---------------------------------------------------------------------------
def check_activation_fee_is_recorded_as_income() -> list[str]:
    """The server half of the contract 6c pins on the client.

    check_income_readers_count_every_fee_type() proves the READERS query all
    three fee types. This proves the WRITER puts the activation fee somewhere a
    reader can find. approve_wallet_recharge withholds the one-time
    registration fee from a provider's FIRST approved recharge and records it
    as platform_fee on a RECHARGE row -- gross is what was paid, net is what
    was credited, and the difference is the platform's income. If it stops
    doing that, or writes the fee on a type nothing reads, or stops reading the
    fee from system_settings, the readers keep working and the income quietly
    drops. Same symptom, other end.

    Read from the LAST migration that defines the function, not from the
    earliest: a restatement is what the database ends up with, so a check
    against an earlier copy would keep passing on a function that no longer
    exists. That is the failure the restatement_diff tool exists for, applied
    here to a property rather than to a whole body.

    Deliberately NOT checked: that the notice text quotes the fee. Migration 73
    fixed a hardcoded "100 birr" in that message, and a check on prose would
    pass on a message that contradicts the ledger as long as it still said
    something.
    """
    problems: list[str] = []
    path, sql = last_migration_defining("approve_wallet_recharge")
    if path is None:
        return [
            "no migration defines public.approve_wallet_recharge(), so the "
            "one-time activation fee has no writer at all and RECHARGE rows "
            "carry no platform_fee for any income reader to sum"
        ]
    rel = str(path.relative_to(ROOT)).replace("\\", "/")
    body = function_body(sql, "approve_wallet_recharge")
    if not body:
        return [
            "could not read the body of approve_wallet_recharge() out of %s, "
            "so whether it records the activation fee as income cannot be "
            "checked" % rel
        ]

    if "'RECHARGE'" not in body:
        problems.append(
            "approve_wallet_recharge() in %s no longer writes a 'RECHARGE' "
            "ledger row, and that row is where every income reader finds the "
            "withheld activation fee" % rel
        )

    # The withheld amount itself. The fee is an expression over what was paid,
    # not a constant: gross is v_recharge.amount and net is v_credit, so
    # platform_fee must be their difference. A literal 0 here is exactly the
    # shape that made admin income render ETB 0.00 while money had been
    # collected.
    if not re.search(
        r"amount\s*-\s*v_credit[\s\S]{0,400}?platform_fee"
        r"|platform_fee[\s\S]{0,400}?amount\s*-\s*v_credit",
        body,
    ):
        problems.append(
            "the RECHARGE insert in approve_wallet_recharge() (%s) does not "
            "record platform_fee as the withheld part of the payment "
            "(v_recharge.amount - v_credit), so the platform can keep money "
            "that no income figure counts" % rel
        )

    if "provider_registration_fee" not in body:
        problems.append(
            "approve_wallet_recharge() in %s no longer reads "
            "provider_registration_fee from system_settings, so the activation "
            "fee stopped being data-driven" % rel
        )

    # A literal in place of the setting: the CEO changes the fee and the charge
    # keeps using the old number. This is the regression 73 fixed in the notice
    # text, and it is worth failing on in the arithmetic too.
    if re.search(r"v_reg_fee\s*:?=\s*\d", body):
        problems.append(
            "approve_wallet_recharge() in %s assigns a numeric literal to "
            "v_reg_fee, so the registration fee no longer follows the "
            "provider_registration_fee setting" % rel
        )

    return problems


# ---------------------------------------------------------------------------
# 7. CEO -> staff -> admin -> provider -> user is wired on both sides
# ---------------------------------------------------------------------------
def check_role_permission_wiring() -> list[str]:
    """The five-way chain, checked end to end at source level.

    The router decides a landing page from the session; the database decides
    everything that matters afterwards. A route without a server-side check
    is decoration, and a role with no landing page is an account that cannot
    sign in. Both directions are asserted.
    """
    problems: list[str] = []

    auth = _read(LIB / "core" / "providers" / "auth_provider.dart")
    m = re.search(r"enum\s+AppUserRole\s*\{([^}]*)\}", auth)
    if not m:
        problems.append("auth_provider.dart: AppUserRole is gone")
    else:
        roles = [r.strip() for r in m.group(1).split(",") if r.strip()]
        expected = ["user", "vehicleProvider", "serviceProvider", "admin"]
        if roles != expected:
            problems.append(
                "AppUserRole is [%s]; ARCHITECTURE.md 5.4 pins the four as [%s]"
                % (", ".join(roles), ", ".join(expected))
            )

    router = _read(LIB / "routing" / "app_router.dart")
    declared = set(re.findall(r"path:\s*['\"]([^'\"]*)['\"]", router))
    for route in ("/staff/dashboard", "/staff/login", "/admin", "/ceo",
                  "/vehicle", "/provider", "/user", "/pending-approval",
                  "/rejected", "/suspended"):
        if route not in declared:
            problems.append(f"the {route} route is gone")

    dm = re.search(
        r"String\s+_getDashboardPath\(AuthState\s+\w+\)\s*\{(.*?)\n\}",
        router,
        re.DOTALL,
    )
    if not dm:
        problems.append(
            "app_router.dart: _getDashboardPath is gone, so no role reaches a "
            "landing page"
        )
    else:
        body = dm.group(1)
        for path in re.findall(r"return\s*'([^']+)'", body):
            if path not in declared:
                problems.append(
                    f"_getDashboardPath lands on {path!r}, which is not a declared GoRoute"
                )
        for token, who in (
            ("isStaffMember", "the staff gateway"),
            ("isAdmin", "admin"),
            ("vehicleProvider", "vehicle providers"),
            ("serviceProvider", "service providers"),
        ):
            if token not in body:
                problems.append(f"_getDashboardPath no longer branches on {token} ({who})")

    all_sql = "\n".join(_read(p) for p in migration_files())
    for fn in ("is_admin", "is_ceo", "is_super_admin", "staff_has_permission", "admin_can"):
        if not re.search(r"FUNCTION\s+public\.%s\s*\(" % re.escape(fn), all_sql, re.I):
            problems.append(
                f"public.{fn}() is gone; the route is now the only thing holding it"
            )
    return problems


# ---------------------------------------------------------------------------
# 8. controllers, focus nodes, timers and subscriptions are released
# ---------------------------------------------------------------------------
def _is_released(text: str, name: str, releaser: str) -> bool:
    if re.search(r"\b%s\s*\??\s*\.\s*%s\s*\(" % (re.escape(name), releaser), text):
        return True
    # a collection released in a loop: for (final c in _controllers) c.dispose();
    for loop in re.finditer(r"for\s*\([^)]*\bin\s+%s\b[^)]*\)" % re.escape(name), text):
        if re.search(r"\.\s*%s\s*\(" % releaser, text[loop.end():loop.end() + 400]):
            return True
    return False


def check_lifecycle_hygiene() -> list[str]:
    """A controller or subscription nobody releases leaks the screen.

    Only fields are checked (names starting with `_`): a local timer inside a
    debounce closure is released through the closure's own disposable, and
    flagging those produces noise that hides real leaks.
    """
    problems: list[str] = []
    resource_rx = (
        (r"(?:final|late\s+final|late|var)\s+(_\w+)\s*=\s*TextEditingController\(",
         "dispose", "TextEditingController"),
        (r"(?:final|late\s+final|late|var)\s+(_\w+)\s*=\s*FocusNode\(",
         "dispose", "FocusNode"),
        (r"(?:final|late\s+final|late|var)\s+(_\w+)\s*=\s*List<TextEditingController>",
         "dispose", "TextEditingController list"),
        (r"(?:final|late\s+final|late)\s+StreamSubscription\s*<[^>]*>\??\s+(_\w+)\s*;",
         "cancel", "StreamSubscription"),
        (r"(?:final|late\s+final|late)\s+StreamSubscription\??\s+(_\w+)\s*;",
         "cancel", "StreamSubscription"),
        (r"(?:final|late\s+final|late)\s+Timer\??\s+(_\w+)\s*;",
         "cancel", "Timer"),
    )
    for path in dart_sources():
        text = _read(path)
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        for rx, releaser, kind in resource_rx:
            for m in re.finditer(rx, text):
                name = m.group(1)
                if not _is_released(text, name, releaser):
                    problems.append(
                        f"{rel}: {kind} {name} is created but never .{releaser}()d"
                    )
    return problems


# ---------------------------------------------------------------------------
# 8b. the two reported product flows, pinned at the source level
# ---------------------------------------------------------------------------
def _method_body(text: str, signature_rx: str) -> str:
    """The text of one Dart method, from its body brace to the brace that
    closes it. Brace counting, not a regex: the bodies under test are long
    and full of nested blocks, and a `\\n  }` match would truncate them.

    The parameter list is skipped first, and this is not a detail. A Dart
    signature with named parameters opens its own brace --
    `Future<void> signIn({required String email, ...}) {` -- so taking the
    first `{` after the signature name returns the PARAMETER LIST and every
    check written against the body silently inspects the wrong text. That is
    exactly the failure mode this file's own header warns about: a test that
    flatters the code it tests.
    """
    m = re.search(signature_rx, text)
    if not m:
        return ""
    i = m.end()
    # Skip the parameter list, brace- and paren-balanced.
    while i < len(text) and text[i] in " \t\r\n":
        i += 1
    if i < len(text) and text[i] == "(":
        depth = 0
        while i < len(text):
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            i += 1
    brace = text.find("{", i)
    if brace < 0:
        return ""
    depth = 0
    for j in range(brace, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[brace:j + 1]
    return text[brace:]


def check_availability_payment_flow() -> list[str]:
    """The availability gate has to END somewhere.

    Migration 74 built the gate and the screens rendered it correctly: the
    buyer was told to wait, the provider got a "Confirm Availability"
    button, and payment details appeared once the order was ACCEPTED. The
    chain still did not close, because ACCEPTED -> PAYMENT_PENDING was
    provider-or-admin only. The order sat at ACCEPTED with the accounts on
    screen and no button anywhere, so the buyer could never attach a receipt
    unless the provider happened to open their own order list and press
    "Request Payment".

    Three things have to hold, and each decays on its own:

      1. the order-level gate migration exists and both columns still exist;
      2. the buyer can act once the provider has confirmed (migration 85);
      3. the accounts to pay into and the button that attaches the receipt
         are rendered together, not at opposite ends of a long scroll.
    """
    problems: list[str] = []
    screen = _read(LIB / "features" / "user" / "user_order_detail_screen.dart")
    if not screen:
        return ["lib/features/user/user_order_detail_screen.dart is missing"]

    # ── 1. the server side ──
    all_sql = "\n".join(_read(p) for p in migration_files())
    for token, why in (
        ("orders.requires_availability_confirmation",
         "has no per-order snapshot for the client to read"),
        ("v_buyer_may_open_payment",
         "has no clause letting a gated buyer open the payment step"),
        ("assert_gated_buyer_payment_request_is_wired",
         "has nothing asserting that clause is still present"),
    ):
        if token not in all_sql:
            problems.append(
                "%s is gone from supabase/migrations, so the availability "
                "gate %s" % (token, why)
            )

    # ── 2. the client offers the buyer the step ──
    body = _method_body(screen, r"bool\s+get\s+_awaitingMyPayment\b")
    if not body:
        problems.append(
            "user_order_detail_screen.dart has no _awaitingMyPayment getter, "
            "so nothing decides when the buyer may pay"
        )
    else:
        flat = re.sub(r"\s+", " ", body)
        if "'ACCEPTED'" not in flat:
            problems.append(
                "_awaitingMyPayment does not consider ACCEPTED, so a gated "
                "order is not payable until the provider makes a SECOND move "
                "(ACCEPTED -> PAYMENT_PENDING). The buyer is left looking at "
                "payment details with no button"
            )
        if "_needsAvailabilityConfirmation" not in flat:
            problems.append(
                "_awaitingMyPayment ignores requires_availability_confirmation, "
                "so the widened step would apply to un-gated orders too and "
                "change behaviour for orders that work today"
            )

    # The submit must actually perform the hop, or the button is a no-op that
    # the server refuses.
    submit = _method_body(screen, r"Future<void>\s+_submitPayment\b")
    if not submit:
        problems.append("user_order_detail_screen.dart has no _submitPayment")
    else:
        flat = re.sub(r"\s+", " ", _strip_comments(submit))
        if "'PAYMENT_PENDING'" not in flat:
            problems.append(
                "_submitPayment never moves the order to PAYMENT_PENDING, so a "
                "gated order confirmed at ACCEPTED cannot reach the state a "
                "payment proof is submitted from"
            )
        if "'PAYMENT_VERIFICATION'" not in flat:
            problems.append(
                "_submitPayment never moves the order to PAYMENT_VERIFICATION, "
                "so the proof is attached and no admin ever sees the order"
            )

    # ── 3. the details and the action are one card ──
    if "_paymentStepCard" not in screen:
        problems.append(
            "the order screen no longer builds a combined payment step; the "
            "accounts to pay into and the upload button must render together"
        )
    card = _method_body(screen, r"Widget\s+_paymentStepCard\b")
    if card and "PAY & UPLOAD PROOF" not in card:
        problems.append(
            "_paymentStepCard does not contain the upload button, so the "
            "buyer is told where to pay with no way to attach the receipt"
        )
    card_flat = re.sub(r"\s+", " ", _strip_comments(card)) if card else ""
    if card and "_awaitingMyPayment" not in card_flat:
        problems.append(
            "_paymentStepCard is not gated on _awaitingMyPayment, so the "
            "upload button would show before the provider has confirmed"
        )
    return problems


def check_login_reports_its_own_outcome() -> list[str]:
    """A login screen that accepts the credentials and then says nothing is
    indistinguishable from one that rejects them.

    The email path awaited signInWithPassword and returned. It never cleared
    _isLoading on the success path, so between "session established" and
    "profile loaded" -- a window the router deliberately sits in, retrying --
    the button was disabled and said nothing. If the profile load then failed,
    the single retry was not enough and the user was stuck on a dead LOGIN
    button: the reported "the login screen does not accept the account the
    admin approved".
    """
    problems: list[str] = []
    path = LIB / "features" / "auth" / "login_screen.dart"
    screen = _read(path)
    if not screen:
        return ["lib/features/auth/login_screen.dart is missing"]

    body = _method_body(screen, r"Future<void>\s+_handleLogin\b")
    if not body:
        return ["login_screen.dart has no _handleLogin"]
    flat = re.sub(r"\s+", " ", _strip_comments(body))

    if "_awaitAccountLoaded" not in flat:
        problems.append(
            "_handleLogin does not wait for the account to load after a "
            "successful sign-in, so the button can stay disabled with no "
            "message when the profile load fails"
        )
    if "_isLoading = false" not in body:
        problems.append(
            "_handleLogin never sets _isLoading = false, so a failed attempt "
            "leaves the LOGIN button permanently spinning"
        )

    # A wrong password and a downed gate are different problems with different
    # fixes. Reporting one as the other sends the user (and support) the wrong
    # way: the canonical example is telling somebody to change a perfectly
    # good password because the security service was unreachable.
    if "Sign-in is temporarily unavailable" not in screen:
        problems.append(
            "login_screen.dart has no message for an unavailable login gate, "
            "so a gate outage is reported as a credential failure"
        )

    # The copy-paste that shipped: a rejected PASSWORD labelled itself a
    # Google sign-in, and splash_screen renders state.error verbatim.
    provider = _read(LIB / "core" / "providers" / "auth_provider.dart")
    # `signIn\b` and not `signInWithGoogle`: the word boundary is what keeps
    # this from matching the OAuth method one declaration below.
    sign_in = _method_body(provider, r"Future<void>\s+signIn\b")
    if sign_in and "Google" in _strip_comments(sign_in):
        problems.append(
            "auth_provider.signIn (the email+password path) mentions Google "
            "in its error context; splash_screen renders state.error "
            "verbatim, so a wrong password is reported as a Google failure"
        )
    return problems
def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    # `//` after a `:` is a URL, not a comment.
    return re.sub(r"(?m)(?<![:\w])//[^\n]*", "", text)


def _strip_mappers(text: str) -> str:
    """Remove `*Error(...)`-style wrappers, balanced, so the raw argument
    inside them is not mistaken for text rendered to a user.

    This project's mappers are named for what they do -- `friendlyError`,
    `_passwordError`, `_friendlyError` -- and all of them take the raw error
    and return a sentence. Anything passed through one is safe by design;
    only text that reaches `Text()` unmapped is not.
    """
    out: list[str] = []
    i = 0
    rx = re.compile(r"[A-Za-z_]*[Ee]rror\(")
    while True:
        m = rx.search(text, i)
        if not m:
            out.append(text[i:])
            break
        out.append(text[i:m.start()])
        depth = 1
        j = m.end()
        while j < len(text) and depth:
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
            j += 1
        i = j
    return "".join(out)


def check_error_handling_wiring() -> list[str]:
    """ARCHITECTURE.md 1.2: one classifier, a durable sink, an error
    boundary, and zero direct renderings of an exception in lib/.

    That last one is asserted, because it is the property that decays
    silently -- a raw PostgrestException in a snackbar is unreadable and
    leaks schema detail, and it arrives one `catch` at a time.
    """
    problems: list[str] = []

    for rel, why in (
        ("lib/core/resilience/failure_mapper.dart", "the single classifier"),
        ("lib/core/resilience/safe_call.dart", "safeCall/withRetry"),
        ("lib/core/services/error_logger.dart", "the error sink writer"),
        ("lib/core/widgets/app_error_boundary.dart", "the error boundary"),
        ("lib/core/widgets/load_error_view.dart", "the load-failure view"),
        ("lib/core/utils/friendly_error.dart", "friendlyError"),
    ):
        if not (ROOT / rel).is_file():
            problems.append(f"{rel} is missing ({why})")

    all_sql = "\n".join(_read(p) for p in migration_files())
    if "client_error_logs" not in all_sql:
        problems.append("the client_error_logs sink table is gone")
    if "assert_resilience_is_wired" not in all_sql:
        problems.append("assert_resilience_is_wired() is gone; nothing asserts the wiring")

    bootstrap = _read(LIB / "core" / "bootstrap.dart")
    for token, why in (
        ("AppErrorBoundary", "the root error boundary"),
        ("ErrorLogger", "the root error sink"),
    ):
        if token not in bootstrap:
            problems.append(f"core/bootstrap.dart no longer wires {why} ({token})")
    if "SupabaseService.init()" not in bootstrap and "Supabase.initialize" not in bootstrap:
        problems.append("core/bootstrap.dart never initialises Supabase")

    raw_rx = re.compile(
        r"\be\.toString\(\)|\berror\.toString\(\)|\bex\.toString\(\)"
        r"|\$\{e\}|\$e\b|\$\{error\}|\$error\b"
    )
    for path in dart_sources():
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        text = _strip_mappers(_strip_comments(_read(path)))
        for m in re.finditer(r"Text\(", text):
            depth = 1
            j = m.end()
            while j < len(text) and depth:
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                j += 1
            window = text[m.end():j]
            hit = raw_rx.search(window)
            if not hit:
                continue
            # A diagnostic behind `if (kDebugMode)` never ships: it is a
            # developer affordance on the crash screen, not user-facing text.
            if "kDebugMode" in text[max(0, m.start() - 400):m.start()]:
                continue
            problems.append(
                f"{rel}: a raw exception is rendered to the user ({hit.group(0)!r}); "
                "use friendlyError()"
            )
    return problems


# ---------------------------------------------------------------------------
# 10. the names ARCHITECTURE.md builds its argument on still exist
# ---------------------------------------------------------------------------
def check_documented_components_exist() -> list[str]:
    """ARCHITECTURE.md is the source of truth, so a component it names must
    be a component that exists.

    Checked in both directions on purpose. The doc had drifted to calling
    `ResilientFeed` (lib/core/services/safe_realtime.dart) by the name
    `SafeRealtimeFeed`, which appears nowhere in lib/ -- and a reader who then
    searched for it would find nothing and conclude the file was missing
    rather than renamed. A rename in either the code or the doc now fails
    here.
    """
    documented = [
        "AppFailureMapper", "AppFailure", "safeCall", "RetryPolicy",
        "ErrorLogger", "AppErrorBoundary", "ResilientFeed",
        "ResilientSubscription", "AsyncView", "LoadErrorView", "RetryWidget",
        "friendlyError", "staff_has_permission", "is_ceo", "is_admin",
        "signup_otp_required", "client_error_logs", "vehicle_images",
    ]
    doc = _read(ROOT / "docs" / "ARCHITECTURE.md")
    if not doc:
        return ["docs/ARCHITECTURE.md is missing"]

    everything = "\n".join(
        _read(p) for p in list(dart_sources()) + migration_files()
    ) + "\n".join(
        _read(p) for p in sorted(FUNCTIONS.glob("*/index.ts"))
    )

    problems: list[str] = []
    for name in documented:
        in_doc = name in doc
        in_code = name in everything
        if in_doc and not in_code:
            problems.append(
                f"ARCHITECTURE.md names {name}, which appears nowhere in lib/, "
                "supabase/ or the Edge Functions -- renamed or deleted?"
            )
        elif in_code and not in_doc:
            problems.append(
                f"{name} exists in the code but ARCHITECTURE.md never mentions "
                "it -- the doc has fallen behind the tree"
            )
    return problems


def check_transaction_notifications() -> list[str]:
    """Money and approval events notify both parties, exactly once, and a
    failed notice cannot roll back the payment.

    The bugs this catches, all of which are silent:
      * a message written somewhere nobody reads, because the app has no
        surface for it,
      * a notification insert inside a money function with no error handling,
        so an undeliverable notice rolls back a real payment,
      * a message that claims money moved when it did not (the ride
        commission is DEBITED; a wallet is never credited on completion),
      * a dedupe key that is not actually derived from the event, so a retry
        notifies twice or two different events collide on one key.
    """
    problems: list[str] = []
    all_sql = "\n".join(_read(p) for p in migration_files())
    new_sql = "\n".join(
        _read(p) for p in migration_files()
        if p.name >= "20260927000086"
    )

    # 1. The shared call site exists and does the two things it promises.
    if "notify_user_once" not in all_sql:
        problems.append("no notify_user_once() call site: money notifications "
                        "have no idempotent, failure-isolated helper")
    else:
        path, sql = last_migration_defining("notify_user_once")
        body = function_body(sql, "notify_user_once")
        body_l = body.lower()
        # The dedupe check itself, not just the key: a helper that takes a lock
        # but never reads the table notifies twice on a retry.
        if "data ->> 'idem_key'" not in body_l and \
           "data->>'idem_key'" not in body_l:
            problems.append("notify_user_once() no longer checks for an "
                            "existing row for the key, so a retried payment "
                            "notifies twice")
        # It must check BOTH delivery tables. notify_user() writes to
        # notifications on the server path and to notification_outbox on the
        # client path; the outbox row does not reach notifications until the
        # cron drain. A dedupe that reads only notifications therefore misses
        # every client-path notification — and the connectivity suite runs as
        # anon, so that is not a corner case, it is the normal case.
        if "notification_outbox" not in body_l:
            problems.append(
                "notify_user_once() deduplicates against notifications only. "
                "notify_user() queues client-path notifications in "
                "notification_outbox and they do not reach notifications until "
                "pg_cron drains them, so a retried call on that path finds no "
                "existing row and queues the same message a second time. The "
                "connectivity suite runs as anon, so this is the path it "
                "exercises.")
        # Dedupe must be under a lock. Checking for the key alone passes on a
        # body that reads-then-writes, which is the race it exists to prevent.
        if "pg_advisory_xact_lock" not in body_l:
            problems.append("notify_user_once() dedupes without taking a lock, "
                            "so two concurrent calls both pass the check and "
                            "both write")
        if "exception" not in body_l:
            problems.append("notify_user_once() has no exception handler, so a "
                            "failed notification insert would roll back the "
                            "money movement it is attached to")
        if "raise warning" not in body_l:
            problems.append("notify_user_once() swallows failures without "
                            "logging them, making them invisible")
        # A client that could call this could notify any user id.
        if "revoke all on function public.notify_user_once" not in sql.lower():
            problems.append("notify_user_once() is not revoked from the client "
                            "roles; a client could notify any user")

    # 2. Both parties are notified on the two money events. A buyer-only or
    #    provider-only regression is the specific failure this feature fixes.
    #
    #    Every needle below is searched in the FUNCTION BODY, lowercased, and
    #    never in the whole migration file. Two earlier versions of this check
    #    did search the file, and both were vacuous: each migration carries the
    #    assert_* function that names these same strings, so disabling the real
    #    call left the string sitting in the assertion and the check stayed
    #    green. A check that passes on broken input is worse than none.
    # 5. The claim the brief got wrong. Completing a ride DEBITS the platform
    #    commission via deduct_transaction_fee; the fare is settled outside the
    #    app and never credited to a wallet. A message saying money was added
    #    contradicts the wallet screen immediately.
    #
    #    Checked against the notifier bodies only. Searching the raw migration
    #    text matches the COMMENT that explains why the message is not written
    #    that way, which is the opposite of the finding being looked for.
    def _body(name: str) -> str:
        path, sql = last_migration_defining(name)
        return function_body(sql, name).lower() if path else ""

    # 7. A plpgsql FOREACH may not iterate with an array-typed loop variable.
    #
    #    plpgsql refuses it at run time with 42804, and nothing catches it
    #    earlier: CREATE FUNCTION does not parse a plpgsql body, db push
    #    succeeds, and the privilege check passes because the function exists
    #    and is executable. Only calling it raises — so the assertion silently
    #    stops asserting, which is the most expensive way to fail.
    #
    #    The static approximation: find FOREACH loops and confirm the loop
    #    variable is not declared as an array type in the same file.
    foreach_rx = re.compile(r"FOREACH\s+(\w+)\s+IN\s+ARRAY", re.IGNORECASE)
    defn_rx = re.compile(
        r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?(\w+)\s*\(",
        re.IGNORECASE)
    # Only the CURRENT definition of each function is judged. A migration that
    # restated a function to fix it must not leave the harness permanently red
    # on the superseded body — that trains people to ignore it, and the fix
    # itself is what the check is asking for.
    all_fns: set[str] = set()
    for path in migration_files():
        all_fns.update(m.group(1) for m in defn_rx.finditer(_read(path)))

    for fn in sorted(all_fns):
        latest, sql = last_migration_defining(fn)
        if not sql:
            continue
        body = function_body(sql, fn)
        if not body:
            continue
        for f in foreach_rx.finditer(body):
            var = f.group(1)
            if re.search(r"\b%s\s+[a-z_]+\[\]" % re.escape(var), body,
                         re.IGNORECASE):
                problems.append(
                    f"{fn}() (last defined in {latest.name}) does FOREACH "
                    f"{var} IN ARRAY ... but {var} is declared as an array. "
                    f"plpgsql refuses an array-typed FOREACH loop variable at "
                    f"run time (42804) and CREATE FUNCTION will not catch it, "
                    f"so the function deploys and then raises on every call. "
                    f"Use a subscripted FOR i IN 1 .. array_length(x, 1) loop "
                    f"instead.")

    # 8. Declared source needles must occur in the bodies they inspect.
    #
    #    Two needles in this series were wrong and each reported a defect that
    #    did not exist, on every run, until a live run caught it: one was
    #    sensitive to line wrapping, one had a typo (v_ledgerid). The assertion
    #    is the thing that is broken in both cases, so nothing else in CI can
    #    notice. The live function declares the needles; this reads the same
    #    declaration so the typo is caught before a deploy rather than a cycle
    #    after one.
    #
    #    Read from the CURRENT definition of assert_source_needles_match, not
    #    from a hardcoded migration. The declaration moved from a 2-D ARRAY
    #    table (0093/0094) to two parallel 1-D arrays (0095), and pinning a
    #    filename would have quietly checked a superseded list.
    path, sql = last_migration_defining("assert_source_needles_match")
    if not sql:
        problems.append("assert_source_needles_match() is not defined, so the "
                        "declared source needles are never verified")
    else:
        body = function_body(sql, "assert_source_needles_match")

        def _declared(var: str) -> list[str]:
            """Entries of `var text[] := ARRAY[ ... ];`, in order.

            Scoped to the array literal rather than matching every lone quoted
            line in the body: a looser pattern also matched the string
            fragments in the failure messages, and reported 16 needles against
            9 targets.
            """
            m = re.search(
                r"%s\s+text\[\]\s*:=\s*ARRAY\[(.*?)\]\s*;" % re.escape(var),
                body, re.DOTALL)
            if not m:
                return []
            return [e.replace("''", "'")
                    for e in re.findall(r"'((?:[^']|'')*)'", m.group(1))]

        needles = _declared("v_needles")
        targets = _declared("v_targets")
        if not needles or not targets:
            problems.append(
                f"the declared needle list in {path.name} is empty or "
                f"unparseable ({len(needles)} needles, {len(targets)} "
                f"targets), so no needle is being verified")
        elif len(needles) != len(targets):
            problems.append(
                f"the needle and target lists in {path.name} are different "
                f"lengths ({len(needles)} vs {len(targets)}), so needles "
                f"would be checked against the wrong functions")
        else:
            for lit, fn in zip(needles, targets):
                needle = lit.replace("''", "'")
                target = _body(fn)
                if not target:
                    problems.append(f"declared needle {needle!r} names {fn}(), "
                                    f"which is not defined")
                    continue
                if needle.replace(" ", "") not in target.replace(" ", ""):
                    problems.append(
                        f"declared needle {needle!r} does not occur in "
                        f"{fn}(). An assertion comparing against text that is "
                        f"not there reports defects that do not exist and "
                        f"passes when it should fail; this exact typo shipped "
                        f"once (v_ledgerid for v_ledger_id).")


    order_src = _body("fn_notify_order_status_change")
    if not order_src:
        problems.append("fn_notify_order_status_change() not found")
    else:
        if "order-payment-verified:" not in order_src:
            problems.append("the buyer no longer gets a payment-confirmed "
                            "notification on order APPROVED")
        if "order-payment-received:" not in order_src:
            problems.append("the provider no longer gets a payment-received "
                            "notification on order APPROVED (both parties are "
                            "the requirement)")

    ride_src = _body("fn_notify_ride_status_change")
    if not ride_src:
        problems.append("fn_notify_ride_status_change() not found")
    else:
        if "ride-completed:" not in ride_src:
            problems.append("the rider no longer gets a trip-completed notice")
        if "ride-completed-driver:" not in ride_src:
            problems.append("the driver no longer gets a trip-completed notice")
        # A trigger that fires on an unchanged status re-notifies on every
        # unrelated write to the row (the fee and updated_at writes).
        if "is not distinct from old.status" not in ride_src:
            problems.append("the ride trigger lost its 'no status change' "
                            "guard, so unrelated row updates re-notify")

    # 3. Source-matching assertions must not be sensitive to line wrapping.
    #    Two assertions written in this series compared a hand-typed needle
    #    against whitespace-normalised prosrc and so reported defects that did
    #    not exist, purely because of where the author had wrapped a line.
    #    The rule the live database taught: match on the key, with whitespace
    #    removed on both sides, not on a formatted string.
    # A substring check against prosrc is fine for a single token
    # ('pg_advisory_xact_lock'); it is only the KEY match that broke, because a
    # key is written across a line break in the source and the needle was not.
    # So the rule is narrow: an assertion that embeds a multi-token SQL
    # expression (a quoted fragment with an operator) inside a position() call
    # must compare against a whitespace-stripped copy.
    #
    # The fragment is `''`-aware: SQL doubles an embedded quote, so the real
    # needle reads 'points-convert:''||v_ledger_id' and a plain [^']* stops at
    # the first doubled quote and never matches. That blindness is why the
    # mutation below went unnoticed until this was fixed.
    # Structural rather than regex-per-needle: SQL doubles an embedded quote,
    # so a needle like 'points-convert:''||v_ledger_id' cannot be matched by a
    # pattern that assumes one closing quote. Scanning the position() call and
    # asking two questions about it is immune to that.
    call_rx = re.compile(r"position\((.*?)\)", re.IGNORECASE | re.DOTALL)
    for name in ("assert_points_conversion_notifies",
                 "assert_notification_inbox_is_owner_only",
                 "assert_order_and_ride_receipts_are_sent",
                 "assert_approval_welcome_covers_all_paths",
                 "assert_notify_user_once_is_idempotent"):
        path, sql = last_migration_defining(name)
        if not path:
            problems.append(f"{name}() not found")
            continue
        for m in call_rx.finditer(sql):
            call = m.group(1)
            if "||" not in call:
                continue  # a single token, safe against line wrapping
            compared = re.search(r"\bIN\s+(\w+)\s*$", call.strip(),
                                 re.IGNORECASE)
            if compared and compared.group(1).lower() == "v_src":
                problems.append(
                    f"{name}() matches a multi-token SQL key (one containing "
                    f"||) against the whitespace-normalised function source. "
                    f"prosrc is normalised to single spaces, so that "
                    f"comparison depends on where the author wrapped the line "
                    f"and it reported a defect that did not exist on the "
                    f"first live run. Compare against a whitespace-stripped "
                    f"copy of the source instead.")
                break
    notifier_src = "".join(
        _body(n) for n in ("fn_notify_order_status_change",
                           "fn_notify_ride_status_change",
                           "convert_points_to_wallet",
                           "approve_provider",
                           "approve_user"))
    for phrase in ("added to your wallet", "added to their wallet"):
        if phrase in notifier_src:
            problems.append(
                f"a notification message claims '{phrase}'. Ride completion "
                f"debits the platform commission and order payment is settled "
                f"outside the app; neither credits a wallet, so the message is "
                f"false and the wallet screen will contradict it")

    # 4. Dedupe keys must be derived from the event, not from the amount.
    #    Two conversions of the same size are two different events, and a key
    #    built from the amount would make the second one a silent no-op.
    points_src = _body("convert_points_to_wallet")
    if not points_src:
        problems.append("convert_points_to_wallet() not found")
    else:
        if "notify_user_once" not in points_src:
            problems.append("the points conversion credits the wallet and "
                            "notifies nobody; the balance changes with no way "
                            "for the user to find out")
        else:
            # Anchor on the notify call itself. The bare key string also appears
            # in the wallet ledger's idempotency_key, so searching for the key
            # anywhere in the body passes even when the notification is
            # disabled — which is exactly what fault injection found.
            #
            # The call is delimited by paren BALANCE, not by the first ')':
            # the arguments are v_birr::text, jsonb_build_object(...) and
            # friends, so a non-greedy match stopped inside the first one and
            # reported a message that had lost its amount as intact.
            m = re.search(
                r"notify_user_once\(\s*'points-convert:'.*?\n\s*\);",
                points_src, re.DOTALL)
            if not m:
                problems.append("the points conversion notice is not keyed on "
                                "the points ledger id, so a retry notifies "
                                "twice and two identical conversions collide "
                                "on one key")
            else:
                call = m.group(0)
                if "v_ledger_id" not in call.split("'points-convert:'")[1][:80]:
                    problems.append("the points conversion key is not derived "
                                    "from the ledger row id; a key built from "
                                    "the amount would collide across two "
                                    "identical conversions")
                # The two figures the brief asks the MESSAGE to carry. Both are
                # checked in the message argument, not merely in the call: the
                # data payload also carries them, so a call-wide search passes
                # on a message that quotes neither.
                msg = call.split("'POINTS_REDEEMED',", 1)[-1]
                msg = msg.rsplit("jsonb_build_object", 1)[0]
                if "p_points::text" not in msg:
                    problems.append("the conversion message no longer reports "
                                    "the points spent")
                if "v_birr::text" not in msg:
                    problems.append("the conversion message no longer reports "
                                    "the birr received")
        # Money invariants that a restatement of a money function loses.
        for needle, why in [
            ("pg_advisory_xact_lock", "its concurrency lock"),
            ("for update", "the FOR UPDATE balance re-read"),
            ("not_your_provider_profile", "its provider-ownership check"),
            ("wallet_transactions", "its ADJUSTMENT ledger row"),
        ]:
            if needle not in points_src:
                problems.append(f"convert_points_to_wallet() lost {why}")

    # 5. The user must have somewhere to read these. A notification nobody can
    #    see is a row in a table.
    notif_screen = ROOT / "lib/features/user/user_notifications_screen.dart"
    if not notif_screen.exists():
        problems.append("lib/features/user/user_notifications_screen.dart is "
                        "gone: notifications are written but have no UI")
    else:
        screen = _read(notif_screen)
        if "from('notifications')" not in screen:
            problems.append("the notifications screen no longer reads the "
                            "notifications table")
        # A receipt message that ellipsizes before the amount is visible
        # defeats the point of quoting the amount.
        m = re.search(r"maxLines:\s*(\d+)", screen)
        if m and int(m.group(1)) < 3:
            problems.append(
                f"the notifications screen truncates the body to "
                f"{m.group(1)} line(s). The money messages are receipts "
                f"('Payment of ETB 12,400.00 for Order #1841 has been "
                f"verified...') and ellipsize before the amount shows.")
        # Every notification family this series sends must map to a real icon
        # and colour. An unmapped type still renders (there is a default), but
        # a generic bell on a payment notice is how a receipt gets missed.
        # The screen branches on the enum PREFIX, which is why the families
        # are checked rather than the four full type names.
        for branch, why in [
            ("ORDER", "order payment receipts"),
            ("RIDE", "ride completion receipts"),
            ("POINTS", "points conversion receipts"),
            ("APPROVAL", "the welcome on approval"),
        ]:
            # Must appear in BOTH the colour mapper and the icon mapper.
            if screen.count(f"'{branch}'") + screen.count(f'"{branch}"') < 2:
                problems.append(f"the notifications screen does not map "
                                f"{branch} in both the icon and colour "
                                f"helpers, so {why} render with the default")
    # ...and an entry point, not just a screen that exists.
    #
    # The ROUTER is excluded: app_router.dart registers the /admin-notifications
    # route, so counting it as an entry point means the check passes even when
    # no screen links to it — a route nothing navigates to is not a surface.
    entry = 0
    for dart in dart_sources():
        if dart.name == "app_router.dart":
            continue
        if "'/admin-notifications'" in _read(dart):
            entry += 1
    if entry == 0:
        problems.append("no screen navigates to the notifications route, so the "
                        "new notifications are written and never seen (the "
                        "route alone is not a surface)")

    # 6. The two approval functions must actually send a welcome. Checked in
    #    the body, for the same reason as the money events above.
    for fn, key in [("approve_provider", "provider-approved:"),
                    ("approve_user", "user-approved:")]:
        body = _body(fn)
        if not body:
            problems.append(f"{fn}() not found")
        elif key not in body:
            problems.append(f"{fn}() no longer sends the welcome "
                            f"({key})")

    # 7. The live assertions must be registered in the connectivity suite, or
    #    they never run against a real database.
    conn = ROOT / "tools/integration_test/connectivity_test.dart"
    if not conn.exists():
        problems.append("tools/integration_test/connectivity_test.dart is gone")
    else:
        conn_sql = _read(conn)
        for fn in ("assert_notify_user_once_is_idempotent",
                   "assert_approval_welcome_covers_all_paths",
                   "assert_order_and_ride_receipts_are_sent",
                   "assert_points_conversion_notifies"):
            if fn not in all_sql:
                problems.append(f"{fn}() is not defined by any migration")
            if fn not in conn_sql:
                problems.append(f"{fn}() is never called from the connectivity "
                                f"test, so it will not run against the live "
                                f"database")

    # 8. Every assertion the suite calls must be executable by the role the
    #    suite ACTUALLY runs as.
    #
    #    The suite builds SupabaseClient with the anon key and no session, so
    #    its RPCs run as `anon`. An assertion granted to `authenticated` only is
    #    invisible to it, and PostgREST reports that as PGRST202 "could not find
    #    the function in the schema cache" — which reads like a missing
    #    migration and sends the reader to the wrong file. Five assertions
    #    shipped that way and failed CI after a clean deploy.
    #
    #    The check has to pair the GRANT with the revoke: a function created in
    #    public has EXECUTE for PUBLIC by default and anon inherits it, so a
    #    GRANT naming authenticated looks correct while `REVOKE ... FROM anon`
    #    silently removes the only path the suite has.
    conn_path = ROOT / "tools/integration_test/connectivity_test.dart"
    if conn_path.exists():
        conn_sql = _read(conn_path)
        # (privilege statements are scanned in file order below, so a later
        # grant correctly supersedes an earlier revoke)

        # The real rule, established by checking what actually passes:
        #
        #   * A function created in public has EXECUTE for PUBLIC by default,
        #     and anon inherits it. GRANTing to `authenticated` is ADDITIVE and
        #     changes nothing for anon — several older assertions do exactly
        #     that and pass.
        #   * REVOKE ... FROM public, anon is what REMOVES the anon path. That
        #     is the active narrowing, and it is the mistake: the GRANT beside
        #     it reads correct while the suite still cannot call the function.
        #
        # So the check is not "is anon in the grant" but "is there a revoke of
        # anon/PUBLIC that the last privilege statement does not undo".
        #
        # Verified by the failure this was written for: five assertions in
        # migrations 86-90 were granted `authenticated, service_role` AND
        # revoked anon, and failed CI with PGRST202 after a clean deploy.
        # assert_ride_chain_has_no_dead_ends and six others are granted
        # `authenticated` only and are fine, because nothing revokes them.
        # Both statement shapes are used in this repo and both must be read:        #
        #   GRANT EXECUTE ON FUNCTION public.assert_x() TO anon, authenticated;
        #   GRANT EXECUTE ON FUNCTION public.assert_x(), public.assert_y()
        #     TO anon, authenticated, service_role;
        #
        # An earlier version of this check only understood the first and read
        # the second's "revoke ... from public" as removing the suite's only
        # access, flagging an assertion that demonstrably passes.
        stmt_rx = re.compile(
            r"(GRANT|REVOKE)\s+(?:ALL\s+)?(?:EXECUTE\s+)?ON\s+FUNCTION\s+"
            r"((?:public\.\w+\s*\(\s*\)\s*,?\s*)+)"
            r"((?:TO|FROM)\s+[^;]+);", re.IGNORECASE)
        # Postgres applies these in ORDER and cumulatively, so the final state
        # has to be modelled, not guessed:
        #
        #   GRANT  EXECUTE ... TO anon   -> anon has a DIRECT grant
        #   REVOKE EXECUTE ... FROM anon -> removes that direct grant
        #   REVOKE EXECUTE ... FROM public -> removes the INHERITED path, but
        #                                        a direct anon grant survives
        #
        # Two earlier versions of this check got this wrong in opposite
        # directions: one kept only the last statement (so a grant sitting
        # before a revoke-from-public looked lost), and one treated any grant
        # anywhere as permanent (so a revoke AFTER a grant was ignored — which
        # is exactly the shape of the bug this is meant to catch).
        direct: dict[str, set[str]] = {}
        public_revoked: set[str] = set()
        for path in migration_files():
            text = _read(path)
            for m in stmt_rx.finditer(text):
                verb = m.group(1).upper()
                funcs = re.findall(r"public\.(\w+)\s*\(\s*\)", m.group(2))
                keyword = "TO" if verb == "GRANT" else "FROM"
                roles_m = re.search(keyword + r"\s+([^;]+)", m.group(3),
                                    re.IGNORECASE)
                named = ({r.strip().lower() for r in roles_m.group(1).split(",")}
                         if roles_m else set())
                for fn in funcs:
                    if verb == "GRANT":
                        direct.setdefault(fn, set()).update(named)
                    else:
                        if "anon" in named:
                            direct.setdefault(fn, set()).discard("anon")
                        if "public" in named:
                            public_revoked.add(fn)

        # "Called by the suite" must mean CALLED, not merely named. A substring
        # search matched list_staff_jobs() and my_staff_record(), which appear
        # only inside comments explaining that anon is correctly refused — and
        # those two are supposed to be anon-revoked. Reading the comment as a
        # call is how a check starts demanding the opposite of the invariant.
        called = set(re.findall(r"rpcText(?:Diagnosed)?\('([\w]+)'\)", conn_sql))
        called |= set(re.findall(r"\bok\('([\w]+)'\)", conn_sql))
        # One test calls a function with a named argument list rather than
        # through ok()/rpcText; pick those up too.
        called |= set(re.findall(r"client\.rpc\('([\w]+)'", conn_sql))

        for name in sorted(called):
            has_direct = "anon" in direct.get(name, set())
            if has_direct:
                continue  # anon holds a direct grant; the suite can call it
            if name not in public_revoked:
                continue  # anon still inherits EXECUTE-for-PUBLIC
            problems.append(
                f"{name}() is called by the connectivity suite, which runs as "
                f"the anon role, but its final privilege state leaves anon "
                f"with no path: EXECUTE from PUBLIC is revoked and there is no "
                f"direct GRANT to anon. PostgREST reports that as PGRST202 "
                f"'could not find the function in the schema cache', which "
                f"reads like a missing migration rather than a missing "
                f"privilege.")

    # 9. The restatements in this series must not have lost anything. This runs
    #    the real differ rather than a proxy for it, because a proxy that
    #    cannot tell a rewrite from a deletion is the exact failure mode that
    #    has hit this repo twice.
    differ = ROOT / "tools/harness/restatement_diff.py"
    if not differ.exists():
        problems.append("tools/harness/restatement_diff.py is missing: the "
                        "restatements in this series are unverified")
    else:
        for migration, fns in [
            ("20260927000087_welcome_on_approval.sql",
             ["approve_provider", "approve_user"]),
            ("20260927000088_order_and_ride_receipts.sql",
             ["fn_notify_order_status_change", "fn_notify_ride_status_change"]),
            ("20260927000089_points_conversion_notice.sql",
             ["convert_points_to_wallet"]),
        ]:
            target = ROOT / "supabase/migrations" / migration
            if not target.exists():
                problems.append(f"{migration} is missing")
                continue
            proc = subprocess.run(
                [sys.executable, str(differ), str(target), *fns],
                capture_output=True, text=True, cwd=str(ROOT))
            if proc.returncode != 0:
                for line in proc.stdout.splitlines():
                    if line.strip().startswith(("-", "LOST", "FAIL")):
                        problems.append(f"{migration}: {line.strip()}")

    return problems


# ---------------------------------------------------------------------------
# 17. the Other document type is wired end to end
# ---------------------------------------------------------------------------
def check_other_document_type_is_wired() -> list[str]:
    """The fourth document-type choice collects and keeps its label.

    The schema half is asserted in SQL (assert_other_document_type_is_wired,
    migration 0099). This is the half SQL cannot see: the Dart surfaces that
    offer the choice and the upload pipeline that carries the label. Fails
    the moment any of the five pieces go missing, because each one failing
    silently produces a different dead end — a choice that cannot be named,
    a name nobody stores, or a stored label nobody displays.
    """
    problems: list[str] = []

    gate = _strip_comments(
        _read(LIB / "core" / "services" / "provider_doc_gate.dart"))
    service = _strip_comments(
        _read(LIB / "core" / "services" / "document_upload_service.dart"))
    partner = _strip_comments(
        _read(LIB / "features" / "provider" / "become_partner_screen.dart"))
    review = _strip_comments(
        _read(LIB / "features" / "admin" / "admin_provider_management_screen.dart"))

    # 1. The constant exists and is deliberately OUTSIDE the gate map: an
    #    OTHER document must not satisfy identity verification by existing.
    if "otherDocType = 'OTHER'" not in gate:
        problems.append("ProviderDocGate.otherDocType ('OTHER') is missing")
    other_in_map = re.search(
        r"acceptedDocTypes\s*=\s*<String, String>\{([^}]*)\}", gate)
    if other_in_map and "OTHER" in other_in_map.group(1):
        problems.append(
            "acceptedDocTypes contains OTHER — an Other document would "
            "satisfy the identity gate without proving identity")

    # 2. The upload pipeline carries the label.
    if "otherDocumentLabel" not in service:
        problems.append("uploadAndRecord has no otherDocumentLabel parameter")
    if "other_document_label" not in service:
        problems.append(
            "the upload service never writes other_document_label, so the "
            "label is collected and dropped")

    # 3. Both upload surfaces offer the choice.
    for label, src, needle in (
        ("the doc-gate upload sheet", gate, "otherDocType, 'Other'"),
        ("Become a Partner", partner, "ProviderDocGate.otherDocType"),
    ):
        if needle not in src:
            problems.append(f"{label} no longer offers the Other choice")

    # 4. The admin review shows the label, not a bare Other.
    if "other_document_label" not in review:
        problems.append(
            "the admin review screen never reads other_document_label, so "
            "staff review an unnamed Other document")
    if "_typeOf" not in review:
        problems.append("the admin review screen lost the row-level type name")

    return problems


# ---------------------------------------------------------------------------
# 18. the CEO account directory routes through the shared cascade
# ---------------------------------------------------------------------------
def check_ceo_account_directory_is_wired() -> list[str]:
    """The CEO delete reuses delete_user_account; it never forks it.

    The SQL half is asserted in the database
    (assert_ceo_delete_is_wired, migration 0100). This is the Dart half: the
    screen exists, is routed and tiled, gates on CEO in the client as well as
    the server, asks for a reason, confirms by typed word, and calls the two
    RPCs — while nothing in lib/ ever writes auth-adjacent tables directly.
    """
    problems: list[str] = []

    screen_path = LIB / "features" / "admin" / "admin_account_directory_screen.dart"
    raw_screen = _read(screen_path)
    if not raw_screen:
        return ["lib/features/admin/admin_account_directory_screen.dart is missing"]
    # Comments stripped: this screen's own doc comment names ceo_delete_user_
    # account() and the cascade, so a raw search would be satisfied by prose
    # describing code that no longer exists — the failure mode the 00093
    # needle bug in this repo already cost two deploy cycles to.
    screen = _strip_comments(raw_screen)

    router = _read(LIB / "routing" / "app_router.dart")
    dashboard = _read(LIB / "features" / "admin" / "admin_dashboard.dart")
    ceo_dash = _read(LIB / "features" / "ceo" / "ceo_dashboard.dart")

    # The RPCs, both called, and the typed destructive confirmation.
    for needle in ("ceo_account_directory", "ceo_delete_user_account",
                   "TypedConfirmDialog", "p_reason"):
        if needle not in screen:
            problems.append(f"the directory screen no longer references {needle}")

    # Client-side CEO gate (the server re-checks everything; this avoids
    # rendering a refused workspace).
    if "is_ceo_authority" not in screen:
        problems.append(
            "the directory screen no longer checks is_ceo_authority() before "
            "loading")

    # Routed and tiled.
    if "/admin/accounts" not in router:
        problems.append("/admin/accounts is not routed")
    if "/admin/accounts" not in dashboard:
        problems.append("no dashboard tile points at /admin/accounts")
    if "/admin/accounts" not in ceo_dash:
        problems.append(
            "the CEO workspace danger-zone no longer links the directory")

    # The new path must not go THROUGH the request table: writing a request
    # and then approving it from the same account is a form filled in twice,
    # and it would blur whose decision a row recorded. (The request queue
    # itself — admin_deletion_requests_screen.dart calling reject_account_
    # deletion — is the existing non-CEO flow and must keep working, so only
    # THIS screen is inspected.)
    for forbidden in ("account_deletion_requests", "approve_account_deletion"):
        if forbidden in screen:
            problems.append(
                f"the directory screen references {forbidden} — the CEO path "
                "is a direct delete through the shared cascade, not a "
                "self-approved request")

    return problems


# ---------------------------------------------------------------------------
# 19. every picker that feeds a storage bucket is downscaled first
# ---------------------------------------------------------------------------
def check_payment_screenshots_are_downscaled() -> list[str]:
    """Every picker that feeds a storage bucket must re-encode, not forward.

    A bare `pickImage(source: ImageSource.gallery, imageQuality: 85)` sends
    the camera's original bytes. Every bucket here has a file_size_limit and
    an image/jpeg|png|webp mime list, so that upload is refused for a modern
    phone photo or an iOS HEIC — and the report that reaches us is never
    "the screenshot is too big", it is "payment screenshot is not accepting
    from provider section", because the refusal happens server-side inside a
    bucket the client never sees.

    Checked at the call site, not in the picker: these are independent
    screens, and the one that was wrong was correct code in isolation.

    `pickMultiImage` takes no `source:` argument, so a regex written for
    `pickImage` silently reports zero matches against it — a check that
    reads as green because it never looked. Both spellings are matched here,
    and the multi-image sites (provider gallery, product form, vehicle form)
    are the three that had been uncovered for the life of the check.
    """
    problems: list[str] = []

    # Every screen that uploads a payment proof or a screenshot, with the
    # bucket it targets (migration 96's limits).
    sites = [
        ("recharge_screen.dart (payment-screenshots, 5MB)",
         LIB / "features" / "wallet" / "recharge_screen.dart",
         ["_pickScreenshot"], "single"),
        ("user_payment_screen.dart (payment-proofs)",
         LIB / "features" / "user" / "user_payment_screen.dart",
         ["_pickScreenshot", "_pickNationalId"], "single"),
        ("user_order_detail_screen.dart (payment-proofs)",
         LIB / "features" / "user" / "user_order_detail_screen.dart",
         ["_submitPayment"], "single"),
        # Multi-image pickers are a different API with no `source:` argument,
        # so the pickImage regex above can never see them. That is how three
        # 5MB-bucket uploads sat here forwarding full-resolution phone photos
        # with nothing complaining: this check read as green the whole time.
        ("provider_gallery_screen.dart (provider-gallery, 5MB)",
         LIB / "features" / "provider" / "provider_gallery_screen.dart",
         ["_add"], "multi"),
        ("provider_product_form_screen.dart (product-images, 5MB)",
         LIB / "features" / "provider" / "provider_product_form_screen.dart",
         ["_pickImages"], "multi"),
        ("vehicle_form_screen.dart (vehicle-images, 5MB)",
         LIB / "features" / "vehicle" / "vehicle_form_screen.dart",
         ["_addPhotos"], "multi"),
        # The provider shop photo (provider-photos, 5MB, 20260927000106).
        # Added to the list rather than left off it: an upload path that no
        # check knows about is exactly how the gallery shipped broken, and
        # this list is the only thing that keeps new pickers honest.
        ("provider_business_profile_screen.dart (provider-photos, 5MB)",
         LIB / "features" / "provider" / "provider_business_profile_screen.dart",
         ["_pickPhoto"], "single"),
    ]

    for label, path, fns, kind in sites:
        src = _strip_comments(_read(path))
        if not src:
            problems.append(f"{label}: the file is missing")
            continue
        if kind == "single":
            found = re.finditer(
                r"pickImage\(\s*source:\s*ImageSource\.gallery(.{0,320}?)\)",
                src, re.DOTALL)
        else:
            found = re.finditer(
                r"pickMultiImage\((.{0,320}?)\)\s*;", src, re.DOTALL)
        for m in found:
            args = m.group(1)
            if "maxWidth" not in args or "maxHeight" not in args:
                line = src[:m.start()].count("\n") + 1
                problems.append(
                    f"{label}: the gallery pick at line {line} forwards the "
                    "original image (no maxWidth/maxHeight), so a large photo "
                    "or a HEIC is refused by the bucket")
        # The named methods must still exist at all.
        for fn in fns:
            if fn not in src:
                problems.append(f"{label}: {fn} is gone — check the upload path")

    # The service must quote a limit the bucket actually has, and check it
    # before uploading rather than surfacing storage's refusal.
    wallet = _strip_comments(
        _read(LIB / "core" / "services" / "wallet_service.dart"))
    if "payment-screenshots" not in wallet:
        problems.append(
            "WalletService no longer targets the payment-screenshots bucket")
    if not re.search(r"5\s*\*\s*1024\s*\*\s*1024", wallet):
        problems.append(
            "uploadScreenshot no longer checks the 5MB limit up front, so a "
            "refused image reaches the provider as a raw storage error")

    return problems


# ---------------------------------------------------------------------------
# 20. the policies the upload and money paths need are in a migration the
#     pipeline actually executes
# ---------------------------------------------------------------------------
# check_client_buckets_are_created (6b) asks whether each bucket EXISTS in a
# migration at or after the baseline. It does not ask whether anyone is allowed
# to write to it -- and those are separate questions, which is how the gallery
# was fixed while document upload stayed broken.
#
# The live half is assert_client_buckets_have_write_and_read_policies() and
# assert_owner_can_read_and_write_their_money() (migration 0102). This is the
# source half: that a CURRENT migration declares those policies at all, so the
# pipeline has something to execute and the assertions have something to find.
BUCKET_POLICY_RX = re.compile(
    r"CREATE\s+POLICY\s+(\w+)\s+ON\s+storage\.objects\s+"
    r"FOR\s+(INSERT|SELECT|UPDATE|DELETE|ALL)\b(.*?);",
    re.IGNORECASE | re.DOTALL,
)

#: (table, command) a non-staff caller must be able to perform. Names the
#: caller, never is_admin()/staff_has_permission(): a provider is neither, and
#: that gap is the bug migration 0102 exists for.
MONEY_POLICY_NEEDS = (
    ("wallets", "SELECT"),
    ("wallet_recharge_requests", "INSERT"),
    ("wallet_recharge_requests", "SELECT"),
)


def _current_migrations():
    """Migrations at or after the deploy baseline -- the only ones that run."""
    for path in migration_files():
        version = path.name.split("_", 1)[0]
        if version.isdigit() and int(version) >= BASELINE:
            yield path


def check_client_write_policies_are_executable() -> list[str]:
    """Every bucket lib/ writes to has a write AND a read policy, and the
    wallet tables have caller-named ones, all declared after the baseline.

    A policy declared below the baseline is a policy in a file nobody runs: the
    deploy workflow marks those applied with `migration repair`, which writes
    the history table and never executes the file. The gallery bucket proved
    the assumption is false, and the same reasoning applied to a policy says a
    bucket can be present, correctly sized, correctly private -- and still
    refuse every upload, because the INSERT policy that would have permitted it
    only ever existed on paper.
    """
    problems: list[str] = []

    # --- storage buckets ---------------------------------------------------
    # bucket -> commands declared in a current migration, comments stripped so
    # a header explaining the policy cannot stand in for the policy itself.
    cmds: dict[str, set[str]] = {}
    for path in _current_migrations():
        body = re.sub(r"--[^\n]*", " ", _read(path))
        body = re.sub(r"/\*.*?.\*/", " ", body, flags=re.DOTALL)
        for m in BUCKET_POLICY_RX.finditer(body):
            rest = m.group(3)
            names = re.findall(r"bucket_id\s*=\s*'([a-z0-9][a-z0-9-]*)'", rest)
            for bucket in names:
                cmds.setdefault(bucket, set()).add(m.group(2).upper())

    for bucket in sorted(dart_buckets()[0]):
        have = cmds.get(bucket, set())
        # ALL covers both sides, which is why it is expanded rather than
        # compared: a bucket guarded by one FOR ALL policy is not half-open.
        writes = bool(have & {"INSERT", "ALL"})
        reads = bool(have & {"SELECT", "ALL"})
        if not writes or not reads:
            missing = ", ".join(
                c for c, ok in (("INSERT", writes), ("SELECT", reads)) if not ok
            )
            problems.append(
                "no migration at or after the deploy baseline %d creates a %s "
                "policy on storage.objects for bucket %r (declared there: %s). "
                "A bucket with no INSERT policy refuses every upload with 'new "
                "row violates row-level security policy for table objects', and "
                "one with no SELECT policy fails every signed-URL fetch. Older "
                "files are marked applied WITHOUT being executed, so a policy "
                "declared only there does not exist."
                % (BASELINE, " and ".join(missing.split(" and ")), bucket,
                   ", ".join(sorted(have)) or "none")
            )

    # --- the money tables --------------------------------------------------
    all_current = "\n".join(
        re.sub(r"--[^\n]*", " ", _read(p)) for p in _current_migrations()
    )
    for table, cmd in MONEY_POLICY_NEEDS:
        rx = re.compile(
            r"CREATE\s+POLICY\s+\w+\s+ON\s+(?:public\.)?%s\s+FOR\s+%s\b(.*?);"
            % (re.escape(table), cmd),
            re.IGNORECASE | re.DOTALL,
        )
        bodies = [m.group(1).lower() for m in rx.finditer(all_current)]
        if not bodies:
            problems.append(
                "no migration at or after the baseline creates a %s policy on "
                "public.%s, so the client path that performs it is refused and "
                "the user is told the record does not exist" % (cmd, table)
            )
        elif not any(re.search(r"auth\.uid|owns_provider_profile", b) for b in bodies):
            problems.append(
                "the only %s policy on public.%s declared after the baseline "
                "does not name the caller (no auth.uid() and no "
                "owns_provider_profile()). A staff- or admin-scoped policy is "
                "unreachable for the signed-in provider who owns the row, which "
                "is exactly how a wallet lookup returns nothing"
                % (cmd, table)
            )

    # --- the assertions that make it stick ---------------------------------
    for guard in ("assert_client_buckets_have_write_and_read_policies",
                  "assert_owner_can_read_and_write_their_money"):
        if guard not in all_current:
            problems.append(
                "the live guard %s() is missing, so the policies above can "
                "quietly stop existing and nothing would say so" % guard
            )

    problems.extend(_money_assertion_cannot_pass_vacuously())

    return problems


def _money_assertion_cannot_pass_vacuously() -> list[str]:
    """The money assertion shipped broken and reported itself as a finding.

    The first version (migration 0102) walked a `text[][]` by subscript and
    produced a NULL table name on the live database, so it raised
    `MONEY_TABLE_MISSING: public.<NULL>` -- naming a table that has never been
    missing. Two separate defects let that read as a schema problem:

      * a 2-D array walked by subscript is the same construct migration 95
        records as having cost two deploy cycles, so the shape is banned here
        rather than rediscovered;
      * its vacuity guard was `v_checked <> array_length(...)`, which is NULL
        -- not true -- when the loop never runs, and `IF NULL` falls through.
        A guard that cannot fail is worse than no guard, because it converts a
        broken check into a green build.

    `function_body` strips comments, so the prose above cannot satisfy these.
    """
    problems: list[str] = []
    path, sql = last_migration_defining(
        "assert_owner_can_read_and_write_their_money")
    if path is None:
        return ["no migration defines assert_owner_can_read_and_write_their_money()"]

    body = function_body(sql, "assert_owner_can_read_and_write_their_money")
    if not body:
        return [
            "%s: could not extract the body of "
            "assert_owner_can_read_and_write_their_money(), so its shape "
            "cannot be checked" % path.name
        ]
    rel = path.name

    if re.search(r"\w+\s+text\s*\[\s*\]\s*\[\s*\]", body):
        problems.append(
            "%s: the money assertion declares a 2-D array. Walking one by "
            "subscript is the construct that shipped broken (it yielded a NULL "
            "table name live and reported a table that exists as missing), and "
            "migration 95 already records a 2-D needle table costing two deploy "
            "cycles. Use two flat arrays zipped with unnest, the shape "
            "migration 0101 uses." % rel
        )

    if re.search(r"\bFOREACH\b", body):
        problems.append(
            "%s: the money assertion uses FOREACH. plpgsql refuses an "
            "array-typed FOREACH loop variable at RUN time (42804); "
            "CREATE FUNCTION does not catch it, so the function deploys green "
            "and raises on every call. The FOREACH lint elsewhere in this file "
            "exists for exactly that." % rel
        )

    if "unnest(" not in body:
        problems.append(
            "%s: the money assertion does not zip its requirement list with "
            "unnest(a, b). The two flat arrays plus "
            "`FOR x, y IN SELECT * FROM unnest(a, b)` shape is what migration "
            "0101 uses in production and is the one that has been proven "
            "against a live database." % rel
        )

    # A guard that cannot fail converts a broken check into a green build. The
    # coalesce need not sit inline in the comparison -- assigning it to the
    # expected count first is the same thing -- so this asks whether the body
    # neutralises NULL anywhere it compares, rather than pinning one spelling.
    if not re.search(r"v_checked\s*<>", body):
        problems.append(
            "%s: the money assertion has no `v_checked <> ...` comparison, so "
            "there is nothing stopping it reporting success after "
            "examining nothing" % rel
        )
    elif "coalesce" not in body.lower():
        problems.append(
            "%s: the money assertion compares v_checked against an expected "
            "count with no coalesce anywhere. When the loop never runs that "
            "count is NULL and `v_checked <> NULL` is NULL, which `IF` treats "
            "as false -- so the guard reports success precisely when it has "
            "checked nothing, which is the failure this check exists to "
            "prevent." % rel
        )

    # An empty requirement list must also fail. coalesce(... , 0) alone does
    # not catch `0 <> 0`.
    if not re.search(r"expected\s*=\s*0|=\s*0\s+OR|OR\s+\w*expected\w*\s*=\s*0", body):
        problems.append(
            "%s: the money assertion never fails on an EMPTY requirement "
            "list. `0 <> 0` is false, so a list that unzips to nothing is "
            "reported as a clean pass rather than as a check that examined "
            "nothing." % rel
        )

    if "MONEY_CHECK_MALFORMED" not in body:
        problems.append(
            "%s: the money assertion has no MONEY_CHECK_MALFORMED guard, so if "
            "its own loop breaks again it reports the breakage as a finding "
            "about the schema and sends the reader to the wrong file." % rel
        )

    return problems


# ---------------------------------------------------------------------------
# 21. a refused recharge names what is actually missing
# ---------------------------------------------------------------------------
def check_recharge_refusals_name_the_real_cause() -> list[str]:
    """friendly_error() maps any error whose text contains 'not found' to
    "That item could not be found. It may have been removed."

    recharge_screen.dart threw `Exception('Wallet not found')` for a lookup
    that returned nothing, and `Exception('Provider profile not found')` for
    the same thing one step earlier. Both were caught by the generic handler
    and rendered as the generic sentence -- so three unrelated failures (no
    provider profile, no wallet, an insert RLS refused) reached the user as
    one indistinguishable "not found", and the report that came back said the
    wrong thing about which layer was broken.

    The rule this pins: a locally-raised refusal must not carry a phrase the
    shared mapper will swallow. Either map it to something a person can act
    on, or let it fall through to the generic fallback -- but it must not
    borrow the mapper's vocabulary.
    """
    problems: list[str] = []
    screen = _strip_comments(
        _read(LIB / "features" / "wallet" / "recharge_screen.dart"))
    if not screen:
        return ["lib/features/wallet/recharge_screen.dart is missing"]

    mapper = _strip_comments(_read(LIB / "core" / "utils" / "friendly_error.dart"))
    m = re.search(r"'404',\s*'not found'", mapper)
    if not m:
        # The mapper changed shape. Stop asserting against a needle that may no
        # longer mean what it meant -- a check that cannot see its own subject
        # is worse than no check.
        return [
            "friendly_error.dart no longer contains the 'not found' needle list, "
            "so this check cannot tell which local refusals it swallows; "
            "re-derive it against the new classifier"
        ]

    for thrown in re.findall(r"throw\s+Exception\(\s*'([^']*)'\s*\)", screen):
        if "not found" in thrown.lower():
            problems.append(
                "recharge_screen.dart throws Exception(%r), and "
                "friendly_error maps any error containing 'not found' to "
                '"That item could not be found. It may have been removed." A '
                "local precondition failure must not borrow the mapper's "
                "vocabulary -- say what is missing in terms the user can act "
                "on, so this failure is distinguishable from a genuinely "
                "deleted record" % thrown
            )

    # The two lookups must still exist: a check that passes because the code
    # was deleted is the failure mode this file's header warns about.
    for needle, why in (
        ("from('provider_profiles')", "the provider profile lookup is gone"),
        ("from('wallets')", "the wallet lookup is gone"),
        ("submitRecharge", "the recharge submit call is gone"),
    ):
        if needle not in screen:
            problems.append(f"recharge_screen.dart: {why}")

    return problems


# ---------------------------------------------------------------------------
# 22. the provider gallery is still reachable from the provider dashboard
# ---------------------------------------------------------------------------
# Reported as "the gallery is gone from the dashboard". Nothing had been
# deleted: the dashboard redesign had moved the tile one level down, into the
# Business tab of DashboardTopTabs, and the screen, the route, the bucket and
# the RPCs were all exactly where they had been since the root commit.
#
# A feature that is one refactor away from being unreachable needs its entry
# point asserted, the same way the CEO directory's is (check 18). The tile is
# allowed to live inside a tab -- what cannot be allowed is for the tab, the
# route, or the tile to disappear without a check going red.
def check_provider_gallery_is_wired() -> list[str]:
    """Gallery screen, route, dashboard tile, shared grid, loud errors.

    The SQL half is asserted in the database (assert_app_buckets_exist in
    migration 96 for the bucket; the INSERT/UPDATE/DELETE policies on
    `provider-gallery` are checked by check_client_write_policies_are_executable).
    This is the Dart half: the feature a provider is told to use actually has
    something to tap.
    """
    problems: list[str] = []

    screen_path = LIB / "features" / "provider" / "provider_gallery_screen.dart"
    raw = _read(screen_path)
    if not raw:
        return ["lib/features/provider/provider_gallery_screen.dart is missing"]
    # Comments stripped: this screen's doc comment names the bucket, the path
    # convention and both RPCs, so a raw search would be satisfied by prose
    # describing code that is no longer there.
    screen = _strip_comments(raw)

    # The screen's own contract: read its table, write through the two RPCs,
    # render the shared grid.
    for needle, why in (
        ("from('provider_gallery')", "the gallery is no longer read"),
        ("add_gallery_image", "the add call is gone"),
        ("delete_gallery_image", "the delete call is gone"),
        ("PhotoGrid", "the gallery no longer uses the shared photo grid"),
        ("provider-gallery", "the gallery no longer names its bucket"),
    ):
        if needle not in screen:
            problems.append(f"provider_gallery_screen.dart: {why}")

    # The owner-scoped storage path. The bucket's INSERT/UPDATE/DELETE
    # policies scope on `auth.uid()::text = first path segment`, so a path
    # that does not lead with the caller's uid is refused by storage with an
    # error the provider cannot act on.
    if not re.search(r"\$uid/\$", screen):
        problems.append(
            "provider_gallery_screen.dart no longer builds the owner-scoped "
            "'<uid>/<image id>/<file>' path its bucket policies require")

    # Routed, and tiled from the provider dashboard. The tile may sit inside a
    # DashboardTopTabs entry -- that is a design choice, not a lost feature.
    router = _read(LIB / "routing" / "app_router.dart")
    if "/provider/gallery/:id" not in router:
        problems.append("/provider/gallery/:id is no longer routed")
    if "ProviderGalleryScreen" not in router:
        problems.append("the gallery route no longer builds ProviderGalleryScreen")

    dashboard = _strip_comments(
        _read(LIB / "features" / "provider" / "service_provider_dashboard.dart"))
    if not dashboard:
        problems.append("service_provider_dashboard.dart is missing")
    else:
        if "/provider/gallery/" not in dashboard:
            problems.append(
                "no tile on the provider dashboard points at /provider/gallery/ "
                "-- the gallery is unreachable")
        # The route is /provider/gallery/:id, so the tile must interpolate the
        # provider id. Pushing a literal or a null would match no route.
        if not re.search(r"/provider/gallery/\$\{", dashboard):
            problems.append(
                "the gallery tile does not interpolate the provider id into "
                "/provider/gallery/, so the path it pushes matches no route")
        # A string search finds dead code. A tile switched off with
        # `if (false)`, or commented out, still contains the path -- the
        # feature is unreachable and this check reads green. Falsification
        # caught exactly that when this check was written: the guard is not
        # adjacent to the push, so matching "the nearest if before the string"
        # does not catch it either. The rule is therefore blunt on purpose --
        # a constant-false condition anywhere in a dashboard is always a
        # disabled feature, never a legitimate branch.
        for cond in re.findall(r"if\s*\(\s*(false|0|null)\s*\)", dashboard,
                               re.IGNORECASE):
            problems.append(
                "the provider dashboard contains a constant-false guard "
                "`if (%s)`, which disables a tile -- the gallery is "
                "unreachable however correct the rest of it is"
                % cond.lower())
        # The tile must actually be inside a tab/entry list that gets built,
        # not commented out of one.
        if "DashboardTopTabs" not in dashboard:
            problems.append(
                "the provider dashboard no longer builds DashboardTopTabs; "
                "the gallery tile is expected to live in one of its tabs")
        # ...and that id has to come from a provider profile row that the
        # dashboard actually loads, or the tile is dead on arrival.
        if "from('provider_profiles')" not in dashboard:
            problems.append(
                "the provider dashboard no longer loads provider_profiles, so "
                "it has no id to push to the gallery route with")

    # Errors surface. A gallery that silently swallows a failed upload reads
    # to the provider as "the app is broken", which is the exact report that
    # sent us looking.
    if "friendlyError" not in screen:
        problems.append(
            "provider_gallery_screen.dart no longer routes failures through "
            "friendlyError, so a refused upload would fail silently")

    # The shared grid must still be the 3-across default; a per-screen
    # column override here would diverge from every other photo surface.
    if re.search(r"PhotoGrid\([^)]*crossAxisCount", screen, re.DOTALL):            problems.append(
                "provider_gallery_screen.dart overrides the shared PhotoGrid "
                "column count; the 3-across default is the product decision")

    return problems


# ---------------------------------------------------------------------------
# 23. the role quick-action shortcuts share one definition and still resolve
# ---------------------------------------------------------------------------
# "Book a ride" on the user home screen was the only instance of this pill
# pattern, which made it simultaneously the only definition of the pattern and
# the reason two provider dashboards had no shortcut at all. Giving each role
# its own hand-written pill would restore the drift in a new place, so the
# markup lives once in QuickActionPill and the roles call it.
#
# What this protects, in the order things actually broke here:
#   1. the pill style is defined once (no second hand-rolled green pill)
#   2. each role still offers a shortcut at all
#   3. each shortcut's target is a declared route, not a hopeful push
#   4. no shortcut is invented for a role that cannot exist
QUICK_ACTION_ROLES = (
    ("user_home_screen.dart", "user", "Book a ride", "/user/ride-request"),
    ("service_provider_dashboard.dart", "service provider",
     "My Gallery", "/provider/gallery/"),
    ("vehicle_provider_dashboard.dart", "vehicle provider",
     "Ride Requests", "/vehicle/ride-requests"),
)


def check_quick_action_shortcuts_are_wired() -> list[str]:
    problems: list[str] = []

    if not _read(LIB / "core" / "widgets" / "quick_action_pill.dart"):
        return ["lib/core/widgets/quick_action_pill.dart is missing"]

    # One definition. A role screen that hand-rolls a brand-green rounded pill
    # is the drift this widget exists to prevent.
    #
    # Scoped to the three role screens on purpose. Scanned across all of lib/
    # it also matches legitimate components that merely share the colour and
    # radius -- the category chip in the user home tab rail was the first
    # false positive -- and a check that cries wolf gets ignored.
    pill_style = re.compile(
        r"AppTheme\.primaryGreen\s*,[\s\S]{0,200}?BorderRadius\.circular\(20\)")
    role_files = {f for f, _, _, _ in QUICK_ACTION_ROLES}
    for path in sorted(dart_sources()):
        if path.name not in role_files:
            continue
        src = _strip_comments(_read(path))
        # A match that is not inside a QuickActionPill call is a second pill.
        for m in pill_style.finditer(src):
            window = src[max(0, m.start() - 400):m.start()]
            if "QuickActionPill" not in window:
                line = src[:m.start()].count("\n") + 1
                problems.append(
                    "%s hand-rolls a brand-green pill at line %d instead of "
                    "using QuickActionPill — that is how the dashboards end up "
                    "with three different button styles"
                    % (path.name, line))

    router = _read(LIB / "routing" / "app_router.dart")

    for filename, role, label, target in QUICK_ACTION_ROLES:
        found = False
        for path in sorted(dart_sources()):
            if path.name != filename:
                continue
            src = _strip_comments(_read(path))
            # The user home's shortcuts are equal-height CARDS now, not
            # pills: the founder's layout puts "Book a ride" and "All
            # providers" side by side right under the header, and the pill
            # row that used to sit above them was the duplicate the redesign
            # removed (spec: remove the duplicate pill buttons at the top).
            # Both widgets carry the same contract -- a label and an onTap --
            # so the assertion is about the contract, not the widget. A role
            # screen that offers NEITHER is the dead-shortcut case this
            # check exists for.
            starts = []
            for name in ("QuickActionPill(", "_QuickActionCard("):
                for m in re.finditer(re.escape(name), src):
                    # `const QuickActionCard({ ... })` is the widget's own
                    # constructor declaration -- named arguments never open
                    # with `{`, so that is the one shape to skip. Counting it
                    # would ask a constructor for the label only a call has.
                    if src[m.end():m.end() + 40].lstrip().startswith("{"):
                        continue
                    starts.append(m.start())
            starts.sort()
            blocks = []
            for i, pos in enumerate(starts):
                # From this call to the next shortcut (or a generous cap).
                nxt = starts[i + 1] if i + 1 < len(starts) else -1
                blocks.append(src[pos:nxt if nxt != -1 else pos + 600])
            if not blocks:
                problems.append(
                    "%s (%s) offers no quick-action shortcut: neither a "
                    "QuickActionPill nor a _QuickActionCard" % (filename, role))
                continue
            found = True
            # The label and the target must be inside the SHORTCUT'S OWN call,
            # not merely somewhere in the file. A file-level search is
            # satisfied by the tab entry that the shortcut duplicates -- so a
            # pill pointed at the wrong route reads green. Falsification
            # caught exactly that.
            #
            # NOTE the model here is "the role's shortcut exists", NOT "every
            # shortcut on the screen is that one". The user home screen
            # carries two -- "Book a ride" and the provider-gallery entry --
            # and an earlier version demanded that EVERY pill be labelled
            # "Book a ride", which punishes a screen for having a second,
            # legitimate shortcut. A check that fails on good work gets
            # disabled, so the assertion is narrowed to what it was for:
            # the role's own shortcut must exist and point where it should,
            # and every other shortcut must still be labelled and live.

            canonical = [b for b in blocks
                         if label in b and target in b]
            if not canonical:
                problems.append(
                    "%s (%s): no quick-action shortcut is labelled %r AND "
                    "pushes %s. Found shortcuts labelled/pushing: %r"
                    % (filename, role, label, target,
                       [(re.findall(r"(?:label|title):\s*'([^']*)'", b),
                         re.findall(r"context\.(?:push|go)\('([^']*)'\)", b))
                        for b in blocks]))

            # A gallery shortcut needs a provider id in the path; a literal
            # would match a route but show the wrong provider's photos.
            #
            # This assertion used to sit inside an `if not QuickActionPill(`
            # branch that the earlier `continue` above had already made
            # unreachable, so it had never run once. It is now evaluated
            # against the pill that actually carries the gallery target.
            if target.endswith("/"):
                for b in canonical:
                    if not re.search(re.escape(target) + r"\$\{", b):
                        problems.append(
                            "%s: the gallery pill pushes %s without "
                            "interpolating the provider id, so it would show "
                            "whichever provider happened to be first"
                            % (filename, target))

            # Every other pill on the screen must at least be LABELLED and have
            # a tap target. A route is not required here: a pill may hand off
            # to a local method (the gallery entry opens a sheet), and a
            # template-literal path like `/provider/gallery/${p['id']}` cannot
            # be matched by a simple `push\('([^']*)'\)` anyway -- the
            # interpolation contains quotes. Route resolution for DIRECT pushes
            # is check_routes_resolve's job; asserting it here produced two
            # false positives on correct code.
            for b in blocks:
                # `title:` is how _QuickActionCard names its label; every
                # other shortcut in the app uses `label:`. Both must be
                # non-empty or the tile is a blank green box.
                labels = re.findall(r"(?:label|title):\s*'([^']*)'", b)
                if not labels or not labels[0].strip():
                    problems.append(
                        "%s: a quick-action shortcut has no label, so it "
                        "renders as an unlabelled green box" % filename)
                if "onTap" not in b:
                    problems.append(
                        "%s: a quick-action shortcut has no onTap, so it is "
                        "a dead shortcut" % filename)
            if re.search(r"if\s*\(\s*(false|0|null)\s*\)", src, re.IGNORECASE):
                problems.append(
                    "%s contains a constant-false guard, which disables a tile "
                    "or shortcut" % filename)
        if not found:
            problems.append("%s is missing" % filename)

    # Every target must be a declared route. check_routes_resolve covers
    # every push in lib/; this states the expectation for these three so the
    # failure names the shortcut rather than a bare push.
    for filename, role, label, target in QUICK_ACTION_ROLES:
        route = target.rstrip("/")
        if route == "/provider/gallery":
            continue  # parameterised; asserted above
        if ("path: '%s'" % route) not in router:
            problems.append(
                "the %s shortcut targets %s, which is not a declared route"
                % (role, route))

    # There is no booking provider. `app_role` is exactly
    # (USER, VEHICLE_PROVIDER, SERVICE_PROVIDER, ADMIN) and provider_type is
    # constrained to the two provider values, so a booking-provider dashboard
    # shortcut would point at a screen no account can ever reach. BOOKING is a
    # category service_group on the shopper side, not a provider role.
    for path in sorted(dart_sources()):
        src = _strip_comments(_read(path))
        if re.search(r"QuickActionPill\([\s\S]{0,200}?BOOKING", src):
            problems.append(
                "%s offers a BOOKING_PROVIDER shortcut, but no such role "
                "exists in app_role" % path.name)

    return problems


# ---------------------------------------------------------------------------
# 24. the gallery's READ path is in a migration the pipeline executes
# ---------------------------------------------------------------------------
# Reported fixed three times. The write path was rebuilt post-baseline as
# SECURITY DEFINER functions; the read path was "already covered" by
# provider_gallery_owner_read, which lives in 0014 -- below BASELINE, so the
# deploy marks it applied without executing it. The 0102 assertion cannot see
# this: it inspects storage.objects, not the table the rows live in.
def check_gallery_read_path_is_migrated() -> list[str]:
    problems: list[str] = []

    # The policies must be created in a migration the pipeline runs, not only
    # in one that is skipped.
    for policy in ("provider_gallery_owner_read", "provider_gallery_public_read"):
        defining = []
        for p in _current_migrations():
            src = _strip_comments(_read(p))
            if src and f"CREATE POLICY {policy}" in src:
                defining.append(p.name)
        if not defining:
            pre = [
                p.name for p in migration_files()
                # isdigit, not int(): 0022a is a real migration prefix and
                # int() raises on it. Falsification caught this the hard way
                # -- the ValueError aborted the whole harness instead of
                # failing one check, which hides every other result.
                if p.name.split("_", 1)[0].isdigit()
                and int(p.name.split("_", 1)[0]) < BASELINE
                and policy in (_strip_comments(_read(p)) or "")
            ]
            problems.append(
                "%s is only defined in pre-baseline migrations (%s), which the "
                "deploy workflow marks applied WITHOUT executing. A provider "
                "reading their own gallery gets zero rows while their upload "
                "succeeds -- migration 0104 restates it."
                % (policy, ", ".join(pre) or "none found"))

    screen = _strip_comments(
        _read(LIB / "features" / "provider" / "provider_gallery_screen.dart"))
    if "from('provider_gallery')" not in screen:
        problems.append(
            "the gallery screen no longer reads provider_gallery directly")

    return problems


# ---------------------------------------------------------------------------
# 25. profile completion + no dead menu rows
# ---------------------------------------------------------------------------
# Two failures that look identical from the user's side -- a tap that does
# nothing. "Edit Profile" was a _menuTile with no onTap at all, so a
# tappable-looking row swallowed the tap silently, which is indistinguishable
# from a broken app. Nothing asserted it, because nothing looked.
def check_profile_completion_and_taps_are_wired() -> list[str]:
    problems: list[str] = []

    # -- The OAuth gate --
    router = _strip_comments(_read(LIB / "routing" / "app_router.dart"))
    if "CompleteProfileScreen" not in router:
        problems.append("CompleteProfileScreen is not routed")
    if "isVerifiable" not in router:
        problems.append(
            "the router no longer gates on profile.isVerifiable, so an OAuth "
            "account can reach the app without a phone number")
    # The gate must exempt the screen it sends people to, or the user
    # ping-pongs between the app and the form forever.
    if "'/complete-profile'" not in (function_body(router, "_isApprovalRoute")
                                     or router):
        problems.append(
            "/complete-profile is not an approval route. An OAuth account is "
            "PENDING_APPROVAL, so the pending gate would bounce it off the "
            "completion screen and the completeness gate would send it back")

    model = _strip_comments(_read(LIB / "core" / "models" / "user_profile.dart"))
    if "isVerifiable" not in model:
        problems.append(
            "UserProfile.isVerifiable is gone, so the router gate has nothing "
            "to test")
    # 'New User' is the trigger's placeholder, not a name. A null check alone
    # waves every Google account straight through.
    if "'New User'" not in model:
        problems.append(
            "UserProfile no longer treats the trigger's 'New User' placeholder "
            "as incomplete -- a Google account has a non-null name that is not "
            "a name")

    for screen, folder in (("complete_profile_screen.dart", "auth"),
                           ("edit_profile_screen.dart", "user")):
        src = _strip_comments(
            _read(LIB / "features" / folder / screen))
        if not src:
            problems.append("%s is missing" % screen)
            continue
        if "complete_profile" not in src:
            problems.append("%s no longer calls the complete_profile RPC"
                            % screen)
        # The RPC raises on empty values; the client must not be the only
        # thing enforcing them, and the two must agree on which fields.
        for field in ("p_full_name", "p_phone", "p_kebele", "p_street_road"):
            if field not in src:
                problems.append(
                    "%s does not send %s, so the form and the RPC disagree "
                    "about what is required" % (screen, field))

    # -- No dead menu rows --
    profile = _read(LIB / "features" / "user" / "user_profile_screen.dart")
    if profile:
        for m in re.finditer(r"_menuTile\(", profile):
            i = m.end() - 1
            depth = 0
            for j in range(i, len(profile)):
                if profile[j] == "(":
                    depth += 1
                elif profile[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
            call = profile[m.start():j + 1]
            if "onTap" not in call and "Navigator" not in call:
                label = re.search(r"'([^']+)'", call)
                problems.append(
                    "the %r menu row on the account screen still has no onTap "
                    "-- a tappable-looking row that does nothing when tapped"
                    % (label.group(1) if label else "?"))

    return problems


# ---------------------------------------------------------------------------
# 26. the redirect rules the cycle simulation models
# ---------------------------------------------------------------------------
# `redirect_cycle_simulation.py` proves the router's rules cannot deadlock,
# but it mirrors them. The moment app_router.dart's redirect() and the mirror
# disagree, the simulation is asserting something the app does not do, which
# is a green light for a crash. These are the exact clauses it depends on.
def check_router_matches_the_cycle_simulation() -> list[str]:
    problems: list[str] = []
    router = _strip_comments(_read(LIB / "routing" / "app_router.dart"))

    # The simulation exempts approved accounts from the completeness gate. If
    # the app stops doing that, an approved account with an incomplete profile
    # is sent to /complete-profile and forwarded straight back out of it.
    if "needsProfileCompletion" not in router:
        problems.append(
            "the profile-completeness gate no longer exists as "
            "needsProfileCompletion; redirect_cycle_simulation.py models it")
    if "!authState.isApproved" not in router:
        problems.append(
            "the completeness gate no longer exempts APPROVED accounts. That "
            "exemption is what stops /complete-profile <-> dashboard looping "
            "for an account whose profile predates kebele/street_road")

    # "Approval resolved" must mean approved, not "not pending and not
    # rejected": the looser form also matched SUSPENDED and INACTIVE, which
    # are approval routes, and looped /suspended <-> dashboard.
    # Compared with whitespace collapsed, because the condition spans lines.
    flat = re.sub(r"\s+", " ", router)
    if "isApprovalRoute && authState.isApproved" not in flat:
        problems.append(
            "the approval-resolved branch is no longer `isApprovalRoute && "
            "authState.isApproved`. A looser condition (not pending, not "
            "rejected) also matches SUSPENDED/INACTIVE and deadlocks them "
            "against /suspended")

    return problems


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
def check_admin_sidebar_cards_are_guarded() -> list[str]:
    """Every admin sidebar card must carry its OWN `if` permission guard.

    In a Dart list literal, `[if (c) a, b]` gives the `if` only the element
    `a`; `b` becomes an unconditional sibling. Writing two cards under one
    `if` by indentation therefore compiles, runs, and silently un-gates the
    second one. That is exactly what happened to "Fees & Pricing": it was
    written as a second argument to the System Settings `if`, so the admin
    gate covered System Settings only and every staff member was shown a
    money screen they cannot use.

    The check walks backwards from each card call, matching parentheses, and
    requires the enclosing `if` to actually enclose THAT call. A dangling
    comma between the `if (...)` and the card is the whole failure mode, so
    "is there an `if` somewhere earlier in the file" is far too weak a test.
    """
    problems: list[str] = []
    checked = 0

    for path in dart_sources():
        if "admin" not in path.name:
            continue
        src = _strip_comments(_read(path))

        for m in re.finditer(r"\b_menuCard\(", src):
            # Skip the widget's own DECLARATION (`Widget _menuCard(...)`).
            # Keyed on the return type, not on a name, so renaming the method
            # makes the declaration a false positive again -- loudly, which is
            # the right way to fail.
            if src[:m.start()].rstrip().endswith("Widget"):
                continue

            # Walk backwards over whitespace only. A comma here is the bug.
            i = m.start() - 1
            while i >= 0 and src[i].isspace():
                i -= 1
            if i < 0:
                problems.append(
                    "%s: a _menuCard( call has nothing before it at all."
                    % path.name)
                continue

            # Comments are already gone, but the guard may itself sit behind
            # one; strip nothing else and match the paren back to its `if`.
            if src[i] != ")":
                problems.append(
                    "%s: the _menuCard( at offset %d is not directly "
                    "preceded by an `if (...)` guard (found %r instead). In a "
                    "list literal a card written after another card's `if` "
                    "becomes an unconditional element."
                    % (path.name, m.start(), src[i]))
                continue

            depth = 0
            open_at = -1
            while i >= 0:
                if src[i] == ")":
                    depth += 1
                elif src[i] == "(":
                    depth -= 1
                    if depth == 0:
                        open_at = i
                        break
                i -= 1

            if open_at < 0:
                problems.append(
                    "%s: unbalanced parentheses before the _menuCard( at "
                    "offset %d." % (path.name, m.start()))
                continue

            head = src[:open_at].rstrip()
            if not head.endswith("if"):
                problems.append(
                    "%s: the _menuCard( at offset %d is wrapped in "
                    "(...) but that is not an `if` guard -- it looks like a "
                    "dangling card that will render for everyone."
                    % (path.name, m.start()))
                continue
            checked += 1

    if checked == 0:
        return ["no guarded _menuCard( call found in any admin dashboard -- "
                "did the sidebar move or get renamed?"]
    return problems


def check_nearest_area_is_wired() -> list[str]:
    """The GPS "where" path must resolve the SMALL area, not just the city.

    The reported symptom was that the where button named the nearest city and
    the nearest big institution and nothing smaller -- no kebele, no sub-city,
    no nearest-area name. Three separate things had to be true, and none of
    them was true:

      1. the geocoder read only `city ?? town ?? village ?? state` out of
         Nominatim's address map and discarded `suburb` / `neighbourhood` /
         `city_district` -- the small-area keys -- which were arriving over
         the wire the whole time;
      2. `nearbyPlaces` is backed by Photon /reverse, which only indexes
         place-level features, so it structurally cannot return a kebele;
      3. the ride screen set the pickup field to the literal string
         'Current Location' on every GPS fix and never reverse-geocoded at
         all.

    Fixing one and not the others leaves the same user-visible bug, and none
    of the three is a compile error -- so this check asserts all three.
    """
    problems: list[str] = []

    geo = _strip_comments(_read(LIB / "core" / "services"
                                / "geocoding_service.dart"))
    if not geo:
        return ["lib/core/services/geocoding_service.dart is missing"]

    # 1. ReverseGeocode actually carries an area, and it is populated from
    #    the address map rather than left at its default.
    if "class ReverseGeocode" not in geo:
        problems.append("ReverseGeocode no longer exists in geocoding_service")
    else:
        if not re.search(r"\bString\s+area\b", geo):
            problems.append(
                "ReverseGeocode has no `area` field, so the small-area name "
                "has nowhere to live and the city-only behaviour is back")
        if "hasArea" not in geo:
            problems.append(
                "ReverseGeocode has no hasArea getter, so no screen can tell "
                "'we named an area' from 'the provider told us nothing'")

    body = _dart_body(geo, "reverseGeocode")
    if not body:
        problems.append(
            "could not extract the Dart body of reverseGeocode() from "
            "geocoding_service.dart -- the check cannot verify it reads the "
            "small-area address keys")
    else:
        for key in ("suburb", "neighbourhood"):
            if key not in body:
                problems.append(
                    "reverseGeocode() no longer reads the '%s' address key. "
                    "Those are the kebele / sub-city names; without them the "
                    "nearest-area name can never resolve." % key)
        if "namedetails" not in body:
            problems.append(
                "the Nominatim /reverse call no longer asks for namedetails, "
                "so the specific place name is unavailable")

    # 2. A source that is not a name index can supply small areas.
    if "nearbyAreas(" not in geo:
        problems.append(
            "GeocodingService has no nearbyAreas(). Photon (the only nearby "
            "source) indexes cities and large institutions only, so small "
            "areas need a structural query -- Overpass -- to appear at all.")
    if "_overpassUrl" not in geo:
        problems.append(
            "the Overpass endpoint constant is gone; nearbyAreas() has no "
            "data source without it")

    # 3. The GPS pickup path resolves and shows the area. A hardcoded
    #    'Current Location' with no lookup nearby is the original bug.
    ride = _strip_comments(_read(LIB / "features" / "user"
                                 / "user_ride_request_screen.dart"))
    if not ride:
        return problems + ["lib/features/user/user_ride_request_screen.dart "
                           "is missing"]
    if "reverseGeocode" not in ride:
        problems.append(
            "user_ride_request_screen.dart never calls reverseGeocode, so "
            "the GPS pickup field cannot show a nearest-area name")
    if "nearbyAreas" not in ride:
        problems.append(
            "user_ride_request_screen.dart never calls nearbyAreas(), so the "
            "small areas are fetched but never offered to the rider")
    if "_pickupAreaLabel" not in ride:
        problems.append(
            "user_ride_request_screen.dart has no _pickupAreaLabel, so the "
            "resolved area is stored and never rendered")

    # ...and at least one surface must show the rider where they are.
    if not any("_areaLabel" in _strip_comments(_read(p))
               for p in dart_sources()
               if "live_map" in p.name or "ride" in p.name):
        problems.append(
            "no map or ride surface renders the resolved area label, so the "
            "lookup runs and its answer is discarded")

    return problems


def _dart_body(src: str, name: str) -> str:
    """The `{ ... }` body of the first Dart method/function called `name`.

    `function_body` above is the SQL extractor -- it looks for
    `FUNCTION public.<name>(`, so it returns nothing for a Dart method. This
    is the Dart equivalent: find the call/declaration, skip its parameter
    list, then brace-match. Used by checks that assert what a Dart body reads
    or calls, which is most of what a client can break silently.

    Returns "" when the method is absent, so callers must treat "" as
    "could not inspect" rather than "empty body" -- otherwise a deleted
    method and an empty one look identical.
    """
    m = re.search(r"\b%s\s*\(" % re.escape(name), src)
    if not m:
        return ""
    i = m.end() - 1
    depth = 0
    # Skip the parameter list.
    while i < len(src):
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
            if depth == 0:
                i += 1
                break
        i += 1
    # Skip to the opening brace of the body.
    while i < len(src) and src[i] != "{":
        if src[i] == ";":
            return ""  # an abstract/declared method, or a call site
        i += 1
    if i >= len(src):
        return ""
    start = i
    depth = 0
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
        i += 1
    return ""


def check_fee_switches_survive_restatement() -> list[str]:
    """Every function 0073 pinned to a fee switch must still read that switch.

    The most expensive finding of this round, and the one no local gate could
    see. 0073 wired `fee_enabled_transaction` into `platform_transaction_fee`
    and `fee_enabled_ride` into `calculate_fare_estimate`. 0107 restated both
    as delegations to new category-aware resolvers -- a correct refactor -- and
    the switch reads went with the old bodies. Both switches became stored but
    inert: the CEO's toggle saved, showed, and changed nothing the platform
    charged.

    `assert_fee_switches_are_wired()` catches this, but it is a SQL function
    that only runs against a live database, so the failure surfaces AFTER the
    deploy, in the connectivity run. This asks the same question of the source
    the deploy will push, which is where it should have been caught.

    The pairs are the ones 0073 pins, read from 0073 itself rather than
    retyped, so adding a pair there cannot leave this check behind.
    """
    # Located by DEFINITION, not by mention. "The last migration containing
    # the name" picked 0115, whose comments refer to the assertion while the
    # pair list lives in 0073 -- the third time this session that a locator
    # matching a bare string found the wrong file. A check that reads its own
    # input from a comment is matching nothing.
    pinner, _ = last_migration_defining("assert_fee_switches_are_wired")
    if pinner is None:
        return ["no migration defines assert_fee_switches_are_wired, so the "
                "list of (function, switch) pairs cannot be read -- the "
                "assertion was renamed or removed and this check is now "
                "testing a hard-coded list that nothing maintains"]

    src = _read(pinner)
    pairs = re.findall(
        r"\['([a-z_]+)',\s*'(fee_enabled_[a-z_]+)'\]", src)
    if not pairs:
        return ["%s: could not read any (function, switch) pair, so this "
                "check is matching nothing" % pinner.name]

    problems: list[str] = []
    for fn, flag in pairs:
        # `last_migration_defining` returns the whole FILE, so the FUNCTION
        # BODY is what gets searched. Reading the file instead reported green
        # on a mutation that deleted the switch, because 0115's comments
        # mention `fee_enabled_transaction` while its code no longer read it
        # -- the same "a mention is not an implementation" mistake this check
        # exists to catch, made by the check itself. The falsifier found it.
        path, sql = last_migration_defining(fn)
        if path is None:
            problems.append("%s() is missing" % fn)
            continue
        body = function_body(sql, fn)
        if not body:
            problems.append(
                "%s(): %s defines it but the body could not be read, so this "
                "check cannot tell whether the switch survived"
                % (fn, path.name))
            continue
        if flag not in body:
            problems.append(
                "%s(): the authoritative definition in %s no longer reads "
                "%s, so that CEO switch is stored but inert. 0073 wired it and "
                "a later restatement dropped it -- this is what happened to "
                "platform_transaction_fee and calculate_fare_estimate in 0107, "
                "and the database only told us after the deploy."
                % (fn, path.name, flag))
    return problems


def authoritative_patch(fn_name: str, old: str, new: str) -> dict[str, str]:
    """A `{filename: patched source}` for the migration that WINS for `fn_name`.

    For falsifiers that mutate a function body. Patching a specific old file
    stops working the moment a later migration restates that function -- the
    mutation lands nowhere, the check reads the newer body, and the case goes
    green while proving nothing. That happened to three falsifiers when 0115
    restated six functions, and it is silent, which is what makes it dangerous.

    Raises (rather than returning an empty patch) when the anchor is absent,
    so a stale needle is a loud failure and never a quiet pass.
    """
    path, _ = last_migration_defining(fn_name)
    if path is None:
        raise AssertionError("no migration defines %s" % fn_name)
    src = _read(path)
    if old not in src:
        raise AssertionError(
            "anchor missing for %s in its authoritative migration %s"
            % (fn_name, path.name))
    return {path.name: src.replace(old, new)}


def category_fee_storage_migration() -> Path | None:
    """The migration that CREATES `category_fee_settings`.

    Shared by the check and its falsifier on purpose. Both used to locate it
    with "the last migration mentioning the name", which is not the same
    question: 0115 restates an assertion that READS information_schema for
    'category_fee_settings', so the check demanded the resolver fallback chain
    in a needle fix, and the falsifier mutated a file with no table definition
    in it and passed while proving nothing. One locator, one answer.
    """
    found = None
    for candidate in migration_files():
        if re.search(
                r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?"
                r"category_fee_settings\b", _read(candidate), re.IGNORECASE):
            found = candidate
    return found


def check_category_fees_are_wired() -> list[str]:
    """Per-category / per-city fees must be reachable end to end.

    Four separate things have to hold, and none of them is a compile error:

      1. every money column is NULLABLE, and NULL means inherit. A NOT NULL
         column (or a default of 0) would make an empty table mean "every fee
         is zero" instead of "every fee is today's global rate" -- which is
         the difference between a harmless new table and the platform giving
         away rides.
      2. the three money paths actually consult the resolver. Rewriting the
         table without rewiring deduct_subscription_fee would leave the admin
         editing a number nothing charges.
      3. the admin screen, its route and its sidebar card all exist. A schema
         with no door is the exact defect that `categories.metadata` per_km
         already has.
      4. the screen never pre-fills a draft from the EFFECTIVE number. The
         catalogue reports resolved numbers, and seeding the text fields with
         them would save them as hard overrides on the first unrelated edit,
         silently freezing the platform default forever.
    """
    problems: list[str] = []

    # The migration that CREATES the storage, not the last one to mention the
    # name. Matching on the bare string picked 0115, which only restates an
    # assertion that READS information_schema for 'category_fee_settings' --
    # so the check demanded the resolver fallback chain in a file whose job is
    # to fix two needles, and reported it as a fee-wiring defect.
    path = category_fee_storage_migration()
    if path is None:
        return ["no migration creates category_fee_settings -- per-category "
                "and per-city fees have no storage"]

    sql = _read(path)
    body = _strip_comments(sql)

    # 1. nullable, and NULL really means inherit.
    #
    # The match must run to END OF LINE, not stop at the word `numeric`:
    # `^\s*col\s+numeric` captures only up to `numeric`, so a `NOT NULL`
    # after it is invisible and this loop can never fire. That is a check
    # that reports green forever -- the exact failure the falsifier exists
    # to catch, and it caught this one.
    for token in ("commission_percent", "subscription_fee", "ride_per_km",
                  "commission_min", "activation_fee", "ride_base_fare",
                  "ride_minimum_fare"):
        m = re.search(r"^[ \t]*%s[ \t]+numeric[^\n]*" % re.escape(token),
                      body, re.M)
        if m and re.search(r"\bNOT\s+NULL\b", m.group(0)):
            problems.append(
                "%s: %s is NOT NULL (%s) -- an empty table would no longer "
                "mean \"inherit the global rate\""
                % (path.name, token, m.group(0).strip()))

    if "coalesce(f." not in body and "COALESCE(f." not in body.upper():
        problems.append(
            "%s: no resolver falls back from the override to the global "
            "setting; an empty table would break pricing instead of "
            "preserving it" % path.name)

    # 2. the money paths read the resolver
    for fn, needle, why in (
        ("deduct_subscription_fee", "fee_subscription",
         "a per-category subscription rate would be silently ignored"),
        ("deduct_transaction_fee", "platform_transaction_fee_for",
         "a per-category commission would be silently ignored"),
        ("calculate_fare_estimate_at", "fee_ride_per_km",
         "a per-category or per-city fare would be silently ignored"),
    ):
        target, defn = last_migration_defining(fn)
        if target is None:
            problems.append("no migration defines public.%s()" % fn)
            continue
        fbody = function_body(defn, fn)
        if needle not in fbody:
            problems.append(
                "%s: %s() no longer reads %s -- %s"
                % (target.name, fn, needle, why))

    # 3. there is a door
    screen = LIB / "features" / "admin" / "category_fee_settings_screen.dart"
    if not screen.is_file():
        problems.append(
            "lib/features/admin/category_fee_settings_screen.dart is missing "
            "-- the per-category rates have no editor, which is the defect "
            "categories.metadata per_km already suffers from")
    else:
        router = _read(LIB / "routing" / "app_router.dart")
        if "'/admin/fees/categories'" not in router:
            problems.append(
                "app_router.dart has no /admin/fees/categories route, so the "
                "category fee screen cannot be reached")
        dash = _strip_comments(_read(LIB / "features" / "admin"
                                     / "admin_dashboard.dart"))
        if "/admin/fees/categories" not in dash:
            problems.append(
                "admin_dashboard.dart has no sidebar card for "
                "/admin/fees/categories -- the screen exists with no way in")

    # 4. the inheritance trap, and the field-to-RPC contract
    if screen.is_file():
        s = _strip_comments(_read(screen))
        if "'admin_save_category_fee'" not in s:
            problems.append(
                "category_fee_settings_screen.dart never calls "
                "admin_save_category_fee -- the form cannot save")
        if "'admin_clear_category_fee'" not in s:
            problems.append(
                "category_fee_settings_screen.dart has no way back to the "
                "platform default (admin_clear_category_fee)")

        # Every declared field list must be part of what the save call sends.
        # A field list that is rendered but not sent is a control that looks
        # live and silently discards what the admin typed.
        params = set(re.findall(r"param:\s*'(p_[a-z_]+)'", s))
        if not params:
            problems.append(
                "category_fee_settings_screen.dart declares no _FeeField "
                "params -- the field list is empty or was renamed")

        save_call = s[s.find("'admin_save_category_fee'"):]
        save_call = save_call[:save_call.find("});")] if "});" in save_call else save_call

        # Two shapes satisfy the contract, and the check must know both or it
        # reports the second one as a defect:
        #   * the call names each group literally, or
        #   * the call iterates the groups the selected fee MODEL uses and
        #     sends `f.param` for each field -- which is what this screen does.
        # In the second shape the group names live in the model mapping, so
        # that mapping is read. Either way the invariant is unchanged: a group
        # that is rendered but can never be sent is a control that silently
        # discards what the admin typed.
        sends_every_field = re.search(
            r"for\s*\(\s*final\s+\w+\s+in\s+_?[A-Za-z0-9]+\s*\)\s*"
            r"for\s*\(\s*final\s+(\w+)\s+in\s+\w+\s*\)\s*"
            r"\n?\s*\1\.param\s*:",
            save_call, re.S)
        reachable_groups = set(_groups_the_model_mapping_can_return(s))

        declared_groups = re.findall(
            r"const\s+List<_FeeField>\s+(_[A-Za-z0-9]+)\s*=\s*\[", s)
        if not declared_groups:
            problems.append(
                "category_fee_settings_screen.dart declares no "
                "const List<_FeeField> group -- the field lists were renamed "
                "or removed")

        for group in declared_groups:
            if group in save_call:
                continue  # named literally by the call
            if sends_every_field and group in reachable_groups:
                continue  # sent through the model mapping's loop
            problems.append(
                "category_fee_settings_screen.dart renders %s but the "
                "admin_save_category_fee call can never send it -- every "
                "input in that group is discarded on save" % group)

        # Seeding a draft from the row would freeze the platform default.
        # Checked structurally rather than by lookahead: a negative lookahead
        # after `\?\?\s*` is defeated by backtracking the `\s*` to zero, so it
        # matches nothing and reports nothing forever.
        ctrl_re = re.compile(r"TextEditingController\(text:\s*([^)]*)\)")
        matches = list(ctrl_re.finditer(s))
        if not matches:
            problems.append(
                "category_fee_settings_screen.dart builds no "
                "TextEditingController -- the fee form has no inputs")

        # The SIMULATOR's inputs are not fee inputs. `_SimState` seeds its
        # example distance ('5' km), nights ('1') and amount ('1000' birr) on
        # purpose: they are the numbers the preview example is computed from,
        # and a blank one would make the simulator meaningless. Reading every
        # controller in the file as a fee input reported those three as
        # "prefilled fee fields" -- a false positive that made a correct screen
        # look broken. Fee inputs are the ones built from their own draft.
        sim_block = re.search(r"class _SimState\b.*?\n\}", s, re.S)
        sim_src = sim_block.group(0) if sim_block else ""

        fee_inputs = 0
        for m in matches:
            seed = m.group(1).strip()
            in_simulator = bool(sim_src) and m.group(0) in sim_src
            if re.search(r"effective|\brow\b|column", seed):
                problems.append(
                    "category_fee_settings_screen.dart seeds a fee input from "
                    "%r. Seeding it with the EFFECTIVE number means the first "
                    "save writes the platform default back as a hard override "
                    "and it can never move again. Show effective values as "
                    "hints under the field instead." % seed)
            elif re.fullmatch(r"_drafts\[[^\]]+\]\s*\?\?\s*''", seed):
                fee_inputs += 1
            elif not in_simulator:
                problems.append(
                    "category_fee_settings_screen.dart seeds a fee input from "
                    "%r rather than from its own empty draft -- a prefilled "
                    "field cannot express 'inherit the platform default'."
                    % seed)

        if fee_inputs == 0:
            problems.append(
                "category_fee_settings_screen.dart builds no fee input from "
                "its own empty draft (_drafts[...] ?? '') -- a fee field that "
                "cannot be left blank cannot express 'inherit the platform "
                "default'")

    return problems


def check_permission_flags_reach_the_widget() -> list[str]:
    """A flag read after the last setState never reaches the widget tree.

    The reported bug: "city/category management in admin side bar is not
    opening -- the icon is there but no opening". The route was right, the card
    was right, the RPCs were all granted and deployed. The screen was:

        setState(() { _rows = ...; _loading = false; });
        _canEdit = await _readEditorFlag();

    `_canEdit` is assigned AFTER the final rebuild, so nothing ever rebuilds
    with it. It stays false for the life of the screen, and every control
    gated on it is dead: the category dropdown's `onChanged` is null, no
    category can be selected, no fee section renders, and the screen tells the
    ACCOUNT OWNER that only the account owner can change what the platform
    charges. From outside that is indistinguishable from a card that does not
    open -- which is exactly how it was reported.

    `flutter analyze` cannot see this: the field is read, so it is not
    "unused", and the assignment type-checks. Only the ORDER of the two
    statements reveals it.
    """
    problems: list[str] = []

    for path in sorted(LIB.rglob("*.dart")):
        src = _read(path)
        # `});\n  _flag = await ...` -- a field written immediately after a
        # closed setState block, with no setState between the two.
        for m in re.finditer(
                r"\}\);\s*\n(\s*)(_[A-Za-z0-9]+)\s*=\s*await\b", src):
            line = src[:m.start()].count("\n") + 1
            flag = m.group(2)
            problems.append(
                "%s:%d assigns %s straight after a setState with no rebuild "
                "after it. The widget never sees the new value, so every "
                "control gated on %s stays at its initial state -- a screen "
                "that looks broken and is not. Read the flag before the "
                "setState, or set it inside one."
                % (str(path.relative_to(ROOT)).replace("\\", "/"),
                   line, flag, flag))

    # Note what this deliberately does NOT do: it does not report a problem
    # when it matches nothing. Matching nothing is what a FIXED codebase looks
    # like, and an "I found no instances of the bug" branch would turn the one
    # clean result into a red. The proof that this anchor still matches the
    # shape it was written for lives in falsify_permission_flag.py, which puts
    # the defect back into a copy of the tree and requires this check to go
    # red — a check that has never been seen red is not yet a check.
    return problems


def check_content_control_is_wired() -> list[str]:
    """The authority surface must exist on the database AND in the app.

    "Full authority to delete uploaded provider images if they violate the
    terms, and to suspend any violent person or activities" is one screen. It
    is absent, and three separate things have to hold for it to be more than a
    button:

      1. the database has somewhere to RECORD what was done — without an
         append-only log, a takedown is indistinguishable from a bug;
      2. the functions exist with the exact signatures the client calls, and
         are admin-gated. A function that exists but is callable by `anon` is
         worse than no function;
      3. the screen, the route and the sidebar card exist, so it can be
         reached.
    """
    problems: list[str] = []

    path = ROOT / "supabase" / "migrations" / (
        "20260927000122_the_admin_can_actually_take_something_down.sql")
    if not path.is_file():
        return ["%s is missing -- an administrator cannot remove an image or "
                "record why they did" % path.name]

    sql = _read(path)
    body = _strip_comments(sql)

    for table in ("moderation_actions", "content_reports"):
        if not re.search(r"CREATE TABLE IF NOT EXISTS public\.%s\b" % table, body):
            problems.append(
                "0122 does not create public.%s, so a takedown or a suspension "
                "leaves no record" % table)

    for fn, args in (("admin_moderate_image", "text, text, text, text"),
                     ("admin_suspend_account", "uuid, text, text"),
                     ("admin_reinstate_account", "uuid, text"),
                     ("admin_resolve_content_report", "uuid, text, text"),
                     ("file_content_report",
                      "uuid, uuid, text, text, text, text")):
        if ("FUNCTION public.%s(%s)" % (fn, args)) not in body:
            problems.append(
                "0122 does not define public.%s(%s) -- the client calls exactly "
                "that signature" % (fn, args))

    # Admin-gating, asserted per function rather than by counting GRANTs: a
    # REVOKE that names one function and not another leaves that one callable
    # by anybody who guessed its name.
    for fn in ("admin_moderate_image", "admin_suspend_account",
               "admin_reinstate_account", "admin_resolve_content_report"):
        m = re.search(r"FUNCTION public\.%s\([^)]*\)(.*?)\$\$;" % fn, body,
                      re.DOTALL)
        if not m:
            continue
        if "IF NOT public.is_admin()" not in m.group(1):
            problems.append(
                "0122's %s() has no is_admin() guard. A content takedown or an "
                "account suspension callable by a signed-in customer is not a "
                "moderation tool, it is a vulnerability." % fn)
        if "GRANT EXECUTE ON FUNCTION public.%s" % fn not in body:
            continue
        # And it must be revoked from anon.
        if not re.search(r"REVOKE ALL ON FUNCTION public\.%s\([^)]*\)\s*\n?\s*"
                         r"FROM PUBLIC, anon" % fn, body):
            problems.append(
                "0122's %s() is not revoked from anon" % fn)

    # `<> ANY` is the membership test everybody writes and nobody means.
    if re.search(r"p_bucket\s*<>\s*ANY", body):
        problems.append(
            "0122 tests the bucket with `<> ANY (ARRAY[...])`. `<> ANY` is "
            "AND-semantics, so a bucket that IS on the list reads as not "
            "moderable and every takedown fails with "
            "THAT_BUCKET_IS_NOT_MODERABLE. Use `<> ALL`.")

    screen = LIB / "features" / "admin" / "admin_content_control_screen.dart"
    if not screen.is_file():
        problems.append("lib/features/admin/admin_content_control_screen.dart "
                        "is missing -- the moderation functions have no door")
    else:
        s = _strip_comments(_read(screen))
        for rpc in ("admin_content_reports", "admin_moderation_actions",
                    "admin_suspend_account", "admin_resolve_content_report"):
            if "'%s'" % rpc not in s:
                problems.append(
                    "admin_content_control_screen.dart never calls %s()" % rpc)
        # The delete path goes through the admin-image-delete Edge Function:
        # the row + audit through admin_moderate_image, the FILE through the
        # Storage API, because a direct DELETE on storage.objects is refused
        # for every role. A screen that lost the call would leave the delete
        # button with nothing behind it — and a screen that fell back to the
        # RPC would look like it deleted the image while the file stayed.
        if ("AdminImageDeleteService" not in s
                and "'admin-image-delete'" not in s):
            problems.append(
                "admin_content_control_screen.dart never reaches the "
                "admin-image-delete Edge Function, so the delete button has "
                "nothing behind it (or removes the row while the file stays)")
        else:
            # The function the screen reaches must itself delete the row and
            # the audit record; a file removed around a surviving row is a
            # broken image.
            edge = (ROOT / "supabase" / "functions" / "admin-image-delete"
                    / "index.ts")
            if not edge.is_file():
                problems.append(
                    "admin_content_control_screen.dart calls the "
                    "admin-image-delete function, but "
                    "supabase/functions/admin-image-delete/index.ts does not "
                    "exist — the call reaches nothing")
            elif "admin_moderate_image" not in edge.read_text(
                    encoding="utf-8", errors="replace"):
                problems.append(
                    "admin-image-delete never calls admin_moderate_image(), "
                    "so a takedown writes no row and no audit record")

    router = _read(LIB / "routing" / "app_router.dart")
    if "'/admin/content'" not in router:
        problems.append("app_router.dart has no /admin/content route")

    dash = _strip_comments(_read(LIB / "features" / "admin"
                                 / "admin_dashboard.dart"))
    if "'/admin/content'" not in dash:
        problems.append("admin_dashboard.dart has no sidebar card for "
                        "/admin/content -- the screen exists with no way in")

    return problems


def check_transaction_documents_are_wired() -> list[str]:
    """Every transaction must leave a document, on every path, for both parties.

    Three things, and the first is the one that is easy to believe is enough:

      1. the documents are written by a TRIGGER on the status-history tables.
         Restating `transition_order_status` / `transition_ride_status` to
         write them would mean reproducing every branch of both, and 0088
         records what a missing branch costs — a ride frozen in a state nobody
         can move out of, with no fee ever charged;
      2. the trigger is AFTER INSERT, so a transaction that rolls back takes
         its document with it. A slip for an order that never existed is worse
         than no slip;
      3. the parties are snapshotted and readable by exactly the customer, the
         provider and an admin.
    """
    problems: list[str] = []

    path = ROOT / "supabase" / "migrations" / (
        "20260927000121_every_transaction_leaves_a_document.sql")
    if not path.is_file():
        return ["%s is missing -- no transaction leaves a document" % path.name]

    sql = _read(path)
    body = _strip_comments(sql)

    if "CREATE TABLE IF NOT EXISTS public.transaction_documents" not in body:
        problems.append("0121 does not create public.transaction_documents")

    for tbl, trg in (("order_status_history", "trg_write_order_transaction_document"),
                     ("ride_status_history", "trg_write_ride_transaction_document")):
        m = re.search(r"CREATE TRIGGER %s\s+AFTER INSERT ON public\.%s"
                      % (re.escape(trg), re.escape(tbl)), body)
        if not m:
            problems.append(
                "0121 has no `AFTER INSERT` trigger %s on public.%s -- a "
                "BEFORE trigger would record the status the subject has not "
                "reached yet, and a trigger on the subject table instead of "
                "the history table would miss every path that writes history "
                "without touching status." % (trg, tbl))

    # Both parties, snapshot. Reading them through a join at display time means
    # the document changes when the parties change, which defeats the purpose.
    for col in ("customer_name", "customer_phone", "provider_name",
                "provider_phone", "platform_fee", "subject_snapshot"):
        if col not in body:
            problems.append(
                "0121's transaction_documents has no %s column, so the slip "
                "cannot carry both parties' information" % col)

    # The reader must not be a bare OR-chain the filters hang off.
    m = re.search(r"FUNCTION public\.my_transaction_documents\(.*?\$\$;", body,
                  re.DOTALL)
    if m:
        fn = m.group(0)
        if "customer_user_id = (SELECT auth.uid())" in fn and \
                "OR d.provider_user_id = (SELECT auth.uid())\n" in fn and \
                "AND (p_subject_type IS NULL" in fn:
            problems.append(
                "0121's my_transaction_documents filters the OR-chain without "
                "parentheses: `AND` binds tighter than `OR`, so a CUSTOMER's "
                "documents ignore p_subject_type/p_subject_id and asking for "
                "one order returns every order they have placed.")

    for bucket in ("transaction-slips",):
        if bucket not in body:
            problems.append(
                "0121 never creates the %s bucket, so a slip has nowhere to be "
                "attached" % bucket)
        elif re.search(r"VALUES\s*\(\s*'%s',\s*'%s',\s*true" % (bucket, bucket),
                       body):
            problems.append(
                "0121 creates %s as a PUBLIC bucket. A slip carries a delivery "
                "address and two phone numbers." % bucket)

    screen = LIB / "features" / "shared" / "transaction_documents_screen.dart"
    if not screen.is_file():
        problems.append(
            "lib/features/shared/transaction_documents_screen.dart is missing "
            "-- documents are written and nobody can read one")
    elif "'my_transaction_documents'" not in _read(screen):
        problems.append(
            "transaction_documents_screen.dart never calls "
            "my_transaction_documents")

    return problems


def check_grantable_permissions_open_something() -> list[str]:
    """A permission a CEO can hand a staff member must gate something.

    `staff_jobs` is the catalogue a CEO assigns from, and `staff_assignment`
    refuses a key the catalogue does not hold -- so every key in it is a real,
    grantable promise. `document_verification` was seeded in 20260927000034 with
    the label "Review identity documents and record a verified or rejected
    decision" and sat in the admin staff screen's checklist for the whole life of
    the feature, granting **nothing**: no screen consulted it, because the only
    way to reach `review_user_document()` was a dialog inside one user row on the
    Users page, behind the `registrations` key instead. Two keys for one action,
    and the specific one dead.

    This reads the seeded keys out of the migrations, then requires each one to
    be used as an actual gate somewhere in `lib/`. Displaying a key in the
    checklist that offers it is not a use: `admin_staff_screen._permissionOptions`
    names all ten, which is exactly why the dead one was invisible.
    """
    problems: list[str] = []

    seeded: dict[str, str] = {}
    for path in sorted(MIGRATIONS.glob("*.sql")):
        sql = _strip_comments(_read(path))
        # ONLY the catalogue insert. A bare `('x', 'y', ...)` scan over the
        # whole file matched every VALUES tuple in 220 migrations -- fee names,
        # category slugs, trigger names, GRANT roles -- and reported 63 dead
        # "permissions" that do not exist. The INSERT keyword and the VALUES
        # block are both required, and the block is bounded by its closing
        # semicolon so nothing after it leaks in.
        for stmt in re.finditer(
                r"INSERT\s+INTO\s+(?:public\.)?staff_jobs\b[^;]*?;",
                sql, re.S | re.I):
            block = stmt.group(0)
            vm = re.search(r"VALUES\b(.*)$", block, re.S | re.I)
            if not vm:
                continue
            for m in re.finditer(
                    r"\(\s*'([a-z_][a-z_0-9]{2,40})'\s*,\s*'([^']{2,200})'",
                    vm.group(1)):
                seeded.setdefault(m.group(1), m.group(2))

    if not seeded:
        return ["no staff_jobs keys could be read from the migrations, so this "
                "check cannot tell a live permission from a dead one"]

    # Narrowed to what the app's OWN staff checklist offers. `staff_jobs` also
    # holds fixture and future keys (`probe_customer_orders`, `password_reset`)
    # that the CEO interface never lists and so cannot hand out from the app;
    # holding those to the same standard would report keys no user can assign.
    offered_keys: set[str] = set()
    for p in sorted(LIB.rglob("*staff*.dart")):
        for m in re.finditer(r"'([a-z_][a-z_0-9]{2,40})'\s*:\s*'[^']+'",
                             _read(p)):
            offered_keys.add(m.group(1))
    seeded = {k: v for k, v in seeded.items() if k in offered_keys}
    if not seeded:
        return ["the staff checklist in lib/ offers no staff_jobs key this "
                "check recognises, so it cannot compare the catalogue against "
                "the permissions the app actually grants"]

    # Where a key is merely OFFERED, versus where it GATES something.
    gates: dict[str, list[str]] = {}
    for p in sorted(LIB.rglob("*.dart")):
        src = _read(p)
        for key in seeded:
            # A gate is the key compared against a permission list, not the key
            # quoted as a checklist entry.
            for pat in (r"_can\(\s*'%s'" % re.escape(key),
                        r"_hasPermission\(\s*'%s'" % re.escape(key),
                        r"permissions\.contains\(\s*'%s'" % re.escape(key),
                        r"perms\.contains\(\s*'%s'" % re.escape(key),
                        r"hasPermission\(\s*'%s'" % re.escape(key),
                        r"perm\s*==\s*'%s'" % re.escape(key)):
                if re.search(pat, src):
                    gates.setdefault(key, []).append(p.name)

    for key, label in sorted(seeded.items()):
        if key in gates:
            continue
        if key in _UNSERVED_PERMISSIONS:
            continue
        problems.append(
            "staff_jobs offers the permission '%s' (\"%s\"), so a CEO can "
            "assign it to a staff member, but no Dart file gates anything on "
            "it -- it grants access to nothing. Either wire a screen to it or "
            "take it out of the catalogue; leaving it there makes the staff "
            "screen promise a permission that does not exist."
            % (key, label))

    return problems


# Catalogue keys the app offers but cannot yet serve, each with the reason.
#
# An allowlist with reasons, not a suppression list: a NEW ungated key still
# fails this check, and a key can only be excused by naming why here. Removing
# these keys from `staff_jobs` instead would delete a promise the CEO interface
# already shows.
_UNSERVED_PERMISSIONS = {
    # There is no auth-event table anywhere in the schema: no sign-in log, no
    # failed-attempt counter, no session table. `admin_history_screen` reads
    # `audit_logs`, whose action types are all administrative acts and contain
    # nothing about a sign-in. So there is nothing for this permission to
    # reveal. Gating a screen on it today would be a card that opens to an
    # empty list -- which is the failure mode this check exists to prevent, not
    # a fix for it. Needs a data source first.
    "view_auth_logs": "no auth-event table exists in the schema to read",
}


def _declared_defaults(fn: str) -> set[str]:
    """Parameter names of `fn` that carry a DEFAULT in its latest declaration.

    A client that omits an OPTIONAL argument is correct; PostgREST fills the
    default. A client that omits a REQUIRED one cannot call the function at
    all. So "the keys the Dart sends" and "the parameters the function
    declares" are only required to agree once the defaulted names are removed
    from the declared side.

    Needed because `search_products` is called with nine of its fourteen
    parameters and `update_driver_location` with three of its five. Demanding
    exact equality -- as 0124's rows do, and correctly, because the client
    sends all of them -- would report every optional omission as drift.
    """
    latest: tuple[str, ...] = ()
    best: str = ""
    pat = re.compile(
        r"CREATE OR REPLACE FUNCTION\s+(?:public\.)?%s\s*\(" % re.escape(fn),
        re.I)
    for path in sorted(MIGRATIONS.glob("*.sql")):
        sql = _read(path)
        for m in pat.finditer(sql):
            depth, i = 1, m.end()
            while i < len(sql) and depth:
                if sql[i] == "(":
                    depth += 1
                elif sql[i] == ")":
                    depth -= 1
                i += 1
            body = sql[m.end():i - 1]
            best = body
    if not best:
        return set()
    raw, cur, depth = [], "", 0
    for ch in best:
        if ch == "(":
            depth += 1
        if ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            raw.append(cur)
            cur = ""
        else:
            cur += ch
    raw.append(cur)
    optional: set[str] = set()
    for piece in raw:
        p = re.sub(r"--[^\n]*", "", piece).strip()
        if not p:
            continue
        pm = re.match(r"(p_\w+)\b", p)
        if pm and re.search(r"\bDEFAULT\b|\bdefault\b", p):
            optional.add(pm.group(1))
    return optional


def check_admin_rpc_argv_is_transcribed() -> list[str]:
    """0124's expected argument names must match the Dart call sites.

    `admin_rpc_signature_report()` carries a hand-written list of the
    parameter names each admin RPC is called with, because a database function
    cannot read the Dart. That transcription is a second copy of a list the
    client already states, which is the exact shape of defect this repository
    has been bitten by repeatedly: 0118 shipped nineteen columns while the
    harness still believed 0054's eight.

    Two ways it rots, both checked here:

      1. the Dart call site gains, loses or renames an argument and the
         transcription does not — the assertion then reports "ok" for a
         mismatch it was written to catch;
      2. the Dart stops calling a function the transcription still lists, or
         starts calling one it does not — the report drifts out of date with
         the app in the other direction.
    """
    problems: list[str] = []

    mig = ROOT / "supabase" / "migrations" / (
        "20260927000124_every_admin_write_path_is_reachable.sql")
    if not mig.is_file():
        return ["%s is missing -- no admin RPC reachability assertion"
                % mig.name]

    sql = _read(mig)
    body = _strip_comments(sql)

    # ('fn', 'identity', '{a,b,c}')
    rows = re.findall(
        r"\('([a-z_]+)',\s*'public\.[a-z_]+\([^']*\)',\s*'\{([^}]*)\}'\)", body)
    if not rows:
        return ["0124 transcribes no admin RPC argument names, so "
                "admin_rpc_signature_report() is asserting nothing"]

    for fn, arglist in rows:
        expected = {a.strip() for a in arglist.split(",") if a.strip()}

        call = _rpc_call_sites(fn)
        if not call:
            problems.append(
                "0124 lists %s but no Dart file calls it -- the report has "
                "drifted out of date with the app" % fn)
            continue

        sent = _sent_keys(call, fn)
        if sent is None:
            problems.append(
                "0124 lists %s but the Dart call site's argument map could not "
                "be read, so its names cannot be verified against the client"
                % fn)
            continue

        # A map built by a `for (final f in [...]) key: value` element states
        # only some of its keys literally. The rest are read from the declared
        # field lists behind the loop, and both halves are compared against
        # 0124 -- skipping them would leave the check reporting "ok" for a
        # mismatch it was written to catch, which is how a fee editor that
        # saved nothing survived a green harness.
        dynamic = _dynamic_param_names(call, fn)
        if dynamic:
            combined = sent | dynamic
            if sent & dynamic:
                problems.append(
                    "%s is sent %s both literally and from a declared field "
                    "list, so the two spellings would have to be renamed "
                    "together" % (fn, sorted(sent & dynamic)))
                continue
            if combined != expected:
                problems.append(
                    "0124 expects %s to be called with %s, but the Dart call "
                    "site sends %s -- %s of them from the declared field "
                    "lists behind its collection-for. Either side drifted; "
                    "the assertion would report 'ok' for a mismatch it exists "
                    "to catch."
                    % (fn, sorted(expected), sorted(combined),
                       len(dynamic)))
                continue
            continue

        if sent != expected:
            problems.append(
                "0124 expects %s to be called with %s, but the Dart call site "
                "sends %s. Either side drifted; the assertion will report 'ok' "
                "for a mismatch it exists to catch."
                % (fn, sorted(expected) or "no arguments",
                   sorted(sent) or "no arguments"))

    return problems


def check_customer_rpc_argv_is_transcribed() -> list[str]:
    """0125's expected argument names must match what the customer call sites
    send, allowing for parameters that carry a DEFAULT.

    Same failure modes as `check_admin_rpc_argv_is_transcribed`, plus one that
    is specific to the customer path: a call site may legitimately OMIT an
    optional argument, which PostgREST fills from the function's DEFAULT. So the
    rule is not equality:

      * a key the function does NOT declare is PGRST202, always a failure --
        this is the `p_booking_base_fare` bug's exact shape;
      * a required parameter the client omits means the call cannot succeed;
      * an optional parameter the client omits is fine, and is why the
        defaulted names are subtracted before the comparison.

    It also has to look at Edge Functions, not just `lib/`: `create_order_secure`
    is called from supabase/functions/order-create/index.ts in TypeScript with
    unquoted object keys, so a Dart-only search reports it as uncalled by
    anything.
    """
    problems: list[str] = []

    mig = ROOT / "supabase" / "migrations" / (
        "20260927000125_the_customer_ride_path_is_reachable_too.sql")
    if not mig.is_file():
        return ["%s is missing -- no customer RPC reachability assertion"
                % mig.name]

    body = _strip_comments(_read(mig))
    rows = re.findall(
        r"\('([a-z_]+)',\s*'public\.[a-z_]+\([^']*\)',\s*'\{([^}]*)\}'\)", body)
    if not rows:
        return ["0125 transcribes no customer RPC argument names, so "
                "customer_rpc_signature_report() is asserting nothing"]

    for fn, arglist in rows:
        declared = {a.strip() for a in arglist.split(",") if a.strip()}

        call = _rpc_call_sites(fn)
        if not call:
            problems.append(
                "0125 lists %s but no Dart file and no Edge Function calls it "
                "-- the report has drifted out of date with the app" % fn)
            continue

        sent = _sent_keys(call, fn)
        if sent is None:
            problems.append(
                "0125 lists %s but the call site's argument map could not be "
                "read, so its names cannot be verified against the client"
                % fn)
            continue

        undeclared = sent - declared
        if undeclared:
            problems.append(
                "0125's %s does not declare %s, but the call site sends them. "
                "PostgREST matches named arguments by name, so an undeclared "
                "key is PGRST202 -- the call fails at runtime, and it used to "
                "reach the customer as \"it may have been removed\"."
                % (fn, sorted(undeclared)))
            continue

        optional = _declared_defaults(fn)
        omitted_required = declared - sent - optional
        if omitted_required:
            problems.append(
                "0125 expects %s to be called with %s, but the call site omits "
                "them and the function gives them no DEFAULT -- the call "
                "cannot succeed."
                % (fn, sorted(omitted_required)))

    return problems


def _rpc_call_chunk(site: str, fn: str) -> str | None:
    """The single `rpc('fn', params: {...})` chunk belonging to `fn`.

    Same scoping rule as `_sent_keys`, factored out so the dynamic-argument
    branch can look at the argument list of the call it is actually judging.
    """
    needle = "'%s'" % fn
    for chunk in [c for c in re.split(r"(?=rpc\()", site) if c.startswith("rpc(")]:
        head = chunk[:chunk.find("params:") if "params:" in chunk else len(chunk)]
        if needle in head:
            return chunk
    return None


def _dynamic_param_names(site: str, fn: str) -> set[str]:
    """Parameter names contributed by a `for (final f in [...]) name: value` map.

    `admin_save_category_fee` is called with thirteen of its fifteen arguments
    built by a collection-for over declared `_FeeField` lists, so the source
    literal does not contain those keys. Skipping them would make the check
    report "ok" for a mismatch it exists to catch, so the declared lists are
    read instead -- `f.param` names come from `param: 'p_...'`, which is the
    only place the app states them.
    """
    chunk = _rpc_call_chunk(site, fn)
    if chunk is None:
        return set()

    attr: str | None = None
    lists: list[str] = []

    # Shape 1: a single loop over a LITERAL list of declared field groups.
    loop = re.search(r"for\s*\(\s*final\s+(\w+)\s+in\s*\[(.*?)\]\s*\)", chunk, re.S)
    if loop:
        var = loop.group(1)
        # The element is `f.param: parse(f.param)` and sits AFTER the loop's
        # closing bracket, so it is read from the chunk past the match.
        # (Splitting the loop match on `"in"` does not work: the first "in" is
        # inside `final`, and the match does not contain the element at all.)
        tail = re.match(r"\s*([\w.]+):", chunk[loop.end():])
        attr = (tail.group(1) if tail else var).split(".")[-1]
        lists = re.findall(r"\b(_[A-Za-z0-9]+)\b", loop.group(2))
    else:
        # Shape 2, introduced by the per-model fee editor: a NESTED loop --
        # `for (final group in _modelFields) for (final f in group)
        # f.param: ...`. No literal list appears in the call at all, so there
        # is nothing here to read the group names from and the check reported
        # the call as sending two arguments. The groups are read from the
        # model mapping instead, which is the only place that states which
        # groups can ever be sent.
        nested = re.search(
            r"for\s*\(\s*final\s+\w+\s+in\s+_?[A-Za-z0-9]+\s*\)\s*"
            r"for\s*\(\s*final\s+(\w+)\s+in\s+\w+\s*\)\s*"
            r"\n?\s*([\w.]+):",
            chunk, re.S)
        if not nested:
            return set()
        attr = nested.group(2).split(".")[-1]
        lists = _groups_the_model_mapping_can_return(site)
        if not lists:
            return set()

    if attr is None:
        return set()
    names: set[str] = set()
    for list_name in lists:
        decl = re.search(
            r"\b%s\s*=\s*\[(.*?)\n\];" % re.escape(list_name), site, re.S)
        if not decl:
            continue
        names.update(re.findall(
            r"\b%s:\s*'([a-z_0-9]+)'\s*," % re.escape(attr), decl.group(1)))
    return names


def _groups_the_model_mapping_can_return(site: str) -> list[str]:
    """Every declared _FeeField group the fee-model mapping can return.

    The per-model editor sends `for (final group in _modelFields) for (final f
    in group) f.param: ...`, and `_modelFields` returns whatever the mapping
    function picks for the selected model. The UNION of that function's
    branches is therefore exactly the set of groups the call can send -- which
    is what has to match 0124's transcription -- and a group that no branch
    returns is the "rendered but never sent" defect, reported by
    check_category_fees_are_wired.
    """
    fn = re.search(
        r"List<List<_FeeField>>\s+\w+\s*\(\s*_FeeModel\s+\w+\s*\)\s*\{"
        r"(.*?)\n\}", site, re.S)
    if not fn:
        return []
    seen: list[str] = []
    for name in re.findall(r"\b(_[A-Za-z0-9]*Fields[A-Za-z0-9]*)\b", fn.group(1)):
        if name not in seen:
            seen.append(name)
    return seen


def _rpc_call_sites(fn: str) -> str:
    """The concatenated source of every Dart or Edge Function file that calls
    `fn`.

    Matches the two shapes the app actually uses -- `.rpc('name')` and
    `.rpc(\n  'name',\n  params: {...},\n)`. A `rpc(\n` anchor alone matched
    nothing, and a check that cannot see its own subject is worse than no
    check: it reported all fourteen functions as uncalled.

    Two details that are not optional:

      * COMMENT LINES between `rpc(` and the name. The ride screen quotes the
        five-argument wrapper and names the city-aware one several lines below
        it, and an anchor that requires the name immediately after `rpc(`
        silently misses that call. Nothing here assumes adjacency, so the
        existing lookahead over the whole file is kept deliberately.
      * EDGE FUNCTIONS, and DOUBLE QUOTES. `create_order_secure` is called from
        supabase/functions/order-create/index.ts as `admin.rpc("...", {...})`,
        in TypeScript with double quotes. Searching only `lib/` for a
        single-quoted name reported it as uncalled by every Dart file, which
        read as "the report has drifted" rather than "you looked in the wrong
        tree".
    """
    out = []
    # A lookahead, NOT `\b`. The closing quote and whatever follows it are
    # both non-word characters, so there is no word boundary there and
    # `rpc\(\s*'name'\b` matches nothing at all -- which made this report all
    # fourteen functions as uncalled while every one of them was called.
    needles = ["'%s'" % fn, '"%s"' % fn]
    files = list(LIB.rglob("*.dart"))
    edge = ROOT / "supabase" / "functions"
    if edge.is_dir():
        files += list(edge.rglob("*.ts"))
    for path in sorted(files):
        src = _read(path)
        if not any(n in src for n in needles):
            continue
        # LINE COMMENTS ARE STRIPPED BEFORE THE SEARCH, and this is not
        # cosmetic. The ride screen's comment says
        # "calculate_fare_estimate(): that wrapper was kept for older clients"
        # -- so a `[^)]*?` walk between `rpc(` and the name stops at the `)`
        # INSIDE that comment, four lines before the real call, and reports a
        # function the screen calls on every fare quote as uncalled. Comments
        # are not code and must not be able to satisfy or block an anchor.
        code = re.sub(r"//[^\n]*", "", src)
        if not any(n in code for n in needles):
            continue
        for n in needles:
            # `\s*` between `rpc(` and the name is NOT enough: the ride screen
            # puts four comment lines in between. `[^)]*?` does, and stops at
            # the closing paren so it cannot run past this call into another.
            if re.search(r"rpc\([^)]*?%s(?=[\s,)\]])" % re.escape(n), code):
                out.append(src)
                break
    return "\n".join(out)


def _sent_keys(site: str, fn: str) -> set[str] | None:
    """The keys in the `params: { ... }` map of the call to `fn` specifically.

    Scoped by function name, because one screen makes several rpc() calls and
    reading the first one in the file attributes another call's arguments to
    this one -- which reported `p_status`/`p_limit` against
    `admin_moderate_image` on a screen that does call all of them.

    Returns None when the shape cannot be read, which is a finding in its own
    right: a transcription nobody can check is not a transcription.
    """
    needle = "'%s'" % fn
    alt = '"%s"' % fn
    # Split on `rpc(` rather than matching to the next `;`: a screen that makes
    # two calls inside one `Future.wait([...])` separates them with a COMMA,
    # so a `.*?;` chunk swallowed the first call's arguments and attributed
    # them to the second. `admin_moderation_actions({p_limit})` was reported as
    # sending `p_status` because of it.
    chunks = [c for c in re.split(r"(?=rpc\()", site) if c.startswith("rpc(")]
    for chunk in chunks:
        # Comments stripped for the same reason as in _rpc_call_sites: a
        # comment mentioning `rpc()` or a sibling function name must not decide
        # which argument map belongs to this call.
        code = re.sub(r"//[^\n]*", "", chunk)
        cut = code.find("params:")
        head = code[:cut] if cut >= 0 else code
        # Both quote styles, and the name may sit BELOW comment lines (see
        # _rpc_call_sites), so `head` is searched rather than anchored at 0.
        if needle not in head and alt not in head:
            continue
        pm = re.search(r"params:\s*\{", code)
        if pm is None:
            # TYPESCRIPT PASSES THE OBJECT AS THE SECOND ARGUMENT, with no
            # `params:` key: `admin.rpc("create_order_secure",\n  {\n
            #    p_user_id: user.id, … })`. Dart always names it. Without this
            # branch the Edge Function call site reads as "called with no
            # argument map at all", so create_order_secure was reported as
            # sending nothing.
            #
            # The object is simply the first `{` AFTER the function name, which
            # is unambiguous because the name is the last thing before it.
            at = code.find(needle if needle in code else alt)
            if at < 0:
                return set()
            map_start = code.find("{", at)
            if map_start < 0:
                return set()      # genuinely called with no argument map
        else:
            map_start = pm.end()
        chunk = code
        tail = chunk[map_start:]
        # Bound the map. Without this the tail runs on into the NEXT rpc()
        # call in the same expression, so `admin_clear_category_fee` was
        # reported as sending a `category` key that belongs to a different
        # call entirely.
        close = re.search(r"\}\s*\)", tail)
        if close:
            tail = tail[:close.start()]
        # Dart quotes every key ('p_user_id': …); TypeScript does not have to
        # (p_user_id: …). Both are call sites for the same function, and the
        # bare form is the only one `create_order_secure` uses -- it is called
        # from supabase/functions/order-create/index.ts.
        keys = set(re.findall(r"'([a-z_0-9]+)'\s*:", tail))
        keys |= set(re.findall(r"^\s*([a-z_0-9]+)\s*:", tail, re.M))
        return keys
    return None


PROVIDER_ACTIONS = (
    "approve_provider",
    "reject_provider",
    "request_correction_provider",
    "suspend_provider",
    "unsuspend_provider",
)

# Surfaces where a staff member's city scope must bite, and where the ONLY
# thing standing between "scope enforced" and "scope decorative" is the guard
# line itself. `verify_payment_proof` moves money and `staff_task_feed` is the
# queue the guard is judged by: if a restatement of either is ever taken from a
# stale copy, the city scope silently stops applying to the largest surface in
# the product while every test that reads a *list* still passes.
CITY_SCOPED_MONEY_AND_FEED = (
    "verify_payment_proof",
    "staff_task_feed",
)

# The assertion that pins the two above. Naming the guard here is what makes
# the pin survive a future restatement.
CITY_SCOPE_FEED_ASSERTION = "assert_staff_city_scope_covers_the_task_feed"


def check_staff_management_is_reachable() -> list[str]:
    """Creating and supervising staff must stay in the admin sidebar.

    Staff creation is the capability this repo most regrets losing, and it
    lives in a sidebar list rather than a route: a route can be dead and
    nothing notices, because nothing navigates to it. A card can be deleted
    and the ONLY symptom is that staff creation has quietly vanished from the
    product. So both halves are asserted -- the card exists AND it points at a
    route that resolves.
    """
    problems: list[str] = []

    dash = _strip_comments(_read(LIB / "features" / "admin"
                                 / "admin_dashboard.dart"))
    if not dash:
        return ["lib/features/admin/admin_dashboard.dart is missing"]

    # The three cards that together are "create and control staff".
    required = {
        "/admin/staff": "Staff / Sub-admins (create, edit, revoke staff)",
        "/admin/staff-assignment": "Staff Assignment (roles, city, warnings, "
                                   "deletion)",
        "/admin/roles/permissions": "Role Permissions (per-staff section access)",
    }

    for route, what in sorted(required.items()):
        # Match the QUOTED route, not the bare substring. `/admin/staff` is a
        # prefix of `/admin/staff-assignment`, so a bare substring test is
        # satisfied by the wrong card -- which is precisely what the
        # falsifier caught this doing.
        if ("'%s'" % route) not in dash:
            problems.append(
                "the admin sidebar no longer links to %s (%s). Staff creation "
                "and supervision are reachable ONLY from these cards -- there "
                "is no other entry point to fall back to." % (route, what))

    # ...and each one must still be a declared route, not just a string.
    router = _read(LIB / "routing" / "app_router.dart")
    for route in sorted(required):
        if ("path: '%s'" % route) not in router:
            problems.append(
                "the sidebar links to %s but app_router.dart declares no such "
                "route -- the card is a dead end" % route)

    # The city scope must exist server-side, and something must enforce it.
    # A predicate that nothing calls is a predicate that constrains nothing,
    # which is the defect the staff-city migration exists to close.
    #
    # NOTE on scanning comment-stripped SQL: `last_migration_defining` is NOT
    # used here. Its regex matches `FUNCTION public.<name>(`, which also
    # matches the COMMENT ON / REVOKE ON / GRANT EXECUTE lines -- so renaming
    # the function in its CREATE still leaves three "definitions" behind and
    # the existence check passes on a function that no longer exists.
    defined = False
    for candidate in migration_files():
        if re.search(
                r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+"
                r"public\.staff_scope_allows_city\s*\(",
                _strip_comments(_read(candidate)), re.IGNORECASE):
            defined = True
            break

    if not defined:
        problems.append(
            "no migration DEFINES public.staff_scope_allows_city() -- a staff "
            "member's assigned city is recorded but enforces nothing")
    else:
        # Count functions whose body actually TESTS the qualified predicate in
        # a WHERE clause.
        #
        # Three things are excluded, and each exclusion was found by the
        # falsifier catching this check passing on broken input:
        #   * the predicate's own definition -- it is the definition, not a use;
        #   * the report / assertion functions -- their bodies contain the
        #     string `staff_scope_allows_city(` inside a LIKE pattern AFTER a
        #     WHERE, so a naive scan counts the very functions that REPORT
        #     enforcement as evidence that it is enforced;
        #   * the bare unqualified name -- a real call is qualified
        #     `public.staff_scope_allows_city(`.
        enforced = 0
        for candidate in migration_files():
            src = _strip_comments(_read(candidate))
            for m in FN_DEFINITION.finditer(src):
                name = m.group(1)
                if name in ("staff_scope_allows_city", "staff_city_scope",
                            "staff_city_scope_report"):
                    continue
                if name.startswith("assert_") or name.endswith("_are_wired"):
                    continue
                fbody = function_body(src, name)
                if re.search(r"WHERE[^;]*public\.staff_scope_allows_city\(",
                             fbody, re.DOTALL):
                    enforced += 1
        if enforced == 0:
            problems.append(
                "staff_scope_allows_city() is defined but no function tests it "
                "in a WHERE clause -- the city scope is decorative. The staff "
                "city column, the roster and the drill-down all display it "
                "while it stops nothing.")

        # Every provider LIFECYCLE ACTION must carry it, not just one. A scope
        # that filters a list and does not filter its buttons is half a scope:
        # a manager who cannot see an Addis Ababa provider in the queue could
        # still approve one by id.
        guarded, missing = 0, []
        for fn in PROVIDER_ACTIONS:
            target, _ = last_migration_defining(fn)
            if target is None:
                missing.append("%s (undefined)" % fn)
                continue
            fbody = function_body(_read(target), fn)
            if re.search(r"staff_scope_allows_city\(", fbody):
                guarded += 1
            else:
                missing.append(fn)
        if missing:
            problems.append(
                "%d of the %d provider lifecycle actions do not enforce the "
                "staff city scope: %s. Each already carries the category "
                "scope; the city scope must be a peer of it, not a "
                "substitute for it."
                % (len(missing), len(PROVIDER_ACTIONS), ", ".join(missing)))

        # The two money/queue surfaces must carry the guard too, and each must
        # carry it in its OWN body. Counting "the guard exists somewhere" is
        # the failure mode: the five provider actions alone satisfy that, so a
        # restatement of the task feed copied from a pre-city-scope migration
        # would pass while the largest queue in the product ignores the scope.
        unguarded: list[str] = []
        for fn in CITY_SCOPED_MONEY_AND_FEED:
            target, _ = last_migration_defining(fn)
            if target is None:
                unguarded.append("%s (undefined)" % fn)
                continue
            fbody = function_body(_read(target), fn)
            if not re.search(r"staff_scope_allows_city\(", fbody):
                unguarded.append(fn)
        if unguarded:
            problems.append(
                "these staff-facing surfaces no longer enforce the city scope: "
                "%s. staff_task_feed is the queue the scope is judged by and "
                "verify_payment_proof moves money; a scope that filters the "
                "registration queue but not the task feed is half a scope."
                % ", ".join(unguarded))

        # The assertion pinning the feed must itself name the guard, or a
        # future restatement of staff_task_feed passes CI.
        target, _ = last_migration_defining(CITY_SCOPE_FEED_ASSERTION)
        if target is None:
            problems.append(
                "no migration DEFINES %s() -- nothing pins the city guard "
                "inside staff_task_feed, so restating that function from a "
                "stale copy would pass every check" % CITY_SCOPE_FEED_ASSERTION)
        else:
            abody = function_body(_read(target), CITY_SCOPE_FEED_ASSERTION)
            # Two weaker tests both survive deleting the pin, and the
            # falsifier caught each of them in turn:
            #   * "is the name anywhere in the body" -- the feed side counts
            #     occurrences with string_to_array, so the name survives;
            #   * "is v_proof mentioned" -- it is still fetched and NULL-checked
            #     even after the test on it is deleted.
            # What actually pins the guard is the assertion SEARCHING the
            # proof body FOR the guard, so that is what is required: the name
            # and `in v_proof` in one position()/strpos() call.
            if not re.search(
                    r"(?:position|strpos)\s*\(\s*'staff_scope_allows_city'"
                    r"[^)]*\bin\s+v_proof", abody, re.IGNORECASE | re.DOTALL):
                problems.append(
                    "%s: %s no longer searches verify_payment_proof's body for "
                    "staff_scope_allows_city. staff_task_feed and "
                    "verify_payment_proof are re-emitted wholesale whenever "
                    "their task types change, and an assertion that no longer "
                    "inspects the proof body passes on a guard that quietly "
                    "dropped it." % (target.name, CITY_SCOPE_FEED_ASSERTION))

        # And the assertion that pins the guard must itself require it, or a
        # future restatement of these five from a stale copy would pass CI --
        # which is precisely how the category layer was lost once (00020).
        target, _ = last_migration_defining(
            "assert_admin_rpc_service_role_access")
        if target is not None:
            abody = function_body(_read(target),
                                  "assert_admin_rpc_service_role_access")
            if "staff_scope_allows_city" not in abody:
                problems.append(
                    "%s: assert_admin_rpc_service_role_access no longer pins "
                    "staff_scope_allows_city. The five provider actions are "
                    "re-emitted wholesale whenever their behaviour changes, "
                    "and an assertion that does not name the new condition "
                    "passes on a body that quietly dropped it."
                    % target.name)

    return problems


def _dart_without_comments(text: str) -> str:
    """Strip Dart line and block comments.

    A name inside a comment is not a call site. Three separate checks in this
    file have been fooled by exactly that, so the rule is applied here once
    rather than remembered per check.
    """
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", " ", text)


def check_staff_roster_is_wired() -> list[str]:
    """A staff member's rank, city and obligations must be READABLE.

    The `staff` table has carried a city and a job role for a long time, and
    both were written by the CEO's terms editor -- and read by nothing. A
    manager could set a person to Hawassa and then act on every Hawassa queue
    without ever being shown that fact. So the city axis was decorative: the
    column existed, the screen showed nothing, and the guards added this
    session had no visible surface to belong to.

    This asserts the roster RPCs are not merely DEFINED. A migration that
    creates admin_staff_roster() and a client that never calls it is the exact
    shape of the original defect, with a new table bolted on.

    Three ways a naive version of this check passes on the broken build, all
    found by the falsifier and all handled below:

      * the field is read off the raw `staff` row instead of the roster, which
        is a different (older) source and is what the screen already did;
      * the roster is fetched into a local and then dropped on the floor;
      * the RPC name survives in a comment, so a "is the string present" test
        is satisfied by prose describing a call that never happens.
    """
    problems: list[str] = []

    screen = _read(LIB / "features" / "admin" / "admin_staff_screen.dart")
    if not screen:
        return ["lib/features/admin/admin_staff_screen.dart is missing"]
    code = _dart_without_comments(screen)

    for rpc, why in (
        ("admin_staff_roster",
         "rank, city, obligations and the movement counters"),
        ("staff_activity_feed",
         "the movement history behind those counters"),
    ):
        # Must be an actual rpc('name') call site, not merely a string.
        if not re.search(r"rpc\(\s*['\"]%s['\"]" % re.escape(rpc), code,
                         re.DOTALL):
            problems.append(
                "the client never calls %s(), so %s are recorded in the "
                "database and shown to nobody" % (rpc, why))

    # The roster must be STORED, not just fetched: a result assigned and
    # discarded is the same defect wearing a different hat. The map's own name
    # is discovered from its declaration rather than hard-coded, so renaming
    # the variable is not a regression.
    decl = re.search(
        r"Map<String,\s*Map<String,\s*dynamic>>\s+(\w+)\s*=\s*\{\}", code)
    roster_map = decl.group(1) if decl else None
    if roster_map is None:
        problems.append(
            "admin_staff_screen.dart holds no per-staff-id roster map, so the "
            "roster rows cannot be joined onto the staff cards at all")
    elif not re.search(r"%s\b[^;]{0,200}?addAll\(" % re.escape(roster_map), code):
        problems.append(
            "the roster map `%s` is declared but never populated: the RPC "
            "result is fetched and then discarded, which is the original "
            "defect with an extra network call in front of it"
            % roster_map)

    # Each fact must be read from a map that CAME FROM THE ROSTER, not from
    # the raw `staff` row. Locally the pattern is
    #     final r = <accessor>(s);   r['city']
    # The accessor is the function that returns the declared roster map, found
    # by what it does rather than by what it is named: a rename of either the
    # map or the accessor is a refactor, and a check that punishes an honest
    # rename is a check that gets disabled. The fallback `s['city']` on the
    # raw staff row cannot satisfy this.
    roster_vars: set[str] = set()
    if roster_map:
        accessor = re.search(
            r"(\w+)\s*\([^)]*\)\s*=>\s*(?:\w+\s*=>\s*)?%s\s*\[" % re.escape(roster_map),
            code)
        if accessor:
            roster_vars = set(re.findall(
                r"(\w+)\s*=\s*%s\s*\(" % re.escape(accessor.group(1)), code))
    for field, label in (
        ("city", "the assigned city"),
        ("job_role", "the rank"),
        ("obligations", "the granted obligations"),
    ):
        read = any(
            re.search(r"\b%s\s*\[\s*['\"]%s['\"]" % (re.escape(v), field), code)
            for v in roster_vars
        )
        if not read:
            problems.append(
                "admin_staff_screen.dart never reads `%s` off the roster, so %s "
                "is not shown on any staff row. A fallback to the raw `staff` "
                "column does not count: that is the pre-roster source, and it "
                "is what was already unread." % (field, label))

    return problems


def check_quoted_fees_resolve_like_the_charge() -> list[str]:
    """A fee QUOTED to a human must be resolved the way it is CHARGED.

    Migration 107 made the platform commission resolvable per category and per
    city. The charge goes through `deduct_transaction_fee()`, which calls
    `platform_transaction_fee_for(amount, provider.category, provider.city,
    is_product)`. The checkout screen quoted `platform_transaction_fee(amount)`
    — the global rate — and a comment there claimed the two "could not drift".

    They did drift, and nothing caught it: the code parsed, the route
    resolved, every check was green, and the only symptom was a provider whose
    displayed commission was a different number from the one debited from
    their wallet the moment an admin set a category or city override.

    So this asserts the two agree, structurally.

    UPDATE: the product rule is now that the BUYER is never quoted the
    commission at all — it is charged to the provider, and the provider and
    admin surfaces display it from the ledger, where there is nothing to
    drift. "The checkout quotes no fee" is therefore a PASSING state, and
    the checkout assertions below are gated on a quote existing at all. The
    invariant is unchanged: a fee QUOTED to a human resolves exactly like
    the charge. A reintroduced figure the buyer sees must satisfy every
    assertion here or this check fires again.
    """
    problems: list[str] = []

    checkout = _read(LIB / "features" / "user" / "user_checkout_screen.dart")
    if not checkout:
        return ["lib/features/user/user_checkout_screen.dart is missing"]

    code = _dart_without_comments(checkout)

    # UPDATE (item H): the app's fee quotes now go through the shared
    # FeeResolver, so the checkout names `commissionAmount(...)` rather than the
    # RPC. The invariant is unchanged — a fee QUOTED to a human resolves exactly
    # like the charge — so the assertions follow the code: whichever door the
    # figure came through, the reader behind it must be the per-category,
    # per-city one, with the order rate class, resolved AFTER the provider
    # context. A checkout that calls the resolver is therefore checked just as
    # strictly as one that called the RPC.
    resolver = _read(LIB / "core" / "services" / "fee_resolver.dart")
    rres = _dart_without_comments(resolver) if resolver else ""
    via_resolver = ("commissionAmount(" in code) or ("commissionPercent(" in code)

    # A quote exists when the checkout names the RPC at all OR asks the
    # resolver for a commission figure. No name and no resolver call → no
    # figure the buyer can see → nothing here can drift.
    quotes_commission = ("platform_transaction_fee" in code) or via_resolver

    # Anchored on the CALL, not the bare name: the resolver's own
    # chargePathResolvers map contains 'platform_transaction_fee_for' as a
    # string, so a check for the name alone stayed green with the actual RPC
    # swapped to the global one. The falsifier caught exactly that.
    commission_rpc = re.search(
        r"rpc\(\s*'platform_transaction_fee_for'", rres)

    if via_resolver and commission_rpc is None:
        problems.append(
            "the checkout quotes the commission through FeeResolver, but "
            "FeeResolver does not resolve it through "
            "platform_transaction_fee_for() with the provider's category and "
            "city — so any category or city override makes the displayed "
            "figure differ from the charge.")

    if quotes_commission and not via_resolver and \
            "platform_transaction_fee_for" not in code:
        problems.append(
            "the checkout quotes the commission through the one-argument "
            "platform_transaction_fee(), which resolves the GLOBAL rate, while "
            "the wallet is debited by platform_transaction_fee_for() with the "
            "provider's category and city. Any category or city override makes "
            "the displayed figure differ from the charge.")

    # The flag matters as much as the arguments: the charge passes
    # `p_order_id IS NOT NULL`, so a quote that sends false quotes the wrong
    # rate class for an order.
    if quotes_commission and "p_is_product" not in code and \
            "isProduct: true" not in code:
        problems.append(
            "the checkout's commission quote does not pass p_is_product, so it "
            "resolves the wrong rate class — deduct_transaction_fee() passes "
            "`p_order_id IS NOT NULL` for an order")

    # ORDERING. This is the bug that was in the first fix: the quote read
    # _feeCity / _feeCategoryId, which are populated by a provider read that
    # ran afterwards. Both were null, the RPC inherited the global rate, and
    # the call looked correct in review. Ordering is the whole fix, so it is
    # the part that has to be asserted.
    load = re.search(r"Future<void> _load\(\)\s*async\s*\{(.*?)\n  \}",
                     code, re.DOTALL)
    if load is None:
        problems.append("could not find _load() in user_checkout_screen.dart")
    else:
        body = load.group(1)
        quote_at = body.find("commissionAmount(")
        if quote_at == -1:
            quote_at = body.find("platform_transaction_fee_for")
        if quote_at != -1:
            before = body[:quote_at]
            if via_resolver:
                # The resolver call must be HANDED the provider's category and
                # city. A quote that does not pass them resolves the global
                # rate while the wallet is debited the per-category one.
                if "providerContext(" not in before:
                    problems.append(
                        "the checkout quotes the commission without first "
                        "resolving the provider's category and city "
                        "(providerContext), so the figure can silently fall "
                        "back to the global rate — the exact drift this check "
                        "exists to prevent")
                around = body[quote_at:quote_at + 400]
                if "ctx.categoryId" not in around or "ctx.city" not in around:
                    problems.append(
                        "the checkout resolves the provider context but does "
                        "not pass its category and city to the commission "
                        "quote, so the quote and the charge resolve different "
                        "fees")
            elif "_refreshProviderReadiness()" not in before:
                problems.append(
                    "the checkout quotes the commission BEFORE the provider "
                    "read that populates _feeCategoryId and _feeCity, so the "
                    "quote silently falls back to the global rate — the exact "
                    "drift this check exists to prevent")

    # The server half: the charge must actually pass a category and a city.
    target, _ = last_migration_defining("deduct_transaction_fee")
    if target is None:
        problems.append("no migration defines deduct_transaction_fee()")
    else:
        fbody = function_body(_read(target), "deduct_transaction_fee")
        if "platform_transaction_fee_for" not in fbody:
            problems.append(
                "%s: deduct_transaction_fee() no longer charges through "
                "platform_transaction_fee_for(), so the per-category and "
                "per-city commission is not being applied at all"
                % target.name)

    # The RIDE fare has the identical defect and got it separately: the client
    # called the five-argument calculate_fare_estimate(), which hardcodes
    # p_city to NULL, while create_ride_request() charges against the rider's
    # profiles.city. Same drift, second surface, found the same way.
    # The quote itself now lives in the shared FeeResolver (item H), so the
    # question moves with it: the SCREEN must not quote a fare at all (two
    # readers for one money path is the whole bug), and the RESOLVER must use
    # the city-aware reader with the pre-0107 fallback. Splitting the check
    # across the two files keeps the original invariant and makes it stricter:
    # a screen that calls the fare RPC directly fails even though the RPC name
    # is the right one.
    ride = _read(LIB / "features" / "user" / "user_ride_request_screen.dart")
    resolver = _read(LIB / "core" / "services" / "fee_resolver.dart")
    if not ride:
        problems.append("lib/features/user/user_ride_request_screen.dart is missing")
    elif not resolver:
        problems.append(
            "lib/core/services/fee_resolver.dart is missing — the shared fee "
            "resolver is what keeps a quoted fee and a charged fee on one "
            "reader")
    else:
        rcode = _dart_without_comments(ride)
        rres = _dart_without_comments(resolver)

        if "FeeResolver" not in rcode or "rideFare(" not in rcode:
            problems.append(
                "the ride request no longer quotes the fare through the shared "
                "FeeResolver, so the quoted fare and the fare "
                "create_ride_request() charges can resolve through two "
                "different readers")
        elif "calculate_fare_estimate" in rcode:
            problems.append(
                "the ride request calls the fare RPC itself instead of going "
                "through FeeResolver, so a second copy of the fare path exists "
                "in the screen and can drift from the charged one")

        # The ride-fare method alone, so a p_city passed by ANOTHER reader in
        # the same file cannot satisfy this. The falsifier showed the bare
        # `'p_city' in rres` test stayed green when the ride call lost its city
        # and the commission reader still had one.
        # The closing brace must be a BARE `  }` line: the parameter list ends
        # with `  }) async {`, so a looser pattern matched there and cut the
        # body off before the RPC name, reporting the real sources red.
        ride_method = re.search(
            r"Future<FeeQuote> rideFare\(.*?\n  \}(?=\n)", rres, re.DOTALL)
        ride_body = ride_method.group(0) if ride_method else ""

        if "calculate_fare_estimate_at" not in ride_body:
            problems.append(
                "FeeResolver quotes the ride fare through the five-argument "
                "calculate_fare_estimate(), which hardcodes p_city to NULL, "
                "while create_ride_request() charges against the rider's "
                "profiles.city — so a city-specific per-km rate is charged but "
                "never quoted")
        elif "'p_city'" not in ride_body:
            problems.append(
                "FeeResolver calls the city-aware fare function but never "
                "passes p_city, so it resolves exactly as the old wrapper did")

        # A deployment that has not run 0107 has neither new entry point. A
        # hard failure would mean "Fare unavailable" on every ride, so the
        # fallback is part of the contract, not a nicety. It must be the
        # five-argument read (NOT the city-aware one) reached from the catch,
        # which is why the trailing quote is required here.
        if not re.search(r"rpc\(\s*'calculate_fare_estimate'\s*,", rres):
            problems.append(
                "FeeResolver defines no fallback to the pre-0107 fare quote, "
                "so a deployment without migration 107 shows 'Fare "
                "unavailable' on every ride instead of the global rate")

    # The SUBSCRIPTION, third surface and the same defect. This one matters
    # more than the other two: the amount IS the screen. A provider opened
    # Subscription precisely to find out what they are about to be charged.
    sub = _read(LIB / "features" / "provider" / "provider_subscription_screen.dart")
    if not sub:
        problems.append(
            "lib/features/provider/provider_subscription_screen.dart is missing")
    else:
        subcode = _dart_without_comments(sub)
        if "fee_subscription" not in subcode:
            problems.append(
                "the provider subscription screen states the monthly fee from "
                "the flat monthly_subscription_fee setting, while "
                "deduct_subscription_fee() charges fee_subscription(category, "
                "city) — so a per-category or per-city rate is charged but the "
                "provider is shown the global one. This is the screen whose "
                "entire job is to state the amount.")
        # The flat setting must not overwrite the resolved one.
        if re.search(
                r"'monthly_subscription_fee'\s*\)\s*\{\s*(?://[^\n]*\n\s*)*"
                r"fee\s*=\s*parsed", subcode):
            problems.append(
                "the subscription screen overwrites the per-category fee with "
                "the flat setting, which undoes the per-category quote")

    return problems


def check_server_refusal_codes_reach_the_user() -> list[str]:
    """A server refusal must arrive as a SENTENCE, not as a code.

    Postgres refusals reach the client as `RAISE EXCEPTION 'SOME_CODE'`, and
    PostgREST returns that as a **400** whose body is the raw code. That is not
    a 403, so the authorisation branch of `friendlyError` never matched it and
    the user saw the generic "Something went wrong. Please try again." —
    which is indistinguishable from a crash and, for a staff member who acted
    outside their assigned city, actively misleading: nothing about it says
    "this is a scope rule, not a fault".

    Not every code needs a global sentence — most are translated at their call
    site, where the code knows what the user was trying to do. The ones
    asserted here are the app's OWN generic refusals, which are raised from
    many different functions and therefore have no single call site to
    translate them.
    """
    problems: list[str] = []

    err = _read(LIB / "core" / "utils" / "friendly_error.dart")
    if not err:
        return ["lib/core/utils/friendly_error.dart is missing"]
    code = _dart_without_comments(err).lower()

    # The code must appear inside a MATCHER LIST — `_any(lower, [ ... ])` —
    # not merely somewhere in the file. A plain "is the string present" test
    # is satisfied twice over: by prose about the refusal, and by the ternary
    # that picks WHICH sentence to show once it has matched. The falsifier
    # caught the second one: deleting the matcher entry left the ternary, and
    # the refusal silently stopped being recognised while the check stayed
    # green.
    needles: set[str] = set()
    for m in re.finditer(r"_any\(\s*lower\s*,\s*\[(.*?)\]\s*\)", code,
                         re.DOTALL):
        # Skip a call that SELECTS the sentence rather than matching the
        # error: `message = _any(lower, ['x']) ? ... : ...` is a downstream
        # consequence of a match, and counting it as a matcher is what let
        # case A of the falsifier stay green.
        before = code[max(0, m.start() - 24):m.start()]
        if "message =" in before:
            continue
        needles |= set(re.findall(r"'([^']*)'", m.group(1)))

    # Raised across many functions; the caller cannot infer the reason.
    for refusal, why in (
        ("insufficient_permission",
         "the staff city / category / role guards, which migrations 110-112 "
         "put on the five provider lifecycle actions, the task feed and "
         "payment verification"),
        ("admin_only",
         "the admin-only gates spread across the staff and role RPCs"),
        ("auth_required",
         "every SECURITY DEFINER function that refuses an anonymous caller"),
    ):
        if refusal not in needles:
            problems.append(
                "friendly_error.dart does not recognise %s, so a refusal "
                "raised by %s reaches the user as a raw code or as the "
                "generic fallback sentence"
                % (refusal.upper(), why))

    return problems


# ---------------------------------------------------------------------------
# The publish path
# ---------------------------------------------------------------------------
#
# PROVIDER_CREATE_FUNCS is derived from what the app CALLS, not curated. The
# earlier version of this check held a hand-written list of three refusal
# codes, and that is precisely how `PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED`
# shipped: a provider filled in a whole listing, the server refused, and the
# app showed them a machine token. The check was green the whole time because
# nobody remembered to add the new code to the list.
#
# A hand-maintained list of "the codes that matter" is a list that decays in
# exactly one direction. The functions below are found by scanning the Dart for
# the RPC names, so a screen that starts calling a new create function is
# covered the day it is written.

#: app file -> the RPCs that file calls, discovered by name below
_PUBLISH_SCREENS = (
    "features/provider/provider_product_form_screen.dart",
    "features/provider/provider_product_list_screen.dart",
    "features/provider/service_provider_dashboard.dart",
)

#: The gate code that carries its reasons, and the bare code it replaced.
REASON_CARRYING = "provider_not_fulfilment_ready"
BARE_PUBLISH_CODE = "provider_not_activated_or_documents_required"


def _latest_defining(fn: str) -> tuple[Path, str] | None:
    """The newest migration that defines `fn`, and its body."""
    head = re.compile(
        r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+(?:public\.)?"
        + re.escape(fn) + r"\s*\(",
        re.IGNORECASE,
    )
    found: tuple[Path, str] | None = None
    for p in sorted(MIGRATIONS.glob("*.sql")):
        text = _read(p)
        m = head.search(text)
        if m:
            rest = text[m.end():]
            end = rest.find("$$;")
            found = (p, rest[:end] if end != -1 else rest)
    return found


def check_publish_refusal_is_actionable() -> list[str]:
    """A provider who cannot publish must be told WHY, and where to fix it.

    The reported bug, in full: a provider opens the dashboard, taps
    Catalogue -> Add Product, fills in the form, taps Save, and is shown

        PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED

    The gate is CORRECT -- an unapproved, unpaid, unfunded or unverified
    provider must not publish. The failure is that the refusal named no
    reason, carried no next step, and the dashboard showed nothing before the
    form either, so the button simply looked broken.

    Three separate things have to hold, and each is checked because each has
    been false independently:

    1. the create functions raise the REASON-CARRYING code, not a bare one;
    2. every code those functions can raise is translated by
       `friendly_error()`, so no refusal from this path reaches a provider as a
       machine token; and
    3. the provider can SEE the state before typing anything -- the dashboard
       reads the SERVER's blockers rather than the client's more permissive
       `ProviderDocGate`, which counts a document awaiting review as good
       enough and is the reason the form accepted input the server would
       refuse.
    """
    problems: list[str] = []

    err = _read(LIB / "core" / "utils" / "friendly_error.dart")
    if not err:
        return ["lib/core/utils/friendly_error.dart is missing"]
    code = _dart_without_comments(err).lower()

    needles: set[str] = set()
    for m in re.finditer(r"_any\(\s*lower\s*,\s*\[(.*?)\]\s*\)", code, re.DOTALL):
        before = code[max(0, m.start() - 24):m.start()]
        if "message =" in before:
            continue
        needles |= set(re.findall(r"'([^']*)'", m.group(1)))

    # --- 1 + 2: the create functions ---------------------------------------
    # Which functions count is read off the app, not written here.
    create_fns: set[str] = set()
    for rel in _PUBLISH_SCREENS:
        dart = _read(LIB / rel)
        if not dart:
            problems.append(f"lib/{rel} is missing")
            continue
        for fn in re.findall(r"rpc\(\s*'([a-z0-9_]+)'", dart):
            if fn.startswith("create_provider_"):
                create_fns.add(fn)

    if not create_fns:
        problems.append(
            "no create_provider_* RPC call site was found in "
            f"{list(_PUBLISH_SCREENS)} -- this check has nothing to inspect, "
            "which means it is passing vacuously")
    else:
        for fn in sorted(create_fns):
            d = _latest_defining(fn)
            if d is None:
                problems.append(f"{fn} is called by the app but no migration defines it")
                continue
            path, body = d
            raises = {r.lower() for r in
                      re.findall(r"RAISE EXCEPTION '([A-Z][A-Z0-9_]{3,})", body)}
            if not raises:
                problems.append(
                    f"{fn} ({path.name}) raises no refusal, but the app calls "
                    f"it on the publish path -- has the gate been removed?")
                continue
            if REASON_CARRYING not in raises:
                problems.append(
                    f"{fn} ({path.name}) does not raise "
                    f"{REASON_CARRYING.upper()}, so a provider who cannot "
                    f"publish is told '{BARE_PUBLISH_CODE.upper()}' with no "
                    f"reason and no way to act on it. It raises: "
                    f"{sorted(r.upper() for r in raises)}")
            for r in sorted(raises):
                if r not in needles:
                    problems.append(
                        f"{fn} ({path.name}) can raise {r.upper()} and "
                        f"friendly_error.dart does not recognise it, so that "
                        f"refusal reaches the provider as a raw code")

    # --- 3: the provider can see it before typing --------------------------
    readiness = _read(LIB / "core" / "services" / "provider_readiness.dart")
    if not readiness:
        problems.append(
            "lib/core/services/provider_readiness.dart is missing, so nothing "
            "asks the server what is outstanding before a provider publishes")
    else:
        # The CALL, not the string. A falsifier case proved the difference:
        # matching the bare name was satisfied by the RPC name surviving as a
        # plain argument after the call itself had been replaced, so a
        # readiness path that asked the client instead of the server passed.
        if not re.search(r"rpc\(\s*'provider_fulfilment_blockers'",
                         _dart_without_comments(readiness)):
            problems.append(
                "ProviderReadiness does not CALL provider_fulfilment_blockers, "
                "so it cannot be reporting what the server will actually "
                "enforce")
        if "ProviderDocGate" in readiness and re.search(
                r"ProviderDocGate\s*\.\s*instance\s*\.\s*(isSatisfied|checkStatus)",
                _dart_without_comments(readiness)):
            problems.append(
                "ProviderReadiness calls ProviderDocGate.isSatisfied() or "
                ".checkStatus(), whose rule DIFFERS from the server's (it "
                "accepts MANUAL_REVIEW; the server does not). Displaying the "
                "client's answer is what made the listing form accept input "
                "the server would refuse. ensureDocuments() is fine -- that is "
                "the ACTION, not a decision about what the server will allow")

    # Searched with comments stripped. A falsifier case proved why: a mutation
    # that commented the widget out left its NAME in a comment, and a raw
    # substring search reported the banner as still present. A check that can be
    # satisfied by a comment about the thing is not checking the thing.
    dash = _read(LIB / "features" / "provider" / "service_provider_dashboard.dart")
    if not dash:
        problems.append("the provider dashboard is missing")
    elif "PublishReadinessBanner" not in _dart_without_comments(dash):
        problems.append(
            "the provider dashboard does not show PublishReadinessBanner, so "
            "the only place the block surfaces is a failed save at the end of "
            "a fully filled form")

    form = _read(LIB / "features" / "provider" / "provider_product_form_screen.dart")
    if form and "showPublishBlockedDialog" not in _dart_without_comments(form):
        problems.append(
            "the product form does not route a gate refusal to "
            "showPublishBlockedDialog, so it falls through to the generic "
            "snackbar that showed the bare code")

    return problems


def check_provider_fulfilment_gate_is_wired() -> list[str]:
    """A provider may only work once verified, paid and funded.

    The product rule is: documents verified, activation fee paid, wallet able
    to cover the platform fee — before posting a product, adding a vehicle,
    claiming a ride or accepting an order.

    Two defects hid behind it, and both are invisible to a reviewer:

      * `provider_docs_satisfied()` accepts MANUAL_REVIEW, which is what a
        document row is BORN as (the column defaults to it and a BEFORE
        INSERT trigger forces it). So the document half of the gate was
        satisfied by uploading an ID, before any human had looked at it.
      * `claim_ride` and `transition_order_status` never consulted the gate at
        all. A vehicle provider with an unpaid activation fee and an
        unreviewed ID could take a rider's trip, and accept an order, while
        the buyer-side checkout — which did check — refused the same provider.

    So all four surfaces are asserted, and the strict predicate is asserted to
    be strict.
    """
    problems: list[str] = []

    gate_mig = None
    for candidate in migration_files():
        if re.search(r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+"
                     r"public\.provider_fulfilment_blockers\s*\(",
                     _strip_comments(_read(candidate)), re.IGNORECASE):
            gate_mig = candidate
            break
    if gate_mig is None:
        problems.append(
            "no migration defines provider_fulfilment_blockers() -- there is "
            "no single place that can say WHY a provider may not work, so no "
            "refusal can name its own reason")
    else:
        body = function_body(_read(gate_mig), "provider_fulfilment_blockers")
        for token, why in (
            ("registration_fee_paid",
             "the one-time activation fee is never charged into the gate"),
            ("DOCUMENTS_UNVERIFIED",
             "an unreviewed document does not stop anyone"),
            ("ACTIVATION_FEE_UNPAID",
             "an unpaid activation fee produces no reason"),
            ("WALLET_EMPTY",
             "an empty wallet is not a blocker, so the platform fee fails "
             "later, at the moment a buyer is waiting"),
        ):
            if token not in body:
                problems.append(
                    "provider_fulfilment_blockers() never mentions %s, so %s"
                    % (token, why))

    # Every surface that hands out work must consult it.
    for fn, what in (
        ("claim_ride", "a provider can take a rider's trip"),
        ("transition_order_status", "a provider can accept an order"),
        ("provider_can_publish", "a provider can post a listing"),
    ):
        target, _ = last_migration_defining(fn)
        if target is None:
            problems.append("%s is undefined" % fn)
            continue
        fbody = function_body(_read(target), fn)
        # provider_can_publish delegates rather than naming the predicate
        # directly, so either counts.
        if not re.search(r"fulfilment_blockers|can_fulfil", fbody):
            problems.append(
                "%s: %s does not consult the fulfilment gate (%s)"
                % (target.name, fn, what))

    # Naming the predicate is not enough: it also has to be REACHABLE. An
    # earlier version of this check was satisfied by `IF false THEN ...
    # provider_fulfilment_blockers(...) END IF`, which is the guard written
    # but disabled — the falsifier caught it. So the actor test the guard is
    # conditioned on is asserted too.
    target, _ = last_migration_defining("transition_order_status")
    if target is not None:
        fbody = function_body(_read(target), "transition_order_status")
        if "fulfilment_blockers" in fbody:
            # The CONDITION of the guard, not the mere presence of the
            # variable. `v_actor_is_provider` is assigned near the top of the
            # function regardless, so a body-wide search is satisfied by an
            # `IF false THEN ... gate ... END IF` — the guard written and then
            # switched off, which is what the falsifier plants.
            at = fbody.find("fulfilment_blockers")
            conds = re.findall(r"\bIF\s+(.*?)\s+THEN",
                               fbody[:at], re.DOTALL | re.IGNORECASE)
            cond = conds[-1] if conds else ""
            if "v_actor_is_provider" not in cond:
                problems.append(
                    "%s: transition_order_status calls the fulfilment gate from "
                    "a condition that does not test whether the actor is the "
                    "provider (found %r), so the guard does not distinguish a "
                    "provider from an admin — and if that condition is ever "
                    "constant-false the gate is simply off"
                    % (target.name, cond.strip()[:80]))

    # The strict predicate must be strict. A substring test for MANUAL_REVIEW
    # cannot distinguish "accepts it" from "excludes it", so this looks for
    # the shape that actually admits it: MANUAL_REVIEW inside the IN list.
    target, _ = last_migration_defining("provider_documents_verified")
    if target is None:
        problems.append(
            "no migration defines provider_documents_verified() -- the gate "
            "has no way to tell a VERIFIED document from an uploaded one")
    else:
        dbody = function_body(_read(target), "provider_documents_verified")
        # The STATUS list, not the first `IN (...)` in the body. The body also
        # has `document_type IN ('NATIONAL_ID', ...)`, and matching that one
        # is how this check passed while MANUAL_REVIEW was admitted — the
        # falsifier caught it, and a document-type list is not a status list.
        admitted = re.search(
            r"verification_status[^;]*?IN\s*\(([^)]*)\)", dbody, re.IGNORECASE)
        if admitted is None:
            problems.append(
                "provider_documents_verified() admits no statuses at all, so "
                "nobody can ever satisfy the document half of the gate")
        elif "MANUAL_REVIEW" in admitted.group(1).upper():
            problems.append(
                "provider_documents_verified() still admits MANUAL_REVIEW, so "
                "\"verified\" still means \"uploaded\" -- the default state of "
                "a document row, and the whole original defect")

    # The client has to be able to explain the refusal, or the provider is
    # told only that they may not.
    #
    # Asserted against the MATCHER LISTS, not the whole file. The string also
    # appears in `_fulfilmentReasons`'s own regex, so a plain presence test is
    # satisfied by the parser that is supposed to consume it — the falsifier
    # caught exactly that.
    err = _read(LIB / "core" / "utils" / "friendly_error.dart")
    if err:
        ecode = _dart_without_comments(err).lower()
        needles: set[str] = set()
        for m2 in re.finditer(r"_any\(\s*lower\s*,\s*\[(.*?)\]\s*\)", ecode,
                              re.DOTALL):
            before = ecode[max(0, m2.start() - 24):m2.start()]
            if "message =" in before:
                continue
            needles |= set(re.findall(r"'([^']*)'", m2.group(1)))
        if "provider_not_fulfilment_ready" not in needles:
            problems.append(
                "friendly_error.dart does not recognise PROVIDER_NOT_"
                "FULFILMENT_READY in any matcher list, so a provider blocked by "
                "the gate is told only that something went wrong, with no "
                "indication of which of the four requirements they have not met")

    return problems


def check_notification_types_exist() -> list[str]:
    """Every notification type WRITTEN must be a member of the enum.

    `insert_notification(p_user_id uuid, p_type notification_type, ...)`
    types its second parameter as the enum, so writing a value that is not a
    member raises `invalid input value for enum notification_type` at RUN
    time — inside the function that was doing something else useful, so the
    whole call fails and the user sees the wrong error entirely.

    This is not hypothetical. Migration 0107 wrote 'RIDE_REQUESTED' where the
    enum spells it 'RIDE_REQUEST'. Every ride request in the product would
    have failed on deploy, and **no check caught it**: pglast parses an enum
    literal as an ordinary string and validates nothing about it, the plpgsql
    gate only checks that embedded statements parse, and every existing
    assertion either did not look or compared against a hand-typed list that
    had the same spelling mistake in it.

    "Parses clean" was never evidence that a value exists. It is now.
    """
    problems: list[str] = []

    # The enum, as the latest migration leaves it. ADD VALUE statements are
    # folded in; a value that is only added and never used is harmless, and one
    # that is used but never added is the bug.
    members: set[str] = set()
    for path in migration_files():
        src = _read(path)
        for m in re.finditer(
                r"CREATE\s+TYPE\s+(?:public\.)?notification_type\s+AS\s+ENUM\s*\((.*?)\)",
                _strip_comments(src), re.IGNORECASE | re.DOTALL):
            for v in re.findall(r"'([^']+)'", m.group(1)):
                members.add(v)
        for m in re.finditer(
                r"ALTER\s+TYPE\s+(?:public\.)?notification_type\s+"
                r"ADD\s+VALUE(?:\s+IF\s+NOT\s+EXISTS)?\s+'([^']+)'",
                _strip_comments(src), re.IGNORECASE):
            members.add(m.group(1))

    if not members:
        return ["no migration defines the notification_type enum, so this "
                "check cannot tell a real type from an invented one"]

    # Everything written: a literal in the TYPE POSITION of a notification
    # call. The position matters, and a naive "first all-caps literal after
    # the call" regex cannot find it: the first argument is frequently
    # `(select user_id from provider_profiles where id = p_provider_id)`,
    # which contains no comma at the top level but does contain parens, and a
    # lazy match happily runs past the end of the statement and picks up
    # something from a GRANT. So the arguments are split on TOP-LEVEL commas
    # with a paren-depth walk, and the type is read by position:
    #
    #   insert_notification(user_id, TYPE, ...)      -> arg 1
    #   notify_user(user_id, TYPE, ...)              -> arg 1
    #   notify_user_once(key, user_id, TYPE, ...)    -> arg 2
    write_sites: dict[str, set[str]] = {}

    def literal_type(arg: str) -> str | None:
        """The enum value if this argument is a bare quoted literal."""
        m = re.fullmatch(r"'([A-Za-z_][A-Za-z_.]*)'", arg.strip())
        return m.group(1) if m else None

    # Kept for the docstring's benefit and for anyone reading the case
    # history; the extraction below uses the shared helpers so that this
    # check and the counterparty check can never disagree about which calls
    # count as notification writes.

    call = _NOTIFY_CALL
    for path in migration_files():
        src = _strip_comments(_read(path))
        for m in call.finditer(src):
            name = m.group(0).split("(")[0].strip().lower()
            args = _split_call_args(src, m.end() - 1)
            if not args:
                continue
            idx = 2 if name.endswith("_once") else 1
            if len(args) <= idx:
                continue
            lit = re.fullmatch(r"'([A-Za-z_][A-Za-z_.]*)'", args[idx].strip())
            val = lit.group(1) if lit else None
            # A variable or a computed value cannot be checked here; those are
            # the ones a type mismatch would hide behind.
            if val and val.upper() not in members:
                write_sites.setdefault(val, set()).add(path.name)

    for val, files in sorted(write_sites.items()):
        problems.append(
            "notification type %r is written in %s but is not a member of the "
            "notification_type enum. insert_notification() types that column, "
            "so the write raises `invalid input value for enum "
            "notification_type` at RUN time and takes the surrounding "
            "operation down with it."
            % (val, ", ".join(sorted(set(files)))))

    return problems


def check_provider_is_told_about_work() -> list[str]:
    """The other side of a marketplace event must be told, not left to poll.

    A notification is the only thing that makes a marketplace reactive. A
    provider who is not told an order arrived finds out by opening the orders
    screen; a driver who is not told a ride is nearby finds out by the same
    polling. Both work, and both are the reason a marketplace feels dead.

    The rule asserted here: for the events where the platform knows who the
    counterparty is, at least one code path notifies them. The buyer-side
    event is already covered elsewhere; this is the provider side.
    """
    problems: list[str] = []

    # Asserted on the notification TYPE, not on the helper that writes it.
    # Naming a type is the actual requirement — a helper can be renamed or
    # wrapped and the provider is still told — whereas naming a function makes
    # the check fail on a refactor and pass on a wrong target.
    for fn, event, who in (
        ("create_order_secure", "ORDER_RECEIVED",
         "a provider is never told an order arrived"),
        ("create_ride_request", "RIDE_REQUEST",
         "no driver is ever told a ride is available near them"),
        ("claim_ride", "RIDE_CLAIMED",
         "a rider is never told their ride has a driver"),
    ):
        target, _ = last_migration_defining(fn)
        if target is None:
            problems.append("%s is undefined" % fn)
            continue
        body = function_body(_read(target), fn)

        if fn == "create_ride_request":
            # This one is special: the rider IS notified here already, so the
            # presence of RIDE_REQUEST proves nothing. What has to be proven is
            # that a DRIVER is addressed, which means a fan-out over
            # find_nearby_drivers.
            #
            # Resolved through the helper that now owns the fan-out, rather
            # than by naming the helper: the requirement is that a driver is
            # told, not which function does the telling. A check that hard-codes
            # the helper's name fails the day it is renamed and keeps passing
            # if the fan-out inside it is emptied.
            # CALLED, not merely mentioned. A substring test is satisfied by
            # `find_nearby_drivers_disabled(`, which is what the falsifier
            # plants: the fan-out gone, the reference left behind.
            near = re.compile(r"\bfind_nearby_drivers\s*\(", re.IGNORECASE)
            reaches_drivers = bool(near.search(body))
            if not reaches_drivers:
                for name in set(re.findall(r"\b(?:public\.)?(notify_\w+)\s*\(",
                                           body)):
                    htarget, _ = last_migration_defining(name)
                    if htarget is None:
                        continue
                    if near.search(function_body(_read(htarget), name)):
                        reaches_drivers = True
                        break
            if not reaches_drivers:
                problems.append(
                    "%s: create_ride_request() notifies the rider but nothing "
                    "it calls fans out over find_nearby_drivers, so %s"
                    % (target.name, who))
        elif event not in _notification_types_written(body):
            problems.append(
                "%s: %s writes no %s notification (found %s), so %s"
                % (target.name, fn, event,
                   ", ".join(sorted(_notification_types_written(body))) or "none",
                   who))

    return problems


def _split_call_args(text: str, open_paren: int) -> list[str]:
    """Args of the call whose '(' is at `open_paren`, split on top-level commas.

    Walks with a paren depth counter and ignores commas inside string literals,
    because the first argument to a notification call is routinely
    `(select user_id from provider_profiles where id = p_provider_id)` and a
    lazy comma split would read whatever is inside it.
    """
    depth = 0
    args: list[str] = []
    cur: list[str] = []
    i = open_paren
    in_str = False
    while i < len(text):
        ch = text[i]
        if in_str:
            cur.append(ch)
            if ch == "'":
                in_str = False
            i += 1
            continue
        if ch == "'":
            in_str = True
            cur.append(ch)
        elif ch == "(":
            depth += 1
            if depth == 1:
                i += 1
                continue
            cur.append(ch)
        elif ch == ")":
            depth -= 1
            if depth == 0:
                args.append("".join(cur).strip())
                return args
            cur.append(ch)
        elif ch == "," and depth == 1:
            args.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
        i += 1
    return args


_NOTIFY_CALL = re.compile(
    r"\b(?:insert_notification|notify_user|notify_user_once|notify_best_effort)\s*\(",
    re.IGNORECASE)


def _notification_types_written(body: str) -> set[str]:
    """The enum literals actually handed to a notification writer in `body`.

    Deliberately positional rather than a substring search. A substring search
    for 'RIDE_CLAIMED' is satisfied by `claim_ride`'s own audit_logs row, which
    has the same word in it for an unrelated reason -- the falsifier found that
    by deleting the notification and watching the check stay green.
    """
    out: set[str] = set()
    for m in _NOTIFY_CALL.finditer(body):
        name = m.group(0).split("(")[0].strip().lower()
        args = _split_call_args(body, m.end() - 1)
        idx = 2 if name.endswith("_once") else 1
        if len(args) <= idx:
            continue
        lit = re.fullmatch(r"'([A-Za-z_][A-Za-z_.]*)'", args[idx].strip())
        if lit:
            out.add(lit.group(1))
    return out


def check_client_rpcs_are_executable() -> list[str]:
    """Every RPC the app calls must be executable by the role that calls it.

    PostgREST hides a function the caller has no EXECUTE on behind PGRST202
    "could not find the function in the schema cache". That reads exactly like
    a migration that never applied, so the natural response is to re-run the
    deploy -- which changes nothing, because the function is there and the
    privilege is not.

    This is not theoretical in this repo. Two separate instances:

      * migration 0113 granted its assertion to `authenticated` only, while
        Connectivity CI runs its read-only assertions as **anon**. That would
        have failed as PGRST202 on the first live run;
      * `calculate_fare_estimate_at()` is granted to `authenticated` and
        revoked from `anon` deliberately, because it exposes a fare. Any new
        caller has to know which side of that line it is on.

    So the assertion is per-role, and it is derived from where the call is
    made rather than from a hand-kept list of RPC names.

    KNOWN LIMIT: privileges are tracked per NAME, not per signature. An
    overloaded function (`fee_subscription(uuid, text)` and
    `fee_subscription(uuid, text, boolean)` are both granted) is reported
    reachable if ANY overload is. PostgREST hides a revoked overload behind
    the same PGRST202 for a caller whose argument shape selects it. Reading
    each call's parameter names to resolve the exact overload is a larger job
    than the risk warrants today; it is recorded rather than hidden.
    """
    problems: list[str] = []

    # Postgres grants EXECUTE ON FUNCTION to PUBLIC by default, so a function
    # with no GRANT and no REVOKE IS callable by everyone. The first version of
    # this check assumed the opposite -- "no GRANT found" meant "not
    # executable" -- and reported fourteen working functions, which is how a
    # check gets ignored. The rule is therefore about REVOKEs, not GRANTs:
    # a function is unreachable only if something took the privilege away.
    granted: dict[str, set[str]] = {}
    revoked: dict[str, set[str]] = {}
    dynamic_fee: set[str] = set()
    # Ordered privilege operations per function, because SQL applies them in
    # order and the LAST one wins. A GRANT followed by a REVOKE of the same role
    # ends revoked; reading only the union of grants reported the earlier state
    # and the falsifier caught it. Positions are offset per file so they stay
    # globally ordered across the migration history.
    ops: dict[str, list[tuple[int, str, set[str]]]] = {}
    dyn_ops: list[tuple[int, str, set[str]]] = []
    base = 0

    def record(key: str | None, pos: int, kind: str, roles: set[str]) -> None:
        if key is None:
            dyn_ops.append((pos, kind, roles))
        else:
            ops.setdefault(key, []).append((pos, kind, roles))

    def _blank(text: str, lo: int, hi: int) -> None:
        for k in range(lo, hi):
            text[k] = " "

    def _statements_only(src: str) -> str:
        """Blank comments and string literals, PRESERVING LENGTH.

        Length matters: the ordering below compares offsets across files, so
        a shortener would silently reorder grants and revokes.

        This is not a hypothetical hazard. Migration 00083 documents the very
        revoke it wants on line 14, inside a `--` comment. Read literally that
        comment revoked `list_staff_jobs` from `public` five migrations after
        00036 had granted it to `authenticated` -- reported as a live PGRST202
        waiting to happen, for a line that is documentation.
        """
        out = list(src)
        i, n = 0, len(src)
        while i < n:
            c = src[i]
            if c == "'":
                j = i + 1
                while j < n:
                    if src[j] == "'":
                        if j + 1 < n and src[j + 1] == "'":
                            j += 2
                            continue
                        j += 1
                        break
                    j += 1
                _blank(out, i, min(j, n))
                i = j
            elif src.startswith("--", i):
                j = src.find("\n", i)
                _blank(out, i, n if j < 0 else j)
                i = n if j < 0 else j
            elif src.startswith("/*", i):
                j = src.find("*/", i + 2)
                _blank(out, i, n if j < 0 else j + 2)
                i = n if j < 0 else j + 2
            else:
                i += 1
        return "".join(out)

    def _comments_gone(src: str) -> str:
        return re.sub(r"/\*.+?\*/|--+[^\n]*",
                      lambda m: " " * len(m.group(0)), src, flags=re.DOTALL)

    for path in migration_files():
        src = _read(path)
        # Comments and string literals blanked for the literal statements;
        # comments only blanked for the format() scan, which lives INSIDE a
        # string literal. Same offsets either way.
        sql = _statements_only(src)
        live = _comments_gone(src)
        for m in re.finditer(
                r"GRANT\s+EXECUTE\s+ON\s+FUNCTION\s+(?:public\.)?(\w+)\s*\([^)]*\)"
                r"\s*TO\s+([^;]+);", sql, re.IGNORECASE):
            granted.setdefault(m.group(1).lower(), set()).update(
                r.strip().lower() for r in m.group(2).split(","))
            record(m.group(1).lower(), base + m.start(), "grant",
                   {r.strip().lower() for r in m.group(2).split(",")})
        for m in re.finditer(
                r"REVOKE\s+(?:ALL|EXECUTE)?\s*ON\s+FUNCTION\s+(?:public\.)?(\w+)"
                r"\s*\([^)]*\)\s*FROM\s+([^;]+);", sql, re.IGNORECASE):
            revoked.setdefault(m.group(1).lower(), set()).update(
                r.strip().lower() for r in m.group(2).split(","))
            record(m.group(1).lower(), base + m.start(), "revoke",
                   {r.strip().lower() for r in m.group(2).split(",")})        # The 0107 DO-block loop builds its GRANT/REVOKE with format(), so the
        # literal statements never appear. The role lists DO appear, inside
        # the format string, and are read from there.
        #
        # The `%[Is]` alternation matters: the loop was rewritten to assemble
        # the signature from pg_proc, so it interpolates `%s` with a variable
        # rather than `%I` with an inline argument list. A pattern that only
        # knew `%I(...)` silently read ZERO dynamic privileges from the file
        # and declared the fee readers unreachable -- and, worse, would have
        # gone on reading zero after a real grant was deleted. The verb and
        # the role list are what this needs; the signature spelling is the
        # loop's business.
        for m in re.finditer(
                r"format\(\s*'(GRANT\s+EXECUTE|REVOKE\s+ALL) ON FUNCTION "
                r"public\.%[Is]\b[^']*?\b(?:TO|FROM)\s*([^']+)'",
                live,
                re.IGNORECASE):
            record(None, base + m.start(),
                   "grant" if m.group(1).lower().startswith("grant") else "revoke",
                   {r.strip().lower() for r in m.group(2).split(",")})
        for m in re.finditer(r"'(fee_[a-z_]+)'", src):
            dynamic_fee.add(m.group(1).lower())
        base += len(src) + 1

    def _reachable(entries: list[tuple[int, str, set[str]]], role: str) -> bool:
        """Final state for `role` after the statements, in order.

        PUBLIC is a SEPARATE grant, not a superset. Every function starts
        executable by PUBLIC; `REVOKE ... FROM PUBLIC` withdraws that default
        and nothing else. Folding PUBLIC into every role -- which the first
        version did -- meant a `REVOKE FROM public` four lines after a
        `GRANT TO authenticated` erased the grant, and reported working
        functions as unreachable. The named-role grant wins if it exists.
        """
        named: bool | None = None
        public: bool | None = None
        for _pos, kind, roles in sorted(entries, key=lambda e: e[0]):
            if role in roles:
                named = (kind == "grant")
            if "public" in roles:
                public = (kind == "grant")
        if named is not None:
            return named
        return True if public is None else public

    def executable(name: str, role: str) -> bool:
        n = name.lower()
        if n in dynamic_fee:
            return _reachable(dyn_ops, role)
        return _reachable(ops.get(n, []), role)

    # --- RPCs the signed-in app calls ------------------------------------
    for name in literal_calls(r"rpc\(\s*'([a-z_0-9]+)'"):
        if not executable(name, "authenticated"):
            problems.append(
                "the app calls %s(), but no migration GRANTs EXECUTE to "
                "`authenticated`. PostgREST answers PGRST202 'could not find "
                "the function in the schema cache', which reads like a missing "
                "migration and sends the next person to re-run the deploy."
                % name)

    # --- assertions the anon-role connectivity suite calls ----------------
    #
    # Scanned directly rather than through literal_calls(), which only walks
    # lib/ -- the suite lives in tools/integration_test/.
    suite = ROOT / "tools" / "integration_test" / "connectivity_test.dart"
    if suite.exists():
        ssrc = _read(suite)
        for m in re.finditer(r"ok\(\s*'([a-z_0-9]+)'", ssrc):
            if not executable(m.group(1), "anon"):
                problems.append(
                    "the connectivity suite calls %s() as ANON, but something "
                    "REVOKEs it from anon or PUBLIC with no GRANT back. It will "
                    "fail as PGRST202 'could not find the function in the "
                    "schema cache', which reads like a missing migration."
                    % m.group(1))
        for m in re.finditer(r"rpcTextDiagnosed\(\s*'([a-z_0-9]+)'", ssrc):
            if not executable(m.group(1), "anon"):
                problems.append(
                    "the connectivity suite calls %s() as ANON, but something "
                    "REVOKEs it from anon or PUBLIC with no GRANT back. It "
                    "will fail as PGRST202." % m.group(1))

    return problems


def _names_near(src: str, pos: int) -> set[str]:
    """The quoted function names belonging to the privilege loop at `pos`.

    The loop's own `FOREACH v_fn IN ARRAY ARRAY['fee_a', 'fee_b']` sits
    ABOVE the signature array, so the window looks back rather than forward.
    Bounded so a later, unrelated list cannot be blamed on this one.
    """
    window = src[max(0, pos - 2000):pos]
    start = window.rfind("ARRAY[")
    if start != -1 and "FOREACH" in window[:start]:
        window = window[:start]
    return set(re.findall(r"'(fee_[a-z_]+)'", window))


def _blank_dollar_bodies(src: str) -> str:
    """`src` with every dollar-quoted body replaced by spaces of equal length.

    Equal length so any offset computed on the result still refers to the
    original. Handles the tagged forms this repo uses -- `$$`, `$function$`,
    `$body$` -- by tagging, not by counting `$$` pairs: a naive
    `re.sub(r"\$\$.*?\$\$")` mispairs on a file that opens with `$$` and
    closes with `$function$`, which is how a first attempt at the check it
    serves reported writes inside function bodies as top-level ones.
    """
    out = list(src)
    i = 0
    n = len(src)
    while i < n:
        if src[i] == "$":
            m = re.compile(r"\$(\w*)\$").match(src, i)
            if m:
                tag = m.group(0)
                close = src.find(tag, m.end())
                if close == -1:
                    i += 1
                    continue
                end = close + len(tag)
                for k in range(i, end):
                    out[k] = " "
                i = end
                continue
        i += 1
    return "".join(out)


def _do_block_bodies(src: str) -> str:
    """The concatenated bodies of every `DO $$` block in `src`.

    These run during the migration; a `CREATE FUNCTION` body does not. A
    privilege or trigger lift that has to happen at migration time therefore
    lives here, and looking for it in the whole file -- or in the text with
    dollar-quoted regions blanked -- misses it either way.
    """
    out: list[str] = []
    for m in re.finditer(r"\bDO\s*\$(\w*)\$", src, re.IGNORECASE):
        tag = "$%s$" % m.group(1)
        end = src.find(tag, m.end())
        if end == -1:
            continue
        out.append(src[m.end():end])
    return "\n".join(out)


def check_guarded_tables_are_lifted_at_migration_time() -> list[str]:
    """A migration that seeds a blanket-guarded table must lift the trigger.

    `system_settings` carries a BEFORE INSERT/UPDATE/DELETE row trigger,
    `trg_system_settings_security` -> `prevent_system_settings_self_modification()`,
    whose whole body is `IF NOT is_admin() THEN RAISE EXCEPTION
    'SETTINGS_ARE_ADMIN_ONLY'`. `is_admin()` is `auth.uid()`-derived and
    `auth.uid()` reads the JWT claim from the GUC store -- a migration
    connection has no JWT, so it is NULL and the guard raises regardless of how
    privileged the migration role is. 0113 seeded one setting and the push died
    on it, after 0107-0112 had all applied.

    0028, 0038 and 0062 lift the trigger for their own seed and restore it
    immediately. That is the pattern and it is easy to forget, so the reminder
    is mechanical.

    DELIBERATELY NARROW. The other trigger functions in this repo that mention
    `is_admin()` -- `prevent_role_escalation`, `prevent_notification_injection`,
    `enforce_provider_write_gate` and the rest -- are SELECTIVE: they block a
    specific escalation and permit ordinary writes, which is why the many
    migrations that write `profiles`, `provider_profiles` and `notifications`
    from a migration connection all applied cleanly. Treating every
    is_admin()-mentioning trigger as a blanket guard reported 1014 problems
    across already-applied history, which is not a check, it is noise. Only a
    guard whose failure is unconditional belongs here.
    """
    problems: list[str] = []

    # (table, trigger). Evidence-based, and asserted to still exist below so a
    # rename fails loudly instead of silently checking nothing.
    GUARDED = [("system_settings", "trg_system_settings_security")]

    # The guard must still be defined somewhere, or this check is vacuous.
    for table, trig in GUARDED:
        if not any(re.search(r"CREATE\s+TRIGGER\s+%s\b" % re.escape(trig),
                             _read(p), re.IGNORECASE)
                   for p in migration_files()):
            problems.append(
                "the guard trigger %s is not created by any migration, so this "
                "check no longer tests anything -- the trigger was renamed or "
                "dropped and its entry above is stale" % trig)

    for path in migration_files():
        version = path.name.split("_")[0]
        if not version.isdigit() or int(version) < BASELINE:
            continue
        src = _read(path)
        # Statements OUTSIDE dollar-quoted bodies. A write inside a function
        # body runs at call time in the caller's context, where auth.uid() is
        # real, and is not this migration's problem -- mistaking those for
        # top-level writes is what produced the 1014-finding version.
        outside = _blank_dollar_bodies(src)
        for table, trig in GUARDED:
            if not re.search(
                    r"(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+"
                    r"(?:public\.)?%s\b" % re.escape(table), outside,
                    re.IGNORECASE):
                continue
            literal = re.search(
                r"DISABLE\s+TRIGGER\s+%s\b" % re.escape(trig), src,
                re.IGNORECASE) and re.search(
                r"ENABLE\s+TRIGGER\s+%s\b" % re.escape(trig), src,
                re.IGNORECASE)
            # The dynamic form: discover the trigger from pg_trigger and lift
            # it by name. 0068, 0069 and 0076 use this, and it is strictly
            # better than naming the trigger because it survives a rename.
            #
            # Searched in the file's `DO` blocks, NOT in `outside` -- the lift
            # itself sits inside a dollar-quoted body, so blanking them hid
            # it and five applied-and-working migrations were reported broken.
            # A DO block runs at migration time; a plain function body does
            # not, which is why the distinction is the body's kind and not
            # whether dollar quotes happen to enclose it.
            do_blocks = _do_block_bodies(src)
            # The `regclass` lookup may sit either inside the DO block (0068,
            # 0069, 0076, 0113) or in a top-level statement just before it
            # (0003 and 0004 stage the trigger names in a TEMP TABLE first).
            # Requiring it in one place only reported a working migration as
            # broken, so both are accepted.
            where = do_blocks + "\n" + outside
            dynamic = (re.search(r"DISABLE\s+TRIGGER\s+%I", do_blocks, re.IGNORECASE)
                       and re.search(r"ENABLE\s+TRIGGER\s+%I", do_blocks, re.IGNORECASE)
                       and re.search(r"'public\.%s'::regclass" % re.escape(table),
                                     where, re.IGNORECASE))
            if literal or dynamic:
                continue
            problems.append(
                "%s writes public.%s at top level, which carries the guard "
                "trigger %s. That trigger raises unless is_admin(), and a "
                "migration connection has no JWT so auth.uid() is NULL and it "
                "raises REGARDLESS of role -- SETTINGS_ARE_ADMIN_ONLY (P0001), "
                "aborting the whole push. Lift it with ALTER TABLE ... DISABLE "
                "TRIGGER %s before the write and ENABLE it after, as "
                "0028/0038/0062 do." % (path.name, table, trig, trig))

    return problems


def _privilege_loop_is_derived(src: str) -> bool:
    """Does the GRANT/REVOKE loop read its signatures from pg_proc?

    Scoped to the block that actually issues the privilege statements, so an
    assertion elsewhere in the file cannot vouch for a loop that hard-codes
    its signatures. The block runs from the `DO $$` that opens the loop to the
    end of that body; if pg_proc appears between them, the signatures came
    from the catalog.
    """
    for m in re.finditer(r"\bDO\s+\$\$", src, re.IGNORECASE):
        end = src.find("$$", m.end())
        if end == -1:
            continue
        block = src[m.end():end]
        if not re.search(r"(?:GRANT|REVOKE)[^']*ON\s+FUNCTION", block, re.IGNORECASE):
            continue
        if re.search(r"FROM\s+pg_proc", block, re.IGNORECASE):
            return True
    return False


def check_dynamic_privileges_name_real_signatures() -> list[str]:
    """A GRANT/REVOKE built with format() can only name a signature that exists.

    Postgres resolves `GRANT ... ON FUNCTION public.f(a, b)` at execution
    time, so naming a function or an arity that was never created is not a
    no-op and not a syntax error:

        ERROR: function public.fee_ride_base_fare(uuid, text, boolean)
        does not exist  (SQLSTATE 42883)

    which aborts the entire `supabase db push`. The deploy that shipped this
    file died on exactly that, after both the whole-file parse and the
    per-body parse had passed: 0107's privilege loop granted a 3-argument
    overload for all ten fee readers, and only two of them take a third
    argument.

    Parsing cannot catch it -- the statement is well formed -- so this reads
    what the file CREATES and requires every name a dynamic privilege
    statement mentions to be among them. Dynamic statements are the only
    place this can happen: a literal `GRANT ... ON FUNCTION` is at least
    syntactically visible, and the deploy reaches it in the same way, so the
    file is scanned for both and only the constructed ones are judged here.
    """
    problems: list[str] = []

    created: dict[str, set[str]] = {}
    for path in migration_files():
        src = _read(path)
        for m in re.finditer(
                r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+(?:public\.)?(\w+)\s*\(",
                src, re.IGNORECASE):
            # The argument list, taken with balanced parens so a default value
            # containing a comma does not read as two arguments.
            i = m.end() - 1
            depth = 0
            close = None
            for j in range(i, len(src)):
                if src[j] == "(":
                    depth += 1
                elif src[j] == ")":
                    depth -= 1
                    if depth == 0:
                        close = j
                        break
            # No closing paren in this file: the definition is truncated or
            # split across it, and a half-read signature would be a false
            # accusation. Skipped rather than guessed at.
            if close is None:
                continue
            args = [a.strip() for a in src[i + 1:close].split(",") if a.strip()]
            # A default does not change the arity for resolution purposes
            # (`p_is_product boolean DEFAULT false` is still one argument).
            types = []
            for a in args:
                a = re.split(r"\bDEFAULT\b", a, flags=re.IGNORECASE)[0].strip()
                types.append(a.split()[0].lower() if a.split() else "")
            created.setdefault(m.group(1).lower(), set()).add(
                ", ".join(types))

    # Every name a dynamic privilege statement mentions.
    named: dict[str, set[tuple[str, str, int]]] = {}
    for path in migration_files():
        src = _read(path)
        for m in re.finditer(
                r"(?:GRANT|REVOKE)\s+(?:ALL|EXECUTE)?\s*ON\s+FUNCTION\s+"
                r"(?:public\.)?%I\s*\(([^)]*)\)", src, re.IGNORECASE):
            sig = ", ".join(a.strip().lower() for a in m.group(1).split(","))
            named.setdefault(path.name, set()).add((m.start(), sig, 0))

        # The other shape is a signature assembled from an array of argument
        # types. The naive `ARRAY\[([^\]]*'uuid'[^\]]*)\]` cannot see it,
        # because `[^\]]*` stops at the FIRST `]` -- which is the end of the
        # inner `ARRAY['uuid', 'text']`, so the outer bracket pair never
        # matched and the whole hard-coded loop read as absent. It has to
        # tolerate one level of nesting.
        for m in re.finditer(
                r"ARRAY\[((?:[^\[\]]|\[[^\[\]]*\])*?'uuid'(?:[^\[\]]|\[[^\[\]]*\])*?)\]",
                src, re.IGNORECASE):
            block = m.group(1)
            # Only the INNER list describes one signature; an outer list of
            # signatures is handled by matching each inner list on its own.
            inner = re.findall(r"\[([^\[\]]*'uuid'[^\[\]]*)\]", block)
            for one in inner or ([block] if "'uuid'" in block else []):
                args = re.findall(r"'(\w+)'", one)
                if len(args) < 2:
                    continue
                window = src[max(0, m.start() - 2000):m.start()]
                names = re.findall(r"'(fee_[a-z_]+)'", window)
                if not names:
                    continue
                for n in names:
                    named.setdefault(path.name, set()).add(
                        (m.start(), ", ".join(a.lower() for a in args), 1))

    for path in migration_files():
        src = _read(path)
        # A loop that derives its privileges FROM pg_proc cannot name a
        # signature that does not exist, so a hard-coded signature list is
        # either dead or belongs to a different loop.
        #
        # Scoped to the privilege loop, NOT to the file: 0107 mentions
        # `FROM pg_proc` seven other times in its assertion functions, so a
        # whole-file test exempts the hard-coded loop the moment any assertion
        # reads a catalog -- which is exactly what happened, and it made three
        # falsifier cases pass while proving nothing. Only the loop whose
        # GRANTs are being judged counts.
        guarded = _privilege_loop_is_derived(src)
        for _pos, sig, _kind in sorted(named.get(path.name, set())):
            if guarded:
                break
            # The loop grants a LIST of names against one signature. That is
            # only safe when every name in the list has that arity, so the
            # names are collected from the enclosing FOREACH and each is
            # required to have it.
            window_names = _names_near(src, _pos)
            offenders = [n for n in window_names if sig not in created.get(n, set())]
            if not offenders or guarded:
                continue
            have = sorted({s for n in offenders for s in created.get(n, set())})
            problems.append(
                "%s: a dynamic privilege statement grants the signature (%s) "
                "to %s, which are created as %s. Postgres resolves this at "
                "EXECUTE time and answers 'function ... does not exist' "
                "(SQLSTATE 42883), aborting the whole push. Either drop the "
                "signature or guard the loop on the arity actually created."
                % (path.name, sig, ", ".join(sorted(offenders)),
                   "; ".join(have) or "nothing at all"))

    return problems


# ---------------------------------------------------------------------------
# N. the public account-deletion page says what the database actually does
# ---------------------------------------------------------------------------

# The eight columns 20260927000054 detaches with a DYNAMIC DO block. It cannot
# be read with a regex over the file (the table and column names are format()
# arguments, and the ALTER is built at run time), so the one place a static
# reader can see them is the migration's own FOREACH array. They are named
# here because pretending the whole history is greppable is how an earlier
# version of this check concluded that `orders` still blocked deletion.
_DETACHED_BY_DO_BLOCK = {
    "orders": "user_id",
    "reviews": "user_id",
    "ride_requests": "user_id",
    "support_tickets": "user_id",
    "payment_agreements": "user_id",
    "ride_ratings": "rater_id",
    "admin_actions": "admin_id",
    "admin_wallet_actions": "admin_id",
}

_FK_ACTION_RANK = {"NO ACTION": 0, "SET NULL": 1, "CASCADE": 2}

#: (table, parent) -> the column the last-written foreign key uses, so a finding
#: can name `orders.provider_id` rather than just `orders`. Replaced wholesale
#: on every call, never mutated in place, so a falsifier that repoints MIGRATIONS
#: at a mutated copy cannot read yesterday's answer out of it.
_FK_COLUMNS: dict[tuple[str, str], str] = {}
# (table, parent, column) -> ON DELETE action, kept alongside the per-parent
# collapse above. The collapse answers "does this parent CASCADE?" for the
# closure walk; this answers "does THIS COLUMN refuse the delete?" for the
# blocker list, and the two disagree exactly when one table has columns with
# different actions onto the same parent.
_FK_COLUMN_ACTIONS: dict[tuple[str, str, str], str] = {}

# Two shapes of dynamic detach block exist in the migration history, and both
# are invisible to a grep for REFERENCES: the table and column names are
# format() arguments or array literals, so the ALTER is assembled at run time.
#
# 0054 uses `FOREACH t IN ARRAY ARRAY['orders', ...]` with a `CASE t` picking
# the column, so its list is a hand-transcribed copy of a DO block.
_DETACHED_BY_CASE_BLOCK = {
    "orders": "user_id",
    "reviews": "user_id",
    "ride_requests": "user_id",
    "support_tickets": "user_id",
    "payment_agreements": "user_id",
    "ride_ratings": "rater_id",
    "admin_actions": "admin_id",
    "admin_wallet_actions": "admin_id",
}

# 0118 uses a VALUES list, so the names are in the file and can be READ rather
# than transcribed. A curated copy of a list the file already states is a
# second thing to forget to update: 0118 shipped 19 columns and the harness
# still believed 8, which is how `orders.provider_id` came back out of the
# deleted/kept derivation as a blocker the page had already published.
_DETACH_VALUES = re.compile(
    r"FROM\s*\(VALUES(.*?)\)\s*AS\s+v\(([^)]*)\)", re.IGNORECASE | re.DOTALL)
_DETACH_TUPLE = re.compile(
    r"'\s*([A-Za-z0-9_]+)\s*',\s*'\s*([A-Za-z0-9_]+)\s*',\s*'\s*([A-Za-z0-9_.]+)\s*'")
_DETACH_PAIR = re.compile(r"'\s*([A-Za-z0-9_]+)\s*',\s*'\s*([A-Za-z0-9_]+)\s*'")
_DO_BLOCK = re.compile(r"DO\s+\$\$(.*?)\$\$\s*;", re.IGNORECASE | re.DOTALL)


def _detach_block_bodies(sql: str):
    """The `DO` blocks in a migration that detach a foreign key."""
    for do in _DO_BLOCK.finditer(sql):
        body = do.group(1)
        if all(marker in body for marker in
               ("DROP CONSTRAINT", "ON DELETE SET NULL", "FOREIGN KEY")):
            yield body


def _detached_by_values_block(sql: str):
    """(child table, column, parent) named by a VALUES-shaped detach block.

    Scoped to a `DO $$ ... $$` block that actually re-adds a foreign key as
    `ON DELETE SET NULL` after dropping it. Scoping matters: this repository is
    full of three-column `VALUES` lists -- status transitions, fee settings,
    connectivity-test expectations -- and a bare `FROM (VALUES ...) AS v(a,b,c)`
    search matched 285 tuples across the history and reported "nothing blocks
    account deletion" for a schema where `orders.provider_id` was still a NOT
    NULL NO ACTION key. A green answer from an unanchored pattern is worse than
    no answer.
    """
    out = []
    for body in _detach_block_bodies(sql):
        for m in _DETACH_VALUES.finditer(body):
            aliases = [a.strip().lower() for a in m.group(2).split(",")]
            if len(aliases) == 3:
                for t in _DETACH_TUPLE.finditer(m.group(1)):
                    out.append((t.group(1).lower(), t.group(2).lower(),
                                t.group(3).lower()))
            elif len(aliases) == 2:
                for t in _DETACH_PAIR.finditer(m.group(1)):
                    out.append((t.group(1).lower(), t.group(2).lower(), None))
    return out


def _unreadable_detach_blocks(sql: str) -> list[str]:
    """Detach blocks this harness can see but cannot read a single name from.

    The failure this exists for: a detach list is present, the reader's anchor
    no longer matches its shape, zero tuples come back, and the derived schema
    quietly reverts to "every key is NO ACTION" -- or, worse, to a set that
    happens to look clean. Reporting "I found a detach block and understood
    none of it" is the only honest answer, and it turns a silent blind spot
    into a red the next person has to look at.
    """
    unreadable = []
    for body in _detach_block_bodies(sql):
        candidates = [m for m in _DETACH_VALUES.finditer(body)
                      if len([a for a in m.group(2).split(",")]) in (2, 3)]
        if not candidates:
            continue
        if not any(_DETACH_TUPLE.search(m.group(1))
                   or _DETACH_PAIR.search(m.group(1)) for m in candidates):
            unreadable.append(body.strip().splitlines()[0][:80])
    return unreadable

_PAGE = "delete-account.html"
_INDEX = "index.html"
# The privacy policy is submitted to Play Console next to the deletion URL; if
# it stops existing the account-deletion page that links to it stops being
# self-contained, so its absence is this check's problem too.
_PRIVACY_PAGE = "privacy-policy.html"


def _foreign_key_actions() -> dict[str, dict[str, str]]:
    """child table -> parent table -> strongest ON DELETE action.

    Tracked per COLUMN, because a table can hold two foreign keys to the same
    parent and the two answers are not interchangeable:

      * `appeal_cases.user_id` is CASCADE and `appeal_cases.resolved_by` has no
        action. DELETE fires both, the row goes, and the nullable column is
        simply never consulted -- so the table is deleted. Taking the LAST
        statement instead of the strongest would call it kept.
      * `wallet_recharge_requests.approved_by` is the only key it has to
        auth.users; it reaches the closure through `wallets`. Last-statement and
        strongest agree here, and the table is genuinely split.

    So the state is (table, parent, column) with the LAST write winning -- which
    is what a `DROP CONSTRAINT` followed by an `ADD CONSTRAINT` means -- and the
    per-parent answer is the strongest of the columns. Merging on the strongest
    action seen ANYWHERE in the history instead would pin the schema to the
    first thing it ever did: changing a CASCADE to a SET NULL in a later
    migration would leave the old answer in place forever, and a check that
    cannot see a change is not a check.
    """
    columns: dict[tuple[str, str, str], str] = {}
    dropped: set[str] = set()

    def norm(parent: str) -> str:
        return "auth.users" if parent in ("auth", "auth.users", "users") else parent

    def put(table: str, parent: str, column: str, action: str) -> None:
        columns[(table, norm(parent), column.lower())] = action
        _FK_COLUMNS[(table, norm(parent))] = column.lower()

    def forget(table: str, parent: str) -> None:
        for key in [k for k in columns if k[0] == table and k[1] == norm(parent)]:
            del columns[key]

    ref = re.compile(
        r"REFERENCES\s+(?:public\.)?\"?([A-Za-z0-9_.]+)\"?\s*"
        r"\(\s*\"?[A-Za-z0-9_]+\"?\s*\)\s*"
        r"(ON\s+DELETE\s+(?:CASCADE|SET\s+NULL))?", re.IGNORECASE)

    def action_of(group: str | None) -> str:
        if not group:
            return "NO ACTION"
        upper = group.upper()
        return "CASCADE" if "CASCADE" in upper else "SET NULL"

    for path in migration_files():
        sql = _read(path)
        for m in re.finditer(
                r"DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:public\.)?\"?([A-Za-z0-9_]+)\"?",
                sql, re.IGNORECASE):
            dropped.add(m.group(1).lower())
            for key in [k for k in columns if k[0] == m.group(1).lower()]:
                del columns[key]
        for m in re.finditer(
                r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?"
                r"\"?([A-Za-z0-9_]+)\"?\s*\(", sql, re.IGNORECASE):
            table = m.group(1).lower()
            end = sql.find(";", m.end())
            body = sql[m.end():end if end > 0 else len(sql)]
            depth, current, parts = 0, "", []
            for ch in body:                      # split on top-level commas only
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                if ch == "," and depth == 0:
                    parts.append(current)
                    current = ""
                else:
                    current += ch
            parts.append(current)
            for part in parts:
                part = " ".join(part.split())
                cm = re.match(r"^\"?([A-Za-z0-9_]+)\"?\s+(.*)$", part, re.DOTALL)
                if not cm:
                    continue
                rm = ref.search(cm.group(2))
                if rm:
                    put(table, rm.group(1).lower(), cm.group(1),
                        action_of(rm.group(2)))
        for am in re.finditer(
                r"ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?(?:public\.)?"
                r"\"?([A-Za-z0-9_]+)\"?\s+(.*?);", sql, re.IGNORECASE | re.DOTALL):
            table, clause = am.group(1).lower(), " ".join(am.group(2).split())
            if (re.search(r"ADD\s+CONSTRAINT", clause, re.IGNORECASE)
                    and re.search(r"FOREIGN\s+KEY", clause, re.IGNORECASE)):
                fm = re.search(
                    r"FOREIGN\s+KEY\s*\(\s*\"?([A-Za-z0-9_]+)\"?\s*\)\s*"
                    r"REFERENCES\s+(?:public\.)?\"?([A-Za-z0-9_.]+)\"?\s*\([^)]*\)\s*"
                    r"(ON\s+DELETE\s+(?:CASCADE|SET\s+NULL))?", clause, re.IGNORECASE)
                if fm:
                    put(table, fm.group(2).lower(), fm.group(1),
                        action_of(fm.group(3)))
                    continue
            # `ADD COLUMN ... REFERENCES auth.users(id)` is a foreign key too,
            # and several of them are the ONLY link a table has to the account
            # (`wallet_recharge_requests.approved_by`). Reading only the
            # ADD CONSTRAINT form makes those tables look unreachable from the
            # account, which is how a table that survives deletion gets filed
            # under "deleted".
            cm = re.search(r"ADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?"
                           r"\"?([A-Za-z0-9_]+)\"?\s+[A-Za-z]+"
                           r"(?:\([^)]*\))?\s*(?:,|\s)*.*?REFERENCES\s+"
                           r"(?:public\.)?\"?([A-Za-z0-9_.]+)\"?\s*\([^)]*\)\s*"
                           r"(ON\s+DELETE\s+(?:CASCADE|SET\s+NULL))?",
                           clause, re.IGNORECASE)
            if cm:
                put(table, cm.group(2).lower(), cm.group(1),
                    action_of(cm.group(3)))
                continue
            # A dropped constraint is the schema walking a key back; the
            # following ADD is the new truth.
            dm = re.search(r"DROP\s+CONSTRAINT\b.*?FOREIGN\s+KEY.*?REFERENCES\s+"
                           r"(?:public\.)?\"?([A-Za-z0-9_.]+)\"?",
                           clause, re.IGNORECASE | re.DOTALL)
            if dm:
                forget(table, dm.group(1).lower())

    for table, column in _DETACHED_BY_CASE_BLOCK.items():
        put(table, "auth.users", column, "SET NULL")
    for table, column, parent in _detached_by_values_block(
            "\n".join(_read(p) for p in migration_files())):
        if parent is not None:
            put(table, parent, column, "SET NULL")
            continue
        # The pair form: detach every parent this column already points at. The
        # migration looks the key up by column and never names a parent, so
        # this is the same set it would touch.
        parents = {k[1] for k in columns if k[0] == table and k[2] == column.lower()}
        if not parents:
            continue
        for p in sorted(parents):
            put(table, p, column, "SET NULL")

    edges: dict[str, dict[str, str]] = {}
    _FK_COLUMNS.clear()
    _FK_COLUMN_ACTIONS.clear()
    for (table, parent, _column), action in columns.items():
        if table in dropped:
            continue
        _FK_COLUMN_ACTIONS[(table, parent, _column)] = action
        cur = edges.setdefault(table, {})
        if parent not in cur or _FK_ACTION_RANK[action] > _FK_ACTION_RANK[cur[parent]]:
            cur[parent] = action
    return edges


def _deletion_cascade() -> tuple[set[str], set[str], set[str]]:
    """(deleted with the account, kept but detached, and the two's overlap).

    Deleted is the CLOSURE, not the direct children: `provider_profiles` is a
    direct child, but `products`, `vehicles`, `wallets` and their dependants go
    with it, and those are exactly the rows a person asks to have removed. Kept
    is every table with a foreign key to auth.users that the closure does not
    reach -- those rows survive and only the link is nulled.

    The overlap is the honest part and is not an edge case. A table can hang off
    a deleted parent while referencing the account only through a NULLABLE
    column: `wallet_recharge_requests` cascades with the provider wallet and is
    nulled out of `approved_by`, so a business account loses the row and a
    customer account keeps it. Filing it under either single bucket states
    something false about one of the two, so it is reported separately.
    """
    edges = _foreign_key_actions()
    deleted: set[str] = set()
    frontier = {"auth.users"}
    while frontier:
        nxt = set()
        for table, parents in edges.items():
            if table in deleted:
                continue
            if any(p in frontier and a == "CASCADE" for p, a in parents.items()):
                deleted.add(table)
                nxt.add(table)
        frontier = nxt
    direct = {t for t, ps in edges.items() if "auth.users" in ps}
    # A second, NULLABLE auth.users column on a table that already cascades
    # changes nothing -- the CASCADE still takes the row (notifications has
    # `user_id` CASCADE and appeal_cases has `resolved_by`). The genuine split
    # is a table with NO cascading link to the account at all, which the closure
    # only reaches through somebody else's wallet.
    split = {t for t in deleted
             if "auth.users" in edges[t] and edges[t]["auth.users"] != "CASCADE"}
    return deleted, direct - deleted, split


def _deletion_blockers() -> list[tuple[str, str, str]]:
    """(table, column, parent) for every key that still refuses the delete.

    A key blocks when the row it hangs off is deleted with the account, the row
    that holds the key is NOT itself deleted with it, and the action is neither
    CASCADE nor SET NULL. The middle clause is why a table like
    `wallet_recharge_requests` is not simply excluded for being inside the
    cascade: the rows in it belong to a provider, so they outlive a customer.

    The last clause is the one that is easy to get wrong. PostgreSQL 18, 5.5.5:
    the default ON DELETE action "will usually result in an error", and the
    exemption for a null referencing column applies to inserting and updating a
    row, not to deleting the parent. 0054 assumed otherwise and left nine
    nullable columns still holding NO ACTION keys.
    """
    edges = _foreign_key_actions()
    deleted, _kept, _split = _deletion_cascade()

    business: set[str] = set()
    frontier = {"provider_profiles"}
    while frontier:
        nxt = set()
        for table, parents in edges.items():
            if table in business or table in deleted:
                continue
            if any(p in frontier and a == "CASCADE" for p, a in parents.items()):
                business.add(table)
                nxt.add(table)
        frontier = nxt

    gone = deleted | business | {"auth.users"}
    out = []
    for table in sorted(edges):
        if table in deleted or table in business:
            continue
        # PER COLUMN, never per parent. `admin_notification_broadcasts` holds
        # two keys to the account table: `admin_id`, which 0118 detaches, and
        # `target_user_id`, which is nullable with no ON DELETE action at all.
        # Collapsing the two to "the strongest action for this parent" reports
        # SET NULL and loses the NO ACTION column -- a false green produced by
        # the very rule 0118's header argues against. A parent is only as safe
        # as its weakest column, so that is what gets checked.
        for (t, parent, column), action in sorted(_FK_COLUMN_ACTIONS.items()):
            if t != table or parent not in gone or action != "NO ACTION":
                continue
            out.append((table, column, parent))
    return sorted(out)


def _declared_tables(html: str, block_id: str) -> list[str]:
    m = re.search(r"<ul[^>]*id=\"%s\"[^>]*>(.*?)</ul>" % re.escape(block_id),
                  html, re.DOTALL | re.IGNORECASE)
    if not m:
        return []
    return re.findall(r"data-table=\"([^\"]+)\"", m.group(1))


def check_account_deletion_page_is_public_and_true() -> list[str]:
    """Google Play rejected the listing: the account-deletion page was down.

    Play requires a page that ANYONE can load -- no app install, no sign-in, no
    country restriction -- saying how to ask for deletion. The repo already
    carried a `delete-account.md` telling users to email an address, and it had
    been overtaken by the app: `request_account_deletion` (migration
    20260927000054) plus AccountDeletionScreen are the real flow. A file in a
    private repository is not a page, which is the whole of the rejection.

    Three things have to hold, and each has been false on its own:

    1. the page is PUBLIC in the mechanical sense Google tests for -- one
       self-contained file, no form, no script, no external request, so there is
       nothing to sign in to, nothing to geolocate, and nothing that can fail to
       load because a third party is down;
    2. the instructions match the app -- every label the page tells a user to
       tap or type is a string that really exists in the screen that submits the
       request, so the page cannot drift into describing a flow nobody has; and
    3. the deleted/kept split is the SCHEMA's split, derived from the foreign
       keys, not a list somebody wrote. Claiming a table is deleted when the
       database keeps it is the one error that makes the page a lie to a policy
       reviewer, so over-claiming is a hard failure and under-claiming is not.
    """
    problems: list[str] = []

    page = _read(ROOT / "docs" / _PAGE)
    if not page:
        return [
            "docs/%s does not exist. Google Play requires a public web page "
            "describing how to request account deletion; a file in a private "
            "repository is not one." % _PAGE,
        ]
    index = _read(ROOT / "docs" / _INDEX)
    if _PAGE not in index:
        problems.append(
            "docs/%s does not link to %s, so the published site root would not "
            "lead a reviewer to the page Play is asking for" % (_INDEX, _PAGE))
    if not _read(ROOT / "docs" / _PRIVACY_PAGE):
        problems.append(
            "docs/%s is missing; Play Console asks for a privacy policy URL "
            "next to the deletion one" % _PRIVACY_PAGE)

    # --- 1. public and self-contained ---------------------------------------
    for pattern, why in (
            (r"<form\b", "a sign-in form"),
            (r"<input\b", "an input control"),
            (r"type=\"password\"", "a password field"),
            (r"<script\b", "a script that can fail to load"),
            (r"\son[a-z]+\s*=", "an inline event handler"),
            (r"http-equiv", "a client-side redirect"),
            (r"<iframe\b", "an embedded frame"),
            (r"navigator\.", "a client-side capability or geolocation check"),
    ):
        if re.search(pattern, page, re.IGNORECASE):
            problems.append(
                "docs/%s contains %s. The page Play loads has to be readable "
                "by anyone, anywhere, with nothing to sign in to and nothing "
                "that can be blocked." % (_PAGE, why))
    for ref in re.findall(r"(?:src|href)\s*=\s*\"([^\"]+)\"", page):
        low = ref.strip().lower()
        if low.startswith(("http://", "https://", "//")):
            problems.append(
                "docs/%s loads %r from another host. A policy page must render "
                "from its own URL alone." % (_PAGE, ref))
    for needed, why in (
            (r"<html[^>]+lang=\"en\"", "a declared language"),
            (r"<title>[^<]+</title>", "a title"),
            (r"name=\"viewport\"", "a viewport meta tag"),
    ):
        if not re.search(needed, page, re.IGNORECASE):
            problems.append("docs/%s is missing %s" % (_PAGE, why))

    # --- 2. the instructions match the app ----------------------------------
    labels = [re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", m)).strip()
              for m in re.findall(r"<span class=\"ui\">(.*?)</span>", page,
                                  re.DOTALL)]
    labels = [lbl for lbl in labels if lbl]
    if not labels:
        problems.append(
            "docs/%s quotes no interface labels, so nothing ties the "
            "instructions to the app and they can drift silently" % _PAGE)

    submitter = ""
    for dart in dart_sources():
        if "rpc('request_account_deletion'" in _read(dart):
            submitter = dart
            break
    if not submitter:
        problems.append(
            "no Dart source calls request_account_deletion, so the flow the "
            "page describes cannot be found and the page is unverifiable")
    else:
        screen = _read(submitter)
        for label in labels:
            if label not in screen:
                problems.append(
                    "docs/%s tells the user to use %r, but that string does not "
                    "appear in %s -- the page describes a control that does not "
                    "exist" % (_PAGE, label, submitter.name))

    menu_labels = [lbl for lbl in labels if lbl == "Delete Account"]
    if menu_labels and not any(
            "Delete Account" in _read(d) and "/account/deletion" in _read(d)
            for d in dart_sources()):
        problems.append(
            "docs/%s says the request starts from a 'Delete Account' menu item, "
            "but no screen in lib/ has one that navigates to the deletion route"
            % _PAGE)

    # --- 3. the deleted/kept split is the schema's split --------------------
    derived_deleted, derived_kept, derived_split = _deletion_cascade()
    if not derived_deleted or not derived_kept:
        problems.append(
            "the foreign-key derivation found %d deleted and %d kept tables -- "
            "it is inspecting nothing, so it cannot judge the page"
            % (len(derived_deleted), len(derived_kept)))

    declared_deleted = set(_declared_tables(page, "deleted-tables"))
    declared_kept = set(_declared_tables(page, "retained-tables"))
    declared_conditional = set(_declared_tables(page, "conditional-tables"))
    if not declared_deleted:
        problems.append(
            "docs/%s declares no deleted tables, so the claim that anything is "
            "removed is unfalsifiable" % _PAGE)
    if not declared_kept:
        problems.append(
            "docs/%s declares no retained tables, so the page cannot be "
            "distinguished from boilerplate" % _PAGE)

    lying = sorted(declared_deleted - derived_deleted)
    if lying:
        problems.append(
            "docs/%s tells users these tables are deleted with the account, and "
            "the schema does not delete them: %s. Either the page is wrong or "
            "the migration is; a policy page must not promise a deletion the "
            "database does not perform."
            % (_PAGE, ", ".join(lying)))
    both = sorted(declared_deleted & declared_kept)
    if both:
        problems.append(
            "docs/%s lists these tables as both deleted and retained: %s"
            % (_PAGE, ", ".join(both)))

    # A table can genuinely be BOTH -- `wallet_recharge_requests` cascades with
    # the provider wallet and is also nulled out of the approver column, so a
    # business account loses it and a customer account keeps it. Filing such a
    # table under either single bucket is a false statement about one of those
    # two cases, so it has to be declared as conditional, and only a table the
    # schema really splits may be.
    split = derived_split
    if split != declared_conditional:
        problems.append(
            "docs/%s declares conditional tables %s, but the schema splits %s. "
            "A table that is deleted for one kind of account and kept for "
            "another has to be declared as conditional; everything else belongs "
            "in exactly one bucket."
            % (_PAGE, sorted(declared_conditional) or "none", sorted(split) or "none"))

    visible = {name for name in literal_calls(r"(?<!storage)\.from\(\s*'([^']+)'")
               if "-" not in name}
    silent = sorted(visible - declared_deleted - declared_kept - declared_conditional)
    if silent:
        problems.append(
            "docs/%s says nothing about tables the app reads, so a user cannot "
            "tell whether they survive: %s. Every one must be listed as deleted "
            "or as retained." % (_PAGE, ", ".join(silent)))

    defined = {
        m.group(1).lower()
        for m in re.finditer(
            r"CREATE\s+(?:OR\s+REPLACE\s+)?(?:TABLE|VIEW|MATERIALIZED\s+VIEW)\s+"
            r"(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?\"?([A-Za-z0-9_]+)\"?",
            "\n".join(_read(p) for p in migration_files()), re.IGNORECASE)
    }
    unknown = sorted((declared_deleted | declared_kept | declared_conditional) - defined)
    if unknown:
        problems.append(
            "docs/%s names tables no migration creates, so the appendix cannot "
            "be checked against the schema: %s" % (_PAGE, ", ".join(unknown)))

    return problems


def check_account_deletion_is_unblocked() -> list[str]:
    """No foreign key may refuse `DELETE FROM auth.users`.

    The page check above asks whether the POLICY PAGE is true. This asks
    whether the DATABASE agrees, which is the half that was false for the whole
    life of the feature.

    `request_account_deletion` writes a PENDING row, the staff screen approves
    it, the Edge Function calls `delete_user_account`, and that function ends
    in `DELETE FROM auth.users WHERE id = p_target_user_id`. Every key still
    pointing at that row with no ON DELETE action takes the whole statement
    down with 23503 — after the request has been marked APPROVED, which is
    precisely the state the design said it wanted to avoid: visible, retryable,
    never silently lost. 0054 detached eight NOT NULL columns and left the
    nullable ones, on the belief that a null column is exempt. It is not:
    PostgreSQL 18, 5.5.5 says a NO ACTION delete "will usually result in an
    error", and the null exemption in the next paragraph is about writing a
    referencing row, not about deleting its parent.

    So `audit_logs.actor_id` — written by a trigger on the mutation paths since
    0035 — blocked the delete for every account that had ever done anything, and
    `orders.provider_id` blocked it for every provider who had ever taken an
    order. Nothing tested the path end to end, so both shipped.

    0118 detaches nineteen columns and adds `account_deletion_blockers()` so the
    live catalog can be asked the same question. This check is the static half.
    """
    problems: list[str] = []

    deleted, kept, _split = _deletion_cascade()
    if not deleted or not kept:
        problems.append(
            "the cascade derivation found %d deleted and %d kept tables -- it is "
            "inspecting nothing, so it cannot judge whether the delete is "
            "blocked" % (len(deleted), len(kept)))

    blockers = _deletion_blockers()
    for table, column, parent in blockers:
        problems.append(
            "%s.%s still holds a NO ACTION key onto %s, which is deleted with "
            "the account, so closing the account fails with a foreign-key "
            "violation after the request has already been approved. Add it to "
            "the detach list in 20260927000118 (or a later migration) as "
            "ON DELETE SET NULL."
            % (table, column, parent))

    # A blocker list that is empty because the derivation found no edges at all
    # is the failure this check exists to prevent, so say so rather than pass.
    if not blockers and not any("auth.users" in ps for ps in
                                _foreign_key_actions().values()):
        problems.append(
            "no foreign key to auth.users was found at all, so 'nothing blocks "
            "the deletion' means the derivation is broken, not that the schema "
            "is clean")

    for path in migration_files():
        for head in _unreadable_detach_blocks(_read(path)):
            problems.append(
                "%s contains a foreign-key detach block this harness cannot "
                "read any name from (%s). The account-deletion derivation is "
                "blind to it, so 'nothing blocks the delete' above is not "
                "evidence. Keep the list as `('table', 'column', 'parent')` "
                "tuples under a three-column alias."
                % (path.name, head))
    return problems


# ---------------------------------------------------------------------------
# every trade ranks its best and prices on its own terms (migration 0128)
# ---------------------------------------------------------------------------
# The migration that introduces the ranked readers and the per-category
# provider fields. Named, not located by "the last migration that mentions the
# name", because that file's own reports mention every function -- so a
# membership test over the string would point at whichever file happened to be
# later, not the file that defines anything.
CATEGORY_FIELD_MIGRATION = (
    "20260927000128_every_trade_ranks_its_best_and_prices_its_own.sql")

# function name -> the exact parameter names it declares. A rename on the SQL
# side (p_category_id -> p_cat) is a PostgREST 202 at runtime with no compiler
# error anywhere, and the user reads it as "not found". This is the comparison
# that pins it.
CATEGORY_FIELD_PARAMS: dict[str, list[str]] = {
    "ranked_providers": ["p_category_id", "p_city", "p_limit", "p_offset"],
    "ranked_categories": ["p_limit", "p_offset"],
    "save_provider_profile_field": [
        "p_field_key", "p_value_text", "p_value_number", "p_value_boolean"],
    "admin_save_category_profile_field": [
        "p_category_id", "p_field_key", "p_label", "p_input_type",
        "p_unit_label", "p_help_text", "p_is_required", "p_is_price",
        "p_sort_order", "p_is_active"],
    "admin_delete_category_profile_field": ["p_field_id"],
    "provider_claim_category": ["p_category_id"],
    "provider_public_profile_fields": ["p_provider_id"],
    "provider_effective_profile_fields": ["p_category_id"],
}

# The six sectors the seed must cover, so no active category is left with an
# empty form just because nobody wrote rows for its marketplace_sector.
CATEGORY_FIELD_SEED_SECTORS = (
    "ACCOMMODATION", "FOOD", "RETAIL", "SERVICES", "TRANSPORT", "OTHER")

# rpc -> the Dart file (basename) that must call it. A screen with no caller is
# a feature with no door, which is the defect this repository has shipped more
# than once.
CATEGORY_FIELD_CALLERS: dict[str, tuple[str, ...]] = {
    "ranked_providers": ("user_home_screen.dart", "user_category_screen.dart"),
    "ranked_categories": ("user_home_screen.dart",),
    "provider_profile_fields": ("provider_category_settings_screen.dart",),
    "save_provider_profile_field": ("provider_category_settings_screen.dart",),
    "provider_public_profile_fields": ("user_provider_detail_screen.dart",),
    "admin_category_profile_fields": ("admin_category_fields_screen.dart",),
    "admin_save_category_profile_field": ("admin_category_fields_screen.dart",),
    "admin_delete_category_profile_field": ("admin_category_fields_screen.dart",),
    "provider_claim_category": (
        "auth_provider.dart", "provider_category_settings_screen.dart"),
}

# rpc -> the keys its LITERAL `params: { ... }` map sends. save_provider_
# profile_field is absent on purpose: it is called with a `params` VARIABLE, so
# _sent_keys cannot read its keys, and the screen is asserted by its literal
# map-key tokens in the check body instead.
CATEGORY_FIELD_SENT_KEYS: dict[str, tuple[str, ...]] = {
    "ranked_providers": ("p_category_id", "p_limit", "p_offset"),
    "ranked_categories": ("p_limit", "p_offset"),
    "provider_public_profile_fields": ("p_provider_id",),
    "admin_save_category_profile_field": (
        "p_category_id", "p_field_key", "p_label", "p_input_type",
        "p_unit_label", "p_help_text", "p_is_required", "p_is_price",
        "p_sort_order", "p_is_active"),
    "admin_delete_category_profile_field": ("p_field_id",),
    "provider_claim_category": ("p_category_id",),
}


def _sql_function_params(name: str) -> list[str]:
    """The parameter names of the LAST declaration of public.<name>().

    Paren-matched rather than a `\(([^)]*)\)` regex, so a DEFAULT that ever
    grows a parenthesis cannot truncate the list; a truncated list would drop
    exactly the names this check exists to compare.
    """
    latest = ""
    pat = re.compile(
        r"CREATE OR REPLACE FUNCTION\s+(?:public\.)?%s\s*\(" % re.escape(name),
        re.I)
    for path in migration_files():
        src = _read(path)
        for m in pat.finditer(src):
            depth, i = 1, m.end()
            while i < len(src) and depth:
                if src[i] == "(":
                    depth += 1
                elif src[i] == ")":
                    depth -= 1
                i += 1
            latest = src[m.end():i - 1]
    if not latest:
        return []
    raw, cur, depth = [], "", 0
    for ch in latest:
        if ch == "(":
            depth += 1
        if ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            raw.append(cur)
            cur = ""
        else:
            cur += ch
    raw.append(cur)
    names: list[str] = []
    for piece in raw:
        piece = re.sub(r"--[^\n]*", "", piece).strip()
        m = re.match(r"(p_\w+)\b", piece)
        if m:
            names.append(m.group(1))
    return names


def _literal_param_keys(site: str, fn: str) -> set[str] | None:
    """The keys in the literal `params: { ... }` map of the first call to fn.

    Brace-matched rather than regex-bounded. The older `_sent_keys` closes the
    map with `\\}\s*\\)`, which only matches when the closing brace is
    immediately followed by `)`; a call formatted with a trailing comma
    (`params: {'p_field_id': field['id']},` then `);` on the next line) has a
    `,` there, so the bound never matches and the key scan runs on into the
    widget tree -- reporting `decoration`, `padding` and `color` as arguments
    of the RPC. Brace matching has no such shape dependence.

    Returns None when there is no literal map at all (a call with no params, or
    one that passes a variable), which is a finding the caller decides on.
    """
    idx = site.find("'%s'" % fn)
    if idx < 0:
        return None
    at = site.find("params:", idx)
    if at < 0:
        return None
    brace = site.find("{", at)
    if brace < 0:
        return None
    depth, i = 0, brace
    while i < len(site):
        if site[i] == "{":
            depth += 1
        elif site[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    tail = site[brace + 1:i]
    keys = set(re.findall(r"'([a-z_0-9]+)'\s*:", tail))
    keys |= set(re.findall(r"^\s*([a-z_0-9]+)\s*:", tail, re.M))
    return keys


def check_category_fields_are_wired() -> list[str]:
    """Every trade ranks its best, and prices on its own terms.

    Two features, one migration, and neither is a compile error if it rots:

      1. the ranked readers (`ranked_providers`, `ranked_categories`) order by
         real completed transactions, and the screens read them. A revert to
         `ORDER BY created_at` still parses and still returns rows -- it just
         stops being a ranking, and a customer sees the newest signup first.
      2. per-category provider fields. The customer page must only ever see an
         APPROVED provider's declared values, the provider's save must pick
         the column from the field's declared type, the admin editor must
         exist AND be reachable, and signup must ask the category. Each has
         its own quiet failure mode.

    The parameter-name comparison is the load-bearing part: a renamed SQL
    parameter yields PGRST202 at runtime, which reads to a user as "not
    found", and nothing in the Dart compiler can see it.
    """
    problems: list[str] = []

    mig = MIGRATIONS / CATEGORY_FIELD_MIGRATION
    if not mig.is_file():
        return ["%s is missing -- ranking and per-category provider fields "
                "have no schema to stand on" % CATEGORY_FIELD_MIGRATION]
    sql = _read(mig)
    body = _strip_comments(sql)

    # 1. the storage both features need.
    for table in ("category_profile_fields", "provider_profile_field_values"):
        if not re.search(
                r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?public\.%s\b"
                % table, sql, re.I):
            problems.append("%s: public.%s is never created" % (mig.name, table))

    # 2. every function exists and declares exactly the parameters the client
    #    contract names. Exact equality as a set, both directions: a missing
    #    name breaks the call, an extra one means the two sides have drifted.
    for fn, expected in CATEGORY_FIELD_PARAMS.items():
        declared = _sql_function_params(fn)
        if not declared:
            problems.append("%s: public.%s() is not defined" % (mig.name, fn))
            continue
        if set(declared) != set(expected):
            problems.append(
                "%s: public.%s() declares %s, the client contract is %s -- a "
                "difference here is a PGRST202 no compiler can see"
                % (mig.name, fn, sorted(declared), sorted(expected)))

    # 2b. the ranking is a ranking: order by real completed work, and expose a
    #     position a screen can print. A revert to `ORDER BY created_at` still
    #     parses and still returns rows -- it just stops ordering from the most
    #     transacted to the least, which is the whole feature.
    ranking_readers = {
        "ranked_providers": ("completed_transactions DESC", "row_number() OVER",
                             "rank_position"),
        "ranked_categories": ("row_number() OVER", "rank_position",
                              "sales_count"),
    }
    for fn, needles in ranking_readers.items():
        rb = function_body(sql, fn)
        if not rb:
            problems.append("%s: %s() has no body" % (mig.name, fn))
            continue
        for needle in needles:
            if needle not in rb:
                problems.append(
                    "%s: %s() no longer contains %r -- the list is no longer "
                    "ranked from the most transacted to the least"
                    % (mig.name, fn, needle))

    # 3. the customer reader only answers for an APPROVED provider, and only
    #    rows that actually carry a value. Dropping the status gate would put a
    #    pending provider's answers on the public page.
    reader = function_body(sql, "provider_public_profile_fields")
    if not reader:
        problems.append("%s: provider_public_profile_fields() has no body"
                        % mig.name)
    else:
        if "APPROVED" not in reader:
            problems.append(
                "%s: provider_public_profile_fields() no longer filters on "
                "APPROVED -- a pending provider's declared values would be "
                "visible to every customer" % mig.name)
        for col in ("value_text", "value_number", "value_boolean"):
            if col not in reader:
                problems.append(
                    "%s: provider_public_profile_fields() does not consider "
                    "%s -- a value stored in that column would never be shown"
                    % (mig.name, col))

    # 4. the saver picks the column from the declared input type, and refuses a
    #    key the category does not define instead of storing it nowhere.
    saver = function_body(sql, "save_provider_profile_field")
    if not saver:
        problems.append("%s: save_provider_profile_field() has no body"
                        % mig.name)
    else:
        for token in ("input_type", "value_text", "value_number",
                      "value_boolean",
                      "THAT_FIELD_IS_NOT_PART_OF_YOUR_CATEGORY"):
            if token not in saver:
                problems.append(
                    "%s: save_provider_profile_field() no longer mentions %s "
                    "-- the save path cannot file a typed value correctly"
                    % (mig.name, token))

    # 5. the seed reaches every sector, so no active category is seeded empty.
    for sector in CATEGORY_FIELD_SEED_SECTORS:
        if "'%s'" % sector not in body:
            problems.append(
                "%s: the field seed has no '%s' rows -- a provider in that "
                "sector gets an empty settings form" % (mig.name, sector))

    # 6. the reads go through the ranked reader, and the customer page reads
    #    the declared fields. A screen reverted to a plain select still works,
    #    it just stops being ranked.
    home = _strip_comments(_read(LIB / "features" / "user"
                                 / "user_home_screen.dart"))
    if "'ranked_providers'" not in home:
        problems.append(
            "user_home_screen.dart no longer reads ranked_providers -- the "
            "home rail is back to signup order")
    cat = _strip_comments(_read(LIB / "features" / "user"
                                / "user_category_screen.dart"))
    if "'ranked_providers'" not in cat:
        problems.append(
            "user_category_screen.dart no longer reads ranked_providers -- the "
            "category screen has no top providers")
    detail = _strip_comments(_read(LIB / "features" / "user"
                                   / "user_provider_detail_screen.dart"))
    if "'provider_public_profile_fields'" not in detail:
        problems.append(
            "user_provider_detail_screen.dart no longer reads "
            "provider_public_profile_fields -- the customer cannot see what "
            "the provider declared")

    # 7. the provider settings screen builds the save map with the field key
    #    and the two value shapes it can send.
    settings = _strip_comments(_read(
        LIB / "features" / "provider" / "provider_category_settings_screen.dart"))
    if "'save_provider_profile_field'" not in settings:
        problems.append(
            "provider_category_settings_screen.dart never calls "
            "save_provider_profile_field -- the settings form cannot save")
    else:
        for token in ("'p_field_key'", "'p_value_text'", "'p_value_boolean'"):
            if token not in settings:
                problems.append(
                    "provider_category_settings_screen.dart does not build the "
                    "save map with %s" % token)

    # 8. the admin editor exists and both doors are open.
    screen = LIB / "features" / "admin" / "admin_category_fields_screen.dart"
    if not screen.is_file():
        problems.append(
            "lib/features/admin/admin_category_fields_screen.dart is missing -- "
            "the per-category field catalogue has no editor")
    router = _read(LIB / "routing" / "app_router.dart")
    for route in ("'/admin/category-fields'", "'/provider/category-settings'"):
        if route not in router:
            problems.append("app_router.dart has no %s route" % route)
    dash = _strip_comments(_read(LIB / "features" / "admin"
                                 / "admin_dashboard.dart"))
    if "/admin/category-fields" not in dash:
        problems.append(
            "admin_dashboard.dart has no sidebar card for "
            "/admin/category-fields -- the admin editor exists with no way in")
    pdash = _strip_comments(_read(LIB / "features" / "provider"
                                  / "service_provider_dashboard.dart"))
    if "/provider/category-settings" not in pdash:
        problems.append(
            "service_provider_dashboard.dart has no way into "
            "/provider/category-settings -- a provider cannot reach their own "
            "field editor")

    # 9. the signup gate actually asks, and carries the answer through.
    signup = _strip_comments(_read(LIB / "features" / "auth"
                                   / "signup_screen.dart"))
    for token in ("_selectedCategoryId", "_providerCategories",
                  "categoryId: draft.categoryId"):
        if token not in signup:
            problems.append(
                "signup_screen.dart no longer carries %s -- the signup gate no "
                "longer asks the provider's category" % token)

    # 10. every rpc has the caller it is supposed to have, and the keys a
    #     literal call site sends are exactly the ones the function declares.
    called_in: dict[str, set[str]] = {}
    for path in dart_sources():
        src = _read(path)
        for fn in CATEGORY_FIELD_CALLERS:
            if "'%s'" % fn in src:
                called_in.setdefault(fn, set()).add(path.name)
    for fn, files in CATEGORY_FIELD_CALLERS.items():
        callers = called_in.get(fn, set())
        if not callers:
            problems.append("no Dart file calls %s()" % fn)
            continue
        for fname in files:
            if fname not in callers:
                problems.append(
                    "%s no longer calls %s() -- that screen's use of it was "
                    "removed or renamed" % (fname, fn))
    for fn, keys in CATEGORY_FIELD_SENT_KEYS.items():
        sent = _literal_param_keys(_rpc_call_sites(fn), fn)
        if sent is None:
            problems.append(
                "the call to %s() has no readable literal argument map -- a "
                "transcription nobody can check" % fn)
            continue
        declared = set(CATEGORY_FIELD_PARAMS.get(fn, ()))
        optional = _declared_defaults(fn)
        for key in keys:
            if key not in sent and key not in optional:
                problems.append(
                    "the call to %s() does not send %s, which the function "
                    "declares and does not default -- that argument is missing "
                    "at the call site" % (fn, key))
        for key in sent:
            if key not in declared:
                problems.append(
                    "the call to %s() sends %s, which the function does not "
                    "declare -- PostgREST resolves a function by its argument "
                    "names, so this call cannot resolve" % (fn, key))

    return problems


REGISTRATION_MIGRATION = "20260927000130_a_submission_tells_both_sides.sql"


def check_registration_notifications_are_wired() -> list[str]:
    """A submitted application must tell the applicant AND the reviewers.

    Nine of the twelve verification states already notify; the two that did
    not were the SUBMITTED state (in either direction) and the reactivation
    that a 0026 restatement silently dropped. Neither is a compile error and
    neither shows up in a screenshot: the rows are simply absent.

    The load-bearing part is that the send is a TRIGGER over approval_requests
    rather than a call inside each of the three submitting functions. A trigger
    is the only place the next caller cannot forget, and a per-caller call is
    precisely how the document half of this went missing in the first place --
    so a check that accepted three call sites would accept the shape that
    caused the bug.
    """
    problems: list[str] = []

    mig = MIGRATIONS / REGISTRATION_MIGRATION
    if not mig.is_file():
        return ["%s is missing -- a submitted application notifies nobody, so "
                "the applicant cannot tell a received application from a lost "
                "one and reviewers only find the queue by going to look"
                % REGISTRATION_MIGRATION]
    sql = _strip_comments(_read(mig))

    # 1. Both triggers, by name. A DROP TRIGGER without its CREATE is how the
    #    document gap reopened once already.
    for trig, why in (
        ("trg_registration_submitted",
         "a signup, a partner application and a resubmission all write "
         "approval_requests and none of them notifies anybody"),
        ("trg_registration_resubmitted",
         "a rejected application reopened by resubmit_rejected_application is "
         "an UPDATE, so the insert trigger cannot see it"),
    ):
        if not re.search(
                r"CREATE\s+TRIGGER\s+%s\b[\s\S]{0,400}?ON\s+"
                r"(?:public\.)?approval_requests\b" % trig,
                sql, re.IGNORECASE):
            problems.append(
                "%s does not create %s on approval_requests, so %s"
                % (mig.name, trig, why))

    # 2. Both sides of the submission. A trigger that only opens the queue for
    #    staff leaves the person who applied in silence, which is the half
    #    that matters most to them.
    for fn in ("on_registration_submitted", "on_registration_resubmitted"):
        target, src = last_migration_defining(fn)
        if target is None:
            problems.append("%s is undefined" % fn)
            continue
        # THE BODY, not the file. 20260927000130 and 20261014000000 each define
        # several notifying functions, so a whole-file search for
        # notify_user_safe is satisfied by a neighbouring function's call after
        # THIS one's has been deleted. That is not hypothetical: the falsifier
        # reported a false green over an account that came back silently
        # exactly that way, and a check a neighbour can satisfy is not a check
        # (same reason function_body strips comments).
        if "notify_user_safe" not in function_body(src, fn).lower():
            problems.append(
                "%s: %s() writes no notification, so the event is silent"
                % (target.name, fn))

    target, src = last_migration_defining("on_registration_submitted")
    if target is not None:
        submitted = function_body(src, "on_registration_submitted")
        # The reviewer fan-out is reached through the recipient set, and a
        # mention of the name is not a call: the falsifier plants the reference
        # with the loop emptied.
        if not re.search(r"registration_review_recipients\s*\(\s*\)", submitted,
                         re.IGNORECASE):
            problems.append(
                "%s: on_registration_submitted() never calls "
                "registration_review_recipients(), so no reviewer is told an "
                "application arrived and the queue is only found by looking"
                % target.name)
        if not re.search(r"\bFOR\s+v_recipient\s+IN\b", submitted, re.IGNORECASE):
            problems.append(
                "%s: on_registration_submitted() does not iterate the recipient "
                "set" % target.name)

    # 3. The enum value. REGISTRATION_RECEIVED has existed since 0001 and is
    #    written by nothing else; using it is what keeps this off a second
    #    parallel system.
    if not re.search(r"'REGISTRATION_RECEIVED'", sql):
        problems.append(
            "%s never writes REGISTRATION_RECEIVED, so the notification that "
            "reaches the applicant and the reviewers has no type" % mig.name)

    # 4. unsuspend_provider: guarded AND telling. Both halves, because a
    #    restatement that dropped the guard is caught elsewhere and one that
    #    dropped the notice is caught nowhere.
    target, src = last_migration_defining("unsuspend_provider")
    if target is None:
        problems.append("unsuspend_provider is undefined")
    else:
        # Body-scoped for the same reason as the two triggers above: this file
        # also defines on_registration_submitted and on_registration_resubmitted,
        # and either one's notify_user_safe call would otherwise keep this
        # green while the reactivation notice is gone.
        low = function_body(src, "unsuspend_provider").lower()
        for clause, why in (
            ("admin_can('registrations')", "its permission check"),
            ("staff_is_action_manager()", "its action-manager check"),
            ("staff_scope_allows_category(", "its category scope"),
            ("staff_scope_allows_city(", "its city scope"),
        ):
            if clause.lower() not in low:
                problems.append(
                    "%s: unsuspend_provider() has lost %s -- this restatement "
                    "re-emits the body, and 0026 lost a whole notification "
                    "this way once already" % (target.name, why))
        if "notify_user_safe" not in low:
            problems.append(
                "%s: unsuspend_provider() reactivates an account without "
                "telling the person, which is the notice 0022c sent and 0026 "
                "dropped" % target.name)

    # 5. The report, so the claim is countable in CI rather than readable.
    if not re.search(r"FUNCTION\s+public\.registration_notification_wiring_report",
                     sql, re.IGNORECASE):
        problems.append(
            "%s has no wiring report, so the coverage cannot be counted by "
            "the connectivity suite" % mig.name)

    return problems


APPEAL_MIGRATION = "20260927000131_an_appeal_reaches_the_people_who_act_on_it.sql"


def check_appeal_notifications_reach_reviewers() -> list[str]:
    """A filed appeal must reach the people who can ACT on it.

    Three separate failures hid behind one report -- "it is not showing at the
    admin front dashboard and in notifications bars, but I get it when I go to
    document verification" -- and two of them are in Dart, so this check reads
    both sides:

      1. the dashboard's count helper read `.count` off whatever a metric
         returned. Ten of eleven metrics are table queries that carry it; the
         document metric is an RPC returning a plain int, which does not, and
         the `catch` turned the mismatch into 0 forever.
      2. the bell badge summed four queues out of the six the dashboard counts,
         so an open appeal or dispute was carded and invisible at the top.
      3. `fn_notify_appeal_case_filed` told only the person the case was filed
         AGAINST. Nobody who can open the queue was told anything.
    """
    problems: list[str] = []

    dash = _read(LIB / "features" / "admin" / "admin_dashboard.dart")

    # 1. The count helper. It must accept BOTH shapes explicitly; a bare
    #    `.count` on `res` is the defect, and so is relying on the `catch` to
    #    turn a shape mismatch into a zero.
    helper = re.search(
        r"Future<int> count\(Future<dynamic> Function\(\) query\) async \{(.*?)\n    \}",
        dash, re.DOTALL)
    if helper is None:
        problems.append("admin_dashboard.dart: the count() helper is gone, so "
                        "every dashboard metric is unverified")
    else:
        body = helper.group(1)
        if "res is int" not in body:
            problems.append(
                "admin_dashboard.dart: count() does not accept a plain int, so "
                "admin_pending_document_count() -- which RETURNS integer -- hits "
                "`int.count`, raises NoSuchMethodError, and is swallowed to 0 "
                "by the catch. The Document Verification card then reads 'No "
                "documents waiting' forever while the screen behind it shows a "
                "full queue.")
        if re.search(r"return\s+\(res as dynamic\)\.count", body):
            problems.append(
                "admin_dashboard.dart: count() reads .count off the result "
                "without checking its shape first, which is the original "
                "defect.")

    # 2. The badge. It must include every queue the dashboard counts, so a
    #    queue cannot be carded below and absent from the number above.
    badge = re.search(r"final pendingTotal = (.*?);", dash, re.DOTALL)
    if badge is None:
        problems.append("admin_dashboard.dart: there is no pendingTotal, so the "
                        "badge is still being summed inline and can omit a queue")
    else:
        for field, why in (
            ("_pendingDocuments", "documents waiting for a verdict"),
            ("_openAppeals", "appeals waiting to be worked"),
            ("_openDisputes", "orders a customer has disputed"),
        ):
            if field not in badge.group(1):
                problems.append(
                    "admin_dashboard.dart: the pending badge omits %s (%s), so "
                    "it can read 0 while the card below it reads a non-zero "
                    "count" % (field, why))

    # 3. The trigger function.
    mig = MIGRATIONS / APPEAL_MIGRATION
    if not mig.is_file():
        problems.append(
            "%s is missing -- filing an appeal notifies only the person it is "
            "filed AGAINST, so nobody who can open the queue is told one "
            "arrived" % APPEAL_MIGRATION)
        return problems
    sql = _strip_comments(_read(mig))

    if not re.search(r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\."
                     r"fn_notify_appeal_case_filed", sql, re.IGNORECASE):
        problems.append(
            "%s does not restate fn_notify_appeal_case_filed, so the function "
            "that only told the respondent is still the live one" % mig.name)

    target, whole = last_migration_defining("fn_notify_appeal_case_filed")
    if target is None:
        problems.append("fn_notify_appeal_case_filed is undefined")
    else:
        # `last_migration_defining` returns the WHOLE FILE, not the body, and
        # this file's header explains at length that it notifies
        # `NEW.respondent_id` and that both sends go through notify_user_safe.
        # Testing that text directly is the "a comment says X so the check for
        # X passes" trap: the migration passes while the function does
        # nothing. So the body is extracted AND stripped of comments first.
        body = _strip_comments(function_body(whole, "fn_notify_appeal_case_filed"))
        if not body:
            problems.append(
                "%s: fn_notify_appeal_case_filed() has no body this check can "
                "read" % target.name)
        else:
            if "appeal_review_recipients" not in body:
                problems.append(
                    "%s: fn_notify_appeal_case_filed() never calls "
                    "appeal_review_recipients(), so no reviewer is told an "
                    "appeal arrived" % target.name)
            if not re.search(r"FOR\s+v_recipient\s+IN\b", body, re.IGNORECASE):
                problems.append(
                    "%s: fn_notify_appeal_case_filed() does not iterate the "
                    "recipient set" % target.name)
            # The respondent notice must survive the restatement. Losing it
            # would be a silent regression of a working feature, which is the
            # exact failure 0026 had with unsuspend_provider.
            if "respondent_id" not in body:
                problems.append(
                    "%s: fn_notify_appeal_case_filed() has stopped notifying "
                    "NEW.respondent_id -- the person named in the case is no "
                    "longer told, which is a regression of working behaviour"
                    % target.name)
            # A client write that raises would roll back the user's own appeal.
            if "notify_user_safe" not in body:
                problems.append(
                    "%s: fn_notify_appeal_case_filed() calls notify_user "
                    "directly. Filing an appeal is a client write, so a failure "
                    "inside this trigger raises and ROLLS BACK the user's "
                    "appeal." % target.name)

    # The case type. Declared but never writable is the shape this repo keeps
    # catching -- `registrations` once granted access to nothing at all.
    #
    # The value is asserted INSIDE the constraint, not merely anywhere in the
    # file: the trigger function also mentions DOCUMENT_VERIFICATION when it
    # words the notice, so a bare "does the string appear" test passes on a
    # migration whose CHECK still refuses the value at runtime.
    chk = re.search(
        r"ADD\s+CONSTRAINT\s+appeal_cases_case_type_known\s*\n?\s*"
        r"CHECK\s*\([^;]*?\)\s*;", sql, re.IGNORECASE | re.DOTALL)
    if chk is None:
        problems.append(
            "%s does not re-add appeal_cases_case_type_known, so the old "
            "two-value CHECK is still in force and DOCUMENT_VERIFICATION is "
            "refused at runtime" % mig.name)
    elif "DOCUMENT_VERIFICATION" not in chk.group(0):
        problems.append(
            "%s: the re-added appeal_cases_case_type_known CHECK does not admit "
            "DOCUMENT_VERIFICATION, so a document appeal is refused by the "
            "constraint at runtime" % mig.name)

    # And the Dart that has to be able to produce it.
    form = _read(LIB / "features" / "appeal" / "appeal_screen.dart")
    if "'case_type'" not in form:
        problems.append(
            "appeal_screen.dart does not send case_type, so the new value can "
            "never be produced by the form and the column is dead")
    if not re.search(r"_about\s*=\s*", form):
        problems.append(
            "appeal_screen.dart has no _about state, so the issue type the "
            "case_type is derived from is gone")

    # The queue filter. Checked IN THE FILTER LIST, not anywhere in the file:
    # the label map also names the value, so a bare search passes on a screen
    # that cannot actually filter by it.
    queue = _read(LIB / "features" / "admin" / "admin_appeals_screen.dart")
    types = re.search(r"_types\s*=\s*\[(.*?)\];", queue, re.DOTALL)
    if types is None:
        problems.append(
            "admin_appeals_screen.dart has no _types filter list, so a "
            "reviewer cannot filter the appeal queue at all")
    elif "DOCUMENT_VERIFICATION" not in types.group(1):
        problems.append(
            "admin_appeals_screen.dart does not offer DOCUMENT_VERIFICATION in "
            "the filter list, so a reviewer can file the work and still never "
            "see it")

    return problems


STORAGE_MIGRATION = "20260927000132_the_uploaded_files_go_too.sql"

# Every (bucket, table, column) the account file sweep is expected to cover.
# The first element is a BUCKET LITERAL and the second a `table.column` the
# collector must read, which is why the body is searched for both: a list
# that only proved the bucket was named would pass with every source dropped.
_ACCOUNT_FILE_SOURCES = [
    ("user-documents", "user_documents.storage_path"),
    ("user-documents", "appeal_cases.photo_path"),
    ("user-documents", "appeal_cases.response_photo_path"),
    ("profile-avatars", "profiles.avatar_storage_path"),
    ("provider-photos", "provider_profiles.photo_storage_path"),
    ("product-images", "product_images.storage_path"),
    ("product-images", "listing_images.storage_path"),
    ("provider-gallery", "provider_gallery.storage_path"),
    ("vehicle-images", "vehicle_images.storage_path"),
    ("provider-gallery", "provider_stores.logo_storage_path"),
    ("provider-gallery", "provider_stores.cover_image_storage_path"),
    ("payment-screenshots", "wallet_recharge_requests.screenshot_storage_path"),
]

# The three ways an account is closed. A trigger on auth.users would be the
# only thing that cannot be forgotten and it cannot be created here, so the
# sweep is an explicit call and every path that skips it leaks a file.
_ACCOUNT_DELETE_PATHS = [
    ("ceo_delete_user_account", "supabase/migrations/"
     + STORAGE_MIGRATION),
    ("account-deletion-gateway", "supabase/functions/account-deletion-gateway/index.ts"),
    ("user-admin", "supabase/functions/user-admin/index.ts"),
]


def check_account_deletion_removes_the_files() -> list[str]:
    """Closing an account must remove the FILES, not only the rows naming them.

    `DELETE FROM auth.users` takes thirty-six tables with it and stops there.
    Every one of those tables is a POINTER to a bucket object, so before
    20260927000132 an approved account deletion left the identity scans, the
    appeal evidence photos, the avatar, the listing photos, the gallery, the
    vehicle photos and the recharge screenshot in storage with nothing left to
    find them by -- unreachable, so no screen ever showed the leak, and still
    there, so the quota and the published privacy page were both wrong.

    Three things have to hold, and each was a way this could be green while
    broken:

      1. the collector must read every SOURCE, not merely name every bucket.
         A bucket with no query behind it sweeps nothing, and the file stays.
      2. the retained rows must stay swept-out. `payment_proofs` belongs to a
         transaction record that 0118 keeps for accounting, so its proof image
         is deliberately NOT deleted; a sweep that took it would break a live
         record to satisfy a tidier story.
      3. all three delete paths must call it. The CEO screen goes through the
         SQL wrapper, the deletion-request screen through one gateway, and
         Staff Assignment through another -- the last of which bypasses
         `delete_user_account()` entirely and calls the auth admin API, so it
         needs its own call or the files of every account closed that way
         survive.
    """
    problems: list[str] = []
    path, sql = last_migration_defining("account_storage_objects")
    if path is None or sql is None:
        return ["account_storage_objects() is missing: nothing collects the "
                "files an account owns, so every uploaded photo, document and "
                "appeal evidence photo survives the deletion"]

    collector = function_body(sql, "account_storage_objects")
    if not collector:
        return ["account_storage_objects() has no readable body, so the list "
                "of what it sweeps cannot be checked"]
    flat = re.sub(r"\s+", " ", collector)

    for bucket, source in _ACCOUNT_FILE_SOURCES:
        table, column = source.split(".")
        if "'%s'" % bucket not in flat:
            problems.append(
                "account_storage_objects() no longer names the %s bucket, so "
                "the files in it are never removed with the account" % bucket)
        if ("public.%s" % table) not in flat or column not in flat:
            problems.append(
                "account_storage_objects() no longer reads %s, so the %s "
                "objects it used to sweep are not collected"
                % (source, bucket))

    if "public.payment_proofs" in flat:
        problems.append(
            "account_storage_objects() now sweeps payment_proofs, whose rows "
            "are RETAINED for accounting by 20260927000118 -- that would "
            "leave a live transaction record pointing at a deleted proof "
            "image. The recharge screenshot is covered, conditionally, and the "
            "order proof must not be.")

    # The conditional half. A provider's recharges hang off the wallet and
    # cascade; a customer's do not and are kept. Reading the bucket without
    # the condition would delete the proof of a transaction that survived.
    recharge = flat[flat.find("wallet_recharge_requests"):] \
        if "wallet_recharge_requests" in flat else ""
    if recharge and "provider_id IN" not in recharge:
        problems.append(
            "the wallet_recharge_requests branch of account_storage_objects() "
            "is no longer conditioned on the provider/wallet, so a CUSTOMER's "
            "recharge proof would be deleted while the recharge row itself is "
            "retained for accounting")

    # The removal itself, and the privilege that guards it.
    _, purge_sql = last_migration_defining("purge_account_storage")
    purge = function_body(purge_sql or "", "purge_account_storage")
    if not purge:
        problems.append("purge_account_storage() is missing or unreadable: "
                        "the files are collected and then nothing acts on them")
    else:
        if "DELETE FROM storage.objects" not in purge:
            problems.append(
                "purge_account_storage() no longer deletes from "
                "storage.objects, so it counts objects without removing any")
        if "account_storage_objects" not in purge:
            problems.append(
                "purge_account_storage() no longer calls "
                "account_storage_objects(), so it has nothing to act on")

    all_sql = "\n".join(_read(p) for p in migration_files())
    if not re.search(
            r"REVOKE\s+ALL\s+ON\s+FUNCTION\s+public\.purge_account_storage\(uuid\)"
            r"\s*FROM\s+PUBLIC,\s*anon,\s*authenticated", all_sql, re.IGNORECASE):
        problems.append(
            "purge_account_storage(uuid) is not revoked from PUBLIC, anon and "
            "authenticated. It deletes files, and any client role able to call "
            "it could delete another account's identity documents")
    if not re.search(
            r"GRANT\s+EXECUTE\s+ON\s+FUNCTION\s+public\.purge_account_storage"
            r"\(uuid\)\s*TO\s+service_role", all_sql, re.IGNORECASE):
        problems.append(
            "purge_account_storage(uuid) is not granted to service_role, so "
            "the gateways that close accounts would silently skip the sweep")

    for name, where in _ACCOUNT_DELETE_PATHS:
        if where.endswith(".ts"):
            src = _read(ROOT / where)
            # The CALL, not the word. Both gateways log
            # `console.error("purge_account_storage failed:", ...)`, so a bare
            # substring survives deleting the invocation and the check goes
            # green on a gateway that leaks every file -- which is the defect
            # it exists to catch.
            called = re.search(
                r"rpc\(\s*[\"']purge_account_storage[\"']"
                r"|purge_account_storage\s*\(", src) is not None
        else:
            called = "purge_account_storage(" in function_body(sql, name)
        if not called:
            problems.append(
                "%s closes an account without calling purge_account_storage, "
                "so the uploaded files of every account deleted that way "
                "survive" % name)

    page = _read(ROOT / "docs" / "delete-account.html").lower()
    # Prose, not the function name: this is the page a user and a Play
    # reviewer read, and naming a SQL function on it would be noise. The
    # words that carry the promise are the ones about FILE STORAGE, because
    # without them the page already claims the documents are deleted.
    if "file storage" not in page:
        problems.append(
            "docs/delete-account.html says nothing about file storage, so "
            "the page tells a user their uploaded documents are removed when "
            "only the row that named them was")

    return problems


def check_admin_image_delete_is_complete() -> list[str]:
    """The admin image delete must remove the FILE, not just the row.

    Reproduced root cause, in two layers:

      * admin_moderate_image() deleted storage.objects with
        `bucket_id = p_bucket`, and the client's `_bucketFor()` guessed that
        bucket from path SUBSTRINGS (`/product` → product-images) that real
        upload paths — `uid/<productId>/<file>` — never contain, so the
        storage delete matched zero rows while the DB row went;
      * and even the corrected `bucket_id = ANY` statement can never run:
        Supabase's guard on storage.objects refuses a direct DELETE for EVERY
        role, a SECURITY DEFINER function included, with
        "Direct deletion from storage tables is not allowed. Use the Storage
        API instead." So the takedown abort it aborts the whole transaction.

    The FILE is therefore removed through the Storage API by the
    `admin-image-delete` Edge Function, which alone holds the service-role key
    needed to delete an object in an owner-scoped bucket. This check pins the
    split: no direct storage.objects delete in the RPC, a real Edge Function
    that verifies the admin and calls both the Storage API and
    admin_moderate_image, friendly_error showing the server's real refusal,
    and the guessing helper gone.
    """
    problems: list[str] = []

    target, _ = last_migration_defining("admin_moderate_image")
    if target is None:
        problems.append("no migration defines admin_moderate_image()")
    else:
        body = function_body(_read(target), "admin_moderate_image")
        # The direct storage write has to be GONE, not merely widened.
        # Supabase's guard refuses it for every role (it is a statement-level
        # trigger, not a privilege check), so a statement here can only abort
        # the whole takedown — and, where forced through, it removes the
        # metadata row and leaves the file orphaned in the bucket.
        if re.search(r"DELETE\s+FROM\s+storage\.objects", body, re.IGNORECASE):
            problems.append(
                "%s: admin_moderate_image() deletes storage.objects "
                "directly. Supabase refuses that for every role, so handing "
                "the file to SQL aborts the takedown (the file is never "
                "removed) — the object must be removed through the Storage "
                "API by the admin-image-delete Edge Function" % target.name)

    # The file half: a real Edge Function, admin-gated, using the service role
    # to call the Storage API and admin_moderate_image for the row + audit.
    edge = (ROOT / "supabase" / "functions" / "admin-image-delete"
            / "index.ts")
    if not edge.is_file():
        problems.append(
            "supabase/functions/admin-image-delete/index.ts is missing — the "
            "FILE half of the admin image delete has no implementation, so a "
            "deleted image lives in the bucket forever")
    else:
        ecode = edge.read_text(encoding="utf-8", errors="replace")
        for needle, why in (
            ("is_admin",
             "it never verifies the caller is an administrator"),
            ("SERVICE_ROLE_KEY",
             "it has no service-role client, so it cannot remove another "
             "account's object from an owner-scoped bucket"),
            (".remove(",
             "it never removes the object through the Storage API"),
            ("admin_moderate_image",
             "it never deletes the row and the audit record, so a takedown "
             "would leave the image referenced after the file is gone"),
        ):
            if needle not in ecode:
                problems.append("admin-image-delete/index.ts: %s" % why)

    # Every client call site must reach that function, not the RPC — the RPC
    # cannot remove the file.
    for rel in ("features/admin/widgets/image_delete_sheet.dart",
                "features/admin/widgets/public_image_gallery.dart",
                "features/admin/admin_content_control_screen.dart"):
        dart = _dart_without_comments(_read(LIB / rel))
        if "AdminImageDeleteService" not in dart and \
                "'admin-image-delete'" not in dart:
            problems.append(
                "%s never reaches the admin-image-delete Edge Function, so "
                "its delete leaves the file in the bucket" % rel)

    err = _read(LIB / "core" / "utils" / "friendly_error.dart")
    code = _dart_without_comments(err) if err else ""
    for needle, why in (
        ("image_moderation_failed",
         "the server's own takedown failure reason is hidden behind the "
         "generic fallback, so the admin cannot act on it"),
        ("no_row_references_that_image",
         "the already-gone refusal reaches the admin as a raw code"),
        ("that_bucket_is_not_moderable",
         "the bucket refusal reaches the admin as a raw code"),
    ):
        if not re.search(r"_any\(\s*lower\s*,\s*\[[^\]]*%s"
                         % re.escape(needle), code, re.DOTALL):
            problems.append(
                "friendly_error.dart has no matcher-list entry for %s — %s"
                % (needle, why))

    ctrl = _read(LIB / "features" / "admin" / "admin_content_control_screen.dart")
    if ctrl and re.search(r"'p_bucket':\s*_bucketFor\(", ctrl):
        problems.append(
            "admin_content_control_screen.dart guesses the delete bucket "
            "with _bucketFor() again — that helper is what stranded "
            "product/vehicle files in storage")

    # ── item 2's second half: Hide is reversible for EVERY image, and the
    # admin sees the real refusal code ──
    hide_target, hide_src = last_migration_defining(
        "admin_set_gallery_image_public")
    if hide_target is None:
        problems.append("no migration defines admin_set_gallery_image_public")
    else:
        hide_body = function_body(hide_src, "admin_set_gallery_image_public")
        for needle, why in (
            ("product_images",
             "Hide does not resolve product-image ids — the product-photo "
             "tap dies with NO_SUCH_IMAGE"),
            ("vehicle_images",
             "Hide does not resolve vehicle-image ids — that action is "
             "dead too"),
            ("moderation_actions",
             "a hide or restore writes no audit row"),
            ("is_active",
             "hiding a product image no longer flips products.is_active, "
             "so nothing disappears"),
        ):
            if needle not in hide_body:
                problems.append("%s: admin_set_gallery_image_public %s"
                                % (hide_target.name, why))
        if "SUSPENDED" not in hide_body:
            problems.append(
                "%s: vehicle images are not hidden by moving the vehicle "
                "out of APPROVED — the public read policy still shows it"
                % hide_target.name)

    gallery_target, gallery_src = last_migration_defining(
        "admin_public_image_gallery")
    if gallery_target is not None:
        gallery_body = function_body(gallery_src, "admin_public_image_gallery")
        if "p.is_active" not in gallery_body:
            problems.append(
                "%s: the gallery chip ignores products.is_active, so a "
                "listing the admin just hid still reads Public"
                % gallery_target.name)

    gallery_dart = _dart_without_comments(
        _read(LIB / "features" / "admin" / "widgets" /
              "public_image_gallery.dart"))
    if "else if (image['source'] == 'provider_gallery')" in gallery_dart:
        problems.append(
            "public_image_gallery.dart: Put-back-in-public is gated to "
            "provider_gallery again, so a hidden product photo can never "
            "be restored")
    if "friendlyErrorWithCode" not in gallery_dart:
        problems.append(
            "public_image_gallery.dart hides the server's real refusal code "
            "from the moderator (item 2: show the real error code)")
    ctrl_dart = _dart_without_comments(ctrl)
    if "friendlyErrorWithCode" not in ctrl_dart:
        problems.append(
            "admin_content_control_screen.dart hides the server's real "
            "refusal code from the moderator")

    ferr = _dart_without_comments(_read(LIB / "core" / "utils" /
                                        "friendly_error.dart"))
    for fn, why in (("errorCodeOf", "no way to extract the real code"),
                    ("friendlyErrorWithCode",
                     "no admin-facing sentence that carries the code")):
        if "String" + ("?" if fn == "errorCodeOf" else "") + " " + fn \
                not in ferr:
            problems.append("friendly_error.dart: %s (%s)" % (fn, why))

    if "assert_image_hide_is_reversible" not in _read(
            ROOT / "tools" / "integration_test" / "connectivity_test.dart"):
        problems.append(
            "connectivity_test.dart does not run "
            "assert_image_hide_is_reversible()")

    return problems


def check_admin_taps_have_handlers() -> list[str]:
    """Every tappable surface in the admin area must have a real handler.

    The four horizontal quick-stat tiles at the top of the admin dashboard
    LOOKED like buttons — cards with icons, in a Row, at the very top — and
    had no InkWell, no onTap and no route: four dead buttons, reported twice.
    Two shapes are caught here:

      * the exact defect, pinned: the dashboard's quick-stat helper must
        wrap its tile in an InkWell driven by an onTap parameter, and each
        of the four tiles must push a registered route (including the new
        /admin/orders screen that gave the Orders tile somewhere to go);
      * the same defect in miniature, mechanically, across every admin
        feature: a literal `onTap: null` / `onPressed: null` (outside a
        ternary disabled state, which is legitimate) or an empty closure
        `() {}` / `() => {}`.
    """
    problems: list[str] = []

    dash = LIB / "features" / "admin" / "admin_dashboard.dart"
    dcode = _dart_without_comments(_read(dash)) if dash.is_file() else ""
    if not dcode:
        problems.append("admin_dashboard.dart is missing")
    else:
        stat = re.search(r"Widget _quickStat\(.*?\n  \}", dcode, re.DOTALL)
        if stat is None:
            problems.append(
                "_quickStat is missing from admin_dashboard.dart, so the "
                "quick-stat tiles have no definition to check")
        else:
            body = stat.group(0)
            if "InkWell" not in body or "onTap" not in body:
                problems.append(
                    "admin_dashboard.dart: _quickStat no longer wraps its "
                    "tile in an InkWell driven by onTap, so the four "
                    "quick-stat tiles are dead buttons again — a card that "
                    "looks tappable and is not is the exact defect this "
                    "check exists to prevent")
        for route in ("/admin/approvals", "/admin/users",
                      "/admin/providers", "/admin/orders"):
            if "'%s'" % route not in dcode:
                problems.append(
                    "admin_dashboard.dart no longer pushes %s from a "
                    "quick-stat tile, so one of the four tiles has nowhere "
                    "to go" % route)

    admin_dir = LIB / "features" / "admin"
    for path in sorted(admin_dir.rglob("*.dart")):
        code = _dart_without_comments(_read(path))
        rel = str(path.relative_to(ROOT))
        for line in code.splitlines():
            stripped = line.strip()
            for prop in ("onTap", "onPressed"):
                m = re.search(
                    r"%s:\s*(null|\(\)\s*\{\s*\}|\(\)\s*=>\s*\{\s*\})"
                    % prop, stripped)
                if not m:
                    continue
                if m.group(1) == "null" and "?" in stripped[: m.start(1)]:
                    # A conditional disable (`busy ? null : handler`) is a
                    # real disabled state, not a dead tap.
                    continue
                problems.append(
                    "%s: %s has no handler (%s) — a tappable-looking "
                    "surface that does nothing is the dead-admin-tile "
                    "defect" % (rel, prop, stripped[:90]))
    return problems


def _split_top_level(text: str) -> list[str]:
    """Split a CREATE TABLE column list on its top-level commas only.

    Types carry commas of their own — numeric(12,2), geography(Point,4326)
    — so a plain split() would invent columns that do not exist.
    """
    parts: list[str] = []
    depth = 0
    cur: list[str] = []
    for ch in text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if cur:
        parts.append("".join(cur))
    return parts


def _ride_requests_schema() -> tuple[set[str], set[str]]:
    """(all columns, NOT-NULL-without-default columns) of ride_requests,
    as the migration chain builds the table.

    The chain is the only schema the deploy runs, so a column that appears
    in no CREATE TABLE and no ADD COLUMN does not exist on the live database
    — no matter what a function body believes.
    """
    cols: set[str] = set()
    required: set[str] = set()
    create_rx = re.compile(
        r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?"
        r"(?:public\.)?ride_requests\s*\((.*?)\)\s*;",
        re.IGNORECASE | re.DOTALL)
    # One ALTER can carry several ADD COLUMN clauses on separate lines, so
    # the statement (up to its first ';') is scanned — a per-clause pattern
    # anchored on the table name would capture only the first one.
    alter_rx = re.compile(
        r"ALTER\s+TABLE\s+(?:ONLY\s+)?(?:public\.)?ride_requests\b",
        re.IGNORECASE)
    add_col_rx = re.compile(
        r"ADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)",
        re.IGNORECASE)
    for path in migration_files():
        src = _strip_comments(_read(path))
        for m in create_rx.finditer(src):
            for seg in _split_top_level(m.group(1)):
                tok = seg.strip()
                if not tok:
                    continue
                head = tok.split()[0].lower()
                if head in {"constraint", "primary", "unique", "foreign",
                            "check", "like"}:
                    continue
                name = head
                cols.add(name)
                if re.search(r"\bNOT\s+NULL\b", tok, re.IGNORECASE) and not re.search(
                        r"\bDEFAULT\b", tok, re.IGNORECASE):
                    required.add(name)
        for m in alter_rx.finditer(src):
            semi = src.find(";", m.end())
            stmt = src[m.end(): semi if semi != -1 else len(src)]
            for am in add_col_rx.finditer(stmt):
                cols.add(am.group(1).lower())
    return cols, required


def check_ride_request_insert_matches_the_ride_requests_table() -> list[str]:
    """create_ride_request() may only write columns ride_requests has.

    Reproduced root cause of "GPS rides are not being claimed" (reported
    twice): the last two restatements of create_ride_request (0107, 0114)
    INSERT INTO ride_requests (user_id, pickup_lat, pickup_lng,
    destination_lat, destination_lng, ..., requested_at) — but no migration
    in the chain ever creates those five columns (the table has
    pickup_location/destination_location geography instead), and PL/pgSQL
    does not check column names at CREATE OR REPLACE time. Every call fails
    at runtime with SQLSTATE 42703 `column "pickup_lat" of relation
    "ride_requests" does not exist`, friendly_error maps "of relation" +
    "does not exist" to its "problem on our side" sentence, no row is ever
    written, and there is therefore nothing for a driver to claim.

    The same INSERT also has to fill the table's NOT NULL columns that carry
    no default (user_id, pickup_location, destination_location) or it trades
    the 42703 for a 23502, and it has to stamp requested_at — the 3-minute
    unclaimed timeout counts from it.
    """
    problems: list[str] = []

    cols, required = _ride_requests_schema()
    if not cols:
        return ["ride_requests has no CREATE TABLE in any migration, so the "
                "schema side of this check is reading nothing"]

    target, src = last_migration_defining("create_ride_request")
    if target is None:
        return ["no migration defines public.create_ride_request()"]
    body = function_body(src, "create_ride_request")
    m = re.search(
        r"INSERT\s+INTO\s+(?:public\.)?ride_requests\s*\((.*?)\)\s*VALUES",
        body, re.IGNORECASE | re.DOTALL)
    if not m:
        return ["%s: the last create_ride_request() has no "
                "INSERT INTO ride_requests ( ... ) VALUES at all, so a "
                "request can never reach the database" % target.name]
    inserted = {c.strip().lower().removeprefix("public.")
                for c in m.group(1).split(",") if c.strip()}

    for col in sorted(inserted - cols):
        problems.append(
            "%s: create_ride_request() INSERTs ride_requests.%s, which no "
            "migration ever adds to the table — every call fails at runtime "
            "with 42703 'column ... of relation \"ride_requests\" does not "
            "exist' and the rider sees 'problem on our side'; no row exists, "
            "so no driver can ever claim" % (target.name, col))

    for col in sorted(required - inserted):
        problems.append(
            "%s: create_ride_request() does not fill ride_requests.%s, "
            "which is NOT NULL with no default — the insert trades its "
            "column error for 23502 not-null violation" % (target.name, col))

    if "requested_at" not in inserted:
        problems.append(
            "%s: create_ride_request() does not stamp requested_at, so the "
            "3-minute unclaimed timeout has nothing to count from and stale "
            "requests can never be identified" % target.name)

    return problems


def check_unclaimed_rides_expire_and_one_driver_wins() -> list[str]:
    """An unclaimed ride dies in 3 minutes, and only one driver can win.

    The other half of the rides report: even with rows reaching the table,
    a REQUESTED ride used to sit there forever (no expiry anywhere) and the
    claim had to prove its race handling stays put. Pins:

      * claim_ride() must take the ride with a conditional
        `WHERE id = ... AND status = 'REQUESTED'` UPDATE that raises
        RIDE_ALREADY_TAKEN when it matches nothing — the atomic compare-and-
        swap that makes exactly one of two concurrent drivers the winner;
      * claim_ride() must refuse a request older than 3 minutes
        (RIDE_REQUEST_EXPIRED), so a cron lag cannot award dead work;
      * expire_stale_ride_requests() must exist and be scheduled on pg_cron,
        so a request is never stuck forever even if nobody opens the app;
      * both screens must act on the same 3-minute window (the rider is
        shown "No driver found" with retry, the driver's list drops stale
        rows), and Connectivity CI must run the live assertions.
    """
    problems: list[str] = []

    claim_src_fn = last_migration_defining("claim_ride")
    claim_target, claim_src = claim_src_fn
    if claim_target is None:
        problems.append("no migration defines public.claim_ride()")
    else:
        cbody = function_body(claim_src, "claim_ride")
        if not re.search(
                r"WHERE\s+id\s*=\s*p_ride_id\s+AND\s+status\s*=\s*'REQUESTED'",
                cbody, re.IGNORECASE | re.DOTALL):
            problems.append(
                "%s: claim_ride() no longer takes the ride with a "
                "conditional UPDATE ... WHERE status = 'REQUESTED' — "
                "without the compare-and-swap two drivers accepting at "
                "once can both win" % claim_target.name)
        if "RIDE_ALREADY_TAKEN" not in cbody:
            problems.append(
                "%s: claim_ride() no longer raises RIDE_ALREADY_TAKEN for "
                "the driver who lost the race, so the loser is told "
                "nothing useful" % claim_target.name)
        if "RIDE_REQUEST_EXPIRED" not in cbody or not re.search(
                r"3\s*minutes", cbody, re.IGNORECASE):
            problems.append(
                "%s: claim_ride() will still award a request older than "
                "3 minutes (no RIDE_REQUEST_EXPIRED guard against the "
                "interval), so a driver can claim work the timeout already "
                "gave up on" % claim_target.name)

    exp_target, exp_src = last_migration_defining("expire_stale_ride_requests")
    if exp_target is None:
        problems.append(
            "no migration defines public.expire_stale_ride_requests() — "
            "with nothing expiring them, unclaimed requests are stuck in "
            "REQUESTED forever")
    else:
        ebody = function_body(exp_src, "expire_stale_ride_requests")
        if not re.search(r"status\s*=\s*'REQUESTED'", ebody, re.IGNORECASE) \
                or "CANCELLED" not in ebody.upper():
            problems.append(
                "%s: expire_stale_ride_requests() no longer moves stale "
                "REQUESTED rides to CANCELLED" % exp_target.name)
        if not re.search(r"3\s*minutes", ebody, re.IGNORECASE):
            problems.append(
                "%s: expire_stale_ride_requests() does not use the "
                "3-minute window" % exp_target.name)

    if not any("5birr-ride-request-expiry" in _read(p)
               for p in migration_files()):
        problems.append(
            "no migration schedules the pg_cron job "
            "'5birr-ride-request-expiry', so nothing ever calls the expiry "
            "function and a request the app never reopens stays REQUESTED "
            "forever")

    active = _dart_without_comments(
        _read(LIB / "features" / "user" / "user_active_ride_screen.dart"))
    if "No driver found" not in active:
        problems.append(
            "user_active_ride_screen.dart never tells the rider 'No driver "
            "found' — a rider whose request times out gets no retry or "
            "widen-search option")
    if "Duration(minutes: 3)" not in active:
        problems.append(
            "user_active_ride_screen.dart does not use the 3-minute window, "
            "so the rider-side timeout disagrees with the server's")

    driver = _dart_without_comments(
        _read(LIB / "features" / "vehicle" / "driver_ride_requests_screen.dart"))
    if "Duration(minutes: 3)" not in driver:
        problems.append(
            "driver_ride_requests_screen.dart does not drop requests older "
            "than 3 minutes — a realtime filter that only sees INSERTs "
            "leaves expired work on the driver's screen to be claimed and "
            "refused")

    conn = _read(ROOT / "tools" / "integration_test" /
                 "connectivity_test.dart")
    for fn in ("assert_ride_request_write_matches_schema",
               "assert_ride_claim_race_has_one_winner",
               "assert_unclaimed_ride_expiry_is_wired"):
        if fn not in conn:
            problems.append(
                "connectivity_test.dart does not run %s(), so the live "
                "database is never asked whether the rides fix is "
                "deployed" % fn)

    return problems


def check_availability_gate_covers_every_checkout() -> list[str]:
    """No order without an ACCEPTED availability request — on any path.

    The report: buyers could reach payment without the provider ever being
    asked whether the item exists (twice). The gate has three halves and
    each one is load-bearing on its own:

      * client: every place that starts checkout — the shared Buy/Book
        button, the detail screen's buy-now, the cart's CHECKOUT, and the
        checkout screen itself as the backstop for deep links — must route
        through /user/availability, where the buyer taps "Is this product
        available?";
      * server: create_order_secure must require an ACCEPTED, unexpired,
        UNUSED availability_requests row for every product in p_items and
        claim it (used_at), raising AVAILABILITY_CONFIRMATION_REQUIRED —
        otherwise the client half is decoration;
      * lifecycle: create/respond/cancel RPCs, the PENDING-uniqueness index,
        the 15-minute expiry on pg_cron, the realtime publication entry, the
        two notification types, the provider dashboard's pending section,
        the admin's view of the queue, and the live assertion Connectivity
        CI runs.
    """
    problems: list[str] = []

    # -- client: every checkout entry crosses the gate ------------------
    for rel, needle in (
        (LIB / "core" / "widgets" / "product_buy_button.dart",
         "/user/availability"),
        (LIB / "features" / "user" / "user_product_detail_screen.dart",
         "/user/availability"),
        (LIB / "features" / "user" / "user_cart_screen.dart",
         "/user/availability"),
        (LIB / "features" / "user" / "user_checkout_screen.dart",
         "/user/availability"),
    ):
        code = _dart_without_comments(_read(rel))
        if needle not in code:
            problems.append(
                "%s no longer routes checkout through %s — a buyer can "
                "reach the payment step without the provider confirming "
                "availability" % (rel.name, needle))
    checkout = _dart_without_comments(
        _read(LIB / "features" / "user" / "user_checkout_screen.dart"))
    if "pushReplacement" not in checkout:
        problems.append(
            "user_checkout_screen.dart does not pushReplacement away — its "
            "gate would stack-loop instead of taking over the route")

    # -- server: the order path demands the request ---------------------
    target, src = last_migration_defining("create_order_secure")
    if target is None:
        problems.append("no migration defines public.create_order_secure()")
    else:
        body = function_body(src, "create_order_secure")
        for needle, why in (
            ("AVAILABILITY_CONFIRMATION_REQUIRED",
             "orders can be created with no availability request at all"),
            ("availability_requests",
             "the order path never reads the request table"),
            ("used_at",
             "an accepted request can be reused for a second order"),
            ("PROVIDER_NOT_ACCEPTING_ORDERS",
             "the unapproved-provider guard from 0013 was dropped, which "
             "assert_orders_block_unapproved_providers exists to catch"),
        ):
            if needle not in body:
                problems.append(
                    "%s: create_order_secure() %s" % (target.name, why))

    # -- lifecycle: the RPCs, the uniqueness, the expiry -----------------
    for fn, why in (
        ("create_availability_requests",
         "the buyer cannot ask — the button would have nothing to call"),
        ("respond_availability_request",
         "the provider cannot answer from the app"),
        ("cancel_availability_request",
         "the buyer cannot stand the request down"),
        ("expire_availability_requests",
         "PENDING requests never time out server-side"),
    ):
        if last_migration_defining(fn)[0] is None:
            problems.append("no migration defines public.%s() — %s" % (fn, why))

    r_target, r_src = last_migration_defining("respond_availability_request")
    if r_target is not None:
        rbody = function_body(r_src, "respond_availability_request")
        for needle, why in (
            ("REQUEST_EXPIRED",
             "a provider can answer after expiry"),
            ("REQUEST_ALREADY_ANSWERED",
             "a provider can answer twice"),
        ):
            if needle not in rbody:
                problems.append(
                    "%s: respond_availability_request() %s"
                    % (r_target.name, why))

    mig_texts = [(p, _read(p)) for p in migration_files()]
    if not any("uq_availability_one_active" in t for _, t in mig_texts):
        problems.append(
            "no migration creates the uq_availability_one_active partial "
            "index, so a buyer can stack duplicate PENDING requests for one "
            "product — the double-tap duplicate the report forbids")
    if not any("5birr-availability-expiry" in t for _, t in mig_texts):
        problems.append(
            "no migration schedules the pg_cron job 5birr-availability-"
            "expiry, so an unanswered request sits PENDING forever")
    if not any(re.search(r"ADD\s+VALUE\s+IF\s+NOT\s+EXISTS\s+'AVAILABILITY_REQUEST'",
                         t, re.IGNORECASE) for _, t in mig_texts):
        problems.append(
            "the notification_type enum never gains AVAILABILITY_REQUEST — "
            "the provider's notify insert raises invalid input value for "
            "enum and the request creation fails with it")
    if not any(re.search(r"ADD\s+VALUE\s+IF\s+NOT\s+EXISTS\s+'AVAILABILITY_RESPONSE'",
                         t, re.IGNORECASE) for _, t in mig_texts):
        problems.append(
            "the notification_type enum never gains AVAILABILITY_RESPONSE — "
            "the buyer is never told the answer")
    if not any(re.search(r"alter\s+publication\s+supabase_realtime\s+"
                         r"add\s+table\s+(?:public\.)?availability_requests",
                         t, re.IGNORECASE) for _, t in mig_texts):
        problems.append(
            "availability_requests is never added to the supabase_realtime "
            "publication, so neither the buyer's waiting screen nor the "
            "provider's popup ever receives a realtime event")
    # The name matters: 0074/0075 already define a TEXT-returning
    # assert_availability_gate_is_wired() for the per-listing
    # requires_availability_confirmation flow. This migration's
    # pre-order-every-purchase assertion must be a DIFFERENT name —
    # CREATE OR REPLACE cannot change a return type, so reusing the name
    # would abort the deploy with 42P13.
    if not any("assert_preorder_availability_gate_is_wired" in t
               for _, t in mig_texts):
        problems.append(
            "no migration defines assert_preorder_availability_gate_is_wired(), "
            "so the live database is never asked whether the gate survived a "
            "later deploy")

    # -- surfaces: provider answers, admin watches -----------------------
    dash = _dart_without_comments(
        _read(LIB / "features" / "provider" /
              "service_provider_dashboard.dart"))
    for needle, why in (
        ("availability_requests",
         "the dashboard never reads the pending queue"),
        ("respond_availability_request",
         "the dashboard cannot answer"),
        ("Pending",
         "a missed popup cannot still be answered from a section"),
    ):
        if needle not in dash:
            problems.append(
                "service_provider_dashboard.dart: %s" % why)

    if not (LIB / "features" / "admin" /
            "admin_availability_screen.dart").is_file():
        problems.append(
            "admin_availability_screen.dart is missing — the admin has no "
            "view of the requests, their status or their response time")
    router = _read(LIB / "routing" / "app_router.dart")
    if "'/admin/availability'" not in router:
        problems.append("app_router.dart has no /admin/availability route")
    dash_admin = _dart_without_comments(
        _read(LIB / "features" / "admin" / "admin_dashboard.dart"))
    if "'/admin/availability'" not in dash_admin:
        problems.append(
            "admin_dashboard.dart never links /admin/availability — the "
            "screen exists but is unreachable")

    # -- the live assertion ------------------------------------------------
    conn = _read(ROOT / "tools" / "integration_test" /
                 "connectivity_test.dart")
    if "assert_preorder_availability_gate_is_wired" not in conn:
        problems.append(
            "connectivity_test.dart does not run "
            "assert_preorder_availability_gate_is_wired()")

    err = _read(LIB / "core" / "utils" / "friendly_error.dart")
    code = _dart_without_comments(err) if err else ""
    if not re.search(r"_any\(\s*lower\s*,\s*\[[^\]]*availability_confirmation_required",
                     code, re.DOTALL):
        problems.append(
            "friendly_error.dart has no matcher for "
            "availability_confirmation_required — the refusal reaches the "
            "buyer as a raw code")

    return problems


def check_bank_accounts_are_enforced() -> list[str]:
    """Bank accounts only, phone numbers nowhere — enforced by the server.

    The report (item 5): providers could store Telebirr/CBE-Birr "accounts",
    any-length numbers, and phone numbers in every field a buyer reads.
    Each finding below is a piece that was missing before and that, if it
    ever goes missing again, silently reopens the hole:

      * normalize_digits + text_looks_like_phone must exist, with the exact
        09/07 and 2519/2517 shapes;
      * the banks table with the CBE 13-digit/1000 seed (the admin-editable
        source of the length/prefix rules);
      * validation on provider_payment_methods (bank required, length,
        prefix, phone rejection, mobile-money names, the 3-active cap, one
        default) and the scan triggers on the four buyer-readable text
        surfaces;
      * the cleanup UPDATE that makes the existing bad rows inactive;
      * the admin-side bank editor that owns the banks table (the length and
        prefix rules the trigger checks against), and the bounded reads that
        end the endless spinner.

    The PROVIDER's own account form is deliberately gone (Part 13): every
    buyer payment goes to the payment account the platform publishes, so a
    provider has no account of their own to enter, bank-pick, cap at three or
    mark as default. The provider-side assertions below are therefore inverted
    — they pin that the form does NOT come back — while every SERVER rule
    stays exactly as it was, because the table and its trigger remain.
    """
    problems: list[str] = []
    mig = ROOT / "supabase" / "migrations" / "20261006000007_bank_accounts_only.sql"
    if not mig.is_file():
        return ["20261006000007_bank_accounts_only.sql is missing — none of "
                "the item 5 rules exist in the pipeline"]
    sql = _read(mig)

    for needle, why in (
        ("text_looks_like_phone",
         "the phone detector does not exist, so phone-like numbers are "
         "accepted everywhere"),
        ("^0(9|7)[0-9]{8}$",
         "the 09/07 + 8-digit shape is not matched"),
        ("^251(9|7)[0-9]{8}$",
         "the 2519/2517 + 8-digit shape is not matched"),
        ("normalize_digits",
         "the shared normaliser is missing, so Ethiopic/Arabic-Indic "
         "digits bypass the scan"),
        ("CREATE TABLE IF NOT EXISTS public.banks",
         "the admin-editable banks table does not exist"),
        ("('Commercial Bank of Ethiopia', 13, 13, '1000')",
         "the CBE seed is not 13 digits starting 1000"),
        ("enforce_payment_account_rules",
         "the payment-account validation trigger is missing"),
        ("ACCOUNT_LIMIT_REACHED",
         "the 3-active-accounts cap is not enforced"),
        ("uq_payment_account_one_default",
         "one-default is not structural"),
        ("MOBILE_MONEY_NOT_ALLOWED",
         "mobile-money names are not refused"),
        ("reject_phone_like_text",
         "the buyer-readable text scan is missing"),
        ("trg_products_no_phone",
         "product titles/descriptions are not scanned"),
        ("trg_provider_profiles_no_phone",
         "business names are not scanned"),
        ("trg_provider_gallery_no_phone",
         "gallery captions are not scanned"),
        ("payment_account_",
         "payment-account changes are not written to audit_logs"),
        ("SET is_active = false",
         "existing phone-like/mobile-money rows are never deactivated"),
    ):
        if needle not in sql:
            problems.append("20261006000007: %s" % why)

    # -- client --
    screen = _dart_without_comments(
        _read(LIB / "features" / "provider" /
              "provider_payment_methods_screen.dart"))
    # The provider-side form must NOT come back. Both spellings of the free-text
    # name field are pinned, because that field is how Telebirr / CBE-Birr rows
    # got in and the account form itself is what Part 13 removed.
    for needle, why in (
        ("Name (shown to buyers)",
         "the free-text name field is back — that is how Telebirr/CBE-Birr "
         "rows got in"),
        ("_bankField",
         "the provider bank-account form is back on a screen whose account "
         "number nothing collects any more"),
        ("Maximum of 3 accounts reached",
         "the provider 3-account cap UI is back with the form it belonged to"),
        ("Make default",
         "a provider can set a default payment account again — the flow "
         "Part 13 removed"),
        ("Add bank account",
         "the provider is invited to add a bank account again"),
    ):
        if needle in screen:
            problems.append("payment_methods screen: %s" % why)
    if "PaymentMethodsService.kTimeout" not in screen:
        problems.append(
            "payment_methods screen: the reads are unbounded again — the "
            "endless spinner")

    # The banks table still needs its editor: the admin one, which owns the
    # length/prefix rules the trigger validates against.
    admin_accounts = _dart_without_comments(
        _read(LIB / "features" / "admin" /
              "admin_payment_accounts_screen.dart"))
    if "_banks" not in admin_accounts or "'banks'" not in admin_accounts:
        problems.append(
            "admin_payment_accounts_screen.dart: the admin-side bank editor no "
            "longer reads the banks table, so the length/prefix rules the "
            "trigger enforces have no editor")

    service = _dart_without_comments(
        _read(LIB / "core" / "services" / "payment_methods_service.dart"))
    if "kTimeout" not in service:
        problems.append(
            "payment_methods_service.dart has no timeout — a hung read "
            "becomes an endless spinner again")
    if "getBanks" not in service:
        problems.append("payment_methods_service.dart never reads the banks table")

    rules = LIB / "core" / "utils" / "bank_account_rules.dart"
    if not rules.is_file():
        problems.append("bank_account_rules.dart missing — the form has no "
                        "client mirror of the server rules")
    else:
        rc = _dart_without_comments(_read(rules))
        if "looksLikePhone" not in rc or "bankAccountError" not in rc:
            problems.append("bank_account_rules.dart lost looksLikePhone / "
                            "bankAccountError")

    err = _dart_without_comments(_read(LIB / "core" / "utils" /
                                       "friendly_error.dart"))
    for code in ("mobile_money_not_allowed",
                 "phone_like_number_not_allowed",
                 "account_limit_reached",
                 "bank_account_prefix_invalid"):
        if code not in err:
            problems.append("friendly_error.dart has no matcher for %s" % code)

    # -- admin surface --
    if not (LIB / "features" / "admin" /
            "admin_payment_accounts_screen.dart").is_file():
        problems.append("admin_payment_accounts_screen.dart is missing — "
                        "no admin can manage banks or disable an account")
    router = _read(LIB / "routing" / "app_router.dart")
    if "'/admin/payment-accounts'" not in router:
        problems.append("no /admin/payment-accounts route")
    dash = _dart_without_comments(_read(LIB / "features" / "admin" /
                                        "admin_dashboard.dart"))
    if "'/admin/payment-accounts'" not in dash:
        problems.append("admin_dashboard.dart never links /admin/payment-accounts")

    return problems


def check_posting_no_longer_requires_a_provider_account() -> list[str]:
    """The platform collects the payment, so the account rule is GONE.

    History, because the reversal is the whole point. 20261006000008 put the
    same rule in three places, on the premise that the buyer sent money to the
    seller's own bank account:

      * create_provider_product raised NO_PAYMENT_ACCOUNT before the insert;
      * products_public_read hid every listing of an account-less provider;
      * search_products carried the same predicate (SECURITY DEFINER, so the
        policy could not reach it).

    The payment model changed: every buyer payment goes to the payment account
    the platform publishes inside the app, and the provider is settled through
    their wallet. A provider therefore has no account number to publish, and
    Part 13 removed the app's flow for entering one — so the rule left behind
    would refuse EVERY posting and hide EVERY listing, a total outage of the
    marketplace rather than a missing feature.

    What must hold now:
      * server: none of the three carries the predicate any more, and the live
        assertion Connectivity CI calls has been restated to prove THAT (the
        name is kept because that is what the CI calls);
      * client: the checklist is two steps with no route to the accounts
        screen, and the readiness banner has no remedy pointing there;
      * the wallet is untouched: balance, history and the funding flow stay.
    """
    problems: list[str] = []
    mig = ROOT / "supabase" / "migrations" / \
        "20261015000010_the_platform_collects_so_no_provider_publishes_an_account.sql"
    if not mig.is_file():
        return [
            "20261015000010_the_platform_collects_so_no_provider_publishes_an_"
            "account.sql is missing — the account rule would still refuse "
            "every posting on a platform that no longer collects an account "
            "number"]
    sql = _read(mig)

    for needle, why in (
        ("DROP POLICY IF EXISTS products_public_read",
         "the buyer-facing products policy is not amended — direct reads "
         "still hide every listing whose provider has no account"),
        ("CREATE OR REPLACE FUNCTION public.search_products",
         "search_products is not restated, so search shows nothing from a "
         "provider without an account (SECURITY DEFINER, policy-blind)"),
        ("is not fully removed",
         "the live assertion is not restated to the new truth, so "
         "Connectivity CI would fail against a correctly migrated database"),
    ):
        if needle not in sql:
            problems.append(
                "20261015000010: %s" % why)

    # The predicate must be gone from the FUNCTION BODIES themselves, read
    # through the same helper the restatement gate uses — not from the file's
    # comments, which discuss the rule it removes.
    for fn, banned, why in (
        ("create_provider_product", "NO_PAYMENT_ACCOUNT",
         "still refuses without a payment account, so no provider could "
         "publish at all now that the app no longer collects one"),
        ("search_products", "provider_payment_methods",
         "still hides providers without a payment account, so every listing "
         "would vanish from search"),
    ):
        target, src = last_migration_defining(fn)
        if target is None:
            problems.append("%s: no migration defines it" % fn)
            continue
        body = function_body(src, fn)
        if banned in body:
            problems.append(
                "%s: %s() %s" % (target.name, fn, why))

    # The policy: its latest definition must not carry the predicate either.
    pol = re.search(
        r"CREATE\s+POLICY\s+products_public_read\s+ON\s+public\.products"
        r"[^;]*;", sql, re.IGNORECASE | re.DOTALL)
    if pol is None:
        problems.append(
            "20261015000010 does not re-create products_public_read, so the "
            "old policy still hides account-less providers' listings")
    elif "provider_payment_methods" in pol.group(0):
        problems.append(
            "20261015000010: the re-created products_public_read still "
            "requires a provider payment account")

    # The shared blockers fn must still stay out of it (ride claims).
    b_target, b_src = last_migration_defining("provider_fulfilment_blockers")
    if b_target is not None:
        body = function_body(b_src, "provider_fulfilment_blockers")
        if "NO_PAYMENT_ACCOUNT" in body:
            problems.append(
                "%s: provider_fulfilment_blockers now carries "
                "NO_PAYMENT_ACCOUNT — claim_ride calls this function, so "
                "drivers without a payout account could no longer claim "
                "rides and assert_ride_claim_race_has_one_winner would fail"
                % b_target.name)

    gate = _dart_without_comments(
        _read(LIB / "core" / "services" / "posting_gate.dart"))
    # The declared count is the checklist's arithmetic, and it must be TWO:
    # documents + the wallet minimum. Three is the pre-removal shape, and a
    # third step nobody can complete is exactly what this rule exists to catch —
    # `doneCount` adds only the document and wallet rows, so a count of 3 can
    # never read anything but "0 of 3", "1 of 3", "2 of 3", and the dialog no
    # longer renders an account row at all. The app's own
    # test/posting_gate_test.dart pins the same two numbers ("2 of 2 done"), so
    # a count of 3 fails that suite as well. The check went red on the correct
    # value once (the regression 8d02ec6 left behind); the assertion is the
    # count, not its direction.
    if "static const int totalSteps = 3" in gate:
        problems.append(
            "posting_gate.dart: the checklist still counts three steps — the "
            "payment-account row was removed from the dialog, so the progress "
            "line can only ever read '2 of 3 done'")
    elif "static const int totalSteps = 2" not in gate:
        problems.append(
            "posting_gate.dart: the checklist does not count its two steps "
            "(documents + wallet minimum)")
    # The checklist is two steps (documents + wallet minimum). The account step
    # is covered by a second rule: [PostingStep.route] must never name a
    # provider-payment screen, because the app no longer has a flow that takes
    # a provider to one — the platform collects the payment, and a step that
    # cannot be completed anywhere in the app is a row a provider can never
    # turn green. Review and complaint screens are the only other route-shaped
    # values, and neither is a posting gate: a review verdict unlocks nothing,
    # and a complaint opens a ticket.
    if re.search(r'route:\s*["\']/(?:provider/payment-methods|provider/documents|admin/\w*|/admin)', gate):
        problems.append(
            'posting_gate.dart: a PostingStep.route still names a provider-payment '
            'or admin screen — the app no longer has a flow that gets there')

    ready = _dart_without_comments(
        _read(LIB / "core" / "services" / "provider_readiness.dart"))
    if "'NO_PAYMENT_ACCOUNT'" in ready:
        problems.append(
            "provider_readiness.dart still carries a NO_PAYMENT_ACCOUNT "
            "remedy — the banner would send a provider to a screen that no "
            "longer accepts an account")
    if "provider_payment_methods" in ready:
        problems.append(
            "provider_readiness.dart still reads the accounts table for a "
            "rule the server no longer has")

    # The provider screen must not offer the flow at all. The wallet parts of
    # it are checked by name, because deleting the screen would be a "fix"
    # that removes the balance and the funding flow with it.
    prov = _dart_without_comments(_read(LIB / "features" / "provider" /
                                        "provider_payment_methods_screen.dart"))
    for needle, why in (
        ("getProviderMethods",
         "the screen still reads the provider's own accounts"),
        ("createMethod", "the screen still offers to create an account"),
        ("updateMethod", "the screen still offers to edit an account"),
        ("deleteMethod", "the screen still offers to remove an account"),
        ("Add bank account",
         "the screen still invites a provider to add a bank account"),
    ):
        if needle in prov:
            problems.append(
                "provider_payment_methods_screen.dart: %s (Part 13 removes "
                "the provider's own account flow entirely)" % why)
    for needle, why in (
        ("_walletBalanceCard", "the wallet balance card"),
        ("_showAddFundsSheet", "the funding request flow"),
    ):
        if needle not in prov:
            problems.append(
                "provider_payment_methods_screen.dart: %s was removed — the "
                "correction is to remove the account input ONLY" % why)

    wallet = _dart_without_comments(
        _read(LIB / "features" / "wallet" / "wallet_screen.dart"))
    for needle in ("Current Balance", "Recent Transactions"):
        if needle not in wallet:
            problems.append(
                "wallet_screen.dart lost %r — the provider wallet screen "
                "itself is hands-off" % needle)

    conn = _read(ROOT / "tools" / "integration_test" /
                 "connectivity_test.dart")
    if "assert_posting_requires_payment_account" not in conn:
        problems.append(
            "connectivity_test.dart does not run "
            "assert_posting_requires_payment_account(), so nothing proves "
            "the removal on the live database")

    return problems


def check_admin_dashboard_counts_and_bells() -> list[str]:
    """One number for "Pending", one bell, and a card for every queue.

    Item 3's reported defect: the Pending tile read `_pendingProviders`
    alone, so it said 0 while 21 identity documents waited one screen away —
    two "truths" on one dashboard. The header also carried two identical
    bells (inbox + pending work), the Requires Attention section only knew
    three of the six queues the badge counts, order payments were missing
    from the sum entirely, the header rosette was untappable decoration, and
    the initials avatar was dark-on-dark on the dark app bar.

    What must hold:
      * the Pending tile, the bell badge and Requires Attention are all
        built from the SAME pendingTotal, and pendingTotal includes every
        queue (documents, appeals, disputes, order payments);
      * one route ladder (`_firstPendingRoute`) drives both the bell and
        the tile, so badge and tile can never disagree about where work is;
      * exactly one bell — the inbox door lives in the account menu;
      * every counted queue has a Requires Attention card with its route;
      * the rosette opens the profile and the avatar menu offers profile,
        notifications, password and sign-out.
    """
    problems: list[str] = []
    path = LIB / "features" / "admin" / "admin_dashboard.dart"
    src = _dart_without_comments(_read(path))
    if not src:
        return ["lib/features/admin/admin_dashboard.dart is missing"]

    if not re.search(
            r"_quickStat\(Icons\.pending_actions, 'Pending', '\$pendingTotal'",
            src):
        problems.append(
            "the Pending tile no longer shows pendingTotal — it can read 0 "
            "while documents wait (the two-truths bug)")

    ladder = re.search(r"String _firstPendingRoute\(\) \{(.*?)\n  \}", src,
                       re.DOTALL)
    if ladder is None:
        problems.append(
            "_firstPendingRoute() is gone — the bell and the tile each "
            "decide where work lives, and they will drift apart")
    else:
        for queue, why in (
            ("'/admin/approvals'", "accounts awaiting a decision"),
            ("'/admin/document-verification'", "identity documents"),
            ("'/admin/appeals'", "filed appeals"),
            ("'/admin/disputes'", "order disputes"),
            ("'/admin/payments'", "money to verify"),
        ):
            if queue not in ladder.group(1):
                problems.append("_firstPendingRoute skips %s" % why)
    if src.count("_firstPendingRoute()") < 2:
        problems.append(
            "fewer than two callers of _firstPendingRoute — one of the "
            "bell or the tile has its own private copy of the ladder")

    total = re.search(r"final pendingTotal = (.*?);\s*final hasPending", src,
                      re.DOTALL)
    if total is None:
        problems.append("pendingTotal assignment not found")
    else:
        for field, why in (
            ("_pendingDocuments", "identity documents"),
            ("_openAppeals", "appeals"),
            ("_openDisputes", "disputes"),
            ("_pendingOrderPayments", "order payments"),
            ("_pendingRecharges", "recharges"),
        ):
            if field not in total.group(1):
                problems.append("pendingTotal does not count %s — the badge "
                                "can read 0 with work waiting" % why)

    # One bell: the second plain inbox bell in the app bar is the duplicate.
    if "tooltip: 'Notifications'" in src:
        problems.append(
            "the header carries both an inbox bell and a pending-work bell "
            "again — two identical icons doing different jobs")

    for needle, why in (
        ("'Identity Documents'", "documents have no Requires Attention card"),
        ("'/admin/document-verification'",
         "no route to document verification from Requires Attention"),
        ("'Appeals'", "appeals have no Requires Attention card"),
        ("'Order Disputes'", "disputes have no Requires Attention card"),
        ("'Order Payments'", "order payments have no Requires Attention card"),
        ("'Your profile'",
         "the header rosette is decoration again — it opens nothing"),
        ("value: 'profile'", "the avatar menu has no profile door"),
        ("value: 'notifications'",
         "the inbox is unreachable — its bell was removed without a "
         "replacement"),
        ("value: 'logout'", "the avatar menu cannot sign out"),
        ("backgroundColor: Colors.white,",
         "the initials avatar is dark-on-dark on the app bar again"),
    ):
        if needle not in src:
            problems.append("admin_dashboard.dart: %s" % why)

    return problems


def check_no_contact_before_payment() -> list[str]:
    """No talking to a seller — or reading their numbers — before the money.

    Item 7's halves (each missing reopens the channel the report describes):

      * server: provider_payment_accounts (and the LAST migration that
        defines it) demands a buyer's ACCEPTED, unexpired, UNUSED
        availability request and is revoked from `anon`, so the public
        product page cannot read bank details unauthenticated;
      * server: order_messages masks phone-shaped tokens, and the pattern
        lives in order_chat_phone_mask_pattern() so the assertion can RUN
        it — against the local 09/07 formats the first draft missed and
        against 13-digit bank accounts it must not touch;
      * client: no "Contact seller"/call/SMS/WhatsApp button on a buyer
        screen, checkout says "Pay the seller directly", and the product
        page does NOT read the reveal RPC to decide buyability — once that
        RPC started gating, such a read hid BUY NOW for every buyer;
      * proof: assert_no_contact_before_payment is registered in CI.
    """
    problems: list[str] = []
    mig = ROOT / "supabase" / "migrations" / \
        "20261006000009_no_contact_before_payment.sql"
    if not mig.is_file():
        return ["20261006000009_no_contact_before_payment.sql is missing — "
                "nothing gates the account-number reveal"]
    sql = _read(mig)

    for needle, why in (
        ("REVOKE ALL ON FUNCTION public.provider_payment_accounts",
         "anon is not locked out — bank details stay readable "
         "unauthenticated"),
        ("availability_requests",
         "the reveal no longer demands the gate's YES"),
        ("used_at",
         "a consumed request still reveals the numbers"),
        ("order_chat_phone_mask_pattern",
         "the mask pattern is not a testable value"),
        ("trg_order_messages_mask_phone",
         "the order thread has no mask trigger"),
        ("assert_no_contact_before_payment",
         "no live assertion for Connectivity CI"),
        ("(?:(?:251|0)",
         "the pattern lost the local trunk prefix — 0911234567 passes "
         "through the filter"),
        ("regexp_replace('0911234567'",
         "the assertion no longer proves 09/07 numbers get masked"),
        ("regexp_replace('1000123456789'",
         "the assertion no longer proves bank accounts are left alone"),
    ):
        if needle not in sql:
            problems.append("20261006000009: %s" % why)

    target, _ = last_migration_defining("provider_payment_accounts")
    if target is None or target.name != mig.name:
        problems.append(
            "%s is now the last definition of provider_payment_accounts — "
            "the availability YES requirement is no longer the last word"
            % (target.name if target else "no migration defines it"))

    # ── the client half ──
    lib_text = "\n".join(
        _dart_without_comments(_read(p)) for p in dart_sources())
    for needle, why in (
        ("Contact seller",
         "a Contact seller button is back on a buyer screen"),
        ("onContactSeller",
         "the contact-seller callback is back in the card API"),
    ):
        if needle in lib_text:
            problems.append("lib/: %s (item 7 removed every pre-payment "
                            "contact channel)" % why)

    card = _dart_without_comments(
        _read(LIB / "core" / "widgets" / "payment_accounts_card.dart"))
    if "'Pay the seller directly'" not in card:
        problems.append(
            "payment_accounts_card.dart: checkout copy no longer says "
            "\"Pay the seller directly\" (it must stay anonymous until an "
            "order exists)")
    if "onFindAnother" not in card:
        problems.append(
            "payment_accounts_card.dart: the no-account card lost its "
            "\"Find another provider\" escape")
    if "providerName" in card:
        problems.append(
            "payment_accounts_card.dart: a provider name is back on the "
            "payment copy")

    # Part 4 of the rework: the buyer pays the PLATFORM's account, configured
    # in Admin → Payment Settings and rendered by AdminPaymentDetailsCard.
    #
    # The card moved with the payment step: the fulfillment screen ends at
    # CONTINUE TO PAYMENT and the account, the amount the buyer writes down
    # and the proof upload are one screen further on. So the card is looked
    # for where it is rendered now, AND the hand-off is checked — a checkout
    # that neither renders the card nor opens the screen that does is exactly
    # the failure this half of the check exists to catch, and it would read
    # as green if only the move were followed.
    #
    # The provider-account ban stays on BOTH screens: the escape hatch this
    # rework deleted ("Find another provider", the provider's own numbers)
    # existed only because payment depended on one provider having an account.
    payment_screen = _dart_without_comments(
        _read(LIB / "features" / "user" / "user_payment_screen.dart"))
    if "AdminPaymentDetailsCard(" not in payment_screen:
        problems.append(
            "user_payment_screen.dart: the payment step no longer renders "
            "AdminPaymentDetailsCard, so the buyer is not pointed at the "
            "platform's configured account (Part 4)")
    checkout = _dart_without_comments(
        _read(LIB / "features" / "user" / "user_checkout_screen.dart"))
    if "'/user/payment'" not in checkout:
        problems.append(
            "user_checkout_screen.dart: the checkout no longer opens "
            "/user/payment, so the fulfillment screen is a dead end and the "
            "platform account is unreachable from the flow (Part 4)")
    for label, screen in (
            ("user_checkout_screen.dart", checkout),
            ("user_payment_screen.dart", payment_screen)):
        if "PaymentAccountsCard(" in screen or \
                "provider_payment_accounts" in screen:
            problems.append(
                "%s: a provider's payment account is back on the buyer's "
                "path — buyers pay the platform, never a provider" % label)

    detail = _dart_without_comments(
        _read(LIB / "features" / "user" / "user_product_detail_screen.dart"))
    if "PaymentAccounts" in detail or "provider_payment_accounts" in detail:
        problems.append(
            "user_product_detail_screen.dart: the product page reads the "
            "reveal RPC again — since 20261006000009 it returns NOTHING "
            "until the availability gate says YES, so BUY NOW would "
            "disappear for every buyer")
    # The button used to be the literal `'BUY NOW'`. It is the same button with
    # a type-derived verb now (`'${actionVerb.toUpperCase()} NOW'`): BUY for a
    # good, BOOK for a service or a room — the report this round is about. The
    # assertion is the same one, on the form the button actually takes, and it
    # still fails if the button or the shared rule behind its verb disappears.
    if "'${actionVerb.toUpperCase()} NOW'" not in detail or \
            "listingActionLabel(p['listing_type'] as String?)" not in detail:
        problems.append(
            "user_product_detail_screen.dart: the product page has no "
            "type-derived BUY/BOOK NOW button, so no buyer can reach the "
            "availability gate")

    # The tap-to-call provider screen must stay off the buyer path: nothing
    # under lib/features/user or lib/core may push its route.
    for p in dart_sources():
        rel = str(p.relative_to(LIB))
        if not (rel.startswith("features/user") or rel.startswith("core/")):
            continue
        if "'/provider/location" in _read(p):
            problems.append(
                "%s pushes /provider/location — a tap-to-call screen with "
                "the provider's phone number, reachable before payment"
                % rel)

    conn = _read(ROOT / "tools" / "integration_test" /
                 "connectivity_test.dart")
    if "assert_no_contact_before_payment" not in conn:
        problems.append(
            "connectivity_test.dart does not run "
            "assert_no_contact_before_payment()")

    return problems


def check_one_action_per_listing_and_no_provider_control_where_buyers_browse() -> list[str]:
    """The report's four halves, each with its own quiet failure mode.

      1. ONE action per listing, and the verb comes from the listing's own
         type. `products.listing_type` has existed since 0022a
         ('PRODUCT','FOOD','SERVICE','ROOM','OTHER'); a SERVICE or a ROOM is
         BOOKED, everything else is BOUGHT. Four surfaces render a listing —
         the shared card (product, raw row and provider photo), the product
         detail screen and the provider page's list rows — and the rule has to
         live in ONE function, or the same service reads BUY on one screen and
         BOOK on the next. The screens also have to PASS the type: the feed's
         mapping omitted `listing_type` entirely, so every card in it was a
         PRODUCT.

      2. No provider-only management control on a buyer surface. Editing a
         listing is the OWNER's action: it belongs on the provider's own
         management screens, never in a surface a customer browses. The one
         provider-intent control a buyer may see is the add-listing entry, and
         it must go through the posting gate (verification, wallet, payment
         account) rather than opening the form directly.

      3. A listing with no photo is private to its provider's page. The browse
         and search reads exclude it (migration 20261011000001), the feed's own
         mapping drops it, and its own provider's page renders it as a
         text-only card — name, price, action, and NO image box, because an
         empty frame reads as a broken photo. Note that `products_public_read`
         must NOT carry the exclusion: that policy also answers the provider
         page, which has to keep showing the listing.

      4. The trending rail ranks by the last 7 days, not by career totals. A
         revert to `completed_transactions DESC` alone still returns rows and
         still looks ranked — it just never changes, which is exactly how the
         "static trending list" was reported.
    """
    problems: list[str] = []

    card_path = LIB / "core" / "widgets" / "product_card.dart"
    card = _dart_without_comments(_read(card_path))
    if card_path.is_file():
        # 1a. the single definition of the verb
        for needle, why in (
            ("String listingActionLabel(String? listingType)",
             "the shared BUY/BOOK rule is gone from the card module"),
            ("type == 'SERVICE' || type == 'ROOM'",
             "BOOK is no longer keyed on the two bookable listing types"),
            ("? 'Book' : 'Buy'",
             "the rule no longer names both verbs"),
            # 1b. every constructor takes its verb from that rule
            ("actionLabel: product.actionLabel",
             "a Product card no longer reads the listing's own type" ),
            ("actionLabel: listingActionLabel(listingType)",
             "a raw listing row's card no longer derives its verb from "
             "listing_type"),
            ("actionLabel: 'Book'",
             "a provider photo lost its BOOK action"),
            # 1c. the card still carries the one action itself
            ("ProductBuyButton(",
             "the card no longer renders the shared purchase button"),
            # 3a. the shared "has a photo" rule, and the text-only branch
            ("String? listingCoverPathFromRows(List<dynamic> images)",
             "the shared cover-path rule is gone"),
            ("final hasImage = img != null && img.isNotEmpty;",
             "the card does not distinguish a photo-less listing"),
        ):
            if needle not in card:
                problems.append("product_card.dart: %s" % why)
        if "inventory_2_outlined" in card:
            problems.append(
                "product_card.dart draws the box placeholder again — a "
                "listing with no photo must render as a text-only card, not "
                "as an empty frame that reads as a broken image")
    else:
        problems.append("product_card.dart is missing")

    model = _dart_without_comments(
        _read(LIB / "core" / "models" / "product.dart"))
    for needle, why in (
        ("bool get isBookable",
         "Product cannot say whether it is booked or bought"),
        ("String get actionLabel",
         "Product no longer derives its own verb"),
        ("bool get hasPhoto",
         "Product cannot say whether it has a photo a card can show"),
    ):
        if needle not in model:
            problems.append("product.dart: %s" % why)

    # 1d. every surface that renders a listing passes its type.
    user = LIB / "features" / "user"
    for name, why in (
        ("user_search_screen.dart",
         "search results render a card without the listing's type, so every "
         "service found by searching reads BUY"),
        ("user_category_screen.dart",
         "category results render a card without the listing's type"),
        ("user_provider_detail_screen.dart",
         "the provider page's tiles render a card without the listing's type"),
    ):
        code = _dart_without_comments(_read(user / name))
        if "listingType:" not in code:
            problems.append("%s: %s" % (name, why))

    detail_path = user / "user_product_detail_screen.dart"
    detail = _dart_without_comments(_read(detail_path))
    if "listingActionLabel(p['listing_type'] as String?)" not in detail:
        problems.append(
            "user_product_detail_screen.dart: the product page's primary "
            "button does not read the shared BUY/BOOK rule, so a service's "
            "own page can still say BUY")
    if "'BUY NOW'" in detail:
        problems.append(
            "user_product_detail_screen.dart: the primary button is hardcoded "
            "to 'BUY NOW' again — a bookable service reads BUY on its own page")

    # 2. no provider-only management control anywhere a buyer browses, and the
    #    one provider-intent entry goes through the posting gate.
    for path in dart_sources():
        rel = str(path.relative_to(LIB))
        if not (rel.startswith("features/user") or rel.startswith("core/")):
            continue
        code = _dart_without_comments(_read(path))
        for needle, why in (
            ("'Edit Product'",
             "the provider's Edit Product action is rendered on a buyer "
             "surface"),
            ("'/provider/products/'",
             "a buyer surface pushes the edit-a-listing route — a buyer can "
             "land on the provider's form"),
            ("delete_product", "a buyer surface can delete a listing"),
            ("archive_product", "a buyer surface can archive a listing"),
            ("provider_product_list_screen",
             "a buyer surface imports the provider's product management "
             "screen"),
        ):
            if needle in code:
                problems.append("%s: %s" % (rel, why))
    home = _dart_without_comments(_read(user / "user_home_screen.dart"))
    if "'/provider/products/new'" in home and "postingGateHook" not in home:
        problems.append(
            "user_home_screen.dart opens the add-product form without the "
            "posting gate — an unverified, unfunded provider reaches the form")

    # 3. the discovery reads exclude photo-less listings; the provider page
    #    keeps them and renders the card without an image box.
    visible_target, visible_src = last_migration_defining(
        "visible_products_for_city")
    if visible_target is None:
        problems.append("no migration defines public.visible_products_for_city()")
    elif ("select 1 from public.product_images pi" not in
          function_body(visible_src, "visible_products_for_city")):
        problems.append(
            "%s: visible_products_for_city no longer excludes photo-less "
            "listings — the category grid fills with empty frames again"
            % visible_target.name)

    search_target, search_src = last_migration_defining("search_products")
    if search_target is None:
        problems.append("no migration defines public.search_products()")
    else:
        sbody = function_body(search_src, "search_products")
        for needle, why in (
            ("SELECT 1 FROM public.product_images pi",
             "search_products no longer excludes photo-less listings (the "
             "cover-path subquery alone is not an exclusion)"),
            ("p.listing_type",
             "search_products no longer projects listing_type, so every "
             "service it returns reads BUY"),
        ):
            if needle not in sbody:
                problems.append("%s: %s" % (search_target.name, why))

    if ".where((p) => p.hasPhoto)" not in home:
        problems.append(
            "user_home_screen.dart does not drop photo-less listings from the "
            "feed — the home rail is a discovery surface")
    if "listingType: (j['listing_type'] as String?) ?? 'PRODUCT'," not in home:
        problems.append(
            "user_home_screen.dart: the feed's mapping dropped listing_type "
            "again — every card in the rail becomes a PRODUCT, so every "
            "service in it reads BUY (this is the exact omission the round is "
            "about)")
    provider_page = _dart_without_comments(
        _read(user / "user_provider_detail_screen.dart"))
    if "listingCoverPathFromRows(" not in provider_page:
        problems.append(
            "user_provider_detail_screen.dart does not render a photo-less "
            "listing as the text-only card — it either shows nothing or an "
            "empty image box")
    if "String? _firstImagePath(" in provider_page:
        problems.append(
            "user_provider_detail_screen.dart grew a private copy of the "
            "cover-path rule again — the card module has the one definition")
    for name in ("user_home_screen.dart", "user_search_screen.dart",
                 "user_category_screen.dart"):
        code = _dart_without_comments(_read(user / name))
        if "Icons.edit" in code or "'Edit Product'" in code:
            problems.append(
                "%s: renders an Edit control — editing a listing is the "
                "owning provider's action, never a buyer's" % name)

    # 4. the trending rail ranks by the last 7 days.
    ranked_target, ranked_src = last_migration_defining("ranked_providers")
    if ranked_target is None:
        problems.append("no migration defines public.ranked_providers()")
    else:
        rbody = function_body(ranked_src, "ranked_providers")
        for needle, why in (
            ("v_window",
             "ranked_providers has no trending window — it ranks by career "
             "totals, which for most providers is the same order forever"),
            ("interval '7 days'",
             "the trending window is no longer a week, so the rail is back to "
             "career totals in all but name"),
            ("updated_at >= now() - v_window",
             "the recency key reads no completion time"),
        ):
            if needle not in rbody:
                problems.append("%s: %s" % (ranked_target.name, why))
        if "created_at ASC" not in rbody:
            problems.append(
                "%s: ranked_providers lost its stable tiebreak — an ordering "
                "the client cannot re-derive must keep one" % ranked_target.name)

    return problems


def check_every_listing_takes_its_type_from_its_category() -> list[str]:
    """BUY vs BOOK, third report: the value the button reads has to be TRUE.

      * The write path never set `listing_type`. `products.listing_type` is
        `NOT NULL DEFAULT 'PRODUCT'` (0022a) and `create_provider_product()`
        inserts without naming it, so every service, room and food listing
        created by this app is stored as a PRODUCT — and the (correct) shared
        rule then reads PRODUCT and says BUY. A grep of the button cannot see
        that, so this pins the DATA half: one derivation from the category, a
        trigger that stamps it on every write, and a backfill of the rows that
        are already wrong.
      * A booking has to behave like a booking downstream too: the cart carries
        the listing's own type, the checkout does not demand a delivery address
        for a basket of bookings (the server answers "Delivery requires an
        address"), and the gate asks the provider a question that is true of an
        appointment.
      * The search screen reads `search_products`, whose DEPLOYED body has no
        `listing_type` in its RETURNS TABLE (the projection lands with
        20261011000001), so the screen must resolve the missing column itself —
        one batched read, not one per card — or every service found by search
        reads BUY until a deploy happens.
    """
    problems: list[str] = []

    mig = ROOT / "supabase" / "migrations" / \
        "20261012000001_every_listing_carries_its_own_type_from_its_category.sql"
    if not mig.is_file():
        return ["20261012000001...sql is missing — nothing writes "
                "products.listing_type, so every service stays a PRODUCT"]
    sql = _read(mig)
    for needle, why in (
        ("CREATE OR REPLACE FUNCTION public.listing_type_for_category",
         "no derivation: the category is never turned into a listing type"),
        ("ACCOMMODATION", "a hotel room would classify as nothing"),
        ("'SERVICES'", "a service category would classify as nothing"),
        ("BOOKING_BASED",
         "the fallback for a row whose marketplace_sector was never set is "
         "gone"),
        ("NEW.listing_type := v_type;",
         "the trigger does not write the column it exists to write"),
        ("CREATE TRIGGER trg_products_listing_type",
         "no trigger: create_provider_product() goes back to storing every "
         "service as a PRODUCT"),
        ("BEFORE INSERT OR UPDATE OF category_id ON public.products",
         "the trigger does not fire on the insert the create path makes"),
        ("UPDATE public.products p",
         "no backfill: the listings that are already wrong stay wrong"),
        ("LISTING_TYPE_BACKFILL_INCOMPLETE",
         "the backfill does not prove it covered the rows it should have"),
        ("assert_listing_types_are_true",
         "no live report, so the actual rows cannot be read back"),
    ):
        if needle not in sql:
            problems.append("20261012000001: %s" % why)
    if "TO anon, authenticated, service_role" not in sql:
        problems.append(
            "20261012000001: assert_listing_types_are_true() is not executable "
            "by anon — the connectivity suite runs as anon and would report "
            "PGRST202, which reads like a missing migration")

    # The client: the cart carries the type, and a booking is not a delivery.
    cart_path = LIB / "core" / "services" / "cart_service.dart"
    cart = _dart_without_comments(_read(cart_path))
    for needle, why in (
        ("bool get isBooking",
         "a cart line cannot say whether it is booked or bought"),
        ("listing_type",
         "the cart's product read no longer selects the listing's type, so "
         "every line reads as a purchase"),
    ):
        if needle not in cart:
            problems.append("cart_service.dart: %s" % why)

    checkout = _dart_without_comments(
        _read(LIB / "features" / "user" / "user_checkout_screen.dart"))
    for needle, why in (
        ("_isBookingCart",
         "the checkout cannot say whether this basket is a booking"),
        ("items.every((i) => i.isBooking)) {",
         "a basket of bookings is not defaulted away from the delivery "
         "path — order-create answers \"Delivery requires an address\", so "
         "booking a service stops at a shipping form"),
        ("_fulfillmentTouched",
         "nothing stops the booking default from overriding a delivery "
         "option the buyer chose themselves"),
    ):
        if needle not in checkout:
            problems.append("user_checkout_screen.dart: %s" % why)

    gate = _dart_without_comments(
        _read(LIB / "features" / "user" / "user_availability_screen.dart"))
    if "Can they take this booking?" not in gate:
        problems.append(
            "user_availability_screen.dart: the gate asks every basket "
            "\"Is this product available?\" — including an appointment")

    search = _dart_without_comments(
        _read(LIB / "features" / "user" / "user_search_screen.dart"))
    for needle, why in (
        ("listing_type",
         "search results no longer resolve the listing's type, and the "
         "DEPLOYED search_products does not project it"),
        ("inFilter('id', ids)",
         "the missing type is not resolved in one batched read"),
    ):
        if needle not in search:
            problems.append("user_search_screen.dart: %s" % why)

    provider_dash = _dart_without_comments(
        _read(LIB / "features" / "provider" / "service_provider_dashboard.dart"))
    if "ACCEPT BOOKING" not in provider_dash:
        problems.append(
            "service_provider_dashboard.dart: the provider is asked whether a "
            "booking is \"AVAILABLE\" and never that it is a booking")

    return problems


def check_like_and_dislike_are_offered_wherever_a_listing_is() -> list[str]:
    """The reaction buttons, restored and actually reflecting the reader.

    Reported as removed. They were not: the shared card has carried them since
    the consolidation (268c108f), and `product_likes` with its `reaction`
    CHECK, its RLS and `set_product_reaction` has been the storage since
    20260927000068. What was TRUE is that the StatefulWidget reads a service the
    screen has to hydrate first, and only the home rail and the product page
    did — so on the category grid, the search results and a provider's page the
    heart always rendered EMPTY for a listing the user had already liked, and
    the first tap then cleared the like they already had. That is
    indistinguishable, to the reader, from a like button that was removed.
    """
    problems: list[str] = []

    card = _dart_without_comments(
        _read(LIB / "core" / "widgets" / "product_card.dart"))
    for needle, why in (
        ("LikeButton(", "the shared card lost the heart"),
        ("DislikeButton(", "the shared card lost the thumb-down"),
    ):
        if card.count(needle) != 1:
            problems.append(
                "product_card.dart: %s (%d occurrences — it is rendered once "
                "per listing card)" % (why, card.count(needle)))

    # The layout rule the report asks for: the reactions are NOT mixed into the
    # action button's row. The action row is price + ProductBuyButton; the
    # reactions share the bottom row with the rank badge.
    buy_idx = card.rindex("ProductBuyButton(")
    action_row = card[card.rindex("Row(", 0, buy_idx):buy_idx]
    if "LikeButton" in action_row or "DislikeButton" in action_row:
        problems.append(
            "product_card.dart: a reaction is rendered inside the BUY/BOOK "
            "row again — the action button and the reactions are separate rows")
    like_idx = card.rindex("LikeButton(")
    reaction_row = card[card.rindex("Row(", 0, like_idx):like_idx]
    if "DislikeButton" not in reaction_row:
        problems.append(
            "product_card.dart: the heart and the thumb-down no longer share "
            "one row")

    engagement = _dart_without_comments(
        _read(LIB / "core" / "widgets" / "product_engagement.dart"))
    for needle, why in (
        ("service.isLiked(",
         "the heart no longer reads the caller's own reaction, so it cannot "
         "show an already-liked listing as liked"),
        ("Icons.favorite", "the filled heart state is gone"),
        ("Icons.thumb_down", "the filled thumb-down state is gone"),
        ("toggleLike(", "the heart no longer writes"),
        ("toggleDislike(", "the thumb-down no longer writes"),
    ):
        if needle not in engagement:
            problems.append("product_engagement.dart: %s" % why)

    service = LIB / "core" / "services" / "product_like_service.dart"
    if not service.is_file():
        problems.append("product_like_service.dart is missing")
    else:
        svc = _dart_without_comments(_read(service))
        for needle, why in (
            ("Future<void> ensureLoaded(",
             "the hydrate the card depends on is gone"),
            ("'set_product_reaction'",
             "the write is a toggle again — a client whose state is stale "
             "would flip the row the wrong way"),
            ("_serverLikeCounts", "the optimistic count has no server baseline"),
        ):
            if needle not in svc:
                problems.append("product_like_service.dart: %s" % why)

    # Hydration is what makes the buttons reflect the reader. Every screen that
    # renders listing cards has to do it, not just the home rail.
    user = LIB / "features" / "user"
    for name in ("user_home_screen.dart", "user_search_screen.dart",
                 "user_category_screen.dart",
                 "user_provider_detail_screen.dart"):
        code = _dart_without_comments(_read(user / name))
        if "ProductLikeService.instance.ensureLoaded(" not in code:
            problems.append(
                "%s: renders listing cards without hydrating the caller's "
                "reactions — every heart shows empty for a product the user "
                "already liked, and the first tap clears that like" % name)

    # The storage half: the reaction is persisted, one row per user+product, and
    # readable/writable only by its owner. The creating migration is the one
    # that has to carry RLS and the owner-scoped policies; a later file that
    # merely touches the table cannot satisfy this.
    creating = [p for p in migration_files()
                if re.search(r"create\s+table\s+if\s+not\s+exists\s+"
                             r"(?:public\.)?product_likes\b", _read(p),
                             re.IGNORECASE)]
    if not creating:
        problems.append(
            "no migration creates product_likes — the reaction buttons have "
            "nowhere to persist")
    else:
        src = _read(creating[0])
        for needle, why in (
            ("enable row level security",
             "product_likes is readable/writable without a policy"),
            ("create policy product_likes",
             "no policy on product_likes: nothing scopes a reaction to its "
             "own author"),
        ):
            if needle.lower() not in src.lower():
                problems.append("%s: %s" % (creating[0].name, why))

    # And the reaction the buttons write is the column the schema has: a
    # LIKE/DISLIKE/NONE CHECK, so one user cannot like the same listing twice
    # and the two reactions stay exclusive.
    reaction_src = "\n".join(_read(p) for p in migration_files()
                             if "set_product_reaction" in _read(p))
    if "DISLIKE" not in reaction_src or "NONE" not in reaction_src:
        problems.append(
            "set_product_reaction() no longer knows LIKE/DISLIKE/NONE — the "
            "thumb-down or the clear-a-reaction state is gone")

    return problems


# ---------------------------------------------------------------------------
# the Parts 1-8 registration rework: every promised half is still connected
# ---------------------------------------------------------------------------
def check_registration_rework_is_wired() -> list[str]:
    """Each part is a server half and a client half; either can quietly vanish.

    The 20261014* migrations restate the rules (self-service registration is
    immediately active, document verification is voluntary, display_price is
    the one public price, the platform's contact number and payment account
    are data, admins may answer availability requests, staff registration
    oversight is counted). None of that REACHES a person if the door in lib/
    disappears: a route nobody declares, a dashboard card nobody renders, a
    card a screen stopped embedding, a banner never mounted. Each needle is
    the smallest string that proves one half of one part is still wired to
    the other, and each failure names the part it protects.
    """
    problems: list[str] = []
    mig_dir = ROOT / "supabase" / "migrations"

    def mig(name: str) -> str:
        path = mig_dir / name
        if not path.is_file():
            problems.append(
                "%s is missing — a part of the rework has no server half"
                % name)
            return ""
        return _read(path)

    m0 = mig("20261014000000_self_service_registration_is_immediately_active"
             ".sql")
    m1 = mig("20261014000001_document_verification_is_voluntary_for_service_"
             "providers.sql")
    m2 = mig("20261014000002_display_price_is_the_public_price.sql")
    m3 = mig("20261014000003_platform_contact_and_payment_settings.sql")
    m4 = mig("20261014000004_admin_answers_availability_requests_too.sql")
    m5 = mig("20261014000005_staff_registration_oversight.sql")

    # ── server halves ──
    for fname, sql, needle, why in (
        ("20261014000000_self_service_registration_is_immediately_active.sql",
         m0, "'APPROVED'::account_status",
         "Part 1: a self-signed-up profile is no longer born APPROVED"),
        ("20261014000000_self_service_registration_is_immediately_active.sql",
         m0, "notify_user_once",
         "Part 1: the keyed welcome after approval is not sent anymore"),
        ("20261014000001_document_verification_is_voluntary_for_service_"
         "providers.sql", m1, "VEHICLE_PROVIDER",
         "Part 1.3: the DOCUMENTS_UNVERIFIED branch is no longer scoped to "
         "vehicle providers, so voluntary verification has become "
         "mandatory again for everyone"),
        ("20261014000002_display_price_is_the_public_price.sql",
         m2, "display_price",
         "Part 2: the generated public price column is gone, so every "
         "surface computes its own markup again"),
        ("20261014000002_display_price_is_the_public_price.sql",
         m2, "search_products",
         "Part 2: the public discovery read still projects raw price"),
        ("20261014000003_platform_contact_and_payment_settings.sql",
         m3, "public_app_settings",
         "Part 3/4: buyers have no whitelisted way to read the platform's "
         "contact number and payment account"),
        ("20261014000003_platform_contact_and_payment_settings.sql",
         m3, "admin_contact_phone",
         "Part 3: the platform contact key is not seeded"),
        ("20261014000003_platform_contact_and_payment_settings.sql",
         m3, "admin_payment_details",
         "Part 4: the platform payment key is not seeded"),
        ("20261014000004_admin_answers_availability_requests_too.sql",
         m4, "public.is_admin()",
         "Part 5: respond_availability_request refuses administrators "
         "again, so the admin queue can show buttons that cannot work"),
        ("20261014000004_admin_answers_availability_requests_too.sql",
         m4, "REQUEST_ALREADY_ANSWERED",
         "Part 5: the either-party-first race guard is gone, so provider "
         "and admin can double-answer one request"),
        ("20261014000005_staff_registration_oversight.sql",
         m5, "staff_registration_stats",
         "Part 6: the per-staff registration oversight aggregate is gone"),
        ("20261014000005_staff_registration_oversight.sql",
         m5, "referred_by_staff_id",
         "Part 6: oversight no longer keys on the staff referral column"),
    ):
        if sql and needle not in sql:
            problems.append("%s: %s" % (fname, why))

    # ── client halves ──
    def dart(rel: str, *needles: str, why: str) -> str:
        text = _read(LIB / rel)
        if not text:
            problems.append("lib/%s is missing — %s" % (rel, why))
            return text
        for needle in needles:
            if needle not in text:
                problems.append("lib/%s: %s (no %r)" % (rel, why, needle))
        return text

    router = "routing/app_router.dart"
    dart(router, "/provider/documents",
         why="Part 1.3/8: the voluntary Verify Documents screen has no route")
    dart(router, "/admin/platform-settings",
         why="Part 3/4: the admin contact/payment settings screen has no route")
    dart(router, "queryParameters['assisted'] == '1'",
         why="Part 6: the staff-assisted signup flag is never read from the "
             "URL, so the staff door opens an ordinary self-service signup")
    dart("features/provider/service_provider_dashboard.dart", "Verify Documents",
         "'/provider/documents'",
         why="Part 1.3: providers cannot reach their own document upload "
             "from Settings")
    dart("features/admin/admin_dashboard.dart", "Contact Settings", "Payment Settings",
         "/admin/platform-settings?section=",
         why="Part 3/4: the admin doors to the platform contact/payment "
             "settings are gone")
    dart("features/auth/signup_screen.dart", "_captchaRequired = true", "_agreedToTerms",
         "SystemBannerController.instance.show", "context.go(switch (widget.role)",
         "'/provider/documents'",
         why="Part 1/6/8: signup lost one of always-on CAPTCHA, privacy "
             "checkbox, welcome banner, direct dashboard navigation or the "
             "staff-assisted walk into document upload")
    dart("app.dart", "const SystemBanner()",
         why="Part 8: the system banner is not mounted above the navigator")
    dart("features/user/user_order_detail_screen.dart", "AdminPaymentDetailsCard(",
         "PlatformContactCard()",
         why="Part 3/4: the order screen no longer shows the platform's "
             "payment account and platform support contact")
    dart("features/user/user_payment_screen.dart", "AdminPaymentDetailsCard(",
         "_pickScreenshot",
         why="Part 4: the payment step no longer renders the platform payment "
             "card")
    dart("features/user/user_checkout_screen.dart", "'/user/payment'",
         why="Part 4: the fulfillment screen no longer hands off to the "
             "payment step, so the platform account is unreachable")
    dart("features/admin/admin_availability_screen.dart", "respond_availability_request",
         "listingCoverUrl", "'APPROVE'",
         why="Part 5: the admin queue lost its answer action or the request "
             "cover photo")
    dart("features/provider/service_provider_dashboard.dart",
         "product_images(storage_path, sort_order)", "listingCoverUrl",
         why="Part 5: the provider's request card lost the listing cover photo")
    dart("features/staff/staff_dashboard_screen.dart", "assisted=1",
         "Register a provider",
         why="Part 6: the staff workspace has no assisted-registration door")
    dart("features/admin/admin_staff_screen.dart", "staff_registration_stats",
         why="Part 6: the performance dialog no longer shows how many "
             "providers this staff member registered and what they posted")
    dart("core/models/product.dart", "formattedDisplayPrice", "publicPrice",
         why="Part 2: the Product model no longer reads the public price")
    dart("core/services/cart_service.dart", "display_price",
         why="Part 2: the cart still reads the provider's raw price")
    dart("core/services/platform_settings_service.dart", "public_app_settings",
         why="Part 3/4: the buyer-safe settings reader no longer calls the "
             "whitelisted RPC")

    for rel in (
        "core/widgets/system_banner.dart",
        "core/widgets/admin_payment_details_card.dart",
        "core/widgets/platform_contact_card.dart",
        "features/provider/provider_documents_screen.dart",
        "features/admin/admin_platform_settings_screen.dart",
    ):
        if not (LIB / rel).is_file():
            problems.append("lib/%s is missing — a rework surface was deleted"
                            % rel)

    return problems


# ---------------------------------------------------------------------------
# the Parts 9-11 rework: every promised half is still connected
# ---------------------------------------------------------------------------
def check_parts_9_to_11_are_wired() -> list[str]:
    """Push for every notification, a wait that lives in the row, the delivery
    fee reusing the ride fare, and a listing that can be hidden or deleted.

    Each part is a server half and a client half, and either can quietly
    vanish: a trigger nobody attached, a section nobody renders, a quote that
    stopped calling the fare reader, a provider control that went back to
    claiming it deletes when it hides. Each needle is the smallest string that
    proves one half is still wired to the other, and each failure names the
    part it protects.
    """
    problems: list[str] = []
    mig_dir = ROOT / "supabase" / "migrations"

    def mig(name: str) -> str:
        path = mig_dir / name
        if not path.is_file():
            problems.append(
                "%s is missing — a part of the rework has no server half"
                % name)
            return ""
        return _read(path)

    m_push = mig("20261015000001_every_notification_also_leaves_as_a_push.sql")
    m_fee = mig("20261015000002_delivery_fee_is_the_ride_fare_reused.sql")
    m_prod = mig("20261015000003_provider_listings_can_be_hidden_or_deleted"
                 ".sql")

    # ── Part 9a: one dispatch point, on the table, through the existing sender
    for needle, why in (
        ("trg_notifications_push_dispatch",
         "Part 9a: the AFTER INSERT trigger that turns every notification into "
         "a push is gone, so the in-app inbox is the only channel again"),
        ("create_n8n_event",
         "Part 9a: the push no longer goes through the repository's existing "
         "dispatcher — a second pathway"),
        ("fcm_tokens",
         "Part 9a: the push carries no device tokens"),
        ("push_enabled",
         "Part 9a: the stored push preference is ignored again"),
        ("assert_every_notification_leaves_as_a_push",
         "Part 9a: nothing asserts that every notification also dispatches a "
         "push"),
        ("assert_availability_wait_is_server_state",
         "Part 9b: nothing asserts the availability wait is the row's state"),
    ):
        if m_push and needle not in m_push:
            problems.append(
                "20261015000001_every_notification_also_leaves_as_a_push.sql: "
                "%s" % why)

    # ── Part 10: the delivery fee is the ride fare, quoted once
    for needle, why in (
        ("calculate_fare_estimate_at",
         "Part 10: the delivery fee no longer calls the ride fare reader"),
        ("platform_display_markup",
         "Part 10: the delivery markup is no longer the product markup"),
        ("quote_delivery_fee",
         "Part 10: there is no single callable the checkout and the order "
         "both price through"),
        ("PROVIDER_HAS_NO_LOCATION",
         "Part 10: an unpriceable delivery would be approximated from the "
         "city again instead of being stated"),
        ("GENERATED ALWAYS AS (public.platform_display_markup(price))",
         "Part 10: products.display_price stopped being generated from the "
         "one markup rule, so the two markups can drift"),
    ):
        if m_fee and needle not in m_fee:
            problems.append(
                "20261015000002_delivery_fee_is_the_ride_fare_reused.sql: %s"
                % why)

    # ── Part 11: hide always, delete only when nothing references the listing
    for needle, why in (
        ("provider_delete_product",
         "Part 11: the provider's delete door is gone"),
        ("provider_set_product_visibility",
         "Part 11: the provider can no longer hide a listing"),
        ("order_items",
         "Part 11: the delete no longer counts order history"),
        ("is_active = false",
         "Part 11: a listing with order history would be hard-deleted again"),
        ("delete from public.products",
         "Part 11: 'delete' hides for every listing again"),
        ("assert_order_history_blocks_a_hard_delete",
         "Part 11: nothing asserts the order-history guard"),
        ("assert_hidden_listings_leave_every_public_surface",
         "Part 11: nothing asserts a hidden listing leaves every public "
         "surface"),
    ):
        if m_prod and needle not in m_prod:
            problems.append(
                "20261015000003_provider_listings_can_be_hidden_or_deleted"
                ".sql: %s" % why)

    # The order_items foreign key is the unskippable guard. NO ACTION ('a') is
    # the value that refuses the delete; CASCADE would rewrite order history.
    fk_src = "\n".join(
        _read(p) for p in migration_files()
        if "order_items" in _read(p)
        and "references products" in _read(p).lower())
    if not re.search(
            r"order_items[^;]*product_id[^;]*references\s+(?:public\.)?products"
            r"\s*\(id\)\s*(?:,|\))",
            fk_src, re.IGNORECASE):
        problems.append(
            "Part 11: no migration declares order_items.product_id -> products "
            "without an ON DELETE action, so a hard delete of a sold listing "
            "is unguarded")
    if re.search(
            r"order_items[^;]*product_id[^;]*references\s+(?:public\.)?products"
            r"\s*\(id\)\s*on\s+delete\s+cascade",
            fk_src, re.IGNORECASE | re.DOTALL):
        problems.append(
            "Part 11: order_items.product_id -> products is ON DELETE CASCADE, "
            "so deleting a listing would take a provider's order history with "
            "it")

    # ── client halves ──
    def dart(rel: str, *needles: str, why: str) -> str:
        text = _read(LIB / rel)
        if not text:
            problems.append("lib/%s is missing — %s" % (rel, why))
            return text
        for needle in needles:
            if needle not in text:
                problems.append("lib/%s: %s (no %r)" % (rel, why, needle))
        return text

    dart("core/services/fee_resolver.dart",
         "quote_delivery_fee", "DeliveryQuote",
         why="Part 10: the app has no door to the delivery quote, so the "
             "delivery fee would be computed client-side")
    dart("features/user/user_checkout_screen.dart",
         "FeeResolver.instance.deliveryFee", "_chooseVehicleType",
         "_chooseDeliveryPoint", "WhereToPicker.open", "_payableTotal",
         why="Part 10: checkout lost a step of the delivery option — the "
             "vehicle, the location prompt, the map, the server quote, or the "
             "combined total")
    dart("features/user/user_orders_screen.dart", "PendingAvailabilitySection",
         why="Part 9b: a waiting availability request is invisible from Orders "
             "again")
    dart("features/user/pending_availability_section.dart",
         "availability_requests", "ResilientSubscription", "PENDING",
         why="Part 9b: the Orders section lost its live read of the request "
             "row or the status wording")
    dart("features/provider/provider_product_list_screen.dart",
         "provider_set_product_visibility", "provider_delete_product",
         "Hidden",
         why="Part 11: the provider's list lost the visibility toggle, the "
             "delete door, or the marker that a listing is hidden")

    fn = _read(FUNCTIONS / "order-create" / "index.ts")
    if not fn:
        problems.append("supabase/functions/order-create/index.ts is missing — "
                        "Part 10 has no charge half")
    else:
        for needle, why in (
            ("quote_delivery_fee",
             "Part 10: the order is no longer priced by the same quote the "
             "checkout showed"),
            ("delivery_lat",
             "Part 10: the order cannot receive the point it is priced to"),
        ):
            if needle not in fn:
                problems.append(
                    "supabase/functions/order-create/index.ts: %s" % why)

    if not (ROOT / "test" / "delivery_fee_reuses_the_ride_fare_test.dart").is_file():
        problems.append(
            "test/delivery_fee_reuses_the_ride_fare_test.dart is missing — the "
            "fare reuse is no longer checked anywhere")

    return problems


# ---------------------------------------------------------------------------
# the payment step: its own screen, and a way to appeal from the money step
# ---------------------------------------------------------------------------
def check_payment_step_and_appeal_are_wired() -> list[str]:
    """The checkout hands off to /user/payment, that screen owns the money, and
    a problem at either step files a case the admin queue can act on.

    Three halves, each of which can vanish on its own: the hand-off (checkout
    decides how the order arrives and pushes the payment step), the money
    screen (the platform's account, what the buyer wrote down, the proof
    upload and the ONE order-create call), and the appeal door from the
    transaction itself into `appeal_cases`, which is what the admin dashboard
    badge counts. A version bump that moves one file and not the other is the
    fourth thing checked, because the build constant and pubspec.yaml are what
    the forced-update gate and Play both read.
    """
    problems: list[str] = []

    def dart(rel: str, *needles: str, why: str) -> str:
        text = _read(LIB / rel)
        if not text:
            problems.append("lib/%s is missing — %s" % (rel, why))
            return text
        code = _dart_without_comments(text)
        for needle in needles:
            if needle not in code:
                problems.append("lib/%s: %s (no %r)" % (rel, why, needle))
        return code

    checkout = dart(
        "features/user/user_checkout_screen.dart",
        "'/user/payment'", "_continueToPayment", "AvailabilityNotice",
        "_payableTotal",
        why="the checkout no longer hands the settled basket to the payment "
            "step, or lost the deferred-payment notice")
    # The availability gate's backstop must survive the split: the checkout
    # still replaces itself with the gate, and it is the screen that decides
    # whether the payment step is deferred.
    for needle in ("/user/availability", "pushReplacement"):
        if checkout and needle not in checkout:
            problems.append(
                "lib/features/user/user_checkout_screen.dart: the availability "
                "gate's backstop is gone (no %r)" % needle)

    payment = dart(
        "features/user/user_payment_screen.dart",
        "AdminPaymentDetailsCard", "_pickScreenshot", "order-create",
        "payment_proofs", "'/appeal?about=dispute'", "OrderDraft",
        "paymentDeferred", "AvailabilityNotice", "user_documents",
        why="the payment step lost the platform's account, the proof upload, "
            "the order call, the appeal door, or the deferred-payment path")

    # The price-writing section: the buyer writes what they sent, and it is
    # recorded on the order rather than used as the price.
    if payment:
        for needle, why in (
            ("Amount you paid",
             "the price-writing section is gone, so a buyer has nowhere to say "
             "what they transferred"),
            ("Amount written by buyer",
             "the written amount never reaches the order"),
            ("Payment Reference",
             "the payment reference field is gone"),
        ):
            if needle not in payment:
                problems.append(
                    "lib/features/user/user_payment_screen.dart: %s" % why)
        # The written amount must not become the price.
        if "payableTotal = _amountCtrl" in payment:
            problems.append(
                "lib/features/user/user_payment_screen.dart: the amount WRITTEN "
                "by the buyer is being used as the order total — the server "
                "prices the order")

    # The order screen's door always knows which order it is about, so it is
    # checked for BOTH halves: the push into the appeal queue and the order
    # reference riding with it. The needle is the quoted route prefix rather
    # than the bare `'/appeal?about=dispute'` literal, because a door that knows
    # the transaction appends `&order=` to the same quote (the payment step uses
    # the bare form only for the deferred case, where no order exists yet).
    dart("features/user/user_order_detail_screen.dart",
         "_appealCard", "'/appeal?about=dispute", "&order=",
         why="an order with something wrong with it has no way to reach the "
             "admin appeals queue, or reaches it without naming the order the "
             "reviewer has to act on")

    dart("core/widgets/availability_notice.dart", "AvailabilityNotice",
         why="the shared deferred-payment notice was deleted, so checkout and "
             "the payment step would each grow their own copy")

    # The route that the hand-off pushes.
    router = _read(LIB / "routing" / "app_router.dart")
    if "'/user/payment'" not in router or "UserPaymentScreen" not in router:
        problems.append(
            "lib/routing/app_router.dart: /user/payment is not declared, so "
            "CONTINUE TO PAYMENT pushes into nowhere")

    # The appeal destination itself: the admin queue the door leads to.
    if "'/admin/appeals'" not in router:
        problems.append(
            "lib/routing/app_router.dart: /admin/appeals is gone, so a filed "
            "appeal has no admin queue")

    # The version bump has to reach BOTH files the release reads.
    pubspec = _read(ROOT / "pubspec.yaml")
    build_const = _read(LIB / "core" / "app_build.dart")
    m = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", pubspec,
                  re.MULTILINE)
    if not m:
        problems.append("pubspec.yaml has no version: x.y.z+N line")
    else:
        name, number = m.group(1), m.group(2)
        if ("kAppVersionName = '%s'" % name) not in build_const:
            problems.append(
                "lib/core/app_build.dart: kAppVersionName does not match "
                "pubspec.yaml's %s — the forced-update gate would report the "
                "wrong version to the server" % name)
        if ("kAppBuildNumber = %s" % number) not in build_const:
            problems.append(
                "lib/core/app_build.dart: kAppBuildNumber does not match "
                "pubspec.yaml's +%s — the app would gate the wrong users" % number)

    return problems


CHECKS = [
    ("a listing carries its own type from its own category, and a booking "
     "behaves like a booking end to end",
     check_every_listing_takes_its_type_from_its_category),
    ("like and dislike are on every listing card, and reflect the reader",
     check_like_and_dislike_are_offered_wherever_a_listing_is),
    ("closing an account removes the uploaded files, from every delete path",
     check_account_deletion_removes_the_files),
    ("the public account-deletion page is reachable and matches the schema",
     check_account_deletion_page_is_public_and_true),
    ("no foreign key refuses the account deletion, on either side",
     check_account_deletion_is_unblocked),
    ("a provider who cannot publish is told why, and where to fix it",
     check_publish_refusal_is_actionable),
    ("every tappable surface in the admin area has a real handler",
     check_admin_taps_have_handlers),
    ("the admin image delete removes the file from every bucket, and says why when it cannot",
     check_admin_image_delete_is_complete),
    ("a ride request writes only columns ride_requests actually has",
     check_ride_request_insert_matches_the_ride_requests_table),
    ("an unclaimed ride expires in 3 minutes and only one driver can win the claim",
     check_unclaimed_rides_expire_and_one_driver_wins),
    ("no order can be created without an ACCEPTED availability request, on any path",
     check_availability_gate_covers_every_checkout),
    ("payment accounts are bank-only, phone-free, capped at 3 and audited",
     check_bank_accounts_are_enforced),
    ("the platform collects the payment, so no listing needs a provider's "
     "account number",
     check_posting_no_longer_requires_a_provider_account),
    ("no contact, and no account number, before the payment exists",
     check_no_contact_before_payment),
    ("one Pending number, one bell, and a card for every waiting queue",
     check_admin_dashboard_counts_and_bells),
    ("signup OTP toggle contract (server pre-checks the toggle; bypass records no verification)",
     check_signup_otp_contract),
    ("every RPC called from lib/ exists in supabase/migrations",
     check_rpc_targets_exist),
    ("every Edge Function the app invokes exists and has a deploy step",
     check_edge_functions_deployed),
    ("every navigation target in lib/ resolves to a declared GoRoute",
     check_routes_resolve),
    ("both email gateways (Resend and the free Brevo tier) still match their APIs",
     check_email_provider_gateways),
    ("every table/view the client queries is created by a migration",
     check_data_targets_exist),
    ("every storage bucket lib/ uses is created by a migration the deploy "
     "workflow executes",
     check_client_buckets_are_created),
    ("every income figure counts every fee type, including the activation fee",
     check_income_readers_count_every_fee_type),
    ("the activation fee is written where an income reader can see it",
     check_activation_fee_is_recorded_as_income),
    ("a grantable staff permission actually opens something",
     check_grantable_permissions_open_something),
    ("CEO -> staff -> admin -> provider -> user routing and permissions agree",
     check_role_permission_wiring),
    ("controllers, focus nodes, timers and subscriptions are released",
     check_lifecycle_hygiene),
    ("a confirmed availability can actually be paid: gate, step, and one card",
     check_availability_payment_flow),
    ("the login screen reports its own outcome instead of spinning forever",
     check_login_reports_its_own_outcome),
    ("error handling: one classifier, a sink, and no raw exception on screen",
     check_error_handling_wiring),
    ("the components ARCHITECTURE.md names exist in the code, and vice versa",
     check_documented_components_exist),
    ("money/approval notifications: both parties, once, and never fatal to the payment",
     check_transaction_notifications),
    ("the Other document type is offered, stored, and displayed where it is reviewed",
     check_other_document_type_is_wired),
    ("the CEO account directory routes through the one deletion cascade",
     check_ceo_account_directory_is_wired),
    ("every image picker that feeds a storage bucket is downscaled before upload, "
     "so the bucket accepts it",
     check_payment_screenshots_are_downscaled),
    ("the bucket and money policies the client needs are in a migration the "
     "pipeline executes",
     check_client_write_policies_are_executable),
    ("a refused recharge names what is missing instead of borrowing the "
     "not-found sentence",
     check_recharge_refusals_name_the_real_cause),
    ("the provider gallery is still reachable from the provider dashboard",
     check_provider_gallery_is_wired),
    ("every role's quick-action shortcut shares one pill and still resolves",
     check_quick_action_shortcuts_are_wired),
    ("the gallery's READ path is in a migration the pipeline executes",
     check_gallery_read_path_is_migrated),
    ("every Edge Function field the client must send is actually sent",
     check_edge_function_required_fields_are_sent),
    ("the connectivity suite asks each RPC through a helper that fits it",
     check_test_helper_matches_return_type),
    ("an OAuth account can complete its profile, and no account menu row is dead",
     check_profile_completion_and_taps_are_wired),
    ("the router's redirect clauses still match the cycle simulation",
     check_router_matches_the_cycle_simulation),
    ("every admin sidebar card carries its own permission guard",
     check_admin_sidebar_cards_are_guarded),
    ("the GPS where-path resolves the nearest AREA, not just the city",
     check_nearest_area_is_wired),
    ("per-category and per-city fees are reachable from the admin sidebar",
     check_category_fees_are_wired),
    ("a permission flag read after the last setState reaches the widget",
     check_permission_flags_reach_the_widget),
    ("content control can take an image down and record why",
     check_content_control_is_wired),
    ("the admin RPC reachability report is transcribed from the Dart, not "
     "guessed",
     check_admin_rpc_argv_is_transcribed),
    ("the customer's ride RPC report is transcribed from the Dart and the "
     "Edge Functions, not guessed",
     check_customer_rpc_argv_is_transcribed),
    ("every order and every ride leaves a document both parties can read",
     check_transaction_documents_are_wired),
    ("staff creation stays in the sidebar, and a staff city stops something",
     check_staff_management_is_reachable),
    ("a staff member's rank, city and obligations are readable, not just stored",
     check_staff_roster_is_wired),
    ("a fee quoted to a human resolves exactly the way it is charged",
     check_quoted_fees_resolve_like_the_charge),
    ("a server refusal code reaches the user as a sentence",
     check_server_refusal_codes_reach_the_user),
    ("a provider may only work once verified, paid and funded",
     check_provider_fulfilment_gate_is_wired),
    ("every notification type written actually exists in the enum",
     check_notification_types_exist),
    ("the other side of an order or a ride is told, not left to poll",
     check_provider_is_told_about_work),
    ("a restatement cannot drop a fee switch another migration pinned",
     check_fee_switches_survive_restatement),
    ("a migration seeding a blanket-guarded table lifts the guard first",
     check_guarded_tables_are_lifted_at_migration_time),
    ("a dynamic GRANT/REVOKE only names signatures the file actually creates",
     check_dynamic_privileges_name_real_signatures),
    ("every RPC the app calls is executable by the role that calls it",
     check_client_rpcs_are_executable),
    ("every trade ranks its best and prices on its own terms (ranking + "
     "per-category fields reach end to end)",
     check_category_fields_are_wired),
    ("a submitted or resubmitted application tells the applicant and the "
     "reviewers, and a reactivation tells the person",
     check_registration_notifications_are_wired),
    ("a filed appeal reaches the dashboard, the badge, and the people who can "
     "act on it",
     check_appeal_notifications_reach_reviewers),
    ("one BUY/BOOK per listing from its own type, no provider control where "
     "buyers browse, photo-less listings private, and trending ranked by the "
     "last 7 days",
     check_one_action_per_listing_and_no_provider_control_where_buyers_browse),
    ("the Parts 1-8 registration rework is wired: server halves, client doors",
     check_registration_rework_is_wired),
    ("Parts 9-11: every notification also pushes, the delivery fee is the ride "
     "fare, and a sold listing is hidden rather than deleted",
     check_parts_9_to_11_are_wired),
    ("the payment step is its own screen with the platform account, the price "
     "the buyer writes and the proof upload, and a problem reaches the admin "
     "appeals queue from the transaction itself",
     check_payment_step_and_appeal_are_wired),
    ("the category rail ranks this week, an admin can add a category under a "
     "mother category, and the seeded test category is kept",
    # A lambda, and only because this check is defined below the registry it
    # is listed in. The name is resolved when the check RUNS, not when the list
    # is built, so the definition can sit with its siblings at the end of the
    # file where the newest check has always gone.
     lambda: check_category_tree_and_weekly_rank_are_wired()),
]


def check_category_tree_and_weekly_rank_are_wired() -> list[str]:
    """The category rail is about NOW, and an administrator can grow the tree.

    Two halves that only make sense together, because the ranking is the thing
    a new category is entering:

      1. `ranked_categories` leads with completed work in the LAST 7 DAYS,
         the same window `ranked_providers` ranks by since 20261011000001. A
         revert to career totals still returns rows and still looks ranked — it
         just never changes, which is how "the top categories" silently became
         "the categories that existed longest".
      2. `admin_create_category` exists, is admin-gated BEFORE it validates,
         refuses a mother category that is not top level, and hands the new
         row its mother's classification. The third one is not cosmetic:
         `categories.sector` and `marketplace_sector` are CHECK-constrained, so
         a row written without them does not insert at all.
      3. The door: the screen calls the RPC, the router registers the route and
         the dashboard pushes it. A server half with no door is how the
         per-category fee rates existed in the schema for months with no editor.
      4. The test category is seeded by the migration and is not deleted by a
         later one — it is KEPT, so the tree has something to look at.
    """
    problems: list[str] = []

    mig = MIGRATIONS / \
        "20261015000011_the_category_rank_is_this_week_too.sql"
    if not mig.is_file():
        return ["20261015000011...sql is missing — the category rail ranks by "
                "career totals (an ordering that never changes) and there is "
                "still no way to add a category from inside the app"]
    sql = _strip_comments(_read(mig))

    # 1. The window, on the body that WINS — a later restatement is the live
    #    definition, and judging a superseded copy is how a false green is born.
    target, src = last_migration_defining("ranked_categories")
    if target is None:
        problems.append("no migration defines public.ranked_categories()")
    else:
        body = function_body(src, "ranked_categories")
        for needle, why in (
            ("v_window",
             "ranked_categories has no weekly window — it ranks by career "
             "totals, so the same categories lead forever"),
            ("interval '7 days'",
             "the category rank is no longer a week, so it disagrees with "
             "ranked_providers about what 'this week' means"),
            ("o.updated_at >= now() - v_window",
             "the order half of the weekly key reads no completion time"),
            ("r.updated_at >= now() - v_window",
             "the ride half of the weekly key reads no completion time, so a "
             "category whose trade is rides never rises"),
            ("c.name ASC",
             "ranked_categories lost its stable tiebreak — an ordering the "
             "client cannot re-derive must keep one"),
        ):
            if needle not in body:
                problems.append("%s: %s" % (target.name, why))

    # 2. The write path.
    ctarget, csrc = last_migration_defining("admin_create_category")
    if ctarget is None:
        problems.append("no migration defines public.admin_create_category() — "
                        "a category can only be added by a deploy")
    else:
        body = function_body(csrc, "admin_create_category")
        low = body.lower()
        # SECURITY DEFINER sits in the header, ABOVE `AS $$`, so it is read
        # from the definition rather than from the body the extract below
        # returns -- a body-only search for it is a check that can never pass.
        # Scoped to THIS function's own header: the file defines several
        # functions, so a whole-file search would be satisfied by a neighbour.
        header = re.search(
            r"FUNCTION\s+public\.admin_create_category\b[\s\S]{0,400}?"
            r"SECURITY\s+DEFINER", src, re.IGNORECASE)
        if header is None:
            problems.append(
                "%s: admin_create_category is not SECURITY DEFINER, so it "
                "writes with the caller's rights and RLS refuses it"
                % ctarget.name)
        for needle, why in (
            ("insufficient_permission",
             "admin_create_category refuses nobody — any caller who can reach "
             "it can grow the category tree"),
            ("v_parent.parent_id is not null",
             "admin_create_category accepts a mother that is not top level, "
             "so a third level can appear where no screen shows it"),
            ("v_parent.sector",
             "admin_create_category no longer inherits the mother's sector, "
             "so the new row violates the column's CHECK constraint"),
            ("v_parent.marketplace_sector",
             "admin_create_category no longer inherits the mother's "
             "marketplace sector, so the fee model and BUY/BOOK rules cannot "
             "classify the new row"),
        ):
            if needle.lower() not in low:
                problems.append("%s: %s" % (ctarget.name, why))
        # The guard has to come FIRST. A function that validated before it
        # authenticated would answer "that slug is taken" for anyone who could
        # call it, which is a write oracle on the catalogue.
        guard = low.find("if not public.is_admin()")
        write = low.find("insert into public.categories")
        if guard < 0:
            problems.append("%s: admin_create_category has no is_admin() "
                            "guard at all" % ctarget.name)
        elif write >= 0 and guard > write:
            problems.append("%s: admin_create_category writes before it "
                            "checks who is calling" % ctarget.name)
        if "revoke all on function public.admin_create_category" not in sql.lower():
            problems.append("%s: admin_create_category is granted without "
                            "first revoking PUBLIC/anon, so the EXECUTE "
                            "privilege depends on the default" % mig.name)
        if not re.search(
                r"GRANT EXECUTE ON FUNCTION public\.admin_create_category\(uuid, text, text, text\)\s*\n\s*TO authenticated;",
                sql, re.IGNORECASE):
            problems.append("%s: admin_create_category is not granted to "
                            "authenticated, so an admin's own call is refused "
                            "by privilege rather than by the guard" % mig.name)

    # 3. The door.
    screen = LIB / "features" / "admin" / "admin_categories_screen.dart"
    if not screen.is_file():
        problems.append("lib/features/admin/admin_categories_screen.dart is "
                        "missing — the RPC exists with no way to call it")
    else:
        code = _dart_without_comments(_read(screen))
        for needle, why in (
            ("'admin_create_category'",
             "the screen no longer calls the RPC"),
            ("'p_parent_id'",
             "the screen no longer sends the mother category"),
            ("c['parent_id'] == null",
             "the mother picker no longer offers only top-level categories, so "
             "the form offers choices the server refuses"),
        ):
            if needle not in code:
                problems.append("admin_categories_screen.dart: %s" % why)
    router = _read(LIB / "routing" / "app_router.dart")
    if "/admin/categories" not in router:
        problems.append("app_router.dart does not register /admin/categories")
    if "AdminCategoriesScreen" not in router:
        problems.append("app_router.dart does not build AdminCategoriesScreen")
    dash = _read(LIB / "features" / "admin" / "admin_dashboard.dart")
    if "context.push('/admin/categories')" not in dash:
        problems.append("admin_dashboard.dart no longer offers the Categories "
                        "card, so the screen is unreachable from the admin's "
                        "own dashboard")

    # 4. The rail's client half, and the test category that is KEPT.
    home = _dart_without_comments(
        _read(LIB / "features" / "user" / "user_home_screen.dart"))
    for needle, why in (
        ("'ranked_categories'",
         "the home feed no longer reads the ranking that drives its rail"),
        ("_rankedCategories",
         "the home feed no longer holds the ranking"),
        ("context.push('/user/category/$id')",
         "a top category chip is no longer navigation — it decorates the rail "
         "without opening the category"),
    ):
        if needle not in home:
            problems.append("user_home_screen.dart: %s" % why)
    for path in migration_files():
        src = _read(path)
        if "test-category" in src and re.search(
                r"DELETE\s+FROM\s+(public\.)?categories[\s\S]{0,200}test-category",
                src, re.IGNORECASE):
            problems.append("%s deletes the seeded test category — it is KEPT "
                            "on purpose, so the tree has something to look at"
                            % path.name)
    if "'test-category'" not in sql:
        problems.append("%s does not seed the test category" % mig.name)

    return problems


def main() -> int:
    print("static harnesses (source-level: no Dart SDK, no Deno, no credentials)")
    print(f"  repo: {ROOT}")
    print(f"  {len(migration_files())} migrations, "
          f"{len(list(FUNCTIONS.glob('*/index.ts')))} edge functions, "
          f"{len(dart_sources())} dart files")
    print()

    failed = 0
    for label, fn in CHECKS:
        problems = fn()
        if problems:
            failed += 1
            print(f"[FAIL] {label}")
            for problem in problems:
                print(f"         - {problem}")
        else:
            print(f"[PASS] {label}")

    print()
    if failed:
        print(f"HARNESSES FAILED ({failed} of {len(CHECKS)})")
        return 1
    print(f"ALL HARNESSES PASS ({len(CHECKS)} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
