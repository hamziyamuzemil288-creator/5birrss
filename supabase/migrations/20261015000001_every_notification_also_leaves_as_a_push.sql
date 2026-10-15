-- =============================================================================
-- 20261015000001 — every notification also leaves as a push, from ONE place
-- =============================================================================
--
-- THE REPORT (Parts 9a and 9b)
-- ----------------------------
--   "Every user-facing event that should notify has to fire an actual push
--    notification visible outside the app AND an in-app panel entry. Audit
--    every event and confirm each one fires FCM, not just some. Fix any event
--    missing the push call — reuse the existing sending mechanism, do not
--    build a second notification pathway."
--
-- WHAT IS TRUE TODAY, STATED HONESTLY (this is the audit, in the schema)
-- ---------------------------------------------------------------------
-- There is NO FCM sender in this repository, and there never has been:
--
--   * pubspec.yaml has no `firebase_core` and no `firebase_messaging`, so the
--     app never asks Firebase for a registration token;
--   * nothing in lib/ writes `fcm_tokens`, so the table 0007 created is empty
--     for every account — there is no device address to push to;
--   * no Edge Function in supabase/functions mentions fcm or firebase;
--   * no migration contains a send function.
--
-- 20260927000130 already recorded this ("FCM IS NOT WIRED, AND THIS MIGRATION
-- DOES NOT PRETEND IT IS"). Attaching Firebase is a piece of work with its own
-- credentials — a google-services.json for the Android application id, a
-- service account for the sender — and neither can be invented in a migration.
-- So the honest answer to "which events push today" is: NONE. Every event
-- listed below lands in the in-app inbox and stops there.
--
-- THE ONE PUSH PATH THAT DOES EXIST
-- ---------------------------------
-- `create_n8n_event()` (0007) is this repository's existing push dispatcher:
-- it writes a row into `n8n_events` and the n8n workflow subscribed to that
-- event carries the push. It is already how two things push:
--
--   * approve_provider()   -> 'PROVIDER_APPROVED'
--   * admin_notify_all_users_of_release() -> 'APP_UPDATE_PUSH', one batched
--     event carrying every active token in `fcm_tokens`.
--
-- So the fix is not a second pathway. It is to make that one pathway fire for
-- EVERY notification instead of for two, at a single point that a future
-- caller cannot forget: an AFTER INSERT trigger on `notifications`.
--
-- WHY A TRIGGER ON THE TABLE RATHER THAN A CALL IN notify_user()
-- --------------------------------------------------------------
-- notify_user() (20260927000058) is the one *call site* for new code, but it
-- is not the only *writer*: drain_notification_outbox() inserts straight into
-- notifications (that is the whole point of the queue), and two functions
-- predate it and insert directly. A push call added to notify_user() alone
-- would therefore miss every queued notification — which is most of them,
-- because a client-path notification is queued by design. An AFTER INSERT
-- trigger sees the row no matter which of the three wrote it, so "both
-- channels, always" becomes a property of the table instead of a habit.
--
-- WHAT IT DELIBERATELY DOES NOT DO
-- --------------------------------
-- * NO event is written for an account with no active token: an n8n row whose
--   token list is empty can only ever fail, and it would make n8n_events grow
--   with the user table rather than with the devices.
-- * `notification_preferences.push_enabled = false` is honoured. A preference
--   that is stored and then ignored is worse than no preference.
-- * The app-release broadcast is skipped: `admin_notify_all_users_of_release`
--   already writes ONE event carrying every token precisely so a thousand
--   users are one orchestration call, and a per-recipient event here would
--   undo that batching.
--
-- Deploy: needs a Supabase deploy (one trigger, one function, one assertion).
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The dispatch point
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
BEGIN
  -- The release broadcast owns its own single batched push event.
  IF NEW.data ->> 'kind' = 'APP_UPDATE' THEN
    RETURN NEW;
  END IF;

  -- A stored preference that is not read is not a preference.
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

  -- No registered device: nothing to push to, and an event with no tokens is
  -- a queue row that can only fail.
  IF v_tokens IS NULL OR cardinality(v_tokens) = 0 THEN
    RETURN NEW;
  END IF;

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
      'channel', 'FCM'
    )
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_enqueue_notification_push() IS
  'AFTER INSERT on notifications: writes ONE n8n push event for the row, '
  'carrying the recipient''s active FCM tokens, so the in-app inbox and the '
  'OS-level push are produced by the same notification row and no caller can '
  'produce one without the other. Silent when the account has no active token, '
  'when push is switched off for that account, or for the app-release '
  'broadcast, which batches its own event.';

