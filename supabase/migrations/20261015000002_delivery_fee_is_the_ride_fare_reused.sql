-- =============================================================================
-- 20261015000002 — the delivery fee IS the ride fare, quoted and charged from
-- one function by both contexts
-- =============================================================================
--
-- THE REQUEST (Part 10)
-- ---------------------
--   "Find the EXISTING fare/distance logic used in the ride/transport flow
--    (base + per-km + vehicle-category rate, configured in Admin). This must
--    be REUSED by calling it, not duplicated. At checkout, with Delivery
--    chosen: pick a vehicle type, get the buyer's location, show the map,
--    calculate provider -> buyer distance with the SAME fare function, apply
--    the existing markup formula, and show
--    product display_price + delivery_display_fee = total."
--
-- THE EXISTING FARE LOGIC — SHOWN, NOT REIMPLEMENTED
-- --------------------------------------------------
-- There are already three layers, and nothing here adds a fourth:
--
--   fee_ride_base_fare(category, city) / fee_ride_per_km(category, city) /
--   fee_ride_minimum_fare(category, city)      [20260927000107]
--        one scalar reader per fee, each carrying the full fallback chain:
--        category_fee_settings -> categories.metadata -> system_settings.
--        This is what the Admin interface writes.
--
--   calculate_fare_estimate_at(pickup_lat, pickup_lng, dest_lat, dest_lng,
--                              vehicle_category_id, city)   [20260927000115]
--        the composed rule: greatest(minimum, base + per_km * distance),
--        where distance is st_distance between the two geography points.
--        This is the reader create_ride_request CHARGES with, and the one
--        FeeResolver.rideFare() QUOTES with in the ride screen. It is the
--        shared function this migration reuses.
--
--   products.display_price (generated)          [20261014000002]
--        provider_price + 5 + provider_price * 0.019 — the platform markup.
--
-- So the delivery path is:
--
--   quote_delivery_fee(provider, buyer_point, vehicle_category, city)
--        resolves the provider's own registered point, then calls
--        calculate_fare_estimate_at(...) and applies the markup. One function,
--        called by BOTH the checkout preview (FeeResolver.deliveryFee) and the
--        Edge Function that creates the order, so the number shown and the
--        number charged cannot come from two rules.
--
-- WHY THE QUOTE RESOLVES THE PROVIDER'S POINT ITSELF
-- --------------------------------------------------
-- The provider's exact coordinates are private: they are released to a buyer
-- only after a payment proof is verified (`get_approved_location_for_buyer`).
-- The checkout client therefore CANNOT compute this distance, and must not
-- approximate it from the city. quote_delivery_fee is SECURITY DEFINER and
-- reads the point on the buyer's behalf, returning the fee AND the distance,
-- and — crucially — returning ok=false with a REASON when the provider has
-- published no point, instead of inventing a city-level number.
--
-- THE MARKUP EXISTS ONCE
-- ----------------------
-- platform_display_markup() is now the single definition, and
-- products.display_price points at it, so "the same formula as the product
-- pricing" is a fact the database can be asked about rather than a comment.
--
-- Deploy: needs a Supabase deploy (three functions, one column expression
-- change, two assertions).
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The markup rule, in ONE place
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.platform_display_markup(p_amount numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  -- The flat 5 ETB platform charge plus the 1.9% platform margin. IMMUTABLE
  -- because a GENERATED column may only call an immutable function.
  SELECT p_amount + 5 + p_amount * 0.019;
$$;

COMMENT ON FUNCTION public.platform_display_markup(numeric) IS
  'The ONE definition of the platform markup: amount + 5 + amount * 0.019. '
  'Used by products.display_price (the public product price) and by the '
  'delivery fee, so the two cannot drift.';

-- Point the generated column at the shared rule rather than repeating the
-- arithmetic. Guarded, so a re-run is a no-op and a deployment that predates
-- 20261014000002 (no column at all) still ends up correct.
DO $$
DECLARE
  v_expr text;
BEGIN
  SELECT pg_get_expr(d.adbin, d.adrelid) INTO v_expr
    FROM pg_attribute a
    JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
   WHERE a.attrelid = 'public.products'::regclass
     AND a.attname = 'display_price';

  IF v_expr IS NULL THEN
    ALTER TABLE public.products
      ADD COLUMN display_price numeric(12, 2)
      GENERATED ALWAYS AS (public.platform_display_markup(price)) STORED;
    RAISE NOTICE 'products.display_price added on the shared markup rule';
  ELSIF position('platform_display_markup' in v_expr) = 0 THEN
    -- Same rule, new spelling. The column is derived, so dropping it loses no
    -- information; the ADD recomputes every row from `price`.
    ALTER TABLE public.products DROP COLUMN display_price;
    ALTER TABLE public.products
      ADD COLUMN display_price numeric(12, 2)
      GENERATED ALWAYS AS (public.platform_display_markup(price)) STORED;
    RAISE NOTICE 'products.display_price repointed at platform_display_markup';
  END IF;
END $$;

-- The search filter/sort reads this column; the index has to survive the
-- DROP/ADD above (a dropped column takes its index with it).
CREATE INDEX IF NOT EXISTS idx_products_display_price
  ON public.products (display_price)
  WHERE listing_status = 'ACTIVE' AND is_active = true;

-- ---------------------------------------------------------------------------
-- 2. The delivery fee: the ride fare, plus the product markup
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calculate_delivery_fee_at(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_dest_lat double precision,
  p_dest_lng double precision,
  p_vehicle_category_id uuid DEFAULT NULL,
  p_city text DEFAULT NULL
)
RETURNS numeric(12, 2)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  -- calculate_fare_estimate_at is the SAME reader create_ride_request charges
  -- with, so a delivery priced for "Car" is priced by the same admin-configured
  -- base + per-km + minimum as a ride for "Car". Nothing is re-derived here.
  SELECT public.platform_display_markup(
           public.calculate_fare_estimate_at(
             p_pickup_lat, p_pickup_lng, p_dest_lat, p_dest_lng,
             p_vehicle_category_id, p_city)
         )::numeric(12, 2);
$$;

COMMENT ON FUNCTION public.calculate_delivery_fee_at(
  double precision, double precision, double precision, double precision,
  uuid, text) IS
  'The delivery fee for a distance: calculate_fare_estimate_at (the fare '
  'create_ride_request charges with) plus platform_display_markup (the rule '
  'products.display_price is generated from). Take the coordinates from '
  'quote_delivery_fee() when the provider''s point is not already in hand.';

-- ---------------------------------------------------------------------------
-- 3. The one callable the buyer's checkout AND the order both use
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quote_delivery_fee(
  p_provider_id uuid,
  p_delivery_lat double precision DEFAULT NULL,
  p_delivery_lng double precision DEFAULT NULL,
  p_vehicle_category_id uuid DEFAULT NULL,
  p_city text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_lat double precision;
  v_lng double precision;
  v_city text;
  v_base numeric;
  v_fee numeric;
  v_distance numeric;
BEGIN
  IF p_provider_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NO_PROVIDER',
                              'fee', null, 'base_fee', null, 'distance_km', null);
  END IF;

  -- The provider's own registered point. Read here rather than passed in: the
  -- buyer may not read it (it is released only after a verified payment), and
  -- resolving it in ONE place is what stops the quote and the charge from
  -- measuring two different distances.
  SELECT pp.location_lat, pp.location_lng, pp.city
    INTO v_lat, v_lng, v_city
    FROM public.provider_profiles pp
   WHERE pp.id = p_provider_id;

  IF v_lat IS NULL OR v_lng IS NULL THEN
    -- Stated, never approximated: without a point there is no distance, and a
    -- fee invented from the city would be a number nobody could justify.
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'PROVIDER_HAS_NO_LOCATION',
      'fee', null, 'base_fee', null, 'distance_km', null,
      'message', 'This provider has not published a delivery point yet, so a '
                 'delivery fee cannot be calculated. Agree it with them, or '
                 'choose self-pickup.');
  END IF;

  IF p_delivery_lat IS NULL OR p_delivery_lng IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'NO_DELIVERY_POINT',
      'fee', null, 'base_fee', null, 'distance_km', null,
      'message', 'Choose where this should be delivered on the map first.');
  END IF;

  v_city := coalesce(nullif(btrim(p_city), ''), v_city);

  -- THE shared fare reader.
  v_base := public.calculate_fare_estimate_at(
    v_lat, v_lng, p_delivery_lat, p_delivery_lng,
    p_vehicle_category_id, v_city);

  v_fee := public.platform_display_markup(v_base)::numeric(12, 2);

  -- The same great-circle measure calculate_fare_estimate_at prices on,
  -- reported so the buyer can see what the number is for.
  v_distance := round(
    (st_distance(
      st_setsrid(st_makepoint(v_lng, v_lat), 4326)::geography,
      st_setsrid(st_makepoint(p_delivery_lng, p_delivery_lat), 4326)::geography
    ) / 1000.0)::numeric, 2);

  RETURN jsonb_build_object(
    'ok', true,
    'reason', null,
    'fee', v_fee,
    'base_fee', v_base,
    'distance_km', v_distance,
    'vehicle_category_id', p_vehicle_category_id,
    'city', v_city,
    'markup_included', true,
    'free', v_fee = 0,
    'source', 'calculate_fare_estimate_at');
