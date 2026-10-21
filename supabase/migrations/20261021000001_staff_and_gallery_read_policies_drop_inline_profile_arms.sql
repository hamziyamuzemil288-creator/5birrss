-- =============================================================================
-- 20261021000001 — The staff and gallery read policies stop reaching
--                   provider_profiles inline
--
-- ROOT CAUSE, finally in the open (Connectivity CI #21, run 39685981264,
-- which named it: `the guest read of products with its product_images embed
-- was refused` — categories passed, the products read died):
--
-- RLS OR's every PERMISSIVE policy for the command being run, and may
-- evaluate any of them for any row. products carries a SECOND permissive
-- SELECT policy next to products_public_read:
--
--     products_staff_reports_read (20260922000012)
--       ... OR provider_id IN (SELECT id FROM provider_profiles
--                              WHERE user_id = auth.uid()) ...
--
-- That subquery runs AS THE CALLING ROLE. For authenticated that is fine —
-- authenticated keeps table SELECT on provider_profiles. For anon it is
-- 42501 "permission denied for table provider_profiles", raised while
-- evaluating a policy the row would never have needed, killing the whole
-- products query AND the product_images embed (whose own policy re-enters
-- products). 20261020000001 and 20261021000000 were both green on grants,
-- helper definer-ness and the three NAMED browse policies — the name filter
-- was the blind spot: an unnamed permissive policy poisons the read just the
-- same.
--
-- The same class sits on provider_gallery, which the app reads DIRECTLY as
-- a guest in two places (user_home_screen avatar fallback, line ~498;
-- user_provider_detail_screen gallery, line ~87 — both caught, so guests
-- silently see NO gallery photos rather than an error). Both of its
-- permissive SELECT policies (20260927000104) carry inline
-- `FROM public.provider_profiles` arms.
--
-- WHY THE ARMS ARE REWRITTEN THIS WAY (semantics are IDENTICAL):
--   * provider_id IN (SELECT id FROM provider_profiles WHERE user_id = auth.uid())
--       == owns_provider_profile(provider_id)          -- same predicate
--   * EXISTS (SELECT 1 FROM provider_profiles WHERE id = provider_id
--             AND status = 'APPROVED')
--       == is_approved_provider(provider_id)           -- NEW helper below
-- Both helpers are SECURITY DEFINER, so evaluation happens as the owner and
-- anon never needs a privilege on provider_profiles. anon gains NOTHING on
-- the base table; no row becomes visible that was not visible before.
--
-- NOT in scope: ride_requests_staff_reports_read carries the same inline arm,
-- but anon never reads ride_requests (the ride request flow is behind
-- authentication), so it is not part of the guest surface.
--
-- THE ASSERTION (v3) fixes the blind spot itself: instead of naming three
-- policies, it scans EVERY permissive SELECT-capable policy on all five
-- tables anon is granted, so an unnamed or pasted-in policy is caught by
-- name AND quoted expression, whatever it is called.
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The products staff arm, as a helper call.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS products_staff_reports_read ON public.products;
CREATE POLICY products_staff_reports_read ON public.products
  FOR SELECT
  USING (
    public.is_admin()
    OR public.owns_provider_profile(provider_id)
    OR (
      public.staff_has_permission(auth.uid(), 'view_reports')
      AND public.staff_scope_allows_category(category_id)
    )
  );

COMMENT ON POLICY products_staff_reports_read ON public.products IS
  'Staff/CEO report rows, plus the provider''s own rows (20260922000012, '
  'arms rewritten by 20261021000001). The owner arm used to be an inline '
  'provider_profiles subquery, which RLS evaluates as the CALLER — for anon '
  'that is 42501 on provider_profiles and the entire guest products read '
  'dies even though products_public_read would allow every row. '
  'owns_provider_profile() is SECURITY DEFINER and expresses the identical '
  'predicate; staff_has_permission() and staff_scope_allows_category() are '
  'SECURITY DEFINER too (verified in 20260922000012), so every arm of this '
  'policy is callable as anon.';

-- ---------------------------------------------------------------------------
-- 2. The helper the gallery policy needs, so its APPROVED check stops being
--    an inline subquery. For anon (auth.uid() NULL) the owner read answers
--    FALSE; for a guest this answers only whether the named provider is
--    approved — public information the gallery row already implies.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_approved_provider(p_provider_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM provider_profiles
    WHERE id = p_provider_id AND status = 'APPROVED'
  );
$$;

COMMENT ON FUNCTION public.is_approved_provider(uuid) IS
  'True when the provider is APPROVED. SECURITY DEFINER (20261021000001): '
  'provider_gallery''s public-read policy calls it while evaluating for '
  'anon, and an inline subquery on provider_profiles would deny anon with '
  '42501 the moment the policy is evaluated.';

