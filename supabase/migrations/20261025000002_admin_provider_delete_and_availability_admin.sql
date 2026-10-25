-- =============================================================================
-- 20261025000002 — an administrator can delete a provider, and availability
-- requests reach the admin side
-- =============================================================================
--
-- PART 1 — PROVIDER DELETION
-- -------------------------
-- WHAT EXISTED: a provider could be approved, rejected, corrected, suspended
-- and reinstated (provider-approval Edge Function → the public.* functions).
-- Nothing could remove one. The only delete in the product was the CEO account
-- directory (`ceo_delete_user_account` → `delete_user_account`), which deletes
-- the auth.users row outright, and the self-service deletion request queue.
-- So an administrator looking at a fake or abandoned business had exactly one
-- option, which was the wrong one: suspend it forever.
--
-- WHY THIS IS A SOFT DELETE, AND WHY THAT IS THE SAFE CHOICE HERE
-- ---------------------------------------------------------------
-- `products` is referenced by `order_items.product_id` with NO ACTION
-- (20261015000003 reads that straight from the catalogue), and
-- `provider_profiles` cascades to `products`. Deleting the provider row
-- therefore tries to delete listings that past orders still point at, and
-- PostgreSQL refuses with 23503. Making that work would mean either deleting
-- order lines (destroying financial history) or detaching them (losing which
-- product was sold). Neither is acceptable for a marketplace that has to keep
-- receipts.
--
-- So deletion here means: the business stops existing as a live business, and
-- nothing anybody paid for is rewritten.
--
--   * `provider_profiles.deleted_at` is stamped and status becomes SUSPENDED
--     (the enum has no DELETED member, and adding one would touch every
--     predicate that says `status = 'APPROVED'`);
--   * every listing is hidden through `is_active` / `is_available`, which is
--     the flag every public surface already filters on (products_public_read,
--     visible_products_for_city, search_products, product_trending),
--     and every vehicle is taken off the road the same way;
--   * auth sessions and refresh tokens are deleted and `banned_until` is set
--     far in the future, so the provider cannot sign back in;
--   * FCM tokens are deleted, so no push is ever addressed to them again;
--   * the provider is told BEFORE the ban (they keep the inbox row);
--   * an `admin_actions` row and an `audit_logs` row record who, what, when and
--     why. Nothing here is unattributable.
--
-- OPEN WORK BLOCKS THE DELETE. Cancelling live orders on someone's behalf and
-- promising refunds from a delete button is a money decision, not a cleanup
-- decision; the function refuses and names the count. The administrator
-- resolves or closes the work first, then deletes. That is the option that
-- cannot leave a customer stuck with a driver who does not exist.
--
-- DOCUMENTS AND FILES: they stay. The provider row stays (soft delete), so no
-- file is orphaned; identity documents are retained because they are the
-- evidence behind decisions already made and because accounting/legal
-- retention applies. The CEO hard-delete path
-- (`ceo_delete_user_account` → `purge_account_storage`) remains the one route
-- that removes files, and it is unchanged.
--
-- PART 2 — AVAILABILITY REQUESTS ON THE ADMIN SIDE
-- ------------------------------------------------
-- The admin screen (`/admin/availability`) already existed with status tabs and
-- approve/decline through `respond_availability_request`. Two things were
-- missing and are added here, both server-side:
--
--   * nothing told an administrator that a request had arrived — the buyer was
--     notified of the answer and the provider of the question, but the queue
--     only filled silently, so an admin had to think to go and look;
--   * there was no count for a sidebar badge, and computing it in Dart meant
--     reading up to 300 rows to count a status the server can count exactly.
--
-- "Availability request" in this codebase means ONE thing (verified, not
-- assumed): a buyer asking, immediately before checkout, whether a specific
-- product is in stock in a specific quantity, answered by the provider or an
-- administrator within a 15-minute window
-- (`availability_requests`, 20261006000006). It is not a provider setting
-- opening hours and it is not a booking request; those do not exist as
-- separate queues in this schema.
--
-- Deploy: needs a Supabase deploy (one column, five functions, one trigger,
-- one assertion).
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The column the soft delete needs
-- ---------------------------------------------------------------------------
ALTER TABLE public.provider_profiles
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

COMMENT ON COLUMN public.provider_profiles.deleted_at IS
  'Set when an administrator removed the business. The row is kept so order '
  'and financial history still resolve; every public surface reads is_active '
  'on its listings and status on the profile, both of which deletion clears.';

