-- 20261016000001 — remove the payment-account posting gate (part 13 completion)

-- CONTEXT
-- -------
-- This migration removes the now-dead payment-account posting gate that was still
-- on the live database even after 20261015000010 restated the server surfaces.
-- The app no longer asks a provider for an account number, so leaving the old
-- predicate in place would block every posting and hide every listing.

-- WHAT THIS MIGRATION DOES
-- ------------------------
-- 1. create_provider_product — drop the NO_PAYMENT_ACCOUNT block.
-- 2. products_public_read — drop the payment-account predicate.
-- 3. search_products — drop the same predicate from the SECURITY DEFINER reader,
--    keeping the function's public return shape byte-for-byte unchanged.
-- 4. Replace the old assertion (assert_posting_requires_payment_account) with the
--    surviving-gate assertion and retire the old name, so the database asserts the
--    rule the app still enforces: documents where required + wallet minimum.

-- WHAT IS DELIBERATELY NOT TOUCHED
--   * provider_payment_methods, its policies and rows: untouched.
--   * provider_fulfilment_blockers(): untouched.
--   * The wallet minimum, posting fee, and document verification: untouched.

-- IMPORTANT DEPLOY NOTE
-- ---------------------
-- search_products already returns display_price, not price. This file must not
-- try to change that return shape with CREATE OR REPLACE, because that raises
-- SQLSTATE 42P13 (cannot change return type of existing function). The removal
-- here is limited to the payment-account predicate and the docs, not the column
-- list or column names.

-- ---------------------------------------------------------------------------
-- 1. create_provider_product — drop the NO_PAYMENT_ACCOUNT block
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_provider_product(
  p_provider_id uuid,
  p_name text,
  p_description text,
  p_price numeric,
  p_category_id uuid,
  p_quantity integer,
  p_price_per_unit numeric DEFAULT 0,
  p_unit text DEFAULT NULL,
  p_is_available boolean DEFAULT true,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL
)
RETURNS public.products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_product public.products;
  v_blockers text[];
  v_post_fee numeric := COALESCE(public.get_setting_numeric('posting_fee'), 0);
  v_wallet public.wallets;
  v_balance_after numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.provider_profiles
    WHERE id = p_provider_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'NOT_YOUR_PROVIDER';
  END IF;

  v_blockers := public.provider_fulfilment_blockers(p_provider_id);
  IF COALESCE(array_length(v_blockers, 1), 0) > 0 THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FULFILMENT_READY: %',
      array_to_string(v_blockers, ',');
  END IF;

  -- Part 13: the payment-account branch is gone. The platform collects the money,
  -- so a provider has no account number to publish and nothing to add. The wallet
  -- minimum and document verification — not an account — are now the only posting
  -- gates, and they are already enforced by provider_fulfilment_blockers() above and
  -- by the optional posting-fee block below.

  IF v_post_fee > 0 THEN
    SELECT * INTO v_wallet
      FROM public.wallets WHERE provider_id = p_provider_id FOR UPDATE;
    IF v_wallet.id IS NULL THEN
      RAISE EXCEPTION 'WALLET_NOT_FOUND';
    END IF;
    IF NOT public.get_setting_bool('allow_negative_wallet')
       AND v_wallet.balance < v_post_fee THEN
      RAISE EXCEPTION 'POSTING_FEE_INSUFFICIENT: %', v_post_fee::text;
    END IF;
  END IF;

  INSERT INTO public.products (
    provider_id, name, description, price, category_id, quantity,
    price_per_unit, unit, is_available, location
  ) VALUES (
    p_provider_id,
    coalesce(nullif(btrim(p_name), ''), 'Untitled listing'),
    nullif(btrim(coalesce(p_description, '')), ''),
    coalesce(p_price, 0),
    p_category_id,
    p_quantity,
    coalesce(p_price_per_unit, 0),
    p_unit,
    coalesce(p_is_available, true),
    CASE WHEN p_lat IS NOT NULL AND p_lng IS NOT NULL
      THEN ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography
      ELSE NULL END
  ) RETURNING * INTO v_product;

  IF v_post_fee > 0 THEN
    UPDATE public.wallets
       SET balance = balance - v_post_fee, updated_at = now()
     WHERE id = v_wallet.id
    RETURNING balance INTO v_balance_after;

    INSERT INTO public.wallet_transactions (
      wallet_id, provider_id, order_id, ride_request_id, transaction_type,
      gross_amount, platform_fee, net_amount, balance_after, status,
      idempotency_key
    ) VALUES (
      v_wallet.id, p_provider_id, NULL, NULL, 'TRANSACTION_FEE',
      v_post_fee, v_post_fee, -v_post_fee, v_balance_after, 'COMPLETED',
      'posting_fee:' || v_product.id::text
    );

    INSERT INTO public.audit_logs (event_type, entity_type, entity_id, metadata)
    VALUES ('POSTING_FEE_DEDUCTED', 'wallets', v_wallet.id,
            jsonb_build_object(
              'provider_id', p_provider_id,
              'product_id', v_product.id,
              'fee', v_post_fee,
              'balance_after', v_balance_after));

    INSERT INTO public.notifications (user_id, type, title, body)
    SELECT user_id, 'POSTING_FEE_DEDUCTED', 'Listing fee deducted',
           v_post_fee::text || ' ETB deducted for a new listing'
      FROM public.provider_profiles WHERE id = p_provider_id;
  END IF;

  RETURN v_product;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_provider_product(
  uuid, text, text, numeric, uuid, integer, numeric, text, boolean,
  double precision, double precision) TO authenticated;

