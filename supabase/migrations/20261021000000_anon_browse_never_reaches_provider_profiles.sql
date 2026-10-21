-- =============================================================================
-- 20261021000000 — Anon browse never reaches provider_profiles
--
-- ROOT CAUSE (found by the post-deploy Connectivity CI run after
-- 20261020000001 landed): anon now holds every GRANT the guest-browse
-- assertion checks, the gallery RPC runs, the declaration assertion passes —
-- and still `SELECT id, product_images(id) FROM products WHERE is_active`
-- as anon answers 42501 "permission denied for table provider_profiles"
-- (run 39680798914, test "the fatal home-feed tables are readable by anon").
-- The guest home feed therefore still lands on the error screen.
--
-- WHY THIS LOOKS IMPOSSIBLE FROM THE REPO: every file in supabase/migrations
-- agrees the surface cannot reach provider_profiles as anon —
--   * categories_public_read = is_active OR is_admin()   (0022b)
--   * products_public_read    = is_active OR owns_provider_profile() OR
--                               is_admin()               (20261016000001)
--   * product_images_read     = EXISTS (products ...)    (0022/0022b)
--   * owns_provider_profile / is_admin are SECURITY DEFINER in every
--     definition the repo ships (0011, 0014-era, 0021 snapshot, 0022, 0022b,
--     20261007000014), so their bodies run as the owner, never as anon.
-- So the LIVE catalog disagrees with the repo. That is possible because the
-- pre-baseline migrations were recorded in schema_migrations WITHOUT being
-- executed (their effects were pasted via the SQL editor), so live policy
-- text and function attributes come from the last paste, not from file order.
-- Two drifts produce exactly the observed reply:
--   1. owns_provider_profile live as SECURITY INVOKER — the products policy
--      arm then runs its `SELECT ... FROM provider_profiles` AS ANON; or
--   2. a live policy still carrying an inline
--      `EXISTS (SELECT 1 FROM provider_profiles ...)` arm (the pattern the
--      gallery/store policies still use for authenticated callers, which
--      works there only because authenticated retains table SELECT).
-- Either way the caller is anon and the object is provider_profiles —
-- the error message cannot say which, and the repo cannot reproduce it.
--
-- THE FIX: restate the surface from the repo's latest definitions. Each
-- statement is a no-op where live already agrees and the repair where it
-- drifted. Row visibility is UNCHANGED — the USING arms are semantically the
-- ones the repo already ships; this widens nobody and grants anon nothing on
-- provider_profiles (the base table keeps owner_national_id and friends;
-- public_provider_profiles exists so nobody needs it).
--
-- THE ASSERTION (v2) makes the two drift classes checkable by NAME:
--   * SECURITY DEFINER on both policy helpers (pg_proc.prosecdef), and
--   * no `provider_profiles` text inside the three read policies
--     (pg_get_expr), so an inline subquery can never hide behind a passing
--     behavior test again.
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The helpers, re-asserted as SECURITY DEFINER with a pinned search_path.
--    Body identical to 0011 / 0021 / 0022 / 0022b — for anon, auth.uid() IS
--    NULL, so owns_provider_profile answers FALSE and reveals nothing.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.owns_provider_profile(p_provider_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT exists (
    SELECT 1 FROM provider_profiles
    WHERE id = p_provider_id AND user_id = auth.uid()
  );
$$;

COMMENT ON FUNCTION public.owns_provider_profile(uuid) IS
  'True when the row belongs to the caller. SECURITY DEFINER (re-asserted by '
  '20261021000000): the products/product_images policies call it while '
  'evaluating for anon, and an INVOKER version selects provider_profiles as '
  'the caller — which anon has no privilege on, failing the guest home feed '
  'with 42501.';

-- ---------------------------------------------------------------------------
-- 2. The three read policies, restated from the repo's latest definitions.
--    Same USING semantics as shipped — this repairs drift, it changes no
--    visibility.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS categories_public_read ON public.categories;
CREATE POLICY categories_public_read ON public.categories
  FOR SELECT
  USING (is_active = true OR is_admin());

COMMENT ON POLICY categories_public_read ON public.categories IS
  'A guest sees active categories (0022b, re-stated by 20261021000000). '
  'is_admin() is SECURITY DEFINER, so evaluating it never reaches a table '
  'the caller lacks privilege on.';

DROP POLICY IF EXISTS products_public_read ON public.products;
CREATE POLICY products_public_read ON public.products
  FOR SELECT
  USING (
    is_active = true
    OR owns_provider_profile(provider_id)
    OR is_admin()
  );

COMMENT ON POLICY products_public_read ON public.products IS
  'A buyer sees an active listing (20261016000001''s text, re-stated by '
  '20261021000000). Both helpers are SECURITY DEFINER, so the policy never '
  'selects provider_profiles as anon.';

DROP POLICY IF EXISTS product_images_read ON public.product_images;
CREATE POLICY product_images_read ON public.product_images
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM products p
      WHERE p.id = product_id
        AND (p.is_active = true
             OR owns_provider_profile(p.provider_id)
             OR is_admin())
    )
  );

