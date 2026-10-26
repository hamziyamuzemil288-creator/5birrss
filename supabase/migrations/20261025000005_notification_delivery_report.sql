-- =============================================================================
-- 20261025000005 — notification delivery, measured live instead of assumed
-- =============================================================================
--
-- THE REPORT
-- -----------
-- "I still don't see any notifications — not the signup welcome, not the
-- availability request, not for admin or the provider."
--
-- Every scenario that complaint names writes its notification from a CLIENT
-- path: a signup is a GoTrue session, an availability request is a PostgREST
-- insert. notify_user() queues those in notification_outbox, and pg_cron's
-- drain is the only thing that ever moves them into notifications — so if the
-- drain is dead, EVERYTHING the user tests vanishes while every existing
-- assertion stays green. That is exactly the hole this migration closes:
-- assert_notification_outbox_is_drained() (00063) checks that a cron ROW
-- exists. It has never checked that the job is active, that its last run
-- succeeded, that anything was ever drained, or that one row reached a real
-- inbox. From the app, an inbox with a dead drain and an inbox with nothing
-- to say look identical.
--
-- The second half of the complaint is the PUSH leg: an in-app row that never
-- leaves as a device push. That leg has three independent failure points —
-- no active fcm_tokens row (a build without Firebase defines, or never
-- signed in on that device), no consumer on n8n_events (the Database Webhook
-- is configured once, by hand, in the dashboard), or a sender that is not
-- deployed. The report carries the measurement for each so the answer is a
-- number, not a guess.
--
-- WHAT THIS MIGRATION DOES
-- ------------------------
--   1. Re-arms the drain schedule if the cron row is gone (idempotent, the
--      same guard 00058 used — a schedule row that vanished is the one
--      realistic way the queue stops moving).
--
--   2. Flushes the backlog during the deploy itself. `supabase db push`
--      connects as postgres, so is_server_write() is true and the drain runs
--      right here: every notification that was queued and never delivered
--      lands in the inbox it was written for, in the same transaction as the
--      fix. Bounded (500 per round, 50 rounds) and idempotent — if the queue
--      was already healthy this is a no-op that returns 0.
--
--   3. Adds notification_delivery_report(): a READ-ONLY report the live
--      connectivity suite calls. It reports and never raises, because the
--      verdict belongs to the caller (which knows which numbers are
--      findings) and a failure must carry the measurements, not just a
--      boolean. It distinguishes:
--
--        a. queue stuck        -> outbox_pending > 0 and growing old,
--                                 drain_last_status=failed (with the error)
--        b. events never queued-> outbox_total = 0 while the app is in use
--        c. inbox fine, no push-> notifications_7d > 0 but active_fcm_tokens=0
--                                 or push_events_7d=0 (enqueue trigger/prefs)
--        d. push never consumed-> push_events_pending > 0 and oldest
--                                 (Database Webhook missing or not invoking
--                                 fcm-dispatch), or push_events_failed > 0
--                                 (sender deployed but rejecting — read the
--                                 Supabase function logs)
--
-- Deploy: needs a Supabase deploy (one function, one schedule guard, one
-- deploy-time flush).
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. Re-arm the drain schedule, then flush what is already queued.
--    Placed BEFORE the report function on purpose: in the local lineage
--    drivers (which stub pg_cron and run with ON_ERROR_STOP=0) this DO block
--    is the part that may fail, and it must not take the function with it.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_round int := 0;
  v_flushed int := 0;
BEGIN
  -- 1a. The schedule row itself. cron.schedule is idempotent by job name, and
  -- the guard keeps a second deploy from creating a second job — the same
  -- pattern 00058/00060/00115 all use, checked against the catalog rather
  -- than assumed, because the local stub has a cron.job table of its own.
  IF to_regclass('cron.job') IS NOT NULL
     AND to_regprocedure('cron.schedule(text,text,text)') IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM cron.job WHERE command ILIKE '%drain_notification_outbox%'
     ) THEN
    PERFORM cron.schedule(
      '5birr-notification-outbox',
      '* * * * *',
      $cron$SELECT public.drain_notification_outbox()$cron$
    );
  END IF;

  -- 1b. The backlog flush. Guarded twice: the function must exist (a lineage
  -- driver applying a subset of migrations may not have 00058), and the
  -- context must be a server write (the drain raises otherwise — on a real
  -- deploy that is always true, since db push connects as postgres).
  IF to_regprocedure('public.drain_notification_outbox(integer)') IS NOT NULL
     AND public.is_server_write() THEN
    LOOP
      v_round := v_round + 1;
      EXIT WHEN v_round > 50;
      v_flushed := public.drain_notification_outbox(500);
      EXIT WHEN v_flushed = 0;
    END LOOP;
  END IF;
