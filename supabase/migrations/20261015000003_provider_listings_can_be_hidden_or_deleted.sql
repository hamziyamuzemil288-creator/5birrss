-- =============================================================================
-- 20261015000003 — a provider can hide a listing, and can only really delete
-- one that no order ever touched
-- =============================================================================
--
-- THE REQUEST (Part 11)
-- ---------------------
--   "Providers can delete / hide / make their own products invisible. Delete a
--    product with past orders would break order history — so: no order history
--    -> full delete; order history -> hide only. Add simple, clearly-labelled
--    controls on the provider's product list. Hidden products must disappear
--    from ALL public surfaces, reusing the visibility-filtering pattern
--    already established."
--
-- WHAT WAS THERE BEFORE THIS MIGRATION (the audit, in the schema)
-- ---------------------------------------------------------------
--   * `products.is_active` (0001) already exists and is ALREADY the public
--     visibility flag: the `products_public_read` policy reads
--     `is_active = true`, `visible_products_for_city` filters `p.is_active`,
--     `search_products` filters `p.is_active = true`, and the
--     `product_trending` view filters `p.is_active`. So the filtering
--     mechanism the request asks for exists and is the one this reuses — no
--     second flag, no second filter, no change to those functions at all.
--   * `products_provider_delete` (0002/0021) already lets a provider delete
--     their own listing.
--   * `trg_products_sync_store_count` already keeps the store's listing count
--     honest across an INSERT or a DELETE.
--   * The provider's screen had a menu item labelled "Delete" whose handler
--     only set `is_active = false` — so the control said "removed for ever"
--     and did the opposite of what it said.
--
-- THE REFERENTIAL-INTEGRITY FACT, READ FROM THE CATALOGUE
-- ------------------------------------------------------
--   select conname, confrelid::regclass, confdeltype
--     from pg_constraint
--    where confrelid = 'products'::regclass and contype = 'f';
--
--   order_items_product_id_fkey   products   a   <- NO ACTION: DELETE refused
--   cart_items_product_id_fkey    products   c   <- CASCADE
--   product_images_product_id_fkey products  c   <- CASCADE
--   listing_images_listing_id_fkey products  c   <- CASCADE
--   product_likes_product_id_fkey  products  c   <- CASCADE
--   availability_requests_product_id_fkey     c   <- CASCADE
--
-- `a` is the whole answer: a listing that an order line references CANNOT be
-- hard-deleted, and PostgreSQL says so (SQLSTATE 23503) whatever the caller
-- does and whichever door it uses. Hiding it is therefore not a policy
-- preference, it is the only thing that can happen — which is exactly what the
-- request asks for, enforced where it cannot be skipped.
--
-- This migration adds the ONE door the provider's screen needs, so that the
-- right thing happens and the wrong thing is explained rather than raised:
-- `provider_delete_product()` deletes when nothing references the listing, and
-- otherwise hides it and says how many order lines are being preserved.
--
-- Deploy: needs a Supabase deploy (two functions, two assertions).
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. Delete when nothing references it, hide when something does
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.provider_delete_product(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_provider uuid;
  v_order_lines int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  SELECT p.provider_id INTO v_provider
    FROM public.products p
   WHERE p.id = p_product_id;

  IF v_provider IS NULL THEN
    -- Already gone, or never there. Reported as such rather than as a
    -- permission failure, so a double tap is not shown as a security event.
    RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
  END IF;

  IF NOT public.owns_provider_profile(v_provider) AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'NOT_YOUR_PRODUCT';
  END IF;

  -- The order history this listing appears in. This is the SAME fact the
  -- order_items foreign key enforces (confdeltype 'a'): counting it first
  -- turns a 23503 the provider cannot read into a sentence they can act on.
  SELECT count(*) INTO v_order_lines
    FROM public.order_items oi
   WHERE oi.product_id = p_product_id;

  IF v_order_lines > 0 THEN
    UPDATE public.products
       SET is_active = false,
           is_available = false
     WHERE id = p_product_id;

    RETURN jsonb_build_object(
      'action', 'hidden',
      'order_count', v_order_lines,
      'message', 'This listing has order history, so it was hidden instead of '
                 'deleted. Buyers can no longer see or buy it, and the past '
                 'orders that mention it are intact.');
  END IF;

  -- Nothing references it: a real delete. product_images, listing_images,
  -- cart_items, product_likes and availability_requests all cascade.
  DELETE FROM public.products WHERE id = p_product_id;

  RETURN jsonb_build_object(
    'action', 'deleted',
    'order_count', 0,
    'message', 'The listing and its photos are gone.');
END;
$$;

COMMENT ON FUNCTION public.provider_delete_product(uuid) IS
  'The provider''s one delete door. Ownership is checked here; a listing with '
  'order history is HIDDEN (is_active = false) and reported as hidden, and one '
  'with none is really deleted. The order_items foreign key is the '
  'unskippable guard behind the count; this function exists so the provider is '
  'told which of the two happened.';

-- ---------------------------------------------------------------------------
-- 2. Visibility on its own, so hiding is a control and not a side effect
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.provider_set_product_visibility(
  p_product_id uuid,
  p_visible boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_provider uuid;
  v_visibility boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  SELECT p.provider_id INTO v_provider
    FROM public.products p
   WHERE p.id = p_product_id;

  IF v_provider IS NULL THEN
    RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
  END IF;

  IF NOT public.owns_provider_profile(v_provider) AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'NOT_YOUR_PRODUCT';
  END IF;

  v_visibility := coalesce(p_visible, true);

  -- `is_active` is the flag every public read already filters on
  -- (products_public_read, visible_products_for_city, search_products,
  -- product_trending), so hiding a listing here hides it on every public
  -- surface at once and nothing had to be taught a second flag.
  UPDATE public.products
     SET is_active = v_visibility
   WHERE id = p_product_id;

  RETURN jsonb_build_object(
    'action', CASE WHEN v_visibility THEN 'shown' ELSE 'hidden' END,
    'is_active', v_visibility,
    'message', CASE WHEN v_visibility
      THEN 'Buyers can see this listing again.'
      ELSE 'Buyers can no longer see this listing. Your order history is untouched.' END);
END;
$$;

COMMENT ON FUNCTION public.provider_set_product_visibility(uuid, boolean) IS
  'Shows or hides one of the caller''s own listings by writing the flag every '
  'public read already filters on (products.is_active), so one toggle changes '
  'the home feed, search, category browse, trending and the gallery together.';

REVOKE ALL ON FUNCTION public.provider_delete_product(uuid)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.provider_delete_product(uuid)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.provider_set_product_visibility(uuid, boolean)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.provider_set_product_visibility(uuid, boolean)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Assertions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_order_history_blocks_a_hard_delete()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_deltype "char";
  v_src text;
  v_policy text;
BEGIN
  -- 1. The database itself refuses the delete. If this constraint is ever
  --    restated as CASCADE, one tap on "delete" would take a provider's sold
  --    order lines with it and the guard below would be decoration.
  SELECT c.confdeltype INTO v_deltype
    FROM pg_constraint c
   WHERE c.conrelid = 'public.order_items'::regclass
     AND c.confrelid = 'public.products'::regclass
     AND c.contype = 'f';

  IF v_deltype IS NULL THEN
    RETURN 'FAIL: order_items has no foreign key to products, so a hard delete of a sold listing is unguarded';
  END IF;

  IF v_deltype <> 'a' THEN
    RETURN 'FAIL: order_items.product_id -> products is ON DELETE ' || v_deltype || ', not NO ACTION, so deleting a listing with order history would rewrite order history';
  END IF;

  -- 2. The provider's door counts that history and hides instead.
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'provider_delete_product';

  IF v_src IS NULL THEN
    RETURN 'FAIL: provider_delete_product is missing, so the provider list has no delete door';
  END IF;

  IF position('order_items' in v_src) = 0 THEN
    RETURN 'FAIL: provider_delete_product no longer counts order history';
  END IF;

  IF position('is_active = false' in v_src) = 0 THEN
    RETURN 'FAIL: provider_delete_product no longer hides a listing that has order history';
  END IF;

  IF position('delete from public.products' in v_src) = 0 THEN
    RETURN 'FAIL: provider_delete_product never actually deletes, so "delete" hides for every listing again';
  END IF;

  -- 3. Ownership is decided by the same predicate the RLS policies use.
  IF position('owns_provider_profile' in v_src) = 0 THEN
    RETURN 'FAIL: provider_delete_product does not check ownership';
  END IF;

  -- 4. The RLS door stays open for the client's own delete, and it is the
  --    foreign key above — not a client check — that makes it safe.
  SELECT pg_get_expr(pol.polqual, pol.polrelid) INTO v_policy
    FROM pg_policy pol
   WHERE pol.polrelid = 'public.products'::regclass
     AND pol.polname = 'products_provider_delete';

  IF v_policy IS NULL OR position('owns_provider_profile' in v_policy) = 0 THEN
    RETURN 'FAIL: products_provider_delete no longer scopes a delete to the owning provider';
  END IF;

  RETURN 'ok: order_items -> products is NO ACTION, the provider door counts it and hides, and a delete stays scoped to the owner';
END;
$$;

CREATE OR REPLACE FUNCTION public.assert_hidden_listings_leave_every_public_surface()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_policy text;
  v_browse text;
  v_search text;
  v_trending text;
BEGIN
  -- One flag, every public read. This is the same filtering pattern the
  -- photo-less rule (20261011000001) joined; nothing here is a second
  -- mechanism.
  SELECT pg_get_expr(pol.polqual, pol.polrelid) INTO v_policy
    FROM pg_policy pol
   WHERE pol.polrelid = 'public.products'::regclass
     AND pol.polname = 'products_public_read';

  IF v_policy IS NULL OR position('is_active' in v_policy) = 0 THEN
    RETURN 'FAIL: products_public_read no longer requires is_active, so a hidden listing stays visible through any direct read';
  END IF;

  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_browse
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'visible_products_for_city';

  IF v_browse IS NULL OR position('p.is_active' in v_browse) = 0 THEN
    RETURN 'FAIL: visible_products_for_city no longer filters is_active, so a hidden listing still shows in category browse';
  END IF;

  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_search
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'search_products';

  IF v_search IS NULL OR position('p.is_active = true' in v_search) = 0 THEN
    RETURN 'FAIL: search_products no longer filters is_active, so a hidden listing is still findable by search';
  END IF;

  SELECT regexp_replace(lower(pg_get_viewdef('public.product_trending'::regclass, true)),
                        E'\\s+', ' ', 'g') INTO v_trending;

  IF v_trending IS NULL OR position('p.is_active' in v_trending) = 0 THEN
    RETURN 'FAIL: product_trending no longer filters is_active, so a hidden listing is still ranked on the trending rail';
  END IF;

  RETURN 'ok: products_public_read, visible_products_for_city, search_products and product_trending all filter the same is_active flag';
END;
$$;

COMMENT ON FUNCTION public.assert_order_history_blocks_a_hard_delete() IS
  'Proves a sold listing cannot be hard-deleted: the order_items foreign key '
  'is NO ACTION (not CASCADE), the provider door counts that history and hides '
  'instead, it still really deletes an unsold one, and both delete doors stay '
  'scoped to the owning provider.';

COMMENT ON FUNCTION public.assert_hidden_listings_leave_every_public_surface() IS
  'Proves hiding a listing hides it everywhere, through the ONE flag the '
  'public reads already filter: the read policy, category browse, search and '
  'the trending view.';

REVOKE ALL ON FUNCTION public.assert_order_history_blocks_a_hard_delete()
  FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.assert_hidden_listings_leave_every_public_surface()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_order_history_blocks_a_hard_delete()
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.assert_hidden_listings_leave_every_public_surface()
  TO anon, authenticated, service_role;
