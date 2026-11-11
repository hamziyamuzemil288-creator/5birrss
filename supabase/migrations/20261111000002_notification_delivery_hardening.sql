-- =============================================================================
-- 20261111000002 — a push carries its Android channel and its audience
-- =============================================================================
--
-- THE REPORT
-- ----------
-- Aliob notifications land in the in-app inbox but not in the phone's tray.
-- The client half of the fix creates real Android channels and a monochrome
-- icon (notification_service.dart). This file is the server half: every push
-- event must name the channel it belongs to and the role of the person it is
-- for, so fcm-dispatch can post an order alert to the order channel, a ride
-- to the ride channel, and route the tap to the right screen.
--
-- Before this file the enqueue trigger wrote only title/body/data. The sender
-- had one hard-coded channel (`aliob_updates`) for every event, so Android
-- users could not turn down promotions without also turning down deliveries,
-- and a tap on an availability request could not know whether the recipient
-- was the buyer, the provider or an administrator.
--
-- Deploy: needs a Supabase deploy (two helpers, one restated trigger function,
-- one assertion).
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. Which Android channel an event belongs to
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notification_android_channel(
  p_type text,
  p_data jsonb
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    -- Driver assignment and delivery are the ride/delivery channel, even
    -- though their notification type is an ORDER type.
    WHEN lower(coalesce(p_data ->> 'event', '')) IN (
           'delivery_assigned', 'driver_assigned', 'driver_arriving',
           'driver_arrived', 'delivery_started', 'delivery_completed'
         ) THEN 'aliob_rides'
    WHEN lower(coalesce(p_type, '')) LIKE '%RIDE%'
      OR lower(coalesce(p_data ->> 'event', '')) LIKE '%ride%' THEN 'aliob_rides'
    -- Checkout approval, checkout request and every order status.
    WHEN lower(coalesce(p_type, '')) LIKE '%ORDER%'
      OR lower(coalesce(p_data ->> 'event', '')) LIKE 'checkout%'
      OR lower(coalesce(p_data ->> 'event', '')) LIKE '%delivery%' THEN 'aliob_orders'
    WHEN lower(coalesce(p_type, '')) LIKE '%PAYMENT%'
      OR lower(coalesce(p_type, '')) LIKE '%WALLET%'
      OR lower(coalesce(p_type, '')) LIKE '%SUBSCRIPTION%'
      OR lower(coalesce(p_type, '')) LIKE '%TRANSACTION%' THEN 'aliob_payments'
    WHEN lower(coalesce(p_type, '')) IN (
           'SECURITY', 'APPROVAL', 'REJECTION', 'CORRECTION_REQUIRED',
           'REGISTRATION_RECEIVED', 'PROVIDER_INACTIVE'
         ) THEN 'aliob_account'
    WHEN lower(coalesce(p_data ->> 'event', '')) IN (
           'promotion', 'promo', 'marketing', 'app_update'
         ) THEN 'aliob_promotions'
    ELSE 'aliob_messages'
  END;
$$;

COMMENT ON FUNCTION public.notification_android_channel(text, jsonb) IS
  'Maps a notification type/event to one of the Android channels the app '
  'creates: aliob_orders, aliob_rides, aliob_payments, aliob_account, '
  'aliob_messages or aliob_promotions. fcm-dispatch sends this id as '
  'android.notification.channel_id, so a background/killed push lands on the '
  'right channel without any Dart code running.';

-- ---------------------------------------------------------------------------
-- 2. Who is receiving it
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notification_recipient_role(p_user_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN p_user_id IS NULL THEN 'buyer'
    WHEN EXISTS (
      SELECT 1 FROM public.user_roles ur
       WHERE ur.user_id = p_user_id AND ur.role = 'ADMIN'
    ) THEN 'admin'
    WHEN EXISTS (
      SELECT 1 FROM public.provider_profiles pp
       WHERE pp.user_id = p_user_id
    ) THEN 'provider'
    ELSE 'buyer'
  END;
$$;

COMMENT ON FUNCTION public.notification_recipient_role(uuid) IS
  'The recipient''s audience for deep-link routing: admin, provider or buyer. '
  'A guest buyer has no provider/admin row and is therefore buyer, which is '
  'exactly the screen they should be sent to.';

-- ---------------------------------------------------------------------------
-- 3. The enqueue trigger now carries both facts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_enqueue_notification_push()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tokens text[];
  v_push_enabled boolean;
  v_channel text;
  v_role text;
BEGIN
  IF NEW.data ->> 'kind' = 'APP_UPDATE' THEN
    RETURN NEW;
  END IF;

  SELECT p.push_enabled INTO v_push_enabled
    FROM public.notification_preferences p
   WHERE p.user_id = NEW.user_id;

  IF v_push_enabled IS FALSE THEN
    RETURN NEW;
  END IF;

  SELECT array_agg(t.token ORDER BY t.updated_at DESC NULLS LAST, t.token)
    INTO v_tokens
    FROM public.fcm_tokens t
   WHERE t.user_id = NEW.user_id
     AND coalesce(t.is_active, true)
     AND coalesce(t.token, '') <> '';

  IF v_tokens IS NULL OR cardinality(v_tokens) = 0 THEN
    RETURN NEW;
  END IF;

  v_channel := public.notification_android_channel(NEW.type::text, NEW.data);
  v_role := public.notification_recipient_role(NEW.user_id);

  PERFORM public.create_n8n_event(
    'NOTIFICATION_PUSH',
    'notifications',
    NEW.id,
    jsonb_build_object(
      'user_id', NEW.user_id,
      'notification_id', NEW.id,
      'type', NEW.type::text,
      'title', NEW.title,
      'body', NEW.body,
      'data', NEW.data,
      'tokens', to_jsonb(v_tokens),
      'token_count', cardinality(v_tokens),
      'batched', false,
      'channel', 'FCM',
      -- Read by fcm-dispatch (android.notification.channel_id).
      'android_channel', v_channel,
      -- Read by the tap router when Dart is not running.
      'recipient_role', v_role
    )
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_enqueue_notification_push() IS
  'AFTER INSERT on notifications: writes ONE n8n push event for the row, '
  'carrying the recipient''s active FCM tokens, the Android channel that '
  'belongs to the event and the recipient''s role. Silent when the account has '
  'no active token, when push is switched off, or for the app-release '
  'broadcast, which batches its own event.';

-- ---------------------------------------------------------------------------
-- 4. Assertion
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_notification_push_is_routable()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
BEGIN
  SELECT lower(regexp_replace(p.prosrc, E'\\s+', ' ', 'g'))
    INTO v_src
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'fn_enqueue_notification_push';

  IF v_src IS NULL THEN
    RETURN 'FAIL: fn_enqueue_notification_push() is missing';
  END IF;

  IF position('android_channel' IN v_src) = 0
     OR position('notification_android_channel' IN v_src) = 0 THEN
    RETURN 'FAIL: push events carry no Android channel';
  END IF;

  IF position('recipient_role' IN v_src) = 0
     OR position('notification_recipient_role' IN v_src) = 0 THEN
    RETURN 'FAIL: push events carry no audience for deep-link routing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
     WHERE t.tgname = 'trg_notifications_push_dispatch'
       AND c.oid = 'public.notifications'::regclass
       AND NOT t.tgisinternal
       AND t.tgenabled <> 'D'
  ) THEN
    RETURN 'FAIL: the push dispatch trigger is not attached';
  END IF;

  RETURN 'ok: every notification push names its channel and audience';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_notification_push_is_routable()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_notification_push_is_routable()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
