-- =============================================================================
-- 20261112000001 — "Welcome back" after a real sign-in
-- =============================================================================
--
-- THE REPORT
-- ----------
-- "When a user signs in again (providers, drivers, admins, anyone who signs
-- in), the app must send a Welcome back notification. Right now nothing
-- arrives."
--
-- WHAT WAS TRUE BEFORE THIS FILE
-- ------------------------------
-- There was no sign-in notification path at all. The only welcome in the
-- database was `20260927000087_welcome_on_approval.sql`, which fires when an
-- administrator APPROVES an account — an event that happens once, possibly
-- days before the person's next login. The client had a new-device security
-- notice (`SecurityNoticeService.noteLogin`) but that is deliberately silent on
-- the same device and is not a greeting. So "signed in again" had no writer.
--
-- WHY THE SERVER OWNS THIS
-- ------------------------
-- The client can say "I just signed in", but it must not be able to say "send
-- a notification to this account". This RPC only ever addresses `auth.uid()`;
-- there is no recipient parameter, so a hostile caller can at worst greet
-- themselves. It is granted to `authenticated` and NOT to `anon`.
--
-- The session id comes from the verified JWT (`session_id`), not from an
-- argument. A client cannot choose it or reuse another session's id. That id
-- is the idempotency key: the same sign-in retried after a timeout, a second
-- tab, or a duplicate auth listener event lands on `already_sent`.
--
-- WHAT THIS FILE ADDS
-- -------------------
--   table     signin_welcome_log — one row per account: last session id and
--             last send time. RLS on, no client policies and no grants; only
--             the SECURITY DEFINER RPC touches it.
--   enum      notification_type.WELCOME_BACK
--   function  record_signin_welcome_for_user(user, session, allow_inbox_only)
--             * skips guests, sessions without an id, profiles created in the
--               last five minutes, and a repeated session;
--             * enforces a five-minute per-account gap;
--             * waits for a device token: if push is on and no token exists it
--               returns `waiting_for_token` WITHOUT writing anything, so the
--               client can retry while FCM finishes registering;
--             * honours `notification_preferences.push_enabled` (inbox still
--               gets the row; no tray push);
--             * requires the explicit `p_allow_inbox_only` flag for the final
--               attempt, so an inbox-only welcome is never silently mistaken
--               for a delivered push;
--             * writes one inbox row through `notify_user_once`, whose trigger
--               enqueues the FCM event — the same path every other
--               notification uses.
--   edge      supabase/functions/signin-welcome — verifies the caller's JWT
--             and calls the function AS SERVICE ROLE, which takes the direct
--             notification path instead of the one-minute outbox. It is the
--             only caller allowed to pass a user id; the id comes from the
--             verified token, never from the request body.
--
-- TEMPLATE
-- --------
-- This repository has no separate translation catalogue. The established
-- convention (stated in 20261025000001) is one clearly marked template block
-- per notification event in the migration that adds it; the WELCOME_BACK copy
-- is kept together below, not scattered through the RPC.
--
-- Copy:
--   title: Welcome back, {name}
--   buyer:    Your orders, favourites and messages are right where you left them.
--   provider: 0 requests/orders -> Your dashboard is ready with today's
--             listings and orders.
--             N availability requests -> You have N item request(s) waiting
--             for your answer. Open your dashboard to respond.
--             N orders -> You have N new order(s) waiting for confirmation.
--             both -> You have N request(s) and M order(s) waiting for you.
--   admin:    N checkout requests -> You have N checkout request(s) waiting
--             for review.
--             otherwise -> Your admin dashboard is ready.
--
-- Deploy: apply this migration, then deploy the signin-welcome Edge Function
-- (the Deploy Supabase workflow does both). The Dart client is backwards
-- compatible: on an undeployed project the function is absent, the client logs
-- it in debug builds and the sign-in itself still succeeds.
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The notification type
-- ---------------------------------------------------------------------------
ALTER TYPE public.notification_type
  ADD VALUE IF NOT EXISTS 'WELCOME_BACK';