DROP TRIGGER IF EXISTS trg_notifications_push_dispatch ON public.notifications;
CREATE TRIGGER trg_notifications_push_dispatch
  AFTER INSERT ON public.notifications
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_enqueue_notification_push();

-- ---------------------------------------------------------------------------
-- 2. The availability wait is the ROW's state, not a widget's
-- ---------------------------------------------------------------------------
-- Part 9b asks whether the waiting screen's countdown lives only in widget
-- memory. On the server half, three properties decide that, and all three are
-- already true — this function pins them so a later edit cannot quietly take
-- one away and leave the screen holding a timer that outlives the row:
--
--   * the buyer can READ their own rows, so re-opening the screen (or opening
--     Orders) re-reads the live status instead of remembering it;
--   * the table is in the realtime publication, so an answer arrives without a
--     poll (the screens poll as a fallback, which is allowed to be the
--     fallback and not the source);
--   * create_availability_requests() RESUMES an existing PENDING row instead
--     of inserting a second one, which is what makes "checking Orders" and
--     "re-opening the waiting screen" the same question with the same answer.
CREATE OR REPLACE FUNCTION public.assert_availability_wait_is_server_state()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
BEGIN
  -- 1. The buyer's own read.
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename = 'availability_requests'
       AND policyname = 'availability_requests_buyer_read'
  ) THEN
    RETURN false;
  END IF;

  -- 2. Realtime, or the screen has no way to learn of an answer.
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename = 'availability_requests'
  ) THEN
    RETURN false;
  END IF;

  -- 3. One active ask per buyer+product, resumed rather than duplicated.
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
     WHERE schemaname = 'public'
       AND tablename = 'availability_requests'
       AND indexname = 'uq_availability_one_active'
  ) THEN
    RETURN false;
  END IF;

  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_src
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_availability_requests';

  -- The resume half: an existing PENDING row is returned, not replaced.
  RETURN v_src IS NOT NULL
     AND position('status = ''pending''' in v_src) > 0
     AND position('availability_request_not_created' in v_src) > 0;
END;
$$;

COMMENT ON FUNCTION public.assert_availability_wait_is_server_state() IS
  'Proves the availability wait is the database row''s state: the buyer can '
  'read their own rows, the table is published for realtime, the one-active-'
  'ask index is in place, and the ask RESUMES a PENDING row instead of '
  'inserting a second one. That is what makes re-opening the screen, or '
  'opening Orders, show the live status rather than a lost in-memory timer.';

-- ---------------------------------------------------------------------------
-- 3. The push dispatch itself is asserted, not assumed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_every_notification_leaves_as_a_push()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
BEGIN
  -- The trigger has to be on the table and enabled, or every notification is
  -- in-app only again and nothing says so.
  IF NOT EXISTS (
    SELECT 1
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
     WHERE t.tgname = 'trg_notifications_push_dispatch'
       AND c.oid = 'public.notifications'::regclass
       AND NOT t.tgisinternal
       AND t.tgenabled <> 'D'
  ) THEN
    RETURN false;
  END IF;

  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_src
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'fn_enqueue_notification_push';

  IF v_src IS NULL THEN
    RETURN false;
  END IF;

  -- It must go through the EXISTING dispatcher, read the tokens the app
  -- registers, and honour the stored preference. Any of the three missing is
  -- either a second pathway or a push nobody receives.
  RETURN position('create_n8n_event' in v_src) > 0
     AND position('fcm_tokens' in v_src) > 0
     AND position('push_enabled' in v_src) > 0
     AND position('notification_push' in v_src) > 0;
END;
$$;

COMMENT ON FUNCTION public.assert_every_notification_leaves_as_a_push() IS
  'Proves every notification row is also dispatched as a push: the AFTER '
  'INSERT trigger is attached and enabled, and the function behind it goes '
  'through the existing create_n8n_event() dispatcher, reads fcm_tokens, and '
  'honours notification_preferences.push_enabled.';

REVOKE ALL ON FUNCTION public.assert_availability_wait_is_server_state()
  FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.assert_every_notification_leaves_as_a_push()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_availability_wait_is_server_state()
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.assert_every_notification_leaves_as_a_push()
  TO anon, authenticated, service_role;
