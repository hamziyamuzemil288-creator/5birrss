-- =============================================================================
-- 20261026000001 — delivery pricing is base fee + per-km × distance, capped by
-- one admin-configurable maximum delivery distance
-- =============================================================================
--
-- THE REQUEST (Stage 1)
-- ---------------------
--   "delivery_price = base_fee (CEO-configurable, default 70) +
--    per_km_rate_for_chosen_vehicle_type * distance_km, where distance is
--    calculated from the provider/admin's set location to the buyer's chosen
--    location, capped/validated against an admin-configurable maximum delivery
--    distance (if the buyer is beyond it, delivery isn't offered — show
--    self-pickup only, with a clear message why)."
--
-- WHAT CHANGES AND WHAT DOES NOT
-- ------------------------------
-- CHANGED: the RULE. 20261015000002 priced a delivery as
-- `platform_display_markup(calculate_fare_estimate_at(...))` — the ride fare
-- (greatest(minimum, ride_base + ride_per_km × km)) plus the product markup.
-- That is a ride price with a floor and a markup, not the rule above.
--
-- NOT CHANGED:
--   * the per-km RATE. It is still `fee_ride_per_km(category, city)`, the same
--     resolver `calculate_fare_estimate_at` reads, so an admin who sets a rate
--     on Admin → Fees → Categories changes the delivery rate for that vehicle
--     type in the same edit as its ride rate. ONE store of per-vehicle rates,
--     not a second delivery table.
--   * `products.display_price` / `platform_display_markup`. The product markup
--     rule is untouched; delivery simply no longer borrows it.
--   * the ride fare. `create_ride_request` still charges through
--     `calculate_fare_estimate_at`, which this migration never restates.
--   * the callable signature. `quote_delivery_fee(uuid, double precision,
--     double precision, uuid, text)` keeps its argument list, so the checkout
--     (FeeResolver.deliveryFee) and the `order-create` Edge Function need no
--     change to keep working — they gain a new refusal reason instead.
--
-- THE TWO NEW SETTINGS
-- --------------------
--   delivery_base_fee          70     flat part of every delivery quote
--   max_delivery_distance_km   40     beyond this the delivery is not offered
--
-- Both live in `system_settings` and are surfaced by `admin_fee_catalogue()`
-- under a DELIVERY group, so the CEO edits them on the settings screen this
-- project already has (Admin → Fees). `is_fee_key()` is extended so the two
-- are CEO-gated and bounds-checked by `admin_update_setting()` exactly like
-- every other fee — a delivery fee nobody can reach is a delivery fee nobody
-- can change, which is the defect category_fee_settings was built to remove.
--
-- THE CAP IS A REFUSAL, NOT A ZERO
-- -------------------------------
-- Beyond the cap `quote_delivery_fee` returns ok=false with
-- reason=BEYOND_MAX_DISTANCE and a sentence naming the cap. A zero fee would
-- read as "free delivery"; the checkout shows the sentence and falls back to
-- self-pickup. `order-create` refuses such an order outright (a client that
-- ignores the checkout must not get free delivery either).
--
-- Deploy: needs a Supabase deploy (two settings, four restated functions).
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The two settings, seeded without clobbering a live value
-- ---------------------------------------------------------------------------
-- `trg_system_settings_security` refuses every write unless is_admin(), which
-- is auth.uid()-derived and therefore false on a migration connection — the
-- first attempt at 20260927000062 died on exactly that. The lift/restore below
-- is that migration's precedent, and the lift is part of this transaction, so
-- a failure anywhere rolls it back too.
ALTER TABLE public.system_settings DISABLE TRIGGER trg_system_settings_security;

INSERT INTO public.system_settings (key, value, description) VALUES
  ('delivery_base_fee', '70'::jsonb,
   'Flat part of every delivery price, in birr: delivery = this + per-km rate x distance'),
  ('max_delivery_distance_km', '40'::jsonb,
   'Furthest a delivery may go, in km. Beyond this the checkout does not offer delivery, only self-pickup')
ON CONFLICT (key) DO NOTHING;

ALTER TABLE public.system_settings ENABLE TRIGGER trg_system_settings_security;

