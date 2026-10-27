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
-- THE SAME RESTATEMENT ALSO BROKE THE BODY
--
-- The grant was not the only thing 20261026000001 got wrong in that function.
-- Its predecessor (20261015000002) flattened bodies with `E'\\s+'`, which is
-- the pattern `\s+`. The restatement wrote `E'\s+'` in all five SELECTs, and an
-- unrecognised escape is taken LITERALLY (PostgreSQL 18, §4.1.2.2), so the
-- pattern became `s+` -- every run of the letter `s` replaced by a space, in
-- the body text the needles are then searched for. Every needle in that
-- function contains an `s` (`calculate_fare_estimate_at`,
-- `platform_display_markup`, ...), so the function returns a FAIL string that
-- describes the regex, not the delivery fee.
--
-- Restoring the grant without this would make a broken function reachable
-- again: before 20261026000001 it was both correct and callable. So the body
-- is restated here and only the five broken lines change.
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

-- -----------------------------------------------------------------------------
-- The body, restated with the escaping defect gone. Only the five
-- `regexp_replace` lines differ from 20261026000001's version; everything else
-- is a verbatim copy of the predecessor, so this cannot quietly change what the
-- assertion checks.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_delivery_fee_reuses_the_ride_fare()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_delivery text;
  v_quote text;
  v_markup text;
  v_column text;
  v_ride text;
  v_per_km text;
BEGIN
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_delivery
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'calculate_delivery_fee_at';

  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_quote
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'quote_delivery_fee';

  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_markup
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'platform_display_markup';

  -- The ride context: untouched by this migration, and it must still be there.
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_ride
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_ride_request';

  -- The shared per-km resolver: the ONE store of per-vehicle rates.
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_per_km
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'fee_ride_per_km';

  SELECT pg_get_expr(d.adbin, d.adrelid) INTO v_column
    FROM pg_attribute a
    JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
   WHERE a.attrelid = 'public.products'::regclass
     AND a.attname = 'display_price';

  IF v_delivery IS NULL OR v_quote IS NULL OR v_markup IS NULL THEN
    RETURN 'FAIL: the delivery quote, the delivery price or the markup function is missing';
  END IF;

  -- 1. The delivery price is base + per-km x distance, read from the platform
  --    stores — not a private formula and not the ride fare with a floor.
  IF position('delivery_base_fee' in v_delivery) = 0
     OR position('fee_ride_per_km' in v_delivery) = 0 THEN
    RETURN 'FAIL: calculate_delivery_fee_at no longer prices delivery_base_fee + fee_ride_per_km x distance';
  END IF;

  -- 2. The preview the buyer sees goes through the same chain, AND applies the
  --    cap, so a checkout can never quote a delivery the charge would refuse.
  IF position('delivery_base_fee' in v_quote) = 0
     OR position('fee_ride_per_km' in v_quote) = 0 THEN
    RETURN 'FAIL: quote_delivery_fee no longer prices through delivery_base_fee + fee_ride_per_km, so the quoted delivery price is not the charged one';
  END IF;

  IF position('max_delivery_distance_km' in v_quote) = 0
     OR position('beyond_max_distance' in v_quote) = 0 THEN
    RETURN 'FAIL: quote_delivery_fee lost the maximum-distance cap, so a delivery too far away is still offered';
  END IF;

  -- 3. The product markup must be untouched: this migration removed it from
  --    the DELIVERY price, which is not a licence to move it.
  IF position('+ 5 +' in v_markup) = 0 OR position('* 0.019' in v_markup) = 0 THEN
    RETURN 'FAIL: platform_display_markup no longer computes amount + 5 + amount * 0.019';
  END IF;

  IF v_column IS NULL OR position('platform_display_markup' in lower(v_column)) = 0 THEN
    RETURN 'FAIL: products.display_price is generated from something other than platform_display_markup (column expression: %)';
  END IF;

  -- 4. The ride side must still be standing, and the per-km resolver it reads
  --    must still be the one delivery now reads too.
  IF v_ride IS NULL OR position('calculate_fare_estimate_at' in v_ride) = 0 THEN
    RETURN 'FAIL: create_ride_request no longer charges through calculate_fare_estimate_at';
  END IF;

  IF v_per_km IS NULL THEN
    RETURN 'FAIL: fee_ride_per_km is missing, so neither rides nor deliveries have a per-km rate';
  END IF;

  RETURN 'ok: delivery prices delivery_base_fee + fee_ride_per_km x distance with a max-distance cap, the product markup is untouched, and the ride fare still resolves through calculate_fare_estimate_at';
END;
$$;

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