-- ---------------------------------------------------------------------------
-- 2. The delete
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_delete_provider(
  p_provider_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_provider public.provider_profiles%ROWTYPE;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_open_orders int := 0;
  v_open_rides int := 0;
  v_products int := 0;
  v_vehicles int := 0;
  v_tokens int := 0;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  -- The real boundary. The sidebar hides this for staff without the job; this
  -- line is what makes that hiding a convenience rather than the security.
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  SELECT * INTO v_provider
    FROM public.provider_profiles
   WHERE id = p_provider_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  IF v_provider.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'PROVIDER_ALREADY_DELETED';
  END IF;

  -- Deleting your own business account from the admin console would lock the
  -- administrator out of the console they are standing in.
  IF v_provider.user_id = v_actor THEN
    RAISE EXCEPTION 'CANNOT_DELETE_SELF';
  END IF;

  -- Live work blocks the delete. Terminal order states are the ones the
  -- transition machine treats as finished; a disputed order is NOT terminal
  -- here on purpose — money is still in play.
  SELECT count(*) INTO v_open_orders
    FROM public.orders o
   WHERE o.provider_id = p_provider_id
     AND o.status NOT IN ('COMPLETED', 'CANCELLED', 'REJECTED', 'REFUNDED');

  SELECT count(*) INTO v_open_rides
    FROM public.ride_requests r
   WHERE r.claimed_by_provider_id = p_provider_id
     AND r.status NOT IN ('COMPLETED', 'CANCELLED');

  IF v_open_orders > 0 OR v_open_rides > 0 THEN
    -- One machine-readable sentence: the screen shows it and the counts come
    -- out of the same measurement that refused the call.
    RAISE EXCEPTION 'PROVIDER_HAS_OPEN_WORK orders=% rides=%',
      v_open_orders, v_open_rides;
  END IF;

  -- Before access is removed: the inbox row survives the revocation, and the
  -- wording does not pretend the decision was automatic.
  PERFORM public.notify_user_once(
    'provider-deleted:' || p_provider_id::text,
    v_provider.user_id, 'ACCOUNT_DELETED',
    'Your business account was removed',
    'An administrator removed your business account from Aliob.'
      || CASE WHEN v_reason IS NULL THEN '' ELSE ' Reason: ' || v_reason END
      || ' If you believe this is a mistake, contact support.',
    jsonb_build_object('provider_id', p_provider_id));

  -- Public surfaces already filter on these two flags; nothing else has to
  -- learn about deletion.
  UPDATE public.products p
     SET is_active = false,
         is_available = false,
         updated_at = now()
   WHERE p.provider_id = p_provider_id
     AND (p.is_active OR p.is_available);
  GET DIAGNOSTICS v_products = ROW_COUNT;

  UPDATE public.vehicles v
     SET is_available = false,
         status = CASE WHEN v.status = 'APPROVED' THEN 'SUSPENDED'::account_status
                       ELSE v.status END
   WHERE v.provider_id = p_provider_id
     AND (v.is_available OR v.status = 'APPROVED');
  GET DIAGNOSTICS v_vehicles = ROW_COUNT;

  DELETE FROM public.fcm_tokens WHERE user_id = v_provider.user_id;
  GET DIAGNOSTICS v_tokens = ROW_COUNT;

  UPDATE public.provider_profiles
     SET status = 'SUSPENDED',
         deleted_at = now(),
         updated_at = now()
   WHERE id = p_provider_id;

  -- The router gates every screen on profiles.status, so a session that was
  -- still live when this ran has to land on the suspended gate rather than on a
  -- working dashboard. (The auth ban below stops the next sign-in; this covers
  -- the one that is already open.)
  UPDATE public.profiles
     SET status = 'SUSPENDED'
   WHERE id = v_provider.user_id
     AND status <> 'SUSPENDED';

  -- Sign them out and keep them out. Both are guarded: a deployment that does
  -- not expose the auth schema to SQL still gets the soft delete, and the
  -- dashboard gate below covers it. `banned_until` is what the GoTrue login
  -- path reads, so a refresh token that survived cannot be exchanged again.
  BEGIN
    DELETE FROM auth.sessions WHERE user_id = v_provider.user_id;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    NULL;
  END;

  BEGIN
    DELETE FROM auth.refresh_tokens WHERE user_id = v_provider.user_id::text;
  EXCEPTION WHEN undefined_table OR undefined_column OR datatype_mismatch THEN
    NULL;
  END;

  BEGIN
    UPDATE auth.users
       SET banned_until = now() + interval '100 years'
     WHERE id = v_provider.user_id;
  EXCEPTION WHEN undefined_column THEN
    NULL;
  END;

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id, details)
  VALUES (v_actor, 'DELETE_PROVIDER', 'provider_profiles', p_provider_id,
          jsonb_build_object(
            'reason', v_reason,
            'business_name', v_provider.business_name,
            'provider_type', v_provider.provider_type,
            'products_hidden', v_products,
            'vehicles_removed', v_vehicles,
            'device_tokens_removed', v_tokens));

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (v_actor, 'PROVIDER_DELETED', 'provider_profiles', p_provider_id,
          jsonb_build_object('reason', v_reason,
                             'products_hidden', v_products,
                             'vehicles_removed', v_vehicles));

  RETURN jsonb_build_object(
    'provider_id', p_provider_id,
    'business_name', v_provider.business_name,
    'products_hidden', v_products,
    'vehicles_removed', v_vehicles,
    'device_tokens_removed', v_tokens,
    'open_orders', 0,
    'open_rides', 0);
END;
$$;

