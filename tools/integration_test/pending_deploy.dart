// tools/integration_test/pending_deploy.dart
//
// The rule that decides whether a failed live connectivity call is
//
//   * PENDING DEPLOY — the migration that creates the function has not reached
//     the live database yet, or
//   * a REAL FINDING — anything else, which must fail the run.
//
// Two conditions are required here, not one, and the difference matters: an
// earlier version of this rule only checked that the function's newest
// definition sat past supabase/DEPLOYED_HEAD. That marker is written by hand
// after a deploy succeeds, so after a deploy that applied migrations and then
// failed it went stale — the functions existed on the live database, the calls
// failed for ordinary reasons (a sentinel rollback, PRODUCT_NOT_FOUND, a wrong
// row count), and every one of them was relabelled "PENDING DEPLOY" and passed.
// A safety net that converts real failures into skips is worse than no safety
// net.
//
// So a call is tolerated only when ALL THREE hold:
//   1. the reply is PostgREST's "could not find the function" (PGRST202),
//   2. the name is defined only by a migration past the applied head, and
//   3. the live database confirms the function really is absent.
//
// Condition 1 alone would hide a missing GRANT on a deployed function (PostgREST
// answers PGRST202 for both). Condition 2 alone hides every other error — that
// is the version that produced the stale-marker run above. Condition 3 is the
// one that makes a stale [deployedHeadFile] harmless: it asks the database
// itself, through the same PostgREST surface the suite uses, via the
// `pg_func_exists(p_fn_name)` probe migration 20261007000008 adds. It lives in
// connectivity_test.dart rather than here because it needs the SupabaseClient,
// and it returns `null` (not `false`) when the probe cannot be answered, so an
// unavailable probe is never mistaken for proof of absence.
//
// Together the three hide only the one case that is genuinely not a defect yet,
// and the grant class stays covered by assert_every_assertion_is_reachable(),
// which returns a FAIL string rather than throwing.
//
// The read side is `dart:io` against the working tree: flutter test runs from
// the package root, where supabase/DEPLOYED_HEAD and supabase/migrations live.

import 'dart:io';

/// The migration the live database has actually applied. Written by hand after
/// a deploy log reports `Applying migration <name>` (ARCHITECTURE.md 7.5 step 6).
const deployedHeadFile = 'supabase/DEPLOYED_HEAD';

const migrationsDir = 'supabase/migrations';

final RegExp functionDefinitionPattern = RegExp(
    r'CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?([a-z_][a-z0-9_]*)',
    caseSensitive: false);

/// Function names defined only by migrations newer than the applied head.
///
/// Empty when the boundary cannot be read, which restores the old strict
/// behaviour rather than inventing a tolerance.
Set<String> readPendingDeployFunctions({
  String headPath = deployedHeadFile,
  String migrationsPath = migrationsDir,
}) {
  try {
    final head = File(headPath).readAsStringSync().trim();
    if (head.isEmpty) return const <String>{};
    final files = Directory(migrationsPath)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.sql'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final headIndex = files.indexWhere((f) => f.path.endsWith(head));
    if (headIndex < 0) return const <String>{};
    Set<String> definedBy(Iterable<File> fs) => fs
        .expand((f) => functionDefinitionPattern.allMatches(f.readAsStringSync()))
        .map((m) => m.group(1)!)
        .toSet();
    return definedBy(files.skip(headIndex + 1))
        .difference(definedBy(files.take(headIndex + 1)));
  } catch (_) {
    return const <String>{};
  }
}

/// PostgREST's reply when the schema cache has no such function for the calling
/// role — and only that reply. Any exception carrying a SQLSTATE, an RPC error
/// name (`PRODUCT_NOT_FOUND`, `RIDE_ALREADY_TAKEN`, …), or a plain message is a
/// finding about the database, not about a missing migration.
bool isMissingFunctionError(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('could not find the function')) return true;
  if (text.contains('pgrst202')) return true;
  // The dart client can surface the bare server body instead of a code.
  if (text.contains('function public.') && text.contains('does not exist')) {
    return true;
  }
  return false;
}

/// PostgREST's reply when the calling role holds no privilege on the object
/// it reached for — SQLSTATE 42501 "permission denied" — and only that.
///
/// The read-side twin of [isMissingFunctionError]: a direct table read the
/// caller's role cannot start (guest browsing reads `categories`/`products`
/// as anon — 20261020000001 grants them) fails with 42501 before RLS is ever
/// consulted. A denied FUNCTION call raises the same code through PostgREST's
/// "could not find the function" shape, which [isMissingFunctionError]
/// already covers. Any other shape — a policy error, a body error such as
/// PRODUCT_NOT_FOUND, a null row — is a finding, never a pending grant.
bool isPermissionDeniedError(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('42501')) return true;
  return text.contains('permission denied');
}

/// Conditions 1 and 2 of the tolerance: the name is one the repo proves is not
/// deployed, and the server reported it as not present. Condition 3 — the live
/// database agreeing — is checked by the caller, which holds the client.
bool isPendingDeploy(
  Object error,
  String fn,
  Set<String> pendingDeployFunctions,
) =>
    pendingDeployFunctions.contains(fn) && isMissingFunctionError(error);

/// The value a text/report helper returns for a pending function: non-null so a
/// caller's `isNotNull` passes, and never starting with `FAIL`, so it cannot be
/// mistaken for a finding.
String pendingDeployNotice(String fn) => 'PENDING DEPLOY: $fn';