COMMENT ON POLICY product_images_read ON public.product_images IS
  'Images of a visible listing (0022/0022b text, re-stated by '
  '20261021000000). The nested products policy evaluates with the same '
  'SECURITY DEFINER helpers — no inline provider_profiles.';

-- ---------------------------------------------------------------------------
-- 3. The assertion, v2: the grants PLUS the two drift classes it could not
--    see before.
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
    'is_admin()',
    'visible_gallery_for_city(text, integer)'
  ] LOOP
    IF NOT has_function_privilege(
      'anon', 'public.' || v_fn, 'EXECUTE'
    ) THEN
      v_missing := v_missing ||
        ('anon has no EXECUTE on public.' || v_fn)::text;
    END IF;
  END LOOP;

  -- Drift class 1: a helper that lost SECURITY DEFINER runs its body AS the
  -- caller, and the caller here is anon reaching provider_profiles. This is
  -- the check whose absence let run 39680798914 fail with every GRANT green.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'owns_provider_profile'
      AND p.prosecdef
  ) THEN
    v_missing := v_missing ||
      'owns_provider_profile is not SECURITY DEFINER (the products policy '
      'selects provider_profiles as anon)'::text;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'is_admin'
      AND p.prosecdef
  ) THEN
    v_missing := v_missing ||
      'is_admin is not SECURITY DEFINER (its has_role arm runs as anon)'
      ::text;
  END IF;

  -- Drift class 2: an inline provider_profiles subquery inside a read
  -- policy. Function-call arms never spell "provider_profiles" in the
  -- policy text, so the match is exact. Named policies only: other policies
  -- on these tables (admin/owner writes) are not the browse surface.
  FOR v_pol IN
    SELECT pol.polname,
           pg_get_expr(pol.polqual, pol.polrelid) AS qual
      FROM pg_policy pol
     WHERE pol.polrelid = ANY (ARRAY[
             'public.categories'::regclass,
             'public.products'::regclass,
             'public.product_images'::regclass
           ])
       AND pol.polcmd IN ('r', '*')
       AND pol.polname IN (
         'categories_public_read', 'products_public_read',
         'product_images_read'
       )
  LOOP
    IF v_pol.qual ILIKE '%provider_profiles%' THEN
      v_missing := v_missing ||
        ('policy ' || v_pol.polname || ' reaches provider_profiles inline, '
         || 'so anon is denied while evaluating it: ' || v_pol.qual)::text;
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION 'guest browse surface is not readable by anon: %',
      array_to_string(v_missing, '; ')
      USING ERRCODE = 'check_violation',
            DETAIL  = '20261021000000',
            HINT    = 'The guest home feed reads these directly; a missing '
                   || 'grant, a helper that lost SECURITY DEFINER, or an '
                   || 'inline provider_profiles arm turns into the error '
                   || 'screen.';
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_guest_browse_surface_is_readable() IS
  'True when the guest browse surface is readable by anon AND cannot reach '
  'provider_profiles as anon (20261020000001 grants, 20261021000000 helper '
  'and policy drift). A false result means guests get the error screen: RLS '
  'never runs without the table GRANT, and a policy arm that selects '
  'provider_profiles as the caller fails the whole query with 42501.';

-- Zero-argument assertion: executable by every client role (the rule from
-- 20261007000008 / 0011's reachability walk).
GRANT EXECUTE ON FUNCTION public.assert_guest_browse_surface_is_readable()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