GRANT EXECUTE ON FUNCTION public.is_approved_provider(uuid)
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. The gallery read policies, helper arms (20260927000104's semantics).
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS provider_gallery_public_read ON public.provider_gallery;
CREATE POLICY provider_gallery_public_read ON public.provider_gallery
  FOR SELECT
  USING (
    is_active = true
    AND public.is_approved_provider(provider_id)
  );

COMMENT ON POLICY provider_gallery_public_read ON public.provider_gallery IS
  'Active photos of an APPROVED provider (20260927000104''s semantics, arms '
  'rewritten by 20261021000001 from an inline provider_profiles subquery to '
  'a SECURITY DEFINER helper — the inline form denies anon with 42501 when '
  'RLS evaluates it, which emptied the guest gallery surface despite '
  '20261020000001''s table GRANT).';

DROP POLICY IF EXISTS provider_gallery_owner_read ON public.provider_gallery;
CREATE POLICY provider_gallery_owner_read ON public.provider_gallery
  FOR SELECT
  USING (
    public.owns_provider_profile(provider_id)
  );

COMMENT ON POLICY provider_gallery_owner_read ON public.provider_gallery IS
  'The provider sees their own photos, active or not (20260927000104''s '
  'semantics via owns_provider_profile(), 20261021000001). SECURITY DEFINER '
  'so evaluating it for anon cannot reach provider_profiles.';

-- ---------------------------------------------------------------------------
-- 4. The assertion, v3: scan EVERY permissive SELECT policy on the granted
--    surface, not three chosen names. The chosen-names filter is exactly
--    what let products_staff_reports_read poison the read while the
--    assertion stayed green (run 39685981264).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_guest_browse_surface_is_readable()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_missing text[] := '{}'::text[];
  v_table text;
  v_fn text;
  v_pol record;
BEGIN
  -- Table grants: without SELECT the query cannot start at all.
  FOREACH v_table IN ARRAY ARRAY[
    'categories', 'products', 'product_images', 'provider_gallery',
    'provider_trust_stats'
  ] LOOP
    IF NOT has_table_privilege('anon', 'public.' || v_table, 'SELECT') THEN
      v_missing := v_missing ||
        ('anon has no SELECT on public.' || v_table)::text;
    END IF;
  END LOOP;

  -- EXECUTE: a policy arm anon cannot invoke fails the whole query too.
  FOREACH v_fn IN ARRAY ARRAY[
    'owns_provider_profile(uuid)',
    'is_approved_provider(uuid)',
    'is_admin()',
    'staff_has_permission(uuid, text)',
    'staff_scope_allows_category(uuid, uuid)',
    'visible_gallery_for_city(text, integer)'
  ] LOOP
    IF NOT has_function_privilege(
      'anon', 'public.' || v_fn, 'EXECUTE'
    ) THEN
      v_missing := v_missing ||
        ('anon has no EXECUTE on public.' || v_fn)::text;
    END IF;
  END LOOP;

  -- Helpers whose bodies read provider_profiles must be SECURITY DEFINER,
  -- or their bodies run as anon and hit the table it has no privilege on.
  -- This is the check whose absence let run 39680798914 pass its grants and
  -- still fail the read.
  FOREACH v_fn IN ARRAY ARRAY[
    'owns_provider_profile', 'is_approved_provider', 'is_admin',
    'staff_has_permission', 'staff_scope_allows_category'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname = v_fn
        AND p.prosecdef
    ) THEN
      v_missing := v_missing ||
        ('public.' || v_fn || ' is not SECURITY DEFINER — a browse policy '
         || 'calls it while evaluating as anon, and its body would run as '
         || 'anon')::text;
    END IF;
  END LOOP;

  -- The scan that replaces the name filter: EVERY permissive policy that
  -- can run for a SELECT (FOR SELECT and FOR ALL) on the five granted
  -- tables, quoted in full so the failure says which policy and what text.
  -- Function-call arms never spell "provider_profiles" in the policy text,
  -- so the match is exact. Live-only or renamed policies are caught too —
  -- that is the entire point of v3.
  FOR v_pol IN
    SELECT n.nspname AS schema,
           c.relname AS table_name,
           pol.polname,
           pg_get_expr(pol.polqual, pol.polrelid) AS qual
      FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname = ANY (ARRAY[
             'categories', 'products', 'product_images', 'provider_gallery',
             'provider_trust_stats'
           ])
       AND pol.polcmd IN ('r', '*')
  LOOP
    IF v_pol.qual ILIKE '%provider_profiles%' THEN
      v_missing := v_missing ||
        ('permissive SELECT policy ' || v_pol.table_name || '.'
         || v_pol.polname || ' reaches provider_profiles inline, so anon is '
         || 'denied while RLS evaluates it: ' || v_pol.qual)::text;
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION 'guest browse surface is not readable by anon: %',
      array_to_string(v_missing, '; ')
      USING ERRCODE = 'check_violation',
            DETAIL  = '20261021000001',
            HINT    = 'The guest home feed reads these directly; a missing '
                   || 'grant, a helper that lost SECURITY DEFINER, an '
                   || 'inline provider_profiles arm, or an unnamed '
                   || 'permissive policy turns into the error screen.';
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_guest_browse_surface_is_readable() IS
  'True when the guest browse surface is readable by anon AND cannot reach '
  'provider_profiles as anon: grants present (20261020000001), helpers are '
  'SECURITY DEFINER (20261021000000/20261021000001), and NO permissive '
  'SELECT policy on the five granted tables carries an inline '
  'provider_profiles arm (20261021000001 — the scan that replaces '
  '20261021000000''s three-name filter, which missed '
  'products_staff_reports_read).';

-- Zero-argument assertion: executable by every client role (the rule from
-- 20261007000008 / 0011's reachability walk).
GRANT EXECUTE ON FUNCTION public.assert_guest_browse_surface_is_readable()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
