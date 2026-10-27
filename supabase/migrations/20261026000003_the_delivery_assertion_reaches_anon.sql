-- =============================================================================
-- 20261026000003_the_delivery_assertion_reaches_anon.sql
-- =============================================================================
--
-- WHY THIS FILE EXISTS
--
-- The connectivity suite runs as the `anon` role: SupabaseClient is built from
-- the anon key with no session, and every check in
-- tools/integration_test/connectivity_test.dart calls an assertion RPC by name.
-- Migration 20260927000091 turns that into a single, whole-family guard:
-- assert_every_assertion_is_reachable() walks every zero-argument `assert_*`
-- function in `public` and returns a FAIL string if any of them is not
-- executable by anon — because PostgREST reports such a function as PGRST202
-- "could not find the function ... in the schema cache", which reads like a
-- missing migration instead of a missing privilege.
--
-- `20261026000001_delivery_pricing_is_base_plus_distance.sql`, applied on the
-- live database, restated public.assert_delivery_fee_reuses_the_ride_fare()
-- with
--
--     REVOKE ALL ON FUNCTION public.assert_delivery_fee_reuses_the_ride_fare()
--       FROM public, anon;
--     GRANT EXECUTE ON FUNCTION public.assert_delivery_fee_reuses_the_ride_fare()
--       TO authenticated, service_role;
--
-- The definition it replaced (20261015000002, also applied) had granted
-- `TO anon, authenticated, service_role`. So the restatement — whose stated
-- purpose was the fee body — also dropped anon, exactly the mistake
-- 20260927000091 and 20261007000008 exist to catch.
--
-- Nothing in the client path noticed: the app never calls an `assert_*`, so
-- "every RPC the app calls is executable by the role that calls it" stayed
-- green and the deploy reported success. It surfaced one run later as
-- Connectivity CI red with 118 tests passed, 1 failed:
--
--     FAIL: the connectivity suite runs as the anon role ... but these
--     assertion functions are not executable by it:
--     assert_delivery_fee_reuses_the_ride_fare.
--
-- WHY A NEW FILE AND NOT AN EDIT
--
-- An applied migration is not edited here. A missing GRANT is runtime state any
-- later migration can repair, which is the same reasoning 20261007000008 gives
-- for putting its grants in a file of its own.
--
-- WHY THE FAMILY CHECK IS REPEATED AT THE END
--
-- The check in 20260927000091 and 20261007000008 lives inside a DO block, so it
-- ran once, at its own deploy. Nothing re-ran it after 20261026000001 — which
-- is precisely how a narrowed grant reached the live database while the deploy
-- reported success. Repeating it here means this shape of regression fails the
-- deploy that introduces it rather than the connectivity run that follows it.
--
-- SAFETY: assert_delivery_fee_reuses_the_ride_fare() is STABLE, SECURITY
-- DEFINER, reads the catalog and returns text; it writes nothing. Callable by
-- anon is the contract the rest of the zero-argument assertion family already
-- meets. Nothing here widens a write path.
--
-- Idempotent: GRANT is a no-op when the privilege is already held, and the
-- guard below only reads the catalog.

GRANT EXECUTE ON FUNCTION public.assert_delivery_fee_reuses_the_ride_fare()
  TO anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- The same check assert_every_assertion_is_reachable() runs, run here at deploy
-- time so an unreachable assertion fails the deploy that introduced it rather
-- than the connectivity run that follows it. Mirrors that function exactly:
-- zero-argument `assert_*` in the public schema, `has_function_privilege` for
-- anon on the no-argument signature.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_name text;
  v_missing text := '';
  v_count integer := 0;
BEGIN
  FOR v_name IN
    SELECT p.proname
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname LIKE 'assert\_%'
       AND p.pronargs = 0
     ORDER BY p.proname
  LOOP
    v_count := v_count + 1;
    IF NOT has_function_privilege('anon',
         format('public.%I()', v_name), 'EXECUTE') THEN
      v_missing := v_missing || v_name || ', ';
    END IF;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION
      'ASSERTION_FAMILY_EMPTY: no zero-argument assert_* function exists, so '
      'the connectivity suite has nothing to run and the grant above proves '
      'nothing';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION
      'ASSERTION_NOT_REACHABLE_BY_ANON: the connectivity suite runs as anon, '
      'but these assertion functions are not executable by it: %. A function '
      'hidden from anon is reported by PostgREST as PGRST202 "could not find '
      'the function in the schema cache" — it reads like a missing migration '
      'and is not. GRANT EXECUTE ... TO anon, authenticated, service_role.',
      rtrim(v_missing, ', ');
  END IF;

  IF NOT has_function_privilege('anon',
       'public.assert_delivery_fee_reuses_the_ride_fare()', 'EXECUTE') THEN
    RAISE EXCEPTION
      '20261026000003: the grant above did not reach anon';
  END IF;

  RAISE NOTICE 'all % zero-argument assert_* functions are executable by anon',
    v_count;
END
$$;

NOTIFY pgrst, 'reload schema';