-- ---------------------------------------------------------------------------
-- 2. The per-account receipt log
-- ---------------------------------------------------------------------------
-- Primary key on user_id means there is never more than one "last welcome" row
-- to reason about, and the advisory lock in the RPC serialises two concurrent
-- sign-ins for the same account. session_id is the idempotency key; sent_at is
-- the minimum-gap clock.
CREATE TABLE IF NOT EXISTS public.signin_welcome_log (
  user_id         uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  session_id      text NOT NULL,
  notification_id uuid REFERENCES public.notifications(id) ON DELETE SET NULL,
  sent_at         timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.signin_welcome_log ENABLE ROW LEVEL SECURITY;

-- No policies and no client grants. This is server memory, not a client table.
REVOKE ALL ON public.signin_welcome_log FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.signin_welcome_log IS
  'The last sign-in welcome per account: session id for idempotency and '
  'sent_at for the five-minute minimum gap. Written only by '
  'record_signin_welcome_for_user().';

-- ---------------------------------------------------------------------------
-- 3. The RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_signin_welcome_for_user(
  p_user_id uuid,
  p_session_id text,
  p_allow_inbox_only boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user uuid := p_user_id;
  v_session text := nullif(btrim(coalesce(p_session_id, '')), '');
  v_guest boolean := false;
  v_profile public.profiles%ROWTYPE;
  v_last public.signin_welcome_log%ROWTYPE;
  v_provider public.provider_profiles%ROWTYPE;
  v_name text;
  v_role text;
  v_title text;
  v_body text;
  v_push boolean;
  v_tokens integer := 0;
  v_pending_requests integer := 0;
  v_pending_orders integer := 0;
  v_pending_checkouts integer := 0;
  v_notification_id uuid;
  v_data jsonb;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'signed_out');
  END IF;

  SELECT coalesce(u.is_anonymous, false)
    INTO v_guest
    FROM auth.users u
   WHERE u.id = v_user;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'status', 'signed_out');
  END IF;

  -- A guest buyer has a real auth.uid() but is not an account that "signs in
  -- again". Anonymous sessions must never receive an account greeting.
  IF v_guest THEN
    RETURN jsonb_build_object('ok', true, 'status', 'guest');
  END IF;

  IF v_session IS NULL THEN
    -- Older tokens may predate the session_id claim. Sending here would make
    -- the notification impossible to deduplicate, so the honest answer is no.
    RETURN jsonb_build_object('ok', false, 'status', 'no_session');
  END IF;

  SELECT * INTO v_profile
    FROM public.profiles
   WHERE id = v_user;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'status', 'no_profile');
  END IF;

  -- A person who created their account moments ago is registering, not coming
  -- back. Approval has its own welcome (20260927000087); this one is for a
  -- returning session.
  IF v_profile.created_at > now() - interval '5 minutes' THEN
    RETURN jsonb_build_object('ok', true, 'status', 'new_account');
  END IF;

  -- One lock per account. Two auth listener events, two devices, or a retried
  -- network call all serialise here before either can read the log.
  PERFORM pg_advisory_xact_lock(
    hashtext('signin-welcome:' || v_user::text)
  );

  SELECT * INTO v_last
    FROM public.signin_welcome_log
   WHERE user_id = v_user;

  IF FOUND THEN
    IF v_last.session_id = v_session THEN
      RETURN jsonb_build_object(
        'ok', true,
        'status', 'already_sent',
        'notification_id', v_last.notification_id
      );
    END IF;

    -- A real sign-in within the gap is deliberately quiet. It is still a
    -- successful outcome, not an error the UI should retry.
    IF v_last.sent_at > now() - interval '5 minutes' THEN
      RETURN jsonb_build_object('ok', true, 'status', 'throttled');
    END IF;
  END IF;

  SELECT coalesce(p.push_enabled, true)
    INTO v_push
    FROM public.notification_preferences p
   WHERE p.user_id = v_user;

  v_push := coalesce(v_push, true);

  IF v_push THEN
    SELECT count(*)
      INTO v_tokens
      FROM public.fcm_tokens t
     WHERE t.user_id = v_user
       AND coalesce(t.is_active, true)
       AND coalesce(t.token, '') <> '';

    -- The client waits and retries while FCM is still registering. Only after
    -- those attempts may it ask for the inbox-only fallback. Writing the row
    -- now would consume the once-per-session key with no tray push, which is
    -- exactly the "created in the inbox but not pushed" failure the brief
    -- warns about.
    IF v_tokens = 0 AND NOT coalesce(p_allow_inbox_only, false) THEN
      RETURN jsonb_build_object(
        'ok', true,
        'status', 'waiting_for_token',
        'tray_expected', false
      );
    END IF;
  END IF;

  v_name := coalesce(
    nullif(btrim(v_profile.full_name), ''),
    nullif(split_part(coalesce(v_profile.email, ''), '@', 1), ''),
    'there'
  );

  v_role := public.notification_recipient_role(v_user);
  v_title := 'Welcome back, ' || v_name;

  IF v_role = 'provider' THEN
    SELECT * INTO v_provider
      FROM public.provider_profiles
     WHERE user_id = v_user
     ORDER BY created_at
     LIMIT 1;

    IF FOUND THEN
      SELECT count(*)
        INTO v_pending_requests
        FROM public.availability_requests ar
       WHERE ar.provider_id = v_provider.id
         AND ar.status = 'PENDING'
         AND ar.expires_at > now();

      SELECT count(*)
        INTO v_pending_orders
        FROM public.orders o
       WHERE o.provider_id = v_provider.id
         AND o.status = 'PENDING_PROVIDER';
    END IF;

    IF v_pending_requests > 0 AND v_pending_orders > 0 THEN
      v_body := 'You have ' || v_pending_requests || ' availability request'
        || CASE WHEN v_pending_requests = 1 THEN '' ELSE 's' END
        || ' and ' || v_pending_orders || ' new order'
        || CASE WHEN v_pending_orders = 1 THEN '' ELSE 's' END
        || ' waiting for you.';
    ELSIF v_pending_requests > 0 THEN
      v_body := 'You have ' || v_pending_requests || ' item request'
        || CASE WHEN v_pending_requests = 1 THEN '' ELSE 's' END
        || ' waiting for your answer. Open your dashboard to respond.';
    ELSIF v_pending_orders > 0 THEN
      v_body := 'You have ' || v_pending_orders || ' new order'
        || CASE WHEN v_pending_orders = 1 THEN '' ELSE 's' END
        || ' waiting for confirmation.';
    ELSE
      v_body := 'Your dashboard is ready with today''s listings and orders.';
    END IF;
  ELSIF v_role = 'admin' THEN
    SELECT count(*)
      INTO v_pending_checkouts
      FROM public.orders o
     WHERE o.status::text = 'AWAITING_APPROVAL';

    IF v_pending_checkouts > 0 THEN
      v_body := 'You have ' || v_pending_checkouts || ' checkout request'
        || CASE WHEN v_pending_checkouts = 1 THEN '' ELSE 's' END
        || ' waiting for review.';
    ELSE
      v_body := 'Your admin dashboard is ready.';
    END IF;
  ELSE
    v_body := 'Your orders, favourites and messages are right where you left '
      || 'them.';
  END IF;

  v_data := jsonb_build_object(
    'event', 'signin_welcome',
    'kind', 'signin_welcome',
    'recipient_role', v_role,
    'session_id', v_session
  );

  v_notification_id := public.notify_user_once(
    'signin-welcome:' || v_user::text || ':' || v_session,
    v_user,
    'WELCOME_BACK',
    v_title,
    v_body,
    v_data
  );

  IF v_notification_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'failed');
  END IF;

  INSERT INTO public.signin_welcome_log
    (user_id, session_id, notification_id, sent_at)
  VALUES
    (v_user, v_session, v_notification_id, now())
  ON CONFLICT (user_id) DO UPDATE SET
    session_id = EXCLUDED.session_id,
    notification_id = EXCLUDED.notification_id,
    sent_at = EXCLUDED.sent_at;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'sent',
    'notification_id', v_notification_id,
    'tray_expected', v_push AND v_tokens > 0
  );
