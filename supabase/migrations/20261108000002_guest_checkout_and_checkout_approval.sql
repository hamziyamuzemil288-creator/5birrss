-- =============================================================================
-- 20261108000002 — guest checkout + the admin checkout-approval gate
-- =============================================================================
--
-- WHAT THIS MIGRATION ADDS
-- ------------------------
-- 1. Anonymous ("guest") accounts can finish signup. The app's first screen is
--    the dashboard and a buyer no longer registers, so the device opens a
--    Supabase ANONYMOUS session when it needs an identity (checkout, an order,
--    a push token). handle_new_user() is re-emitted with ONE early branch for
--    that subject; every other signup path is byte-for-byte the previous body.
--
-- 2. Buyer contact on the order. A guest has no profile worth reading at the
--    door, so checkout writes the name and phone the delivery actually needs
--    onto the order itself.
--
-- 3. The checkout-approval gate. A delivery order submitted by the current app
--    is created exactly as before and then moved to AWAITING_APPROVAL by
--    attach_checkout_request(); an admin decides it in
--    admin_review_checkout_request(), which is the ONLY place a vehicle and a
--    driver are attached. Every decision writes audit_logs.
--
-- WHY THIS IS BACKWARD COMPATIBLE
-- -------------------------------
-- * Older app versions call order-create without `request_approval`, so their
--   orders keep starting in PENDING_PROVIDER. Nothing in this file changes a
--   path they take.
-- * No column is dropped and no existing policy is removed. The self-pickup
--   value stays readable (old orders still display it) even though the new
--   checkout never writes it.
-- * The approval RPCs are additive; the existing assign_delivery_driver() is
--   left untouched for the admin order screen.
--
-- SECURITY
-- --------
-- * Anonymous sessions are real auth subjects: RLS still scopes every row by
--   auth.uid(), so a guest can only ever read their own order. Nothing here
--   grants anon a table privilege.
-- * prevent_anonymous_write() makes the privileged tables read-only for a
--   guest JWT, so "authenticated" cannot be used as a shortcut to open a
--   business account. Service-role/definer paths have no JWT and are
--   unaffected.
-- * Every new function is SECURITY DEFINER with a pinned search_path and a
--   role check before it does anything.
--
-- Deploy: after 20261108000001 (the enum value), before the app build.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Anonymous signups create an ordinary, approved buyer profile
-- ---------------------------------------------------------------------------
-- Re-emitted from 20261014000000 with ONE addition: the `new.is_anonymous`
-- branch at the top. The OTP gate below it is untouched — an anonymous subject
-- has no email to verify, and it is not a provider or a staff gateway, so it
-- must not fall through to EMAIL_OTP_REQUIRED.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin_subject boolean;
  v_provider text;
  v_referral_code text := upper(btrim(coalesce(new.raw_user_meta_data ->> 'referral_code', '')));
  v_referrer_staff_id uuid;
  v_referrer_name text;
  v_is_provider boolean := coalesce(new.raw_user_meta_data ->> 'provider_type', '') <> '';
  v_staff_assisted boolean := false;
  v_provider_id uuid;
  v_welcome_name text;
