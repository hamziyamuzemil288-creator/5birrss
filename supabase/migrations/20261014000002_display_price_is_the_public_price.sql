-- 20261014000002 — display_price is the ONE public price
-- =============================================================================
--
-- WHY
-- ---
-- Every public surface must show the same number, and that number is the
-- platform's price:
--
--     display_price = provider_price + 5 + (provider_price × 0.019)
--
-- (a flat 5 ETB platform charge plus the 1.9% platform margin). The provider
-- sets and sees THEIR OWN raw price — `products.price`, which is what the
-- product form writes and what the provider's own screens (product list,
-- wallet) read — and that number must never appear publicly.
--
-- Until now there was only `price`, displayed everywhere, so "one computed
-- source" did not exist: each surface could only show what the column held.
-- The rule is now a GENERATED column, so the arithmetic exists exactly ONCE —
-- in the table. No screen computes it, no RPC recomputes it, and the number
-- cannot drift between home, search, trending, gallery, category, cart,
-- checkout and the product page.
--
-- WHAT CHANGES
-- -------------
-- 1. products.display_price — STORED GENERATED, computed from `price`. It
--    can never be written by a client or a trigger (GENERATED), so a provider
--    cannot post a listing whose public price disagrees with the rule.
--
-- 2. search_products() — the one public discovery read that projects explicit
--    columns. It now returns `display_price` INSTEAD of `price` (the raw
--    provider price must not even ride along in a public payload), and its
--    price filter and price sort compare the same column the buyer sees. The
--    transform is monotonic, but the FILTER bounds a buyer types are in
--    display-price terms ("max 100 ETB" means "cards that say ≤ 100"), so
--    comparing price would silently mismatch the cards. A changed return type
--    cannot be applied by CREATE OR REPLACE (42P13), so the signature is
--    DROPPED first and its GRANTs re-issued, exactly as 20261011000001 did.
--    Every other predicate — the payment-account requirement, the photo
--    requirement, listing_type, city scope, ranking — is byte-identical.
--
-- 3. The Edge Function order-create is the authoritative pricer for an order
--    (it accepts only product_id + quantity). It now reads display_price, so
--    the buyer is CHARGED the same number every public screen shows. (Edited
--    in supabase/functions/order-create/index.ts in this same release.)
--
-- 4. The client reads the column; it never computes the formula:
--      * Product.formattedDisplayPrice reads `display_price` (falls back to
--        `price` only when the column is absent, i.e. during the window
--        before this migration is applied);
--      * listingPriceLabel() (the ONE raw-row formatter) prefers
--        `display_price`;
--      * the cart's line prices read `display_price`.
--    Provider-facing screens keep reading `price` (provider_price): the
--    product form, the provider product list.
--
-- VERIFICATION of the math for one real listing (price = 100 ETB):
--     display_price = 100 + 5 + 100 × 0.019 = 105 + 1.9 = 106.90 ETB
-- The same numbers appear in test/product_card BoxFit/price wiring test and
-- in the widget/unit surfaces that read the column.

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The generated column
-- ---------------------------------------------------------------------------
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS display_price numeric(12, 2)
  GENERATED ALWAYS AS (price + 5 + price * 0.019) STORED;

COMMENT ON COLUMN public.products.display_price IS
  'The PUBLIC price, computed once from the provider''s raw price: '
  'price + 5 + price * 0.019 (flat 5 ETB platform charge + 1.9% margin), '
  'rounded to cents by the numeric(12,2) type. GENERATED, so no client or '
  'trigger can diverge from the rule. Every public screen and the order '
  'pricer read THIS column; `price` remains the provider''s own number and '
  'is never shown publicly.';

-- The search filter/sort reads this column; mirror the old price index.
CREATE INDEX IF NOT EXISTS idx_products_display_price
  ON public.products (display_price)
  WHERE listing_status = 'ACTIVE' AND is_active = true;

-- ---------------------------------------------------------------------------
-- 2. search_products — return and compare the public price
-- ---------------------------------------------------------------------------
-- DROP before CREATE: the RETURNS TABLE below swaps `price` for
-- `display_price`, and PostgreSQL refuses a changed return type on CREATE OR
-- OR REPLACE (42P13), which would abort the whole deploy at this file. The
-- argument list is spelled the way pg_dump spells it, which is the same
-- signature PostgreSQL resolves.
DROP FUNCTION IF EXISTS public.search_products(
  text, uuid, text, float8, float8, numeric, numeric,
  numeric, numeric, text, int4, int4, text, bool);

