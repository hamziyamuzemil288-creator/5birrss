-- =============================================================================
-- 20261020000001 — The guest browse surface is readable by anon
--
-- ROOT CAUSE: commit e724344 ("guest marketplace, read-only member areas")
-- lets a visitor browse the marketplace before registering, and the guest
-- home feed reads the catalogue DIRECTLY as anon:
--
--     client.from('categories').select()            <- fatal, no try/catch
--     client.from('products').select('*, product_images(*)')  <- fatal
--     client.rpc('visible_gallery_for_city', ...)   <- best-effort
--     client.rpc('ranked_providers' / 'ranked_categories')
--
-- Both fatal reads sit inside withRetry(); when the server answers 42501
-- ("permission denied") the whole load fails and the guest lands on the
-- home screen's error box instead of a marketplace. Two separate grants
-- can produce that 42501:
--
--  1. TABLE PRIVILEGES. 0011 revoked ALL table privileges from anon across
--     public (a server-role-shaped default), and nothing after it re-granted
--     anon the catalogue tables the guest reads directly. RLS policies
--     (categories_public_read, products_public_read, product_images_read,
--     provider_gallery_public_read) are what should decide which ROWS a
--     guest sees — but a policy is only consulted after the table-level
--     GRANT lets the query start. Without SELECT the policy never runs and
--     the query fails outright.
--
--  2. FUNCTION PRIVILEGES. products_public_read and product_images_read both
--     call owns_provider_profile(), and the gallery rail calls
--     visible_gallery_for_city(). 0011 / 20261010000002 revoked anon from
--     those functions. Whether the policy arm can still evaluate for anon
--     (PUBLIC inheritance) is an accident of default ACLs, not a decision —
--     so this migration makes it a decision: anon gets EXECUTE on exactly
--     the helpers the browse policies call.
--
-- WHAT ANON ACTUALLY SEES (unchanged — this migration widens no policy):
--   * categories: active rows only (categories_public_read).
--   * products: is_active = true (products_public_read as restated by the
--     pending 20261016000001), plus the owner/admin arms which are FALSE
--     for anon because auth.uid() is NULL.
--   * product_images: rows whose product is visible (product_images_read).
--   * provider_gallery: is_active and APPROVED owner
--     (provider_gallery_public_read / visible_gallery_for_city).
--   * owns_provider_profile(auth.uid()): NULL uid matches no profile —
--     the SECURITY DEFINER function answering FALSE for a guest, which is
--     exactly what the policy wants from it.
--
-- NOT granted here: provider_profiles. The guest's profile-photo fallback
-- read is best-effort (a caught failure renders the placeholder), and the
-- base table carries owner_national_id and friends — public_provider_profiles
-- exists precisely so nobody needs the base table.
--
-- Idempotent by nature: GRANT on an existing privilege is a no-op, and the
-- zero-argument assertion is executable by anon (0011's every-assertion
-- rule / 20261007000008).
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The tables the guest home feed and product pages read directly.
--    Row visibility stays entirely with the RLS policies named above.
-- ---------------------------------------------------------------------------

GRANT SELECT ON public.categories TO anon;
GRANT SELECT ON public.products TO anon;
GRANT SELECT ON public.product_images TO anon;
GRANT SELECT ON public.provider_gallery TO anon;
-- The verified-badge read (_resolveVerifiedProviders) is best-effort, but
-- the view answers from postgres's view-owner rights and exposes only the
-- badge itself — safe for a guest to see.
GRANT SELECT ON public.provider_trust_stats TO anon;

-- ---------------------------------------------------------------------------
-- 2. The functions the browse policies call as anon.
-- ---------------------------------------------------------------------------

-- Called by products_public_read / product_images_read for every row the
-- first policy arm does not already cover. For anon: auth.uid() IS NULL,
-- so it returns FALSE and reveals nothing (it is STABLE, SECURITY DEFINER,
-- search_path-pinned — see 0002).
GRANT EXECUTE ON FUNCTION public.owns_provider_profile(uuid) TO anon;

-- The guest's trending gallery rail (revoked from anon by 20261010000002).
-- Its own body already only returns is_active rows owned by an APPROVED
-- provider — the same promise provider_gallery_public_read makes — so
-- EXECUTE here widens nothing beyond what table-level SELECT would allow.
GRANT EXECUTE ON FUNCTION public.visible_gallery_for_city(text, integer) TO anon;

-- ---------------------------------------------------------------------------
-- 3. The assertion: the guest browse surface is readable by anon.
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
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'categories', 'products', 'product_images', 'provider_gallery',
    'provider_trust_stats'
  ] LOOP
    IF NOT has_table_privilege('anon', 'public.' || v_table, 'SELECT') THEN
      v_missing := v_missing ||
        ('anon has no SELECT on public.' || v_table)::text;
    END IF;
  END LOOP;

  FOREACH v_fn IN ARRAY ARRAY[
    'owns_provider_profile(uuid)',
    'visible_gallery_for_city(text, integer)'
  ] LOOP
    IF NOT has_function_privilege(
      'anon', 'public.' || v_fn, 'EXECUTE'
    ) THEN
      v_missing := v_missing ||
        ('anon has no EXECUTE on public.' || v_fn)::text;
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION 'guest browse surface is not readable by anon: %',
      array_to_string(v_missing, '; ')
      USING ERRCODE = 'check_violation',
            DETAIL  = '20261020000001',
            HINT    = 'The guest home feed reads these directly as anon; '
                   || 'a missing grant turns into the error screen.';
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_guest_browse_surface_is_readable() IS
  'True when anon holds every table/function privilege the guest home feed '
  'reads directly (20261020000001). A false result means guests get the '
  'error screen: RLS never runs without the table GRANT, and a policy arm '
  'anon cannot execute fails the whole query with 42501.';

-- Zero-argument assertion: executable by every client role (the rule from
-- 20261007000008 / 0011's reachability walk).
GRANT EXECUTE ON FUNCTION public.assert_guest_browse_surface_is_readable()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