EXCEPTION
  -- A re-arm or flush that cannot run must not abort the migration: the
  -- report below is the instrument that tells us why, and failing the deploy
  -- would leave the user with neither the fix nor the diagnosis.
  WHEN OTHERS THEN
    RAISE NOTICE '20261025000005: drain re-arm/flush skipped: %', SQLERRM;
END $$;

-- ---------------------------------------------------------------------------
-- 2. The report.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notification_delivery_report()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_pending bigint := 0;
  v_oldest int := 0;
  v_total bigint := 0;
  v_job text := 'unknown';
  v_last_status text := 'none';
  v_last_age int := -1;
  v_last_error text := 'none';
  v_notif_total bigint := 0;
  v_notif_7d bigint := 0;
  v_latest_age int := -1;
  v_welcome bigint := 0;
  v_availability bigint := 0;
  v_push_7d bigint := 0;
  v_push_pending bigint := 0;
  v_push_sent bigint := 0;
  v_push_failed bigint := 0;
  v_push_oldest int := -1;
  v_tokens_active bigint := 0;
  v_tokens_total bigint := 0;
  v_triggers text := 'none';
  v_hooks text := 'absent';
BEGIN
  -- ── The queue ───────────────────────────────────────────────────────────
  SELECT count(*),
         coalesce(max(extract(epoch FROM (now() - created_at)))::int, 0)
    INTO v_pending, v_oldest
    FROM public.notification_outbox
   WHERE drained_at IS NULL;

  SELECT count(*)::bigint INTO v_total FROM public.notification_outbox;

  -- ── The drain job ───────────────────────────────────────────────────────
  -- Wrapped because the local lineage drivers stub pg_cron with a reduced
  -- catalog (no active column, no job_run_details): an unreadable catalog
  -- must read 'unreadable', not raise — the report's whole job is to be
  -- callable when things are broken.
  BEGIN
    IF to_regclass('cron.job') IS NULL THEN
      v_job := 'cron_schema_absent';
    ELSE
      EXECUTE $q$
        SELECT CASE WHEN count(*) = 0 THEN 'missing'
                    WHEN bool_or(active) THEN 'active'
                    ELSE 'inactive' END
          FROM cron.job
         WHERE command ILIKE '%drain_notification_outbox%'
      $q$ INTO v_job;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_job := 'unreadable';
  END;

  BEGIN
    IF to_regclass('cron.job_run_details') IS NOT NULL THEN
      EXECUTE $q$
        SELECT r.status,
               greatest(extract(epoch FROM now() - r.start_time)::int, 0),
               left(coalesce(nullif(btrim(r.return_message), ''), 'none'), 300)
          FROM cron.job_run_details r
          JOIN cron.job j ON j.jobid = r.jobid
         WHERE j.command ILIKE '%drain_notification_outbox%'
         ORDER BY r.start_time DESC
         LIMIT 1
      $q$ INTO v_last_status, v_last_age, v_last_error;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_last_status := 'unreadable';
  END;
  -- EXECUTE ... INTO with no row leaves NULLs; a drain that has never run
  -- must read 'none', not an empty line.
  v_last_status := coalesce(nullif(v_last_status, ''), 'none');
  v_last_error := replace(coalesce(nullif(v_last_error, ''), 'none'), E'\n', ' ');

  -- ── What reached (or never reached) the inbox ───────────────────────────
  SELECT count(*) INTO v_notif_total FROM public.notifications;
  SELECT count(*),
         coalesce(max(extract(epoch FROM (now() - created_at)))::int, 0)
    INTO v_notif_7d, v_latest_age
    FROM public.notifications
   WHERE created_at > now() - interval '7 days';

  -- The signup welcome, written keyed by 20261014000000.
  SELECT count(*) INTO v_welcome
    FROM public.notifications
   WHERE data ->> 'event' = 'signup_welcome';

  -- Availability traffic. The type enum is shared with order states, so the
  -- title carries the word; this is a report line, not a routing key.
  SELECT count(*) INTO v_availability
    FROM public.notifications
   WHERE title ILIKE '%availability%'
      OR body ILIKE '%availability%';

  -- ── The push leg ────────────────────────────────────────────────────────
  SELECT count(*),
         count(*) FILTER (WHERE status = 'PENDING'),
         count(*) FILTER (WHERE status = 'SENT'),
         count(*) FILTER (WHERE status IN ('FAILED', 'RETRYING')),
         coalesce((max(extract(epoch FROM (now() - created_at)))
                   FILTER (WHERE status = 'PENDING'))::int, -1)
    INTO v_push_7d, v_push_pending, v_push_sent, v_push_failed, v_push_oldest
    FROM public.n8n_events
   WHERE event_type = 'NOTIFICATION_PUSH'
     AND created_at > now() - interval '7 days';

  SELECT count(*) FILTER (WHERE coalesce(is_active, true)
                          AND coalesce(token, '') <> ''),
         count(*)
    INTO v_tokens_active, v_tokens_total
    FROM public.fcm_tokens;

  -- Who could be consuming n8n_events. A Database Webhook installs a trigger
  -- on the table; reported verbatim so 'none' is a visible finding.
  BEGIN
    SELECT coalesce(string_agg(t.tgname, ','), 'none') INTO v_triggers
      FROM pg_trigger t
     WHERE t.tgrelid = 'public.n8n_events'::regclass
       AND NOT t.tgisinternal;
  EXCEPTION WHEN OTHERS THEN
    v_triggers := 'unreadable';
  END;

  BEGIN
    IF to_regclass('supabase_functions.hooks') IS NULL THEN
      v_hooks := 'schema_absent';
    ELSE
      EXECUTE 'SELECT count(*)::text FROM supabase_functions.hooks' INTO v_hooks;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_hooks := 'unreadable';
  END;

  -- ── One line per metric: the Dart side parses key=value ─────────────────
  RETURN array_to_string(ARRAY[
    'outbox_pending=' || v_pending,
    'outbox_oldest_pending_seconds=' || v_oldest,
    'outbox_total=' || v_total,
    'drain_job=' || v_job,
    'drain_last_status=' || v_last_status,
    'drain_last_age_seconds=' || v_last_age,
    'drain_last_error=' || v_last_error,
    'notifications_total=' || v_notif_total,
    'notifications_7d=' || v_notif_7d,
    'notification_latest_age_seconds=' || v_latest_age,
    'signup_welcome_rows=' || v_welcome,
    'availability_mentions=' || v_availability,
    'push_events_7d=' || v_push_7d,
    'push_events_pending=' || v_push_pending,
    'push_events_sent=' || v_push_sent,
    'push_events_failed=' || v_push_failed,
    'push_pending_oldest_seconds=' || v_push_oldest,
    'active_fcm_tokens=' || v_tokens_active,
    'fcm_tokens_total=' || v_tokens_total,
    'n8n_event_triggers=' || v_triggers,
    'supabase_hooks_total=' || v_hooks
  ], E'\n');
END;
$$;

COMMENT ON FUNCTION public.notification_delivery_report() IS
  'Read-only live report of the notification pipeline: queue depth and age, '
  'drain schedule state and last run result, what reached notifications, and '
  'the push leg (tokens, n8n_events consumption, webhook trigger). One '
  'key=value metric per line. Never raises: the caller decides which numbers '
  'are findings.';

REVOKE ALL ON FUNCTION public.notification_delivery_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.notification_delivery_report()
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Self-check: the instrument must exist and the live suite (which calls
--    as anon) must be able to read it — a report nobody can call is the same
--    as no report.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure('public.notification_delivery_report()') IS NULL THEN
    RAISE EXCEPTION '20261025000005 did not take: notification_delivery_report()';
  END IF;

  IF NOT has_function_privilege('anon', 'public.notification_delivery_report()', 'EXECUTE') THEN
    RAISE EXCEPTION
      '20261025000005: the connectivity suite calls as anon and cannot execute the delivery report';
  END IF;
END $$;