CREATE OR REPLACE FUNCTION public.search_products(
  p_query text DEFAULT NULL,
  p_category_id uuid DEFAULT NULL,
  p_sector text DEFAULT NULL,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL,
  p_radius_km NUMERIC DEFAULT NULL,
  p_min_price NUMERIC DEFAULT NULL,
  p_max_price NUMERIC DEFAULT NULL,
  p_min_rating NUMERIC DEFAULT NULL,
  p_sort_by text DEFAULT 'relevance',
  p_limit int DEFAULT 20,
  p_offset int DEFAULT 0,
  p_city text DEFAULT NULL,
  p_include_global boolean DEFAULT true
)
RETURNS TABLE (
  id uuid, name text, description text, display_price NUMERIC, currency text,
  rating NUMERIC, review_count int, sales_count int, category_id uuid,
  provider_id uuid, provider_name text, distance_km NUMERIC,
  listing_type listing_type,
  is_available boolean, image_path text, rank_score NUMERIC
)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
    v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
  END IF;
  RETURN QUERY
  SELECT p.id, p.name, p.description, p.display_price, p.currency, p.rating,
    p.review_count, p.sales_count, p.category_id, p.provider_id,
    pp.business_name AS provider_name,
    CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL
      THEN ROUND((ST_Distance(p.location, v_location) / 1000.0)::numeric, 2)
      ELSE null END AS distance_km,
    p.listing_type,
    p.is_available,
    (SELECT pi.storage_path FROM product_images pi
     WHERE pi.product_id = p.id ORDER BY pi.sort_order LIMIT 1) AS image_path,
    CASE WHEN p_query IS NOT NULL AND p_query != ''
      THEN (ts_rank(p.search_vector, plainto_tsquery('simple', p_query))
           + (1.0 / (1.0 + coalesce(
             CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL
               THEN ST_Distance(p.location, v_location) / 1000.0
               ELSE 9999 END, 9999))))::numeric
      ELSE 0::numeric END AS rank_score
  FROM products p
  JOIN provider_profiles pp ON pp.id = p.provider_id AND pp.status = 'APPROVED'
  WHERE p.is_active = true AND p.is_available = true
    -- Item 6: an account-less provider's listings are hidden from buyers,
    -- exactly like the products_public_read policy (this function runs as
    -- its owner, so the policy alone cannot reach it).
    AND EXISTS (
      SELECT 1 FROM public.provider_payment_methods m
       WHERE m.provider_id = p.provider_id AND m.is_active = true)
    -- A listing with no photo never appears in a search result: the result is
    -- a card, and a card with no photo is an empty frame. The listing is not
    -- gone — its own provider's page still shows it, as a text-only card.
    AND EXISTS (
      SELECT 1 FROM public.product_images pi
       WHERE pi.product_id = p.id)
    AND (p_query IS NULL OR p_query = '' OR p.search_vector @@ plainto_tsquery('simple', p_query))
    AND (p_category_id IS NULL OR p.category_id = p_category_id)
    AND (p_sector IS NULL OR EXISTS (
      SELECT 1 FROM categories c WHERE c.id = p.category_id AND c.sector = p_sector))
    AND (v_location IS NULL OR p.location IS NULL
         OR ST_DWithin(p.location, v_location, p_radius_km * 1000))
    -- 20261014000002: bounds and ordering speak the buyer's number. A filter
    -- typed as "max 100 ETB" means "cards that SAY at most 100".
    AND (p_min_price IS NULL OR p.display_price >= p_min_price)
    AND (p_max_price IS NULL OR p.display_price <= p_max_price)
    AND (p_min_rating IS NULL OR p.rating >= p_min_rating)
    -- Phase 1: city scope. NULL param = no filter (old behavior).
    AND (p_city IS NULL OR p.city IS NULL OR p.city = p_city)
  ORDER BY
    CASE p_sort_by WHEN 'price_asc' THEN p.display_price ELSE null END ASC,
    CASE p_sort_by WHEN 'price_desc' THEN p.display_price ELSE null END DESC,
    CASE p_sort_by WHEN 'rating' THEN p.rating ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'newest' THEN p.created_at ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'relevance' THEN
      CASE WHEN p_query IS NOT NULL AND p_query != ''
        THEN (ts_rank(p.search_vector, plainto_tsquery('simple', p_query))
             + (1.0 / (1.0 + coalesce(
               CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL
                 THEN ST_Distance(p.location, v_location) / 1000.0
                 ELSE 9999 END, 9999))))::numeric
        ELSE 0::numeric END
      ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'distance' THEN
      CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL
        THEN ST_Distance(p.location, v_location) ELSE 999999999 END
      ELSE null END ASC NULLS LAST
  LIMIT p_limit OFFSET p_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.search_products(text, uuid, text, double precision, double precision, numeric, numeric, numeric, numeric, text, int, int, text, boolean)
  TO authenticated, anon;

COMMENT ON FUNCTION public.search_products(text, uuid, text, double precision, double precision, numeric, numeric, numeric, numeric, text, int, int, text, boolean) IS
  'Public listing search. Returns the listing''s own `listing_type` (the '
  'shared card says BUY for a good and BOOK for a service or a room), '
  'excludes listings with no photo in `product_images`, and — since '
  '20261014000002 — returns and filters on `display_price`, the public price '
  '(provider_price + 5 + 1.9%), so the raw provider price never rides along '
  'in a public payload and a typed price bound means the number the buyer '
  'sees on the cards.';