-- ---------------------------------------------------------------------------
-- 2. is_fee_key — the delivery keys are fees too (pure addition)
-- ---------------------------------------------------------------------------
-- Restated, not replaced: every existing arm is kept word for word and the new
-- key list is appended, so the CEO gate, the bounds check and the catalogue's
-- "OTHER DETECTED" branch all keep working exactly as they did.
CREATE OR REPLACE FUNCTION public.is_fee_key(p_key text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(
    p_key IN (
      'transaction_fee_percent', 'transaction_fee_min', 'provider_registration_fee',
      'provider_subscription_fee', 'ride_base_fare', 'ride_per_km', 'ride_minimum_fare'
    )
    OR p_key ~ '(_fee|_fee_min|_fee_percent|_fare|_per_km)$'
    OR p_key ~ '^ride_'
    OR p_key ~ '^provider_(registration|subscription)'
    -- The delivery pair. delivery_base_fee would already match `_fee$`; the
    -- distance cap matches nothing, and an unmatched key would be editable by
    -- any admin and invisible on the fee screen.
    OR p_key IN ('delivery_base_fee', 'max_delivery_distance_km'),
    false
  );
$$;

COMMENT ON FUNCTION public.is_fee_key(text) IS
  'One predicate for "is this a fee": used by the validator, the catalogue and '
  'the assertions. delivery_base_fee and max_delivery_distance_km are CEO fees '
  'like every other price on the platform.';

-- ---------------------------------------------------------------------------
-- 3. The fee catalogue — a DELIVERY group so both are editable, not merely
--    writable. Restated: the known list gains two rows, the UNION ALL exclusion
--    grows to match (otherwise every delivery key would print TWICE, once with
--    a label and once as OTHER DETECTED).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_fee_catalogue()
RETURNS TABLE (
  key text,
  value jsonb,
  description text,
  fee_group text,
  is_percent boolean,
  min_value numeric,
  max_value numeric,
  updated_at timestamptz,
  is_missing boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'FEE_SETTINGS_CAN_ONLY_BE_VIEWED_BY_ADMINISTRATORS';
  END IF;

  RETURN QUERY
  WITH known(k, g, is_pct, lo, hi) AS (
    VALUES
      ('transaction_fee_percent'::text,   'TRANSACTION'::text, true,  0::numeric, 100::numeric),
      ('transaction_fee_min',             'TRANSACTION',         false, 0::numeric, 1000000::numeric),
      ('provider_registration_fee',       'ACTIVATION',          false, 0::numeric, 1000000::numeric),
      -- The subscription key this deployment actually charges from: it has
      -- existed since 0021 and is read live by deduct_subscription_fee(), the
      -- revenue scheduler and subscription-process. Listing it here is what
      -- gives it a label, bounds and an editor instead of leaving it as an
      -- anonymous row the CEO cannot find.
      ('monthly_subscription_fee',        'SUBSCRIPTION',        false, 0::numeric, 1000000::numeric),
      ('provider_subscription_fee',       'SUBSCRIPTION',        false, 0::numeric, 1000000::numeric),
      ('ride_base_fare',                  'RIDE DEFAULTS',       false, 0::numeric, 1000000::numeric),
      ('ride_per_km',                     'RIDE DEFAULTS',       false, 0::numeric, 1000000::numeric),
      ('ride_minimum_fare',               'RIDE DEFAULTS',       false, 0::numeric, 1000000::numeric),
      -- Delivery: the flat part of the price and the cap that decides whether
      -- delivery is offered at all. The per-km half is deliberately NOT here —
      -- it is the vehicle category's own rate, edited per vehicle type on
      -- Admin → Fees → Categories, so one rate serves rides and deliveries.
      ('delivery_base_fee',               'DELIVERY',            false, 0::numeric, 1000000::numeric),
      ('max_delivery_distance_km',        'DELIVERY',            false, 0::numeric, 1000000::numeric)
  )
  SELECT kn.k, s.value, s.description, kn.g, kn.is_pct, kn.lo, kn.hi, s.updated_at, (s.key IS NULL)
    FROM known kn
    LEFT JOIN public.system_settings s ON s.key = kn.k
  UNION ALL
  SELECT s.key, s.value, s.description, 'OTHER DETECTED', (s.key ~ 'percent$'),
         (CASE WHEN jsonb_typeof(s.value) = 'number' THEN 0::numeric ELSE NULL::numeric END),
         1000000, s.updated_at, false
    FROM public.system_settings s
   WHERE public.is_fee_key(s.key)
     AND s.key NOT IN ('transaction_fee_percent', 'transaction_fee_min',
                       'provider_registration_fee', 'provider_subscription_fee',
                       'monthly_subscription_fee',
                       'ride_base_fare', 'ride_per_km', 'ride_minimum_fare',
                       'delivery_base_fee', 'max_delivery_distance_km')
   ORDER BY 4, 1;
END;
$$;

COMMENT ON FUNCTION public.admin_fee_catalogue() IS
  'Every fee the CEO can edit, with its group, bounds and label. The DELIVERY
group carries delivery_base_fee and max_delivery_distance_km; the per-km half
of a delivery price is the vehicle category''s own ride_per_km row.';

-- ---------------------------------------------------------------------------
-- 4. The price rule itself, in one place
-- ---------------------------------------------------------------------------
-- calculate_delivery_fee_at(p_pickup, p_dest, vehicle, city) stays the pure
-- arithmetic: it answers "what does this distance cost", no policy in it.
-- The CAP lives in quote_delivery_fee, which is the callable both the checkout
-- and the Edge Function use, because a cap is a decision about whether to sell
-- the delivery at all and that decision belongs in one place.
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
  -- distance in km: the same great-circle measure calculate_fare_estimate_at
  -- prices a ride on, so a delivery and a ride over the same ground measure
  -- the same distance even though they price differently.
  --
  -- The ::numeric on the distance term is load-bearing, not decoration.
  -- st_distance(geography, geography) returns double precision, and
  -- numeric * double precision resolves to double precision, so the sum came
  -- out as double precision and round(double precision, integer) does not
  -- exist — Deploy Supabase #29 died on exactly that (SQLSTATE 42883) after
  -- the first half of this file had already run. Casting the distance keeps
  -- the arithmetic in numeric, which is what round(x, 2) accepts and what
  -- quote_delivery_fee already does with the same measurement below.
  SELECT round(
    coalesce(public.get_setting_numeric('delivery_base_fee'), 70)
    + coalesce(public.fee_ride_per_km(p_vehicle_category_id, p_city), 0)
      * (st_distance(
           st_setsrid(st_makepoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
           st_setsrid(st_makepoint(p_dest_lng, p_dest_lat), 4326)::geography
         ) / 1000.0)::numeric,
    2
  )::numeric(12, 2);
$$;

COMMENT ON FUNCTION public.calculate_delivery_fee_at(
  double precision, double precision, double precision, double precision,
  uuid, text) IS
  'delivery price = delivery_base_fee + fee_ride_per_km(vehicle, city) x '
  'distance_km, rounded to cents. The per-km rate is the vehicle category''s '
  'own rate — the same row its ride price reads — so a delivery and a ride '
  'for one vehicle type never carry two different rates. Use quote_delivery_fee '
  'when the cap has to be applied too.';

-- ---------------------------------------------------------------------------
-- 5. The one callable: the checkout quote AND the order price
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
  v_per_km numeric;
  v_fee numeric;
  v_distance_km numeric;
  v_max_km numeric;
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

  -- The distance is measured BEFORE anything is priced, because it decides
  -- both the price and whether delivery is offered at all.
  v_distance_km := round(
    (st_distance(
      st_setsrid(st_makepoint(v_lng, v_lat), 4326)::geography,
      st_setsrid(st_makepoint(p_delivery_lng, p_delivery_lat), 4326)::geography
    ) / 1000.0)::numeric, 2);

  -- THE CAP. Admin-configurable, default 40 km. Past it there is no delivery
  -- to price — the checkout is told why and offers self-pickup instead.
  v_max_km := coalesce(public.get_setting_numeric('max_delivery_distance_km'), 40);

  IF v_max_km > 0 AND v_distance_km > v_max_km THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'BEYOND_MAX_DISTANCE',
      'fee', null, 'base_fee', null,
      'distance_km', v_distance_km, 'max_distance_km', v_max_km,
      'message', 'Delivery is not available this far away — this point is '
                 || v_distance_km::text || ' km away and the delivery limit is '
                 || v_max_km::text || ' km. Choose self-pickup instead.');
  END IF;

  -- THE RULE: base fee + per-km rate for THIS vehicle type x distance.
  -- Both halves are read from the platform's own stores: the flat part from
  -- delivery_base_fee, the rate from the same per-category resolver the ride
  -- price reads. Nothing is computed by the caller.
  v_base   := coalesce(public.get_setting_numeric('delivery_base_fee'), 70);
  v_per_km := coalesce(public.fee_ride_per_km(p_vehicle_category_id, v_city), 0);
  v_fee    := round(v_base + v_per_km * v_distance_km, 2);

  RETURN jsonb_build_object(
    'ok', true,
    'reason', null,
    'fee', v_fee::numeric(12, 2),
    'base_fee', v_base,
    'per_km_rate', v_per_km,
    'distance_km', v_distance_km,
    'max_distance_km', v_max_km,
    'vehicle_category_id', p_vehicle_category_id,
    'city', v_city,
    'markup_included', false,
    'free', v_fee = 0,
    'source', 'delivery_base_fee + fee_ride_per_km x distance');
END;
$$;

COMMENT ON FUNCTION public.quote_delivery_fee(uuid, double precision,
  double precision, uuid, text) IS
  'The delivery price a buyer is shown AND is charged: resolves the provider''s '
  'registered point, measures the distance to the buyer''s point, prices it '
  'delivery_base_fee + fee_ride_per_km(vehicle, city) x distance_km, and refuses '
  'BEYOND_MAX_DISTANCE past max_delivery_distance_km. Returns ok=false with a '
  'stated reason when the provider has no point or the buyer has none, so no '
  'caller ever invents a fee.';

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
-- 6. The assertion, restated for the rule that is now live
-- ---------------------------------------------------------------------------
-- The old body asserted the ride-fare reuse (20261015000002). It reads the
-- LIVE function bodies, so leaving it unchanged would make it fail the moment
-- this migration applies — an assertion that punishes the fix is worse than no
-- assertion. What it still proves, unchanged in intent:
--   * the quote and the charge go through ONE reader (no arithmetic in Dart,
--     none in the Edge Function);
--   * the product markup rule and its generated column are untouched;
--   * the ride fare still exists to be talked about at all.
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
  SELECT regexp_replace(lower(p.prosrc), E'\s+', ' ', 'g') INTO v_delivery
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'calculate_delivery_fee_at';

  SELECT regexp_replace(lower(p.prosrc), E'\s+', ' ', 'g') INTO v_quote
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'quote_delivery_fee';

  SELECT regexp_replace(lower(p.prosrc), E'\s+', ' ', 'g') INTO v_markup
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'platform_display_markup';

  -- The ride context: untouched by this migration, and it must still be there.
  SELECT regexp_replace(lower(p.prosrc), E'\s+', ' ', 'g') INTO v_ride
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_ride_request';

  -- The shared per-km resolver: the ONE store of per-vehicle rates.
  SELECT regexp_replace(lower(p.prosrc), E'\s+', ' ', 'g') INTO v_per_km
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

COMMENT ON FUNCTION public.assert_delivery_fee_reuses_the_ride_fare() IS
  'Reads the live bodies and proves the delivery price is one rule quoted and '
  'charged through the same reader, capped by max_delivery_distance_km, with '
  'the product markup and the ride fare untouched.';

REVOKE ALL ON FUNCTION public.assert_delivery_fee_reuses_the_ride_fare()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_delivery_fee_reuses_the_ride_fare()
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Self-check: the settings are visible to the editor the CEO actually uses
-- ---------------------------------------------------------------------------
-- A fee that exists but has no door is the defect this project already
-- documented once (categories.metadata per_km). The catalogue is that door, so
-- the deploy fails loudly if the DELIVERY group did not take.
DO $$
BEGIN
  IF to_regprocedure('public.admin_fee_catalogue()') IS NULL THEN
    RAISE EXCEPTION '20261026000001: admin_fee_catalogue() is missing';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.system_settings
                  WHERE key IN ('delivery_base_fee', 'max_delivery_distance_km')) THEN
    RAISE EXCEPTION '20261026000001: the delivery settings were not seeded, so the price rule has nothing to read';
  END IF;

  IF position('delivery_base_fee' in coalesce(
       (SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'admin_fee_catalogue'), '')) = 0 THEN
    RAISE EXCEPTION '20261026000001: admin_fee_catalogue() does not list delivery_base_fee, so the CEO cannot edit it';
  END IF;
END $$;