END;
$$;

COMMENT ON FUNCTION public.quote_delivery_fee(uuid, double precision,
  double precision, uuid, text) IS
  'The delivery fee a buyer is shown AND is charged: resolves the provider''s '
  'registered point, measures the distance to the buyer''s point, prices it '
  'with calculate_fare_estimate_at (the fare create_ride_request charges with) '
  'and applies platform_display_markup. Returns ok=false with a stated reason '
  'when the provider has no point or the buyer has none, so no caller ever '
  'invents a fee.';

REVOKE ALL ON FUNCTION public.calculate_delivery_fee_at(
  double precision, double precision, double precision, double precision,
  uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.calculate_delivery_fee_at(
  double precision, double precision, double precision, double precision,
  uuid, text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.quote_delivery_fee(
  uuid, double precision, double precision, uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.quote_delivery_fee(
  uuid, double precision, double precision, uuid, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Assertions — the reuse is checkable, not a claim in a comment
-- ---------------------------------------------------------------------------
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

  -- The ride context: the function create_ride_request charges with must still
  -- be the reader the whole fare model composes through.
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_ride
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_ride_request';

  SELECT pg_get_expr(d.adbin, d.adrelid) INTO v_column
    FROM pg_attribute a
    JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
   WHERE a.attrelid = 'public.products'::regclass
     AND a.attname = 'display_price';

  IF v_delivery IS NULL OR v_quote IS NULL OR v_markup IS NULL THEN
    RETURN 'FAIL: the delivery quote, the delivery fee or the markup function is missing';
  END IF;

  -- 1. The delivery fee is the ride fare, not a second formula.
  IF position('calculate_fare_estimate_at' in v_delivery) = 0 THEN
    RETURN 'FAIL: calculate_delivery_fee_at no longer calls calculate_fare_estimate_at, so the delivery fee has stopped being the ride fare';
  END IF;

  -- 2. The preview the buyer sees goes through the same chain.
  IF position('calculate_fare_estimate_at' in v_quote) = 0 THEN
    RETURN 'FAIL: quote_delivery_fee no longer prices through calculate_fare_estimate_at, so the quoted delivery fee is not the charged one';
  END IF;

  -- 3. The markup the product price is generated from is the markup the
  --    delivery fee applies: one definition, two users.
  IF position('platform_display_markup' in v_quote) = 0 THEN
    RETURN 'FAIL: quote_delivery_fee does not apply platform_display_markup';
  END IF;

  IF v_column IS NULL OR position('platform_display_markup' in lower(v_column)) = 0 THEN
    RETURN 'FAIL: products.display_price is generated from something other than platform_display_markup, so the product markup and the delivery markup are two formulas again (column expression: %)';
  END IF;

  IF position('+ 5 +' in v_markup) = 0 OR position('* 0.019' in v_markup) = 0 THEN
    RETURN 'FAIL: platform_display_markup no longer computes amount + 5 + amount * 0.019';
  END IF;

  -- 4. The ride side must still be standing, or "reuses the ride fare" would
  --    be true of a fare nothing rides on any more.
  IF v_ride IS NULL OR position('calculate_fare_estimate_at' in v_ride) = 0 THEN
    RETURN 'FAIL: create_ride_request no longer charges through calculate_fare_estimate_at, so there is no ride fare left to reuse';
  END IF;

  RETURN 'ok: the delivery fee, the delivery quote, the product price and the ride charge all resolve through calculate_fare_estimate_at + platform_display_markup';
END;
$$;

COMMENT ON FUNCTION public.assert_delivery_fee_reuses_the_ride_fare() IS
  'Behavioural-ish proof of the fare reuse, read from the deployed bodies: '
  'the delivery fee calls calculate_fare_estimate_at, the buyer''s quote calls '
  'it too, the delivery markup IS the markup products.display_price is '
  'generated from, and the ride charge still calls the same reader.';

REVOKE ALL ON FUNCTION public.assert_delivery_fee_reuses_the_ride_fare()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_delivery_fee_reuses_the_ride_fare()
  TO anon, authenticated, service_role;
