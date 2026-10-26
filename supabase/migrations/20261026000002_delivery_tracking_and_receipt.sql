-- =============================================================================
-- 20261026000002 — a delivery has a destination, a driver, an arrival and a
-- receipt, all server-decided
-- =============================================================================
--
-- THE REQUEST (Stage 3)
-- ---------------------
--   "If the buyer chose delivery and paid: live tracking of the assigned
--    driver, driver assignment reusing whichever mechanism exists, the
--    provider's contact revealed on the tracking screen, an 'I am here'
--    button for the driver that reveals the buyer's contact at that moment,
--    an 'I received it' button for the buyer that completes the delivery, the
--    completion visible in the admin sidebar, and both parties notified at
--    each step."
--
-- WHAT ALREADY EXISTED, AND WHAT DID NOT
-- --------------------------------------
--   * Assignment: NONE for orders. Rides claim through `claim_ride`
--     (ride_requests.claimed_by_provider_id), but a delivery is an `orders`
--     row and nothing ever assigned one. Rather than invent a second claiming
--     system, an ADMIN assigns an approved vehicle provider to the delivery —
--     the same people `claim_ride` serves, found through the same
--     `driver_status`/`provider_profiles` tables, and the same live GPS
--     channel (`driver_status`, published by 20260925210000) carries them to
--     the buyer. The ride flow itself is not touched.
--   * Tracking: the ride path's own instruments — `driver_status.current_location`
--     streaming through the supabase_realtime publication, drawn by the shared
--     `LiveMap` widget. Nothing here re-implements a map or a GPS channel.
--   * Arrival / receipt: the order_status enum has no arrival state and this
--     migration does not add one. Arrival is delivery state
--     (delivery_status), and the RECEIPT completes the order through the
--     existing status machine: STARTED -> COMPLETED, the same move every other
--     completion in the product makes.
--
-- WHY THE BUYER CANNOT COMPLETE THE ORDER DIRECTLY
-- ------------------------------------------------
-- `prevent_order_self_privilege_escalation` refuses any client-originated
-- change to orders.status, and no SECURITY DEFINER function can lift that
-- (PostgreSQL refuses set_config('role', ...) inside one — see 20260927000024
-- and 20260927000058). So the completion goes through the existing server
-- path — the `order-transition` Edge Function, which runs as service_role —
-- and `transition_order_status` gains ONE clause: the order's own buyer may
-- complete a STARTED DELIVERY order whose delivery_status is DELIVERED.
-- Both facts are server-written: the buyer cannot set delivery_status (the
-- RPC below refuses anyone who is not the order's own buyer, and refuses
-- unless the assigned driver marked arrival first), and every other branch of
-- the whitelist is restated verbatim.
--
-- MONEY IS NOT TOUCHED
-- --------------------
-- The transaction fee still moves at APPROVED -> STARTED, inside
-- transition_order_status, exactly as before. The receipt path therefore
-- REQUIRES the order to be STARTED, so a delivery can never skip the fee by
-- jumping APPROVED -> COMPLETED: the seller starts the work (which charges),
-- the driver delivers, the buyer receives.
--
-- Deploy: needs a Supabase deploy (five columns, one policy, seven functions,
-- one restated whitelist).
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The delivery's own state, on the order it belongs to
-- ---------------------------------------------------------------------------
-- delivery_dest_*: WHERE the delivery goes — the point the buyer chose on the
--   map at checkout. Deliberately separate from delivery_lat/lng, which since
--   0032 are the buyer's LIVE GPS share (a different thing that must not be
--   overwritten by an address chosen hours earlier).
-- delivery_driver_provider_id: WHO takes it — an approved vehicle provider.
-- delivery_status: HOW FAR along it is. NULL on every order that is not a
--   delivery, and on delivery orders placed before this migration; 'ASSIGNED'
--   when a driver has it; 'ARRIVED' the moment the driver says they are there
--   (which is what unlocks the buyer's contact for them); 'DELIVERED' when the
--   buyer confirms they received it — the state transition_order_status now
--   needs before a buyer may complete the order.
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS delivery_dest_lat double precision,
  ADD COLUMN IF NOT EXISTS delivery_dest_lng double precision,
  ADD COLUMN IF NOT EXISTS delivery_status text,
  ADD COLUMN IF NOT EXISTS delivery_arrived_at timestamptz,
  ADD COLUMN IF NOT EXISTS delivery_confirmed_at timestamptz;

-- The driver, in its own statement, for two reasons that are both load-
-- bearing:
--
--   * ON DELETE SET NULL, not the default. Account deletion reaches
--     provider_profiles through the cascade, and a NO ACTION key here would
--     take `DELETE FROM auth.users` down with 23503 AFTER the request was
--     already marked APPROVED — the exact defect 20260927000118 fixed for
--     nineteen other columns, and the one the harness's "no foreign key
--     refuses the account deletion" check reads straight off this clause. A
--     driver whose account is closed simply stops being the assigned driver,
--     which is also the honest state: the order keeps its history, the admin
--     can assign somebody else.
--   * attribution: the harness reads a `REFERENCES` as belonging to the
--     FIRST column of a multi-column ADD COLUMN clause, so inlining this
--     key into the statement above would record it against
--     delivery_dest_lat and leave the real column unchecked.
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS delivery_driver_provider_id uuid
    REFERENCES public.provider_profiles(id) ON DELETE SET NULL;

-- A delivery has one of three states or none at all. The CHECK is here so a
-- typo cannot become a state nobody's screen has ever heard of.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'orders_delivery_status_check'
  ) THEN
    ALTER TABLE public.orders
      ADD CONSTRAINT orders_delivery_status_check
      CHECK (delivery_status IS NULL
             OR delivery_status IN ('ASSIGNED', 'ARRIVED', 'DELIVERED'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_orders_delivery_driver
  ON public.orders (delivery_driver_provider_id)
  WHERE delivery_driver_provider_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_orders_delivery_open
  ON public.orders (delivery_status)
  WHERE fulfillment_mode = 'DELIVERY';

-- ---------------------------------------------------------------------------
-- 2. The buyer may read the ASSIGNED driver's live location — and nobody else
--    may through this door
-- ---------------------------------------------------------------------------
-- The ride path reads driver_status through `driver_status_rider_read`
-- (0032), which keys on current_ride_id — a column a delivery never has. This
-- is the delivery counterpart: the same table, the same escrow window
-- (APPROVED/STARTED/COMPLETED), scoped to the one driver assigned to the
-- caller's own delivery order. Policies are OR'ed in PostgreSQL, so every
-- existing policy on driver_status keeps its own reach exactly as it was.
DROP POLICY IF EXISTS delivery_buyer_reads_driver_status ON public.driver_status;
CREATE POLICY delivery_buyer_reads_driver_status
  ON public.driver_status
  FOR SELECT
  TO authenticated
  USING (
    provider_id IN (
      SELECT o.delivery_driver_provider_id
        FROM public.orders o
       WHERE o.user_id = auth.uid()
         AND o.delivery_driver_provider_id IS NOT NULL
         AND o.status IN ('APPROVED', 'STARTED', 'COMPLETED')
    )
  );

-- ---------------------------------------------------------------------------
-- 3. Admin: who can be given a delivery, and giving one
-- ---------------------------------------------------------------------------
-- The roster. Approved VEHICLE_PROVIDER profiles only: they are the role that
-- already carries a `driver_status` row (auto-created on approval, 0010) and
-- therefore the role whose device already streams GPS.
CREATE OR REPLACE FUNCTION public.admin_delivery_drivers()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'DELIVERY_DRIVERS_ARE_ADMIN_ONLY';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT pp.id,
             coalesce(nullif(btrim(pp.business_name), ''),
                      pr.full_name) AS name,
             coalesce(ds.is_online, false) AS is_online,
             ds.last_location_update
        FROM public.provider_profiles pp
        JOIN public.profiles pr ON pr.id = pp.user_id
        LEFT JOIN public.driver_status ds ON ds.provider_id = pp.id
       WHERE pp.status = 'APPROVED'
         AND pp.provider_type = 'VEHICLE_PROVIDER'
       ORDER BY coalesce(ds.is_online, false) DESC,
                coalesce(nullif(btrim(pp.business_name), ''), pr.full_name)
    ) t;

  RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION public.admin_delivery_drivers() IS
  'The drivers an admin may assign to a delivery order: approved vehicle '
  'providers, online first. Admin-only.';

REVOKE ALL ON FUNCTION public.admin_delivery_drivers() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_delivery_drivers()
  TO authenticated, service_role;

-- Assignment. The admin picks the driver; the server decides everything else.
CREATE OR REPLACE FUNCTION public.assign_delivery_driver(
  p_order_id uuid,
  p_driver_provider_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order public.orders;
  v_driver public.provider_profiles;
  v_driver_user uuid;
  v_buyer_user uuid;
  v_name text;
  v_label text;
  v_ref text;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ONLY_AN_ADMINISTRATOR_MAY_ASSIGN_A_DELIVERY_DRIVER';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF coalesce(v_order.fulfillment_mode, 'DELIVERY') <> 'DELIVERY' THEN
    RAISE EXCEPTION 'THIS_ORDER_IS_A_SELF_PICKUP_AND_NEEDS_NO_DRIVER';
  END IF;

  IF v_order.status NOT IN ('APPROVED', 'STARTED') THEN
    RAISE EXCEPTION 'DELIVERY_DRIVER_CAN_ONLY_BE_ASSIGNED_AFTER_PAYMENT_IS_VERIFIED';
  END IF;

  SELECT * INTO v_driver
    FROM public.provider_profiles WHERE id = p_driver_provider_id;
  IF v_driver.id IS NULL OR v_driver.status <> 'APPROVED'
     OR v_driver.provider_type <> 'VEHICLE_PROVIDER' THEN
    RAISE EXCEPTION 'DRIVER_MUST_BE_AN_APPROVED_VEHICLE_PROVIDER';
  END IF;

  v_driver_user := v_driver.user_id;
  v_buyer_user := v_order.user_id;
  v_label := coalesce(nullif(btrim(v_order.delivery_address), ''),
                      'the delivery address on this order');
  v_ref := left(v_order.id::text, 8);

  UPDATE public.orders
     SET delivery_driver_provider_id = p_driver_provider_id,
         delivery_status = 'ASSIGNED',
         delivery_arrived_at = NULL,
         delivery_confirmed_at = NULL,
         updated_at = now()
   WHERE id = p_order_id;

  -- Keyed by driver as well as order, so a RE-assignment notifies the new
  -- driver (and tells the buyer again) while a retried call stays silent.
  PERFORM public.notify_user_safe(
    'delivery-assigned:' || p_order_id::text || ':' || p_driver_provider_id::text,
    v_driver_user,
    'ORDER_RECEIVED',
    'New delivery job',
    'You have been assigned a delivery. Open it for the address and the '
    || 'buyer''s details once you arrive.',
    jsonb_build_object('order_id', p_order_id)
  );

  PERFORM public.notify_user_safe(
    'delivery-assigned:' || p_order_id::text || ':' || p_driver_provider_id::text || ':buyer',
    v_buyer_user,
    'ORDER_ACCEPTED',
    'A driver is bringing your order',
    'Your delivery (order #' || v_ref || ') has a driver. Track them live on '
    || 'the order, and call them once they arrive.',
    jsonb_build_object('order_id', p_order_id)
  );

  SELECT coalesce(nullif(btrim(pp.business_name), ''), pr.full_name)
    INTO v_name
    FROM public.provider_profiles pp
    JOIN public.profiles pr ON pr.id = pp.user_id
   WHERE pp.id = p_driver_provider_id;

  RETURN jsonb_build_object(
    'ok', true,
    'driver_provider_id', p_driver_provider_id,
    'driver_name', v_name,
    'delivery_status', 'ASSIGNED'
  );
END;
$$;

COMMENT ON FUNCTION public.assign_delivery_driver(uuid, uuid) IS
  'Admin-only: attach an approved vehicle provider to a delivery order as its '
  'driver, set delivery_status = ASSIGNED and tell both sides. Refuses before '
  'the payment is verified, on a self-pickup order, and on any driver who is '
  'not an approved vehicle provider.';

REVOKE ALL ON FUNCTION public.assign_delivery_driver(uuid, uuid)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assign_delivery_driver(uuid, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. The driver: their jobs, and "I am here"
-- ---------------------------------------------------------------------------
-- The driver's own list. The order row itself is not readable by the driver
-- (RLS scopes it to the buyer, their seller and the admin), so this RPC is the
-- door: it returns only what the driver needs to do the job — where to go and
-- how far along it is. The buyer's contact is NOT here: it is released by
-- get_delivery_buyer_contact(), and only once arrival is recorded.
CREATE OR REPLACE FUNCTION public.my_delivery_jobs()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_provider uuid;
  v_rows jsonb;
BEGIN
  SELECT pp.id INTO v_provider
    FROM public.provider_profiles pp
   WHERE pp.user_id = auth.uid() AND pp.status = 'APPROVED'
   LIMIT 1;

  IF v_provider IS NULL THEN
    RAISE EXCEPTION 'NOT_AN_APPROVED_PROVIDER';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.created_at DESC),
                  '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT o.id,
             o.status AS order_status,
             coalesce(o.delivery_status, 'ASSIGNED') AS delivery_status,
             o.delivery_dest_lat AS dest_lat,
             o.delivery_dest_lng AS dest_lng,
             o.delivery_address AS dest_label,
             o.total_amount,
             o.currency,
             o.created_at
        FROM public.orders o
       WHERE o.delivery_driver_provider_id = v_provider
         AND o.status IN ('APPROVED', 'STARTED', 'COMPLETED')
    ) t;

  RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION public.my_delivery_jobs() IS
  'The delivery orders assigned to the calling approved provider, with the '
  'drop-off point and the delivery state. The buyer''s contact is not in it — '
  'that is released by get_delivery_buyer_contact() on arrival.';

REVOKE ALL ON FUNCTION public.my_delivery_jobs() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.my_delivery_jobs()
  TO authenticated, service_role;

-- "I am here". Proximity is not measured anywhere in this product (no
-- geofence exists for rides either), so the button is available once the
-- driver has the job and the order is live — the same rule the driver's own
-- screen mirrors. What it does is server-decided: it records the arrival, and
-- the arrival is what unlocks the buyer's contact for this driver.
CREATE OR REPLACE FUNCTION public.delivery_mark_arrived(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order public.orders;
  v_provider uuid;
  v_is_admin boolean := public.is_admin();
  v_buyer_user uuid;
  v_driver_name text;
  v_ref text;
BEGIN
  SELECT pp.id INTO v_provider
    FROM public.provider_profiles pp
   WHERE pp.user_id = auth.uid();

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF NOT v_is_admin THEN
    IF v_provider IS NULL
       OR v_order.delivery_driver_provider_id IS DISTINCT FROM v_provider THEN
      RAISE EXCEPTION 'ONLY_THE_ASSIGNED_DRIVER_MAY_MARK_ARRIVAL';
    END IF;
  END IF;

  IF v_order.delivery_driver_provider_id IS NULL THEN
    RAISE EXCEPTION 'NO_DRIVER_IS_ASSIGNED_TO_THIS_DELIVERY';
  END IF;

  IF v_order.status NOT IN ('APPROVED', 'STARTED') THEN
    RAISE EXCEPTION 'THIS_DELIVERY_IS_NOT_ACTIVE';
  END IF;

  IF coalesce(v_order.delivery_status, 'ASSIGNED') = 'DELIVERED' THEN
    RAISE EXCEPTION 'THIS_DELIVERY_IS_ALREADY_CONFIRMED';
  END IF;

  UPDATE public.orders
     SET delivery_status = 'ARRIVED',
         delivery_arrived_at = coalesce(delivery_arrived_at, now()),
         updated_at = now()
   WHERE id = p_order_id;

  v_buyer_user := v_order.user_id;
  v_ref := left(v_order.id::text, 8);

  PERFORM public.notify_user_safe(
    'delivery-arrived:' || p_order_id::text,
    v_buyer_user,
    'ORDER_ACCEPTED',
    'Your delivery has arrived',
    'Your driver is at the delivery point for order #' || v_ref
    || '. Confirm on the order once you have received it.',
    jsonb_build_object('order_id', p_order_id)
  );

  SELECT coalesce(nullif(btrim(pp.business_name), ''), pr.full_name)
    INTO v_driver_name
    FROM public.provider_profiles pp
    JOIN public.profiles pr ON pr.id = pp.user_id
   WHERE pp.id = v_order.delivery_driver_provider_id;

  RETURN jsonb_build_object(
    'ok', true,
    'delivery_status', 'ARRIVED',
    'buyer_contact_released', true,
    'driver_name', v_driver_name
  );
END;
$$;

COMMENT ON FUNCTION public.delivery_mark_arrived(uuid) IS
  'The assigned driver (or an admin) records arrival at the delivery point. '
  'Sets delivery_status = ARRIVED, which is the exact moment '
  'get_delivery_buyer_contact() starts releasing the buyer''s number to this '
  'driver, and tells the buyer.';

REVOKE ALL ON FUNCTION public.delivery_mark_arrived(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.delivery_mark_arrived(uuid)
  TO authenticated, service_role;

-- The buyer's number, for the driver who is standing at the door. The reveal
-- rule is one condition: the arrival is on the order, recorded server-side by
-- the function above — the same shape as release_order_contact's
-- "payment verified" rule.
CREATE OR REPLACE FUNCTION public.get_delivery_buyer_contact(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order public.orders;
  v_provider uuid;
  v_is_admin boolean := public.is_admin();
  v_phone text;
  v_name text;
BEGIN
  SELECT pp.id INTO v_provider
    FROM public.provider_profiles pp
   WHERE pp.user_id = auth.uid();

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF NOT v_is_admin THEN
    IF v_provider IS NULL
       OR v_order.delivery_driver_provider_id IS DISTINCT FROM v_provider THEN
      RAISE EXCEPTION 'ONLY_THE_ASSIGNED_DRIVER_MAY_READ_THE_BUYER_CONTACT';
    END IF;
  END IF;

  IF v_order.delivery_arrived_at IS NULL THEN
    RAISE EXCEPTION 'BUYER_CONTACT_IS_RELEASED_WHEN_YOU_MARK_ARRIVAL';
  END IF;

  SELECT p.phone, p.full_name INTO v_phone, v_name
    FROM public.profiles p WHERE p.id = v_order.user_id;

  RETURN jsonb_build_object(
    'ok', true,
    'buyer_name', v_name,
    'buyer_phone', v_phone,
    'released_at', v_order.delivery_arrived_at
  );
END;
$$;

COMMENT ON FUNCTION public.get_delivery_buyer_contact(uuid) IS
  'The buyer''s name and phone for the driver assigned to that delivery — and '
  'only after delivery_arrived_at is set. The arrival is the reveal condition, '
  'written server-side, so the driver cannot read the number early.';

REVOKE ALL ON FUNCTION public.get_delivery_buyer_contact(uuid)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_delivery_buyer_contact(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. The buyer: tracking, and "I received it"
-- ---------------------------------------------------------------------------
-- One read for the tracking screen: the delivery state, where it is going and
-- who is taking it (with their live GPS). Buyer, assigned driver and admin may
-- each read it for their own order; everyone else is refused.
CREATE OR REPLACE FUNCTION public.get_delivery_tracking(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order public.orders;
  v_provider uuid;
  v_is_admin boolean := public.is_admin();
  v_driver_lat double precision;
  v_driver_lng double precision;
  v_driver_at timestamptz;
  v_driver_online boolean := false;
  v_driver_name text;
  v_buyer_name text;
  v_buyer_phone text;
BEGIN
  SELECT pp.id INTO v_provider
    FROM public.provider_profiles pp
   WHERE pp.user_id = auth.uid();

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF NOT v_is_admin
     AND v_order.user_id <> auth.uid()
     AND v_order.delivery_driver_provider_id IS DISTINCT FROM v_provider THEN
    RAISE EXCEPTION 'NOT_YOUR_DELIVERY';
  END IF;

  -- The same escrow window every other reveal in this product uses: nothing
  -- about the delivery moves or is shown before the payment is verified.
  IF v_order.status NOT IN ('APPROVED', 'STARTED', 'COMPLETED') THEN
    RAISE EXCEPTION 'DELIVERY_NOT_REVEALED_YET';
  END IF;

  IF v_order.fulfillment_mode IS DISTINCT FROM 'DELIVERY' THEN
    RAISE EXCEPTION 'THIS_ORDER_IS_NOT_A_DELIVERY';
  END IF;

  IF v_order.delivery_driver_provider_id IS NOT NULL THEN
    SELECT st_y(ds.current_location::geometry),
           st_x(ds.current_location::geometry),
           ds.last_location_update,
           coalesce(ds.is_online, false),
           coalesce(nullif(btrim(pp.business_name), ''), pr.full_name)
      INTO v_driver_lat, v_driver_lng, v_driver_at, v_driver_online, v_driver_name
      FROM public.driver_status ds
      JOIN public.provider_profiles pp ON pp.id = ds.provider_id
      JOIN public.profiles pr ON pr.id = pp.user_id
     WHERE ds.provider_id = v_order.delivery_driver_provider_id;
  END IF;

  -- The buyer's own details ride along only for the parties allowed to see
  -- them: the buyer themselves, an admin, and — once arrival is recorded —
  -- the driver (who gets the fuller contact through
  -- get_delivery_buyer_contact).
  IF v_order.user_id = auth.uid() OR v_is_admin
     OR (v_order.delivery_arrived_at IS NOT NULL
         AND v_order.delivery_driver_provider_id IS NOT NULL
         AND v_order.delivery_driver_provider_id = v_provider) THEN
    SELECT p.full_name, p.phone INTO v_buyer_name, v_buyer_phone
      FROM public.profiles p WHERE p.id = v_order.user_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'order_status', v_order.status::text,
    'delivery_status', coalesce(v_order.delivery_status, 'ASSIGNED'),
    'dest_lat', v_order.delivery_dest_lat,
    'dest_lng', v_order.delivery_dest_lng,
    'dest_label', v_order.delivery_address,
    'driver_provider_id', v_order.delivery_driver_provider_id,
    'driver_name', v_driver_name,
    'driver_lat', v_driver_lat,
    'driver_lng', v_driver_lng,
    'driver_location_at', v_driver_at,
    'driver_online', v_driver_online,
    'arrived_at', v_order.delivery_arrived_at,
    'confirmed_at', v_order.delivery_confirmed_at,
    'buyer_contact_released', v_order.delivery_arrived_at IS NOT NULL,
    'buyer_name', v_buyer_name,
    'buyer_phone', v_buyer_phone
  );
END;
$$;

COMMENT ON FUNCTION public.get_delivery_tracking(uuid) IS
  'The delivery tracking payload for the buyer, the assigned driver or an '
  'admin: state, drop-off point and the driver''s live GPS. Escrow-gated to '
  'APPROVED and later, and the driver''s position comes from the same '
  'driver_status row the ride screens stream.';

REVOKE ALL ON FUNCTION public.get_delivery_tracking(uuid)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_delivery_tracking(uuid)
  TO authenticated, service_role;

-- "I received it". Marks the delivery DELIVERED — and only that. The ORDER
-- then completes through the existing server path (order-transition ->
-- transition_order_status), whose widened clause reads exactly this state.
-- Doing it in two deliberate steps is what keeps the money path untouched:
-- the fee still moves at STARTED, inside the FSM, where it always moved.
CREATE OR REPLACE FUNCTION public.delivery_confirm_received(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order public.orders;
  v_driver_user uuid;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.user_id <> auth.uid() AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'ONLY_THE_BUYER_MAY_CONFIRM_RECEIPT';
  END IF;

  IF v_order.fulfillment_mode IS DISTINCT FROM 'DELIVERY' THEN
    RAISE EXCEPTION 'THIS_ORDER_IS_NOT_A_DELIVERY';
  END IF;

  IF v_order.delivery_status IS DISTINCT FROM 'ARRIVED' THEN
    RAISE EXCEPTION 'RECEIPT_IS_CONFIRMED_AFTER_THE_DRIVER_ARRIVES';
  END IF;

  UPDATE public.orders
     SET delivery_status = 'DELIVERED',
         delivery_confirmed_at = now(),
         updated_at = now()
   WHERE id = p_order_id;

  -- The driver is told the parcel landed. The buyer and the seller are told
  -- by the orders status trigger the moment the order itself completes.
  IF v_order.delivery_driver_provider_id IS NOT NULL THEN
    SELECT pp.user_id INTO v_driver_user
      FROM public.provider_profiles pp
     WHERE pp.id = v_order.delivery_driver_provider_id;

    PERFORM public.notify_user_safe(
      'delivery-received:' || p_order_id::text,
      v_driver_user,
      'ORDER_COMPLETED',
      'Delivery confirmed by the buyer',
      'The buyer confirmed they received order #' || left(v_order.id::text, 8)
      || '. Thank you.',
      jsonb_build_object('order_id', p_order_id)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'delivery_status', 'DELIVERED',
    'next', 'complete_order',
    'note', 'The order completes through order-transition (COMPLETED); the '
            || 'transaction fee already moved at STARTED, as it always has.'
  );
END;
$$;

COMMENT ON FUNCTION public.delivery_confirm_received(uuid) IS
  'The buyer confirms the parcel arrived: delivery_status = DELIVERED and the '
  'driver is told. The order itself completes through the existing '
  'order-transition path, which now admits the buyer for a STARTED delivery '
  'in exactly this state.';

REVOKE ALL ON FUNCTION public.delivery_confirm_received(uuid)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.delivery_confirm_received(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. transition_order_status — restated, ONE clause added
-- ---------------------------------------------------------------------------
-- Body copied verbatim from 20260930000001_provider_verifies_buyer_payment.sql
-- (the live definition), including the fulfilment gate for a provider actor,
-- the buyer-opens-payment clause from 20260927000085 and the provider-or-admin
-- PAYMENT_VERIFICATION branch. The ONLY change is the STARTED branch: the
-- order's own buyer may complete it when — and only when — this is their
-- DELIVERY order and delivery_confirm_received has already recorded the
-- receipt. Every other branch is unchanged, and the money line at STARTED is
-- unchanged.
CREATE OR REPLACE FUNCTION public.transition_order_status(
  p_order_id uuid,
  p_new_status order_status,
  p_actor uuid,
  p_note text DEFAULT null
)
RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order orders;
  v_old order_status;
  v_valid boolean := false;
  v_actor_is_provider boolean := false;
  v_actor_is_admin boolean := false;
  v_buyer_may_open_payment boolean := false;
  v_blockers text[];
BEGIN
  SELECT * INTO v_order FROM orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  v_old := v_order.status;

  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_actor AND role = 'ADMIN')
    INTO v_actor_is_admin;
  SELECT exists (SELECT 1 FROM provider_profiles WHERE id = v_order.provider_id AND user_id = p_actor)
    INTO v_actor_is_provider;

  -- Unchanged (20260927000113): accepting an order is taking the work, so a
  -- provider actor must be fulfilment-ready. An admin/CEO acting on the same
  -- order is doing the job this gate exists to make possible, so they are not
  -- gated on the provider's paperwork.
  IF v_actor_is_provider AND NOT v_actor_is_admin THEN
    v_blockers := public.provider_fulfilment_blockers(v_order.provider_id);
    IF COALESCE(array_length(v_blockers, 1), 0) > 0 THEN
      RAISE EXCEPTION 'PROVIDER_NOT_FULFILMENT_READY: %', array_to_string(v_blockers, ',');
    END IF;
  END IF;

  v_buyer_may_open_payment :=
    v_order.requires_availability_confirmation
    AND v_order.user_id = p_actor
    AND NOT v_actor_is_admin;

  v_valid := case v_old
    when 'CREATED' then
      p_new_status in ('PENDING_PROVIDER','CANCELLED')
      AND (v_order.user_id = p_actor OR v_actor_is_admin)

    when 'PENDING_PROVIDER' then
      (p_new_status in ('ACCEPTED','REJECTED') AND (v_actor_is_provider OR v_actor_is_admin))
      OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin))

    when 'ACCEPTED' then
      (p_new_status = 'PAYMENT_PENDING'
        AND (v_actor_is_provider OR v_actor_is_admin OR v_buyer_may_open_payment))
      OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin))

    when 'PAYMENT_PENDING' then
      (p_new_status = 'PAYMENT_VERIFICATION' AND v_order.user_id = p_actor)
      OR (p_new_status = 'CANCELLED' AND v_actor_is_admin)

    -- THE CHANGED LINE. The buyer is deliberately absent: the money reached
    -- the provider, so the provider decides, and the platform's admin may
    -- always override. `v_order.user_id = p_actor` is NOT consulted here.
    when 'PAYMENT_VERIFICATION' then
      p_new_status in ('APPROVED','REJECTED') AND (v_actor_is_provider OR v_actor_is_admin)

    when 'APPROVED' then
      (p_new_status = 'STARTED' AND (v_actor_is_provider OR v_actor_is_admin))
      OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin))

    when 'STARTED' then
      (p_new_status = 'COMPLETED' AND (v_actor_is_provider OR v_actor_is_admin))
      -- The delivery receipt (20261026000002): the buyer alone may complete
      -- their OWN order when it is a delivery whose driver marked arrival and
      -- whose buyer then confirmed receipt. Both facts are server-written by
      -- delivery_confirm_received(), which refuses anyone who is not the
      -- order's buyer — so this clause hands the buyer no other power.
      OR (p_new_status = 'COMPLETED'
          AND v_order.user_id = p_actor
          AND v_order.fulfillment_mode = 'DELIVERY'
          AND v_order.delivery_status = 'DELIVERED')
      OR (p_new_status in ('DISPUTED','CANCELLED') AND (v_order.user_id = p_actor OR v_actor_is_admin))

    when 'COMPLETED' then
      (p_new_status in ('DISPUTED','REFUNDED') AND (v_order.user_id = p_actor OR v_actor_is_admin))
      OR (p_new_status = 'CANCELLED' AND v_actor_is_admin)

    when 'DISPUTED' then
      p_new_status in ('REFUNDED','COMPLETED') AND v_actor_is_admin

    else false
  end;

  IF NOT v_valid THEN
    RAISE EXCEPTION 'INVALID_TRANSITION_%_TO_%_FOR_ACTOR', v_old, p_new_status;
  END IF;

  -- Unchanged: contact and fulfilment stay behind a VERIFIED proof.
  IF p_new_status = 'APPROVED' AND v_order.requires_payment_proof THEN
    IF NOT exists (
      SELECT 1 FROM payment_proofs
       WHERE order_id = p_order_id AND verification_status = 'VERIFIED'
    ) THEN
      RAISE EXCEPTION 'PAYMENT_PROOF_REQUIRED';
    END IF;
  END IF;

  UPDATE orders SET status = p_new_status, updated_at = now()
   WHERE id = p_order_id
   RETURNING * INTO v_order;

  INSERT INTO order_status_history (order_id, from_status, to_status, changed_by, note)
  VALUES (p_order_id, v_old, p_new_status, p_actor, p_note);

  -- Unchanged (migration 73): the transaction fee moves at STARTED.
  IF p_new_status = 'STARTED' THEN
    PERFORM deduct_transaction_fee(
      v_order.provider_id, p_order_id, null, v_order.total_amount,
      'order:' || p_order_id::text
    );
  END IF;

  RETURN v_order;
