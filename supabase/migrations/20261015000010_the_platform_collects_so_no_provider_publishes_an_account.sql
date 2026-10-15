-- 20261015000010 — the platform collects the money, so no provider publishes
-- an account number, and posting must stop requiring one
--
-- WHY THIS REVERSES 20261006000008 (Part 13)
-- -----------------------------------------
-- 20261006000008 ("posting requires a payment account") put the same rule in
-- three places, on the premise that a buyer sends money straight to the
-- seller's own bank account:
--
--   create_provider_product  raised NO_PAYMENT_ACCOUNT before the insert.
--   products_public_read     hid every listing of an account-less provider.
--   search_products          the same predicate inside the search RPC.
--
-- The payment model changed: all buyer payments now go to the payment account
-- the platform publishes inside the app (20260929000001 and
-- 20261014000003/004), and the provider is settled through their wallet. A
-- provider therefore has no account number to publish, and the flow that asked
-- them for one is removed from the app (Part 13 — the wallet screen's balance,
-- history and funding are untouched; only the "add/edit your bank account"
-- section is gone).
--
-- LEAVING THE RULE IN PLACE WOULD BE A HARD REGRESSION
-- ---------------------------------------------------
-- The client can no longer create a provider_payment_methods row, so every
-- provider would be "account-less" — and 20261006000008's rule would then
-- refuse every posting and hide every listing that already exists. The rule has
-- to go from all three places at once, which is what this file does.
--
-- WHAT IS DELIBERATELY NOT TOUCHED
--   * provider_payment_methods itself, its policies and its admin screen: the
--     table stays, the rows that already exist stay readable to their owner and
--     to an administrator, and nothing is deleted. Only the requirement is
--     removed.
--   * provider_fulfilment_blockers(): never carried this rule (it is shared
--     with claim_ride and the order-acceptance path), so it needs no change.
--   * The wallet, the posting fee, and the fulfilment gate: unchanged.
--
-- Deploy: needs a Supabase deploy (two function restatements + one policy).

-- ---------------------------------------------------------------------------
-- 1. create_provider_product — restated from 20261006000008 with the item-6
--    gate removed. Everything else is byte-for-byte the body that was live.
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

  -- 20261015000010: the NO_PAYMENT_ACCOUNT gate that 20261006000008 put HERE
  -- is gone. It required the provider to own an active
  -- provider_payment_methods row, which is a row the app no longer lets them
  -- create — so the gate would now refuse every posting on the platform. The
  -- buyer's money goes to the platform's own published account, which
  -- create_order_secure and the payment step both read, so there is nothing
  -- for the provider to publish and nothing to check here.

  -- Optional posting fee. The gate above already required the wallet to
  -- cover GREATEST(minimum, fee), so the lock and the second check only
  -- catch a balance that moved between the two reads. Refusing BEFORE the
  -- insert keeps the invariant simple: a product exists only when its fee
  -- was payable — no listing is ever created that the fee check would have
  -- refused.
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

  -- Charge and log. One TRANSACTION_FEE ledger row per product, keyed by the
  -- product id, so the charge is idempotent per listing and the platform's
  -- existing income readers (which sum platform_fee across TRANSACTION_FEE)
  -- count posting fees without knowing this key exists. net_amount is the
  -- BALANCE DELTA (-fee), not gross - fee: assert_income_ledger_consistent
  -- compares each wallet's balance with the sum of its COMPLETED net_amount,
  -- so a row whose net_amount disagrees with the movement it caused plants
  -- drift in exactly the check that exists to catch missing ledger rows.
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
  'Creates a listing. The posting fee and the fulfilment gate still apply; '
  'the NO_PAYMENT_ACCOUNT rule 20261006000008 added was removed by '
  '20261015000010, because all buyer payments go to the platform''s own '
  'published account and a provider has no account number to publish.';

-- ---------------------------------------------------------------------------
-- 2. products_public_read — buyers stop being shown only account-holding
--    providers. Active is active again; the platform collects the money.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS products_public_read ON public.products;
CREATE POLICY products_public_read ON public.products FOR SELECT
  USING (
    is_active = true
    OR owns_provider_profile(provider_id)
    OR is_admin()
  );

COMMENT ON POLICY products_public_read ON public.products IS
  'A buyer sees an active listing. Until 20261015000010 this also required an '
  'active provider_payment_methods row for the provider, from the era when the '
  'buyer paid the seller directly; since the platform collects the payment, '
  'that condition hid every listing of a provider who (correctly) has no '
  'account to publish.';

-- ---------------------------------------------------------------------------
-- 3. search_products — restated from 20261014000002 with the same predicate
--    dropped. SECURITY DEFINER, so the policy above cannot reach it.
--
--    The signature and the RETURNS TABLE are untouched: this changes a filter,
--    not the result contract, so no DROP FUNCTION is needed or wanted.
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
    -- 20261015000010: the provider_payment_methods EXISTS that stood here is
    -- gone with the rule it enforced. A listing with no photo still never
    -- appears in a search result: the result is a card, and a card with no
    -- photo is an empty frame.
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
  'excludes listings with no photo in `product_images`, and returns and '
  'filters on `display_price`, the public price (provider_price + 5 + 1.9%), '
  'so the raw provider price never rides along in a public payload and a typed '
  'price bound means the number the buyer sees on the cards. Since '
  '20261015000010 it no longer requires the provider to hold a payment '
  'account: the platform collects the payment.';

-- ---------------------------------------------------------------------------
-- 4. The live assertion, restated to the new truth.
--
--    20261006000008's assert_posting_requires_payment_account() read the LIVE
--    prosrc of the two functions and the live policy and REQUIRED the
--    payment-account predicate to be there. Connectivity CI calls it by name,
--    so leaving it alone would make it raise against the database this file
--    creates — a red run against a correctly migrated platform. The name is
--    kept (it is what the CI calls); the body now asserts the opposite, which
--    is the same discipline: the live database must match the model the app
--    ships.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_posting_requires_payment_account()
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
  IF v_create IS NULL OR v_create ILIKE '%NO_PAYMENT_ACCOUNT%' THEN
    v_bad := v_bad || ARRAY[
      'create_provider_product still refuses with NO_PAYMENT_ACCOUNT — the '
      'app no longer lets a provider publish an account number, so that '
      'refusal now blocks EVERY posting on the platform'];
  END IF;

  SELECT prosrc INTO v_search
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'search_products';
  IF v_search IS NULL OR v_search ILIKE '%provider_payment_methods%' THEN
    v_bad := v_bad || ARRAY[
      'search_products still hides providers without a payment account — '
      'every listing would disappear from search'];
  END IF;

  SELECT coalesce(p.qual, '') INTO v_policy
    FROM pg_policies p
   WHERE p.schemaname = 'public' AND p.tablename = 'products'
     AND p.policyname = 'products_public_read';
  IF v_policy ILIKE '%provider_payment_methods%' THEN
    v_bad := v_bad || ARRAY[
      'products_public_read still requires a provider payment account — every '
      'listing would be hidden from buyers'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the payment-account requirement is not fully removed: %',
      array_to_string(v_bad, '; ');
  END IF;
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_posting_requires_payment_account()
  TO anon, authenticated;

COMMENT ON FUNCTION public.assert_posting_requires_payment_account() IS
  'Historically: true when a provider without a payment account could neither '
  'publish, nor be found, nor be browsed. Since 20261015000010 the platform '
  'collects the payment and no provider publishes an account, so it is true '
  'when NO part of the platform still requires one — create_provider_product, '
  'search_products and products_public_read must all be free of the provider '
  'payment-account predicate.';