COMMENT ON FUNCTION public.admin_delete_provider(uuid, text) IS
  'Admin-only soft delete: hides every listing, revokes sessions and device '
  'tokens, stamps deleted_at, records the reason, and refuses while live '
  'orders or rides still depend on the business.';

REVOKE ALL ON FUNCTION public.admin_delete_provider(uuid, text)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_provider(uuid, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Availability requests reach the admins, and the badge is counted exactly
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.on_availability_request_created()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin record;
  v_business text;
BEGIN
  SELECT pp.business_name INTO v_business
    FROM public.provider_profiles pp
   WHERE pp.id = NEW.provider_id;

  FOR v_admin IN
    SELECT DISTINCT ur.user_id
      FROM public.user_roles ur
     WHERE ur.role = 'ADMIN'
  LOOP
    PERFORM public.notify_user_once(
      'availability-admin:' || NEW.id::text || ':' || v_admin.user_id::text,
      v_admin.user_id, 'AVAILABILITY_REQUEST',
      'New availability request',
      coalesce(nullif(v_business, ''), 'A provider')
        || ' has a stock check waiting for an answer.',
      jsonb_build_object('availability_request_id', NEW.id,
                         'provider_id', NEW.provider_id));
  END LOOP;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.on_availability_request_created() IS
  'Tells every administrator that a buyer is waiting on a stock check. The '
  'buyer''s own ask already notifies the provider (20261006000006).';

DROP TRIGGER IF EXISTS trg_availability_request_notifies_admins
  ON public.availability_requests;
CREATE TRIGGER trg_availability_request_notifies_admins
  AFTER INSERT ON public.availability_requests
  FOR EACH ROW EXECUTE FUNCTION public.on_availability_request_created();

-- Exactly the number the badge shows, counted by the server. Gated the same
-- way the screen is (registrations), so it cannot be used to scrape volume
-- from a customer account.
CREATE OR REPLACE FUNCTION public.pending_availability_request_count()
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  RETURN (
    SELECT count(*)::int
      FROM public.availability_requests
     WHERE status = 'PENDING'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pending_availability_request_count()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.pending_availability_request_count()
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. A live assertion, and the deploy-time one
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_provider_admin_delete_is_guarded()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  v_missing text := '';
BEGIN
  SELECT p.prosrc INTO v_src
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'admin_delete_provider';

  -- It is a guard, not a suggestion: the admin check, the live-work refusal,
  -- the token removal and the audit row all have to be in the body.
  IF v_src IS NULL
     OR position('is_admin()' in v_src) = 0
     OR position('PROVIDER_HAS_OPEN_WORK' in v_src) = 0
     OR position('DELETE FROM public.fcm_tokens' in v_src) = 0
     OR position('admin_actions' in v_src) = 0 THEN
    v_missing := v_missing || ' admin_delete_provider guards;';
  END IF;

  -- Staff without the admin role must NOT be able to call it: the sidebar
  -- hides the button, and this is what makes that hiding a convenience.
  IF has_function_privilege(
      'anon', 'public.admin_delete_provider(uuid,text)', 'EXECUTE') THEN
    v_missing := v_missing || ' admin_delete_provider is callable by anon;';
  END IF;
  IF NOT has_function_privilege(
      'authenticated', 'public.admin_delete_provider(uuid,text)', 'EXECUTE') THEN
    v_missing := v_missing || ' admin_delete_provider is not callable;';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 'trg_availability_request_notifies_admins'
                    AND NOT tgisinternal) THEN
    v_missing := v_missing || ' availability trigger;';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'provider_profiles'
       AND column_name = 'deleted_at') THEN
    v_missing := v_missing || ' provider_profiles.deleted_at;';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION
      'provider delete / availability admin are not fully wired:%.',
      v_missing;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_provider_admin_delete_is_guarded()
  FROM public;
GRANT EXECUTE ON FUNCTION public.assert_provider_admin_delete_is_guarded()
  TO anon, authenticated;

-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_src text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'provider_profiles'
       AND column_name = 'deleted_at'
  ) THEN
    RAISE EXCEPTION '20261025000002 did not take: provider_profiles.deleted_at';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 'trg_availability_request_notifies_admins'
                    AND NOT tgisinternal) THEN
    RAISE EXCEPTION '20261025000002 did not take: availability trigger';
  END IF;

  SELECT p.prosrc INTO v_src
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'admin_delete_provider';

  -- The three facts that make the function a guard rather than a suggestion:
  -- it checks the admin role, it refuses live work, and it really removes the
  -- device tokens. A restatement that drops any of them fails the deploy.
  IF v_src IS NULL
     OR position('is_admin()' in v_src) = 0
     OR position('PROVIDER_HAS_OPEN_WORK' in v_src) = 0
     OR position('DELETE FROM public.fcm_tokens' in v_src) = 0
     OR position('admin_actions' in v_src) = 0 THEN
    RAISE EXCEPTION
      '20261025000002: admin_delete_provider lost a guard (admin check, open '
      'work refusal, token removal, or audit row)';
  END IF;
END;
$$;