END;
$$;

COMMENT ON FUNCTION public.transition_order_status(uuid, order_status, uuid, text) IS
  'The order lifecycle whitelist. PAYMENT_VERIFICATION may be left by an admin '
  'OR by the order''s own provider — the party the buyer paid — and by nobody '
  'else; the BUYER is deliberately excluded. APPROVED still requires a VERIFIED '
  'payment proof. A STARTED delivery whose receipt the buyer confirmed through '
  'delivery_confirm_received() may additionally be completed by that buyer.';

REVOKE ALL ON FUNCTION public.transition_order_status(uuid, order_status, uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transition_order_status(uuid, order_status, uuid, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. The assertion: this flow is wired, or the deploy says so
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_delivery_flow_is_wired()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_whitelist text;
  v_arrived text;
  v_policy boolean;
  v_missing text := '';
BEGIN
  -- 1. The columns. A missing one makes every read below NULL rather than
  --    wrong, which is the worst shape a failure can take.
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'orders'
       AND column_name IN ('delivery_dest_lat', 'delivery_dest_lng',
                           'delivery_driver_provider_id', 'delivery_status',
                           'delivery_arrived_at', 'delivery_confirmed_at')
     GROUP BY table_name
    HAVING count(*) = 6
  ) THEN
    RETURN 'FAIL: the delivery columns are not all on orders, so a delivery '
           || 'has no destination, no driver and no state';
  END IF;

  -- 2. Every door this flow opens.
  IF to_regprocedure('public.assign_delivery_driver(uuid, uuid)') IS NULL THEN
    v_missing := v_missing || ' assign_delivery_driver';
  END IF;
  IF to_regprocedure('public.admin_delivery_drivers()') IS NULL THEN
    v_missing := v_missing || ' admin_delivery_drivers';
  END IF;
  IF to_regprocedure('public.my_delivery_jobs()') IS NULL THEN
    v_missing := v_missing || ' my_delivery_jobs';
  END IF;
  IF to_regprocedure('public.delivery_mark_arrived(uuid)') IS NULL THEN
    v_missing := v_missing || ' delivery_mark_arrived';
  END IF;
  IF to_regprocedure('public.delivery_confirm_received(uuid)') IS NULL THEN
    v_missing := v_missing || ' delivery_confirm_received';
  END IF;
  IF to_regprocedure('public.get_delivery_tracking(uuid)') IS NULL THEN
    v_missing := v_missing || ' get_delivery_tracking';
  END IF;
  IF to_regprocedure('public.get_delivery_buyer_contact(uuid)') IS NULL THEN
    v_missing := v_missing || ' get_delivery_buyer_contact';
  END IF;
  IF v_missing <> '' THEN
    RETURN 'FAIL: these delivery functions do not exist:' || v_missing;
  END IF;

  -- 3. The buyer's door to the driver's GPS. Without the policy the realtime
  --    subscription is a silent no-op and the tracking map never moves — the
  --    exact failure 20260925210000 fixed for rides.
  SELECT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'driver_status'
       AND policyname = 'delivery_buyer_reads_driver_status'
  ) INTO v_policy;
  IF NOT v_policy THEN
    RETURN 'FAIL: the buyer has no policy to read their assigned driver''s '
           || 'live location, so the delivery tracking map is dead';
  END IF;

  -- 4. The whitelist: the new buyer clause must be there, and the old
  --    provider/admin clause must STILL be there. A restatement that swapped
  --    one for the other would let a seller complete their own orders again.
  SELECT regexp_replace(lower(p.prosrc), E'\s+', ' ', 'g') INTO v_whitelist
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'transition_order_status';

  IF position('v_actor_is_provider or v_actor_is_admin' in v_whitelist) = 0
     OR position('v_actor_is_provider or v_actor_is_admin or v_buyer_may_open_payment'
                 in v_whitelist) = 0 THEN
    RETURN 'FAIL: transition_order_status lost the provider/admin clauses of '
           || 'the whitelist while adding the delivery receipt';
  END IF;

  IF position('delivery_status = ''delivered''' in v_whitelist) = 0
     OR position('fulfillment_mode = ''delivery''' in v_whitelist) = 0 THEN
    RETURN 'FAIL: transition_order_status no longer admits a buyer to complete '
           || 'a received delivery, so the "I received it" button cannot finish '
           || 'the order';
  END IF;

  -- The buyer must still be barred from completing anything else: the new
  -- clause is gated on the delivery state, and that gate is checked here.
  IF position('when ''started'' then (p_new_status = ''completed'' and (v_actor_is_provider or v_actor_is_admin))'
              in v_whitelist) = 0 THEN
    RETURN 'FAIL: the STARTED -> COMPLETED clause is not the reviewed shape, '
           || 'so the delivery receipt may have widened completion for everyone';
  END IF;

  -- 5. Arrival is the reveal, and it is written where the reveal reads it.
  SELECT regexp_replace(lower(p.prosrc), E'\s+', ' ', 'g') INTO v_arrived
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'delivery_mark_arrived';

  IF position('delivery_status = ''arrived''' in v_arrived) = 0
     OR position('delivery_arrived_at' in v_arrived) = 0 THEN
    RETURN 'FAIL: delivery_mark_arrived no longer records the arrival the '
           || 'buyer contact reveal depends on';
  END IF;

  RETURN 'ok: the delivery has a destination, a driver, an arrival, a receipt '
         || 'and a live-tracking policy, and the whitelist gained the receipt '
         || 'clause without losing anything else';
END;
$$;

COMMENT ON FUNCTION public.assert_delivery_flow_is_wired() IS
  'Read-only. Proves the delivery flow exists end to end: the columns, the '
  'functions, the buyer''s GPS policy, and that transition_order_status gained '
  'the buyer-receipt clause without dropping any branch it had.';

REVOKE ALL ON FUNCTION public.assert_delivery_flow_is_wired() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_delivery_flow_is_wired()
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. Self-check: the assertion must actually be able to fail this deploy
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_verdict text;
BEGIN
  v_verdict := public.assert_delivery_flow_is_wired();
  -- A FAIL raised here stops the deploy at the migration that caused it,
  -- instead of leaving a half-wired flow for a screen to discover later.
  IF v_verdict LIKE 'FAIL%' THEN
    RAISE EXCEPTION '20261026000002: %', v_verdict;
  END IF;
END $$;