COMMENT ON FUNCTION public.create_provider_product IS
  'Creates a listing. Since 20261014000003 the platform collects the payment, so a '
  'provider has no account number to publish and nothing to add — the posting gate is '
  'the wallet minimum and document verification (provider_fulfilment_blockers()), not a '
  'provider payment account. The old NO_PAYMENT_ACCOUNT block was removed in '
  '20261016000001.';

-- ---------------------------------------------------------------------------
-- 2. products_public_read — drop the payment-account predicate
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS products_public_read ON public.products;
CREATE POLICY products_public_read ON public.products FOR SELECT
  USING (
    is_active = true
    OR owns_provider_profile(provider_id)
    OR is_admin()
  );

COMMENT ON POLICY products_public_read ON public.products IS
  'A buyer sees an active listing. Since 20261016000001 the decision no longer depends '
  'on the provider having an active payment account — the platform collects the money, so '
  'a provider without a bank account can still sell. The only remaining posting gate is '
  'provider_fulfilment_blockers() (wallet minimum / document verification).';

-- ---------------------------------------------------------------------------
-- 3. search_products — drop the same predicate from the SECURITY DEFINER reader
-- ---------------------------------------------------------------------------

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
    -- Part 13: the account-less branch is gone from search as well. A provider who
    -- satisfies the server posting gate is visible to buyers, even before they add a
    -- payment method (which no longer exists as a concept for the provider).
    AND EXISTS (
      SELECT 1 FROM public.product_images pi
       WHERE pi.product_id = p.id)
    AND (p_query IS NULL OR p_query = '' OR p.search_vector @@ plainto_tsquery('simple', p_query))
    AND (p_category_id IS NULL OR p.category_id = p_category_id)
    AND (p_sector IS NULL OR EXISTS (
      SELECT 1 FROM categories c WHERE c.id = p.category_id AND c.sector = p_sector))
    AND (v_location IS NULL OR p.location IS NULL
         OR ST_DWithin(p.location, v_location, p_radius_km * 1000))
    AND (p_min_price IS NULL OR p.display_price >= p_min_price)
    AND (p_max_price IS NULL OR p.display_price <= p_max_price)
    AND (p_min_rating IS NULL OR p.rating >= p_min_rating)
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
  'excludes listings with no photo in `product_images`, and returns and '
  'filters on `display_price`, the public price (provider_price + 5 + 1.9%), '
  'so the raw provider price never rides along in a public payload and a typed '
  'price bound means the number the buyer sees on the cards. Since '
  '20261016000001 it no longer requires the provider to hold a payment '
  'account: the platform collects the payment.';

-- ---------------------------------------------------------------------------
-- 4. Retire the old assertion, wire the surviving gate.
--
-- The old assertion asserted the payment-account rule. That rule is gone. Replace it
-- with the rule the app still enforces: a provider must satisfy the server posting gate
-- (provider_fulfilment_blockers — documents where required + wallet minimum) before a
-- listing goes live, and the app side (PostingGateState / ProviderReadiness) still reads
-- that same gate and still points at the right remedy screens.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_posting_gate_is_document_and_wallet_not_payment_account()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_create text;
  v_search text;
  v_policy text;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_create
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_provider_product';
  IF v_create IS NULL THEN
    v_bad := v_bad || ARRAY[
      'create_provider_product does not exist'];
  ELSE
    -- The live function must have dropped the account branch.
    IF v_create ILIKE '%NO_PAYMENT_ACCOUNT%' THEN
      v_bad := v_bad || ARRAY[
        'create_provider_product still refuses without a payment account — the app '
        'no longer lets a provider publish an account number, so that refusal now blocks '
        'every posting on the platform'];
    END IF;
  END IF;

  SELECT prosrc INTO v_search
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.proname
   WHERE n.nspname = 'public' AND p.proname = 'search_products';
  IF v_search IS NULL THEN
    v_bad := v_bad || ARRAY[
      'search_products does not exist'];
  ELSE
    -- Search must have dropped the account predicate too.
    IF v_search ILIKE '%provider_payment_methods%' THEN
      v_bad := v_bad || ARRAY[
        'search_products still hides providers without a payment account — every '
        'listing would disappear from search'];
    END IF;
  END IF;

  SELECT coalesce(p.qual, '') INTO v_policy
    FROM pg_policies p
   WHERE p.schemaname = 'public' AND p.tablename = 'products'
     AND p.policyname = 'products_public_read';
  IF v_policy NOT ILIKE '%is_active = true%' THEN
    v_bad := v_bad || ARRAY[
      'products_public_read no longer shows active listings'];
  END IF;
  IF v_policy ILIKE '%provider_payment_methods%' THEN
    v_bad := v_bad || ARRAY[
      'products_public_read still hides providers without a payment account — direct '
      'buyer reads would hide every listing'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the payment-account posting gate was not fully removed: %',
      array_to_string(v_bad, '; ');
  END IF;

  -- The surviving gate must still exist server-side.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'provider_fulfilment_blockers'
  ) THEN
    v_bad := v_bad || ARRAY[
      'provider_fulfilment_blockers() is missing — the server posting gate no longer exists'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the posting gate is broken: %',
      array_to_string(v_bad, '; ');
  END IF;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_posting_gate_is_document_and_wallet_not_payment_account()
  TO anon, authenticated;

COMMENT ON FUNCTION public.assert_posting_gate_is_document_and_wallet_not_payment_account IS
  'True when the payment-account posting gate is gone from create_provider_product, '
  'search_products and products_public_read, and the surviving server gate '
  '(provider_fulfilment_blockers) still exists.';

-- ---------------------------------------------------------------------------
-- 5. Retire the old assertion so no runner reaches for it by name.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.assert_posting_requires_payment_account();