BEGIN
  -- 20261108000002: a guest buyer.
  --
  -- Supabase's anonymous sign-in creates a real auth.users row with
  -- is_anonymous = true and no email/phone. That identity is what lets a guest
  -- place an order under RLS (auth.uid() = orders.user_id), receive a push
  -- token, and subscribe to their own order's realtime updates. It is a BUYER
  -- and nothing else: no provider row, no staff row, no document request.
  IF coalesce(new.is_anonymous, false) THEN
    INSERT INTO public.profiles (id, full_name, phone, email, national_id, status, city)
    VALUES (
      new.id,
      coalesce(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''), 'Guest'),
      nullif(btrim(new.raw_user_meta_data ->> 'phone'), ''),
      NULL,
      NULL,
      'APPROVED'::account_status,
      public.default_city()
    ) ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.user_roles (user_id, role)
    VALUES (new.id, 'USER'::app_role)
    ON CONFLICT (user_id, role) DO NOTHING;

    -- Closed on arrival: there is nothing for a human to approve. A PENDING row
    -- here would park every guest in the admin approval counters.
    INSERT INTO public.approval_requests (subject_type, subject_id, status)
    SELECT 'USER', new.id, 'APPROVED'::account_status
    WHERE NOT EXISTS (
      SELECT 1 FROM public.approval_requests
      WHERE subject_type = 'USER' AND subject_id = new.id
    );

    RETURN new;
  END IF;

  v_provider := NULLIF(btrim(coalesce(new.raw_app_meta_data ->> 'provider', '')), '');

  v_is_admin_subject := (
    (new.email_confirmed_at IS NOT NULL AND new.raw_user_meta_data IS NULL)
    OR COALESCE(new.raw_app_meta_data ->> 'staff_gateway', '') = 'true'
    OR (v_provider IS NOT NULL AND v_provider NOT IN ('email', 'phone'))
  );

  IF public.signup_otp_required()
     AND NOT v_is_admin_subject
     AND NOT public.otp_verified_recently(new.email) THEN
    RAISE EXCEPTION 'EMAIL_OTP_REQUIRED: verify your email code before creating the account';
  END IF;

  IF v_referral_code <> '' THEN
    SELECT c.staff_id, s.name
      INTO v_referrer_staff_id, v_referrer_name
      FROM public.referral_codes c
      JOIN public.staff s ON s.id = c.staff_id
     WHERE upper(btrim(c.code)) = v_referral_code
       AND c.is_active
       AND s.is_active
     LIMIT 1;
  END IF;

  v_staff_assisted := v_is_provider AND v_referrer_staff_id IS NOT NULL;

  INSERT INTO public.profiles (id, full_name, phone, email, national_id, status, city, kebele, street_road)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data ->> 'full_name', 'New User'),
    COALESCE(new.phone, new.raw_user_meta_data ->> 'phone'),
    new.email,
    new.raw_user_meta_data ->> 'national_id',
    'APPROVED'::account_status,
    COALESCE(NULLIF(new.raw_user_meta_data ->> 'city', ''), public.default_city()),
    NULLIF(new.raw_user_meta_data ->> 'kebele', ''),
    NULLIF(new.raw_user_meta_data ->> 'street_road', '')
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (new.id, 'USER'::app_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  INSERT INTO public.approval_requests (subject_type, subject_id, status)
  SELECT 'USER', new.id, 'APPROVED'::account_status
  WHERE NOT EXISTS (
    SELECT 1 FROM public.approval_requests
    WHERE subject_type = 'USER' AND subject_id = new.id
  );

  IF v_is_provider THEN
    INSERT INTO public.provider_profiles
      (user_id, provider_type, business_name, owner_national_id, status, city, kebele, street_road,
       referral_code, referred_by_staff_id, referred_by_name)
    SELECT
      new.id,
      (new.raw_user_meta_data ->> 'provider_type')::app_role,
      COALESCE(
        new.raw_user_meta_data ->> 'business_name',
        new.raw_user_meta_data ->> 'full_name',
        'New Provider'
      ),
      new.raw_user_meta_data ->> 'national_id',
      CASE WHEN v_staff_assisted
           THEN 'PENDING_APPROVAL'::account_status
           ELSE 'APPROVED'::account_status END,
      COALESCE(NULLIF(new.raw_user_meta_data ->> 'city', ''), public.default_city()),
      NULLIF(new.raw_user_meta_data ->> 'kebele', ''),
      NULLIF(new.raw_user_meta_data ->> 'street_road', ''),
      CASE WHEN v_referrer_staff_id IS NULL AND v_referral_code <> '' THEN v_referral_code END,
      v_referrer_staff_id,
      v_referrer_name
    WHERE NOT EXISTS (
      SELECT 1 FROM public.provider_profiles WHERE user_id = new.id
    )
    RETURNING id INTO v_provider_id;
  END IF;

  IF v_provider_id IS NOT NULL THEN
    INSERT INTO public.wallets (provider_id, balance)
    VALUES (v_provider_id, 0)
    ON CONFLICT (provider_id) DO NOTHING;

    INSERT INTO public.subscriptions (provider_id, status, next_due_date)
    VALUES (v_provider_id, 'ACTIVE', now() + interval '1 month')
    ON CONFLICT (provider_id) DO NOTHING;
  END IF;

  v_welcome_name := COALESCE(NULLIF(btrim(new.raw_user_meta_data ->> 'full_name'), ''), NULL);
  PERFORM public.notify_user_once(
    'signup-welcome:' || new.id::text,
    new.id,
    'APPROVAL',
    'Welcome to Aliob',
    CASE WHEN v_staff_assisted THEN
      'Welcome to Aliob' || COALESCE(', ' || v_welcome_name, '') ||
      '. Your account was created by our team and becomes active once your documents are reviewed.'
    ELSE
      'Welcome to Aliob' || COALESCE(', ' || v_welcome_name, '') ||
      '. Your account is ready — start browsing or set up your business profile.'
    END,
    jsonb_build_object(
      'event', 'signup_welcome',
      'staff_assisted', v_staff_assisted)
  );

  RETURN new;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. The order's own record of a delivery checkout
-- ---------------------------------------------------------------------------
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS buyer_name text,
  ADD COLUMN IF NOT EXISTS buyer_phone text,
  ADD COLUMN IF NOT EXISTS buyer_note text,
  ADD COLUMN IF NOT EXISTS delivery_vehicle_category_id uuid
    REFERENCES public.categories(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS delivery_vehicle_id uuid
    REFERENCES public.vehicles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS checkout_decided_at timestamptz,
  ADD COLUMN IF NOT EXISTS checkout_decided_by uuid
    REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS checkout_rejection_reason text;

COMMENT ON COLUMN public.orders.buyer_name IS
  'The name the buyer gave at checkout (a guest has no profile worth reading at the door).';
COMMENT ON COLUMN public.orders.buyer_phone IS
  'The phone the buyer gave at checkout. Released to the assigned driver only on arrival.';
COMMENT ON COLUMN public.orders.delivery_vehicle_id IS
  'The specific fleet vehicle an admin assigned at checkout approval.';
COMMENT ON COLUMN public.orders.checkout_decided_by IS
  'The administrator who approved or rejected this checkout request.';

CREATE INDEX IF NOT EXISTS idx_orders_checkout_pending
  ON public.orders (created_at)
  WHERE status = 'AWAITING_APPROVAL';

CREATE INDEX IF NOT EXISTS idx_orders_delivery_vehicle
  ON public.orders (delivery_vehicle_id)
  WHERE delivery_vehicle_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. A guest identity must never be a business identity
-- ---------------------------------------------------------------------------
-- Anonymous sessions are `authenticated` to PostgREST, so every policy written
-- as "TO authenticated" would otherwise apply to them. These tables are the
-- ones where that would be a privilege, not a convenience. The trigger is a
-- no-op for real accounts and for service-role/definer writes (no JWT).
CREATE OR REPLACE FUNCTION public.prevent_anonymous_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) THEN
    RAISE EXCEPTION 'GUEST_ACCOUNT_IS_READ_ONLY';
  END IF;
  -- BEFORE DELETE must return OLD (returning NULL would silently cancel the
  -- delete); every other operation returns NEW.
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DO $$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'provider_profiles', 'products', 'product_images', 'vehicles',
    'vehicle_images', 'user_roles', 'staff', 'staff_permissions',
    'system_settings', 'app_release_config', 'banks', 'provider_stores'
  ] LOOP
    IF EXISTS (
      SELECT 1 FROM pg_tables
       WHERE schemaname = 'public' AND tablename = v_table
    ) THEN
      EXECUTE format(
        'DROP TRIGGER IF EXISTS trg_guest_read_only ON public.%I', v_table);
      EXECUTE format(
        'CREATE TRIGGER trg_guest_read_only BEFORE INSERT OR UPDATE OR DELETE '
        'ON public.%I FOR EACH ROW EXECUTE FUNCTION public.prevent_anonymous_write()',
        v_table);
    END IF;
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION public.prevent_anonymous_write() FROM public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Submit a checkout request (called by the order-create Edge Function)
-- ---------------------------------------------------------------------------
-- The Edge Function has already created the order through create_order_secure
-- (service role). This attaches the guest's delivery details and asks for an
-- admin decision. Service-role only: the buyer's identity is the parameter the
-- Edge Function read from the authenticated session, never a client claim.
CREATE OR REPLACE FUNCTION public.attach_checkout_request(
  p_order_id uuid,
  p_user_id uuid,
  p_buyer_name text DEFAULT NULL,
  p_buyer_phone text DEFAULT NULL,
  p_buyer_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order public.orders;
  v_name text := left(btrim(coalesce(p_buyer_name, '')), 120);
  v_phone text := left(btrim(coalesce(p_buyer_phone, '')), 40);
  v_note text := left(btrim(coalesce(p_buyer_note, '')), 1000);
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;
  IF v_order.user_id IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'NOT_YOUR_ORDER';
  END IF;
  IF v_order.status NOT IN ('PENDING_PROVIDER', 'CREATED') THEN
    RAISE EXCEPTION 'CHECKOUT_REQUEST_CANNOT_BE_SUBMITTED_NOW';
  END IF;
  IF v_order.fulfillment_mode IS DISTINCT FROM 'DELIVERY' THEN
    RAISE EXCEPTION 'CHECKOUT_IS_DELIVERY_ONLY';
  END IF;

  UPDATE public.orders
     SET status = 'AWAITING_APPROVAL',
         buyer_name = NULLIF(v_name, ''),
         buyer_phone = NULLIF(v_phone, ''),
         buyer_note = NULLIF(v_note, ''),
         updated_at = now()
   WHERE id = p_order_id;

  INSERT INTO public.order_status_history
    (id, order_id, from_status, to_status, changed_by, note)
  VALUES
    (gen_random_uuid(), p_order_id, v_order.status, 'AWAITING_APPROVAL',
     p_user_id, 'Checkout submitted — waiting for admin approval');

  RETURN jsonb_build_object('ok', true, 'status', 'AWAITING_APPROVAL');
END;
$$;

COMMENT ON FUNCTION public.attach_checkout_request(uuid, uuid, text, text, text) IS
  'Service-role only: moves a freshly created delivery order to AWAITING_APPROVAL '
  'and records the name/phone/location note the buyer gave at checkout.';

REVOKE ALL ON FUNCTION public.attach_checkout_request(uuid, uuid, text, text, text)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.attach_checkout_request(uuid, uuid, text, text, text)
  TO service_role;

-- Tell the admins, once per request. The buyer is not notified here: their own
-- waiting screen shows the live status, and a "we received it" push would be
-- noise on top of it.
CREATE OR REPLACE FUNCTION public.notify_new_checkout_request(p_order_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order public.orders;
  v_admin uuid;
  v_sent int := 0;
  v_ref text;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order.id IS NULL THEN
    RETURN 0;
  END IF;

  v_ref := coalesce(nullif(v_order.order_number, ''), left(v_order.id::text, 8));

  FOR v_admin IN
    SELECT DISTINCT ur.user_id FROM public.user_roles ur
     WHERE ur.role = 'ADMIN'
  LOOP
    IF public.notify_user_safe(
      'checkout-request:' || p_order_id::text || ':' || v_admin::text,
      v_admin,
      'ORDER_RECEIVED',
      'New checkout request',
      'Order #' || v_ref || ' needs a decision. Open Checkout Requests to '
      || 'review the delivery, assign a vehicle and driver, or reject it.',
      jsonb_build_object('order_id', p_order_id, 'event', 'checkout_request')
    ) THEN
      v_sent := v_sent + 1;
    END IF;
  END LOOP;

  RETURN v_sent;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_new_checkout_request(uuid)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.notify_new_checkout_request(uuid) TO service_role;

-- Callable by the Edge Function after attach_checkout_request succeeds. Kept
-- separate so a notification failure can never undo the order.
CREATE OR REPLACE FUNCTION public.submit_checkout_request(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN jsonb_build_object(
    'ok', true,
    'admins_notified', public.notify_new_checkout_request(p_order_id)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.submit_checkout_request(uuid)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_checkout_request(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. The admin queue
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_checkout_request_count()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN public.is_admin() THEN (
    SELECT count(*)::int FROM public.orders WHERE status = 'AWAITING_APPROVAL'
  ) ELSE 0 END;
$$;

REVOKE ALL ON FUNCTION public.admin_checkout_request_count() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_checkout_request_count() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_checkout_requests(
  p_tab text DEFAULT 'PENDING',
  p_search text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tab text := upper(coalesce(nullif(btrim(p_tab), ''), 'PENDING'));
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_rows jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ONLY_AN_ADMINISTRATOR_MAY_READ_CHECKOUT_REQUESTS';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT o.id,
             o.order_number,
             o.status::text AS status,
             o.created_at,
             o.checkout_decided_at,
             o.checkout_rejection_reason,
             coalesce(nullif(btrim(o.buyer_name), ''), pr.full_name) AS buyer_name,
             coalesce(nullif(btrim(o.buyer_phone), ''), pr.phone) AS buyer_phone,
             o.fulfillment_mode,
             o.delivery_address,
             o.delivery_dest_lat,
             o.delivery_dest_lng,
             o.total_amount,
             o.currency,
             o.delivery_driver_provider_id,
             o.delivery_vehicle_id,
             o.delivery_vehicle_category_id,
             o.delivery_status,
             pp.business_name AS provider_name,
             pp.city AS provider_city,
             (SELECT count(*)::int FROM public.order_items oi
               WHERE oi.order_id = o.id) AS item_count,
             (SELECT count(*)::int FROM public.payment_proofs pf
               WHERE pf.order_id = o.id) AS proof_count,
             driver.business_name AS driver_name,
             veh.plate_number AS vehicle_plate
        FROM public.orders o
        LEFT JOIN public.profiles pr ON pr.id = o.user_id
        LEFT JOIN public.provider_profiles pp ON pp.id = o.provider_id
        LEFT JOIN public.provider_profiles driver
               ON driver.id = o.delivery_driver_provider_id
        LEFT JOIN public.vehicles veh ON veh.id = o.delivery_vehicle_id
       WHERE (
         CASE v_tab
           WHEN 'PENDING' THEN o.status = 'AWAITING_APPROVAL'
           WHEN 'APPROVED' THEN o.status IN ('APPROVED', 'STARTED', 'COMPLETED')
           WHEN 'REJECTED' THEN o.status IN ('REJECTED', 'CANCELLED')
           ELSE o.status IN ('AWAITING_APPROVAL', 'APPROVED', 'STARTED',
                             'COMPLETED', 'REJECTED', 'CANCELLED')
         END
       )
       AND (
         v_search IS NULL
         OR coalesce(o.order_number, '') ILIKE '%' || v_search || '%'
         OR coalesce(o.buyer_name, '') ILIKE '%' || v_search || '%'
         OR coalesce(o.buyer_phone, '') ILIKE '%' || v_search || '%'
         OR coalesce(pp.business_name, '') ILIKE '%' || v_search || '%'
         OR left(o.id::text, 8) ILIKE '%' || v_search || '%'
       )
       ORDER BY o.created_at DESC
       LIMIT 300
    ) t;

  RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION public.admin_checkout_requests(text, text) IS
  'Admin-only queue for the checkout approval flow. PENDING is the live work, '
  'APPROVED is every decision that let the order through, REJECTED is every '
  'decision that closed it.';

REVOKE ALL ON FUNCTION public.admin_checkout_requests(text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_checkout_requests(text, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_checkout_request_detail(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order public.orders;
  v_items jsonb;
  v_proofs jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ONLY_AN_ADMINISTRATOR_MAY_READ_A_CHECKOUT_REQUEST';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price,
             p.name AS product_name, p.unit
        FROM public.order_items oi
        LEFT JOIN public.products p ON p.id = oi.product_id
       WHERE oi.order_id = p_order_id
    ) t;

  SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb), '[]'::jsonb)
    INTO v_proofs
    FROM (
      SELECT pf.id, pf.storage_path, pf.verification_status, pf.created_at
        FROM public.payment_proofs pf
       WHERE pf.order_id = p_order_id
       ORDER BY pf.created_at DESC
    ) t;

  RETURN jsonb_build_object(
    'order', to_jsonb(v_order),
    'buyer_name', coalesce(nullif(btrim(v_order.buyer_name), ''), 'Guest'),
    'buyer_phone', v_order.buyer_phone,
    'items', v_items,
    'payment_proofs', v_proofs,
    'provider_name', (
      SELECT business_name FROM public.provider_profiles
       WHERE id = v_order.provider_id
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_checkout_request_detail(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_checkout_request_detail(uuid)
  TO authenticated, service_role;

-- The vehicles an admin may attach to a driver. Approved, available, and of
-- the driver's own fleet — the same rule the review RPC re-checks under a
-- row lock.
CREATE OR REPLACE FUNCTION public.admin_delivery_vehicles(p_driver_provider_id uuid)
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
    RAISE EXCEPTION 'DELIVERY_VEHICLES_ARE_ADMIN_ONLY';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT v.id, v.category_id, v.brand, v.model, v.plate_number,
             v.color, v.capacity, v.is_available,
             c.name AS category_name
        FROM public.vehicles v
        LEFT JOIN public.categories c ON c.id = v.category_id
       WHERE v.provider_id = p_driver_provider_id
         AND v.status = 'APPROVED'
       ORDER BY v.is_available DESC, v.plate_number
    ) t;

  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delivery_vehicles(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_delivery_vehicles(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5b. The proof-verification guard must recognise the server path
-- ---------------------------------------------------------------------------
-- The approval below records the admin's decision on the payment proof in the
-- same transaction. It runs as service_role (the order-status guard forbids a
-- client-originated status change, even with an ADMIN JWT), so auth.uid() is
-- NULL and is_admin() is false inside that call. The existing trigger would
-- therefore refuse the proof update with VERIFICATION_IS_ADMIN_ONLY and undo
-- the whole approval. This restatement adds the server-write branch and keeps
-- the provider-ownership branch unchanged; a client is still refused.
CREATE OR REPLACE FUNCTION public.prevent_payment_proof_self_verification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_provider_owns boolean := false;
BEGIN
  IF new.verification_status IS DISTINCT FROM old.verification_status THEN
    IF public.is_server_write() OR public.is_admin() THEN
      RETURN new;
    END IF;

    -- The provider the buyer paid may decide their own order's proof. Scoped
    -- to ownership of this order's provider profile, so this grants no reach
    -- over another provider's order and never over the buyer's own.
    SELECT EXISTS (
      SELECT 1
        FROM public.orders o
       WHERE o.id = new.order_id
         AND o.provider_id IS NOT NULL
         AND public.owns_provider_profile(o.provider_id)
    ) INTO v_provider_owns;

    IF NOT v_provider_owns THEN
      RAISE EXCEPTION 'VERIFICATION_IS_ADMIN_ONLY';
    END IF;
  END IF;

  RETURN new;
END;
$$;

COMMENT ON FUNCTION public.prevent_payment_proof_self_verification() IS
  'A payment proof is verified only by an administrator, the order''s own '
  'provider, or the server path (checkout approval, which runs as service_role '
  'because the order status change must be a server write).';

-- ---------------------------------------------------------------------------
-- 6. The decision — the only place a vehicle and a driver are attached
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_review_checkout_request(
  p_order_id uuid,
  p_decision text,
  p_reason text DEFAULT NULL,
  p_vehicle_category_id uuid DEFAULT NULL,
  p_vehicle_id uuid DEFAULT NULL,
  p_driver_provider_id uuid DEFAULT NULL,
  -- The reviewer, passed by the `checkout-review` Edge Function after it has
  -- verified the caller's JWT. It is not `auth.uid()` because this function
  -- is service-role only: the order's status change must run as a server
  -- write (prevent_order_self_privilege_escalation refuses a client-originated
  -- status change even for an admin JWT), and a service-role call has no
  -- auth.uid(). Taking the id as an argument keeps the audit trail exact.
  p_admin_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order public.orders;
  v_decision text := upper(coalesce(btrim(p_decision), ''));
  v_reason text := left(btrim(coalesce(p_reason, '')), 500);
  v_driver public.provider_profiles;
  v_vehicle public.vehicles;
  v_buyer uuid;
  v_provider_user uuid;
  v_driver_user uuid;
  v_ref text;
  v_busy int;
  v_has_proof boolean;
BEGIN
  -- This function is EXECUTE-granted to service_role only, and the Edge
  -- Function has already authenticated the caller; this check is the second,
  -- independent guarantee that the id it names really holds ADMIN.
  IF p_admin_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_roles ur
     WHERE ur.user_id = p_admin_id AND ur.role = 'ADMIN'
  ) THEN
    RAISE EXCEPTION 'ONLY_AN_ADMINISTRATOR_MAY_DECIDE_A_CHECKOUT_REQUEST';
  END IF;
  IF v_decision NOT IN ('APPROVE', 'REJECT') THEN
    RAISE EXCEPTION 'DECISION_MUST_BE_APPROVE_OR_REJECT';
  END IF;

  -- FOR UPDATE is the two-admins-at-once guard: the second reviewer waits,
  -- then reads AWAITING_APPROVAL already gone and is refused instead of
  -- overwriting the first decision.
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;
  IF v_order.status <> 'AWAITING_APPROVAL' THEN
    RAISE EXCEPTION 'CHECKOUT_REQUEST_ALREADY_DECIDED';
  END IF;

  v_ref := coalesce(nullif(v_order.order_number, ''), left(v_order.id::text, 8));
  v_buyer := v_order.user_id;

  IF v_decision = 'REJECT' THEN
    IF v_reason = '' THEN
      RAISE EXCEPTION 'A_REJECTION_NEEDS_A_REASON';
    END IF;

    UPDATE public.orders
       SET status = 'REJECTED',
           checkout_rejection_reason = v_reason,
           checkout_decided_at = now(),
           checkout_decided_by = p_admin_id,
           updated_at = now()
     WHERE id = p_order_id;

    INSERT INTO public.order_status_history
      (id, order_id, from_status, to_status, changed_by, note)
    VALUES
      (gen_random_uuid(), p_order_id, 'AWAITING_APPROVAL', 'REJECTED',
       p_admin_id, 'Rejected: ' || v_reason);

    INSERT INTO public.audit_logs
      (actor_id, event_type, entity_type, entity_id, metadata)
    VALUES
      (p_admin_id, 'CHECKOUT_REQUEST_REJECTED', 'ORDER', p_order_id,
       jsonb_build_object('reason', v_reason, 'ref', v_ref));

    PERFORM public.notify_user_safe(
      'checkout-rejected:' || p_order_id::text,
      v_buyer,
      'ORDER_REJECTED',
      'Checkout not approved',
      'Order #' || v_ref || ' was not approved. Reason: ' || v_reason,
      jsonb_build_object('order_id', p_order_id, 'event', 'checkout_rejected')
    );

    IF v_order.provider_id IS NOT NULL THEN
      SELECT pp.user_id INTO v_provider_user
        FROM public.provider_profiles pp WHERE pp.id = v_order.provider_id;
      PERFORM public.notify_user_safe(
        'checkout-rejected:' || p_order_id::text || ':provider',
        v_provider_user,
        'ORDER_REJECTED',
        'Checkout not approved',
        'Order #' || v_ref || ' was not approved by the administrator.',
        jsonb_build_object('order_id', p_order_id)
      );
    END IF;

    RETURN jsonb_build_object('ok', true, 'status', 'REJECTED');
  END IF;

  -- APPROVE
  IF p_driver_provider_id IS NULL OR p_vehicle_id IS NULL THEN
    RAISE EXCEPTION 'APPROVAL_REQUIRES_A_VEHICLE_AND_A_DRIVER';
  END IF;

  SELECT * INTO v_driver
    FROM public.provider_profiles WHERE id = p_driver_provider_id;
  IF v_driver.id IS NULL
     OR v_driver.status <> 'APPROVED'
     OR v_driver.provider_type <> 'VEHICLE_PROVIDER' THEN
    RAISE EXCEPTION 'DRIVER_MUST_BE_AN_APPROVED_VEHICLE_PROVIDER';
  END IF;

  SELECT * INTO v_vehicle FROM public.vehicles WHERE id = p_vehicle_id;
  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'VEHICLE_NOT_FOUND';
  END IF;
  IF v_vehicle.provider_id IS DISTINCT FROM p_driver_provider_id THEN
    RAISE EXCEPTION 'VEHICLE_DOES_NOT_BELONG_TO_THAT_DRIVER';
  END IF;
  IF v_vehicle.status <> 'APPROVED' OR NOT coalesce(v_vehicle.is_available, false) THEN
    RAISE EXCEPTION 'VEHICLE_IS_NOT_AVAILABLE';
  END IF;
  IF p_vehicle_category_id IS NOT NULL
     AND v_vehicle.category_id IS NOT NULL
     AND v_vehicle.category_id IS DISTINCT FROM p_vehicle_category_id THEN
    RAISE EXCEPTION 'VEHICLE_DOES_NOT_MATCH_THE_CHOSEN_TYPE';
  END IF;

  -- A vehicle can only be on one live delivery. The lock on this order does
  -- not lock OTHER orders, so the count is checked explicitly, and the partial
  -- index idx_orders_delivery_vehicle makes it cheap.
  SELECT count(*)::int INTO v_busy
    FROM public.orders o
   WHERE o.delivery_vehicle_id = p_vehicle_id
     AND o.id <> p_order_id
     AND o.status IN ('APPROVED', 'STARTED')
     AND coalesce(o.delivery_status, 'ASSIGNED') <> 'DELIVERED';
  IF v_busy > 0 THEN
    RAISE EXCEPTION 'VEHICLE_ALREADY_BUSY';
  END IF;

  SELECT count(*)::int INTO v_busy
    FROM public.orders o
   WHERE o.delivery_driver_provider_id = p_driver_provider_id
     AND o.id <> p_order_id
     AND o.status IN ('APPROVED', 'STARTED')
     AND coalesce(o.delivery_status, 'ASSIGNED') <> 'DELIVERED';
  IF v_busy > 0 THEN
    RAISE EXCEPTION 'DRIVER_ALREADY_BUSY';
  END IF;

  -- Payment rule, unchanged in substance: an order that requires a payment
  -- proof never moves forward without one. The admin's approval IS the
  -- verification step for this queue (the detail sheet shows the proof).
  SELECT EXISTS (
    SELECT 1 FROM public.payment_proofs pf WHERE pf.order_id = p_order_id
  ) INTO v_has_proof;
  IF coalesce(v_order.requires_payment_proof, true) AND NOT v_has_proof THEN
    RAISE EXCEPTION 'PAYMENT_PROOF_REQUIRED';
  END IF;

  -- The admin's approval IS the payment verification for this queue: the
  -- detail sheet shows the proof, and this decision is what records it as
  -- verified. Kept inside the same transaction as the order move, so a proof
  -- can never read VERIFIED on an order that was not approved.
  UPDATE public.payment_proofs
     SET verification_status = 'VERIFIED',
         verified_by = p_admin_id,
         verified_at = now()
   WHERE order_id = p_order_id
     AND verification_status IS DISTINCT FROM 'VERIFIED';

  UPDATE public.orders
     SET status = 'APPROVED',
         -- The chosen type is the vehicle's own category unless the admin sent
         -- a different one; either way the order records the vehicle it got.
         delivery_vehicle_category_id = coalesce(p_vehicle_category_id,
                                                 v_vehicle.category_id),
         delivery_vehicle_id = p_vehicle_id,
         delivery_driver_provider_id = p_driver_provider_id,
         delivery_status = 'ASSIGNED',
         delivery_arrived_at = NULL,
         delivery_confirmed_at = NULL,
         checkout_decided_at = now(),
         checkout_decided_by = p_admin_id,
         checkout_rejection_reason = NULL,
         updated_at = now()
   WHERE id = p_order_id;

  INSERT INTO public.order_status_history
    (id, order_id, from_status, to_status, changed_by, note)
  VALUES
    (gen_random_uuid(), p_order_id, 'AWAITING_APPROVAL', 'APPROVED',
     p_admin_id,
     'Approved and assigned vehicle ' || coalesce(v_vehicle.plate_number, '—')
     || ' / driver ' || coalesce(v_driver.business_name, '—'));

  INSERT INTO public.audit_logs
    (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES
    (p_admin_id, 'CHECKOUT_REQUEST_APPROVED', 'ORDER', p_order_id,
     jsonb_build_object(
       'ref', v_ref,
       'vehicle_id', p_vehicle_id,
       'vehicle_plate', v_vehicle.plate_number,
       'vehicle_category_id', p_vehicle_category_id,
       'driver_provider_id', p_driver_provider_id,
       'driver_name', v_driver.business_name
     ));

  -- Buyer: the state change itself is already announced by
  -- fn_notify_order_status_change (ORDER_PAYMENT_VERIFIED). This one carries
  -- the part the buyer acts on — the assigned vehicle is on its way.
  PERFORM public.notify_user_safe(
    'checkout-approved:' || p_order_id::text,
    v_buyer,
    'ORDER_ACCEPTED',
    'Checkout approved',
    'Order #' || v_ref || ' is approved. Amount: '
    || to_char(v_order.total_amount, 'FM999999990.00') || ' '
    || coalesce(v_order.currency, 'ETB')
    || '. Your driver is on the way — open the order to follow the vehicle live.',
    jsonb_build_object('order_id', p_order_id, 'event', 'checkout_approved')
  );

  SELECT pp.user_id INTO v_driver_user
    FROM public.provider_profiles pp WHERE pp.id = p_driver_provider_id;
  PERFORM public.notify_user_safe(
    'checkout-assigned:' || p_order_id::text,
    v_driver_user,
    'ORDER_RECEIVED',
    'New delivery job',
    'Order #' || v_ref || ' is assigned to you. Drop-off: '
    || coalesce(nullif(btrim(v_order.delivery_address), ''), 'open the job for the address')
    || '.',
    jsonb_build_object('order_id', p_order_id, 'event', 'delivery_assigned')
  );

  IF v_order.provider_id IS NOT NULL THEN
    SELECT pp.user_id INTO v_provider_user
      FROM public.provider_profiles pp WHERE pp.id = v_order.provider_id;
    PERFORM public.notify_user_safe(
      'checkout-approved:' || p_order_id::text || ':provider',
      v_provider_user,
      'ORDER_ACCEPTED',
      'Order approved',
      'Order #' || v_ref || ' was approved and has a driver assigned. Amount: '
      || to_char(v_order.total_amount, 'FM999999990.00') || ' '
      || coalesce(v_order.currency, 'ETB') || '.',
      jsonb_build_object('order_id', p_order_id)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'APPROVED',
    'driver_provider_id', p_driver_provider_id,
    'vehicle_id', p_vehicle_id,
    'driver_name', v_driver.business_name
  );
END;
$$;

COMMENT ON FUNCTION public.admin_review_checkout_request(uuid, text, text, uuid, uuid, uuid, uuid) IS
  'Service-role only, called by the checkout-review Edge Function after it has '
  'verified the reviewer''s ADMIN role. Approves (requires an approved, '
  'available vehicle from the driver''s fleet and a payment proof when the '
  'order requires one) or rejects with a reason. Row-locked, so two admins '
  'cannot decide the same request; writes order history, audit_logs and the '
  'notifications for buyer, driver and provider. The status change must be a '
  'server write, which is why this is not callable with an admin JWT.';

REVOKE ALL ON FUNCTION public.admin_review_checkout_request(uuid, text, text, uuid, uuid, uuid, uuid)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_review_checkout_request(uuid, text, text, uuid, uuid, uuid, uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 7. The buyer cancels from the waiting screen
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_checkout_request(
  p_order_id uuid,
  -- The buyer, verified by the checkout-cancel Edge Function. The order's
  -- status change must run as a server write, which has no auth.uid().
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order public.orders;
  v_ref text;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;
  IF p_user_id IS NULL OR v_order.user_id IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'ONLY_THE_BUYER_MAY_CANCEL_THIS_REQUEST';
  END IF;
  IF v_order.status <> 'AWAITING_APPROVAL' THEN
    RAISE EXCEPTION 'CHECKOUT_REQUEST_CAN_ONLY_BE_CANCELLED_WHILE_PENDING';
  END IF;

  UPDATE public.orders
     SET status = 'CANCELLED',
         checkout_decided_at = now(),
         updated_at = now()
   WHERE id = p_order_id;

  INSERT INTO public.order_status_history
    (id, order_id, from_status, to_status, changed_by, note)
  VALUES
    (gen_random_uuid(), p_order_id, 'AWAITING_APPROVAL', 'CANCELLED',
     p_user_id, 'Cancelled by the buyer while waiting for approval');

  v_ref := coalesce(nullif(v_order.order_number, ''), left(v_order.id::text, 8));
  INSERT INTO public.audit_logs
    (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES
    (p_user_id, 'CHECKOUT_REQUEST_CANCELLED_BY_BUYER', 'ORDER', p_order_id,
     jsonb_build_object('ref', v_ref));

  RETURN jsonb_build_object('ok', true, 'status', 'CANCELLED');
END;
$$;

COMMENT ON FUNCTION public.cancel_checkout_request(uuid, uuid) IS
  'Service-role only, called by the checkout-cancel Edge Function after it has '
  'verified the caller. Only the order''s own buyer may cancel, only while the '
  'request is AWAITING_APPROVAL; writes history and the audit row.';

REVOKE ALL ON FUNCTION public.cancel_checkout_request(uuid, uuid)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_checkout_request(uuid, uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Timeout reminders for a queue nobody opened
-- ---------------------------------------------------------------------------
-- Deduped per order per hour. The admin dashboard calls this on load; the same
-- RPC can be scheduled (pg_cron / n8n) if the team wants it without anybody
-- opening the panel.
CREATE OR REPLACE FUNCTION public.notify_stale_checkout_requests()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order record;
  v_admin uuid;
  v_sent int := 0;
  v_bucket text;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ONLY_AN_ADMINISTRATOR_MAY_REMIND_ADMINS';
  END IF;

  v_bucket := to_char(now(), 'YYYYMMDDHH');

  FOR v_order IN
    SELECT o.id,
           coalesce(nullif(o.order_number, ''), left(o.id::text, 8)) AS ref
      FROM public.orders o
     WHERE o.status = 'AWAITING_APPROVAL'
       AND o.created_at < now() - interval '10 minutes'
     ORDER BY o.created_at
     LIMIT 50
  LOOP
    FOR v_admin IN
      SELECT DISTINCT ur.user_id FROM public.user_roles ur WHERE ur.role = 'ADMIN'
    LOOP
      IF public.notify_user_safe(
        'checkout-reminder:' || v_order.id::text || ':' || v_bucket || ':' || v_admin::text,
        v_admin,
        'ADMIN_MESSAGE',
        'Checkout still waiting',
        'Order #' || v_order.ref || ' has been waiting more than 10 minutes '
        || 'for a decision.',
        jsonb_build_object('order_id', v_order.id, 'event', 'checkout_reminder')
      ) THEN
        v_sent := v_sent + 1;
      END IF;
    END LOOP;
  END LOOP;

  RETURN v_sent;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_stale_checkout_requests() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.notify_stale_checkout_requests() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. Realtime for the waiting screen
-- ---------------------------------------------------------------------------
-- orders is not in the publication today. Adding it is safe: Supabase Realtime
-- still applies the SELECT policy to every row, so a guest receives only their
-- own order.
--
-- REPLICA IDENTITY FULL is what makes that policy evaluation possible for an
-- UPDATE: without it the WAL only carries the primary key and a policy that
-- reads user_id cannot be checked, so the buyer's own approval update would be
-- dropped. It costs WAL size on orders; the waiting screen depends on it.
ALTER TABLE public.orders REPLICA IDENTITY FULL;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = 'orders'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.orders;
    END IF;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 10. PostgREST sees the new columns immediately
-- ---------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';