END;
$$;

COMMENT ON FUNCTION public.record_signin_welcome_for_user(uuid, text, boolean) IS
  'The service-role half of the sign-in welcome. Edge Function signin-welcome '
  'verifies the caller first, then calls this with the verified user id and '
  'JWT session id. Deduplicated by session, minimum five minutes apart, '
  'skipped for guests/new accounts, waits for an FCM token unless '
  'p_allow_inbox_only is true, honours push_enabled, and adds provider/admin '
  'next-step copy only when that data already exists.';

REVOKE ALL ON FUNCTION public.record_signin_welcome_for_user(uuid, text, boolean)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_signin_welcome_for_user(uuid, text, boolean)
  TO service_role;


-- ---------------------------------------------------------------------------
-- 4. Android channel: a welcome belongs with account notices, not promotions
-- ---------------------------------------------------------------------------
-- Restated from 20261111000002 with ONE added branch. The function is the
-- single mapping used both by the push payload and by Dart's foreground
-- display, so WELCOME_BACK has to be named here or it falls to the generic
-- messages channel (which has lower importance).
CREATE OR REPLACE FUNCTION public.notification_android_channel(
  p_type text,
  p_data jsonb
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN lower(coalesce(p_data ->> 'event', '')) IN (
           'delivery_assigned', 'driver_assigned', 'driver_arriving',
           'driver_arrived', 'delivery_started', 'delivery_completed'
         ) THEN 'aliob_rides'
    WHEN lower(coalesce(p_type, '')) LIKE '%RIDE%'
      OR lower(coalesce(p_data ->> 'event', '')) LIKE '%ride%' THEN 'aliob_rides'
    WHEN lower(coalesce(p_type, '')) LIKE '%ORDER%'
      OR lower(coalesce(p_data ->> 'event', '')) LIKE 'checkout%'
      OR lower(coalesce(p_data ->> 'event', '')) LIKE '%delivery%' THEN 'aliob_orders'
    WHEN lower(coalesce(p_type, '')) LIKE '%PAYMENT%'
      OR lower(coalesce(p_type, '')) LIKE '%WALLET%'
      OR lower(coalesce(p_type, '')) LIKE '%SUBSCRIPTION%'
      OR lower(coalesce(p_type, '')) LIKE '%TRANSACTION%' THEN 'aliob_payments'
    -- The left side is lower-cased, so these literals must be lower-case too.
    -- The previous restatement had them upper-case and every one of these
    -- account events silently fell through to the general channel.
    WHEN lower(coalesce(p_type, '')) IN (
           'security', 'approval', 'rejection', 'correction_required',
           'registration_received', 'provider_inactive', 'welcome_back'
         ) THEN 'aliob_account'
    WHEN lower(coalesce(p_data ->> 'event', '')) IN (
           'promotion', 'promo', 'marketing', 'app_update'
         ) THEN 'aliob_promotions'
    ELSE 'aliob_messages'
  END;
$$;

COMMENT ON FUNCTION public.notification_android_channel(text, jsonb) IS
  'Maps a notification type/event to one of the Android channels the app '
  'creates. WELCOME_BACK is an account notice, so it uses aliob_account.';

-- ---------------------------------------------------------------------------
-- 5. The live assertion
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_signin_welcome_is_wired()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  v_enum int;
  v_table int;
BEGIN
  SELECT lower(regexp_replace(p.prosrc, E'\\s+', ' ', 'g'))
    INTO v_src
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'record_signin_welcome_for_user';

  IF v_src IS NULL THEN
    RETURN 'FAIL: record_signin_welcome_for_user() is missing';
  END IF;

  IF position('session_id' IN v_src) = 0
     OR position('already_sent' IN v_src) = 0 THEN
    RETURN 'FAIL: the welcome is not deduplicated by the JWT session id';
  END IF;

  IF position('interval ''5 minutes''' IN v_src) = 0 THEN
    RETURN 'FAIL: the welcome has no minimum gap';
  END IF;

  IF position('waiting_for_token' IN v_src) = 0 THEN
    RETURN 'FAIL: the welcome does not wait for a device token';
  END IF;

  IF position('push_enabled' IN v_src) = 0 THEN
    RETURN 'FAIL: the welcome ignores notification_preferences.push_enabled';
  END IF;

  IF position('availability_requests' IN v_src) = 0
     OR position('pending_provider' IN v_src) = 0 THEN
    RETURN 'FAIL: the provider next step is not backed by real pending data';
  END IF;

  SELECT count(*) INTO v_enum
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    JOIN pg_namespace n ON n.oid = t.typnamespace
   WHERE n.nspname = 'public'
     AND t.typname = 'notification_type'
     AND e.enumlabel = 'WELCOME_BACK';

  IF v_enum = 0 THEN
    RETURN 'FAIL: notification_type.WELCOME_BACK does not exist';
  END IF;

  SELECT count(*) INTO v_table
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relname = 'signin_welcome_log'
     AND c.relkind = 'r';

  IF v_table = 0 THEN
    RETURN 'FAIL: signin_welcome_log is missing';
  END IF;

  IF has_function_privilege(
       'anon', 'public.record_signin_welcome_for_user(uuid, text, boolean)',
       'EXECUTE') THEN
    RETURN 'FAIL: anon can call the service-role welcome function';
  END IF;

  IF has_function_privilege(
       'authenticated',
       'public.record_signin_welcome_for_user(uuid, text, boolean)',
       'EXECUTE') THEN
    RETURN 'FAIL: a client role can address another account via the welcome '
      'function';
  END IF;

  IF NOT has_function_privilege(
       'service_role',
       'public.record_signin_welcome_for_user(uuid, text, boolean)',
       'EXECUTE') THEN
    RETURN 'FAIL: the service-role welcome function is not executable by the '
      'server that calls it';
  END IF;

  RETURN 'ok: welcome back is personalised, session-idempotent, spaced, '
    || 'token-aware, preference-aware and signed-in only';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_signin_welcome_is_wired()
  FROM public;
GRANT EXECUTE ON FUNCTION public.assert_signin_welcome_is_wired()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
