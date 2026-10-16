-- 20260927000092 — three findings from the first live run of the money
-- notifications
--
-- Migrations 86-90 were deployed and the connectivity suite ran them for the
-- first time against the live database. Three failed, and only one of the three
-- was a defect in the notifications themselves. The other two were defects in
-- the assertions written to check them, which is worth stating plainly: a
-- green assertion and a correct one are different things, and this is what
-- the difference cost.
--
-- ===========================================================================
-- FINDING 1 (real bug): the dedupe did not see the client-path queue
-- ===========================================================================
--   NOTIFY_ONCE_NOT_IDEMPOTENT: a repeated call with key
--   assert-notify-user-once:... returned a new id instead of NULL
--
-- notify_user_once() checked only public.notifications for an existing
-- idem_key. But notify_user() routes on is_server_write():
--
--   server write  -> INSERT straight into notifications
--   client write  -> INSERT into notification_outbox, drained by pg_cron
--
-- So on the client path the row goes to notification_outbox and NEVER reaches
-- notifications until the cron job runs. The dedupe read the wrong table for
-- that path and the second call found nothing, queued a second row, and
-- returned its id. Both messages were then delivered by the drain.
--
-- This is not a theoretical path. The connectivity suite runs as anon, and so
-- does anything a signed-in rider or provider triggers: approve_provider and
-- approve_user are called with the administrator's own JWT, review_user_document
-- likewise, and the order/ride triggers fire inside transitions a client
-- initiates. notify_user_once is not a server-only call site — it routes both
-- ways, exactly as notify_user does.
--
-- The fix checks BOTH tables. notification_outbox keeps drained rows (drained_at
-- is set, the row is not deleted), so a key that has already been delivered and
-- flushed is still visible there; checking it as well as notifications closes
-- the window in both directions.
--
-- The advisory lock is unchanged and still load-bearing: it is what stops two
-- concurrent callers both passing this check.
--
-- ===========================================================================
-- FINDING 2 (my assertion was wrong): whitespace in a source match
-- ===========================================================================
--   FAIL: the conversion notice is not keyed on the points ledger id
--
-- convert_points_to_wallet() IS keyed correctly — the live body reads
--   public.notify_user_once( 'points-convert:' || v_ledger_id::text, ...
-- The assertion searched pg_proc.prosrc for the literal
--   notify_user_once('points-convert:' || v_ledger_id
-- with no space after the paren. prosrc is whitespace-normalised to single
-- spaces, and the source has a newline there, so the comparison never matched
-- and the assertion reported a defect that does not exist.
--
-- A needle that is sensitive to the author's line wrapping is not checking the
-- key; it is checking the formatting. The match is now written so that
-- whitespace cannot decide the outcome.
--
-- ===========================================================================
-- FINDING 3 (my assertion was wrong): client INSERT is intentional here
-- ===========================================================================
--   FAIL: authenticated can INSERT into notifications directly
--
-- The assertion assumed no client role may insert. That is not this schema's
-- design. Two policies deliberately open the SENDER side:
--
--   notifications_admin_all    FOR ALL, USING (is_admin())
--   notifications_staff_insert FOR INSERT, is_admin() OR
--                              staff_has_permission(auth.uid(),'support_chat')
--
-- and the admin broadcast screen (admin_notification_send_screen.dart) writes
-- through PostgREST as a signed-in admin. Revoking the table privilege would
-- break that screen, and this task is not allowed to change unrelated
-- behaviour.
--
-- So the invariant is not "no client inserts" — it is "a client insert is
-- refused unless the caller is an admin or support staff, and the guard trigger
-- enforces that independently of RLS". That is what the assertion now checks,
-- by reading the policies back off the live database:
--
--   * every INSERT policy on notifications is gated on is_admin() or a staff
--     permission check, with no open USING/WITH CHECK clause;
--   * an ordinary authenticated user is refused by the policy set;
--   * the guard trigger still refuses a non-admin client regardless.
--
-- This is the more useful assertion anyway: the original would have "passed"
-- only by deleting a feature.

-- ===========================================================================
-- The fix
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.notify_user_once(
  p_idem_key text,
  p_user_id uuid,
  p_type public.notification_type,
  p_title text,
  p_body text,
  p_data jsonb DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_data jsonb;
BEGIN
  IF p_user_id IS NULL OR p_idem_key IS NULL OR p_idem_key = '' THEN
    RETURN NULL;
  END IF;

  -- Serialize every writer of this key before any of them reads. Without the
  -- lock two concurrent calls both see "no existing row" and both write.
  PERFORM pg_advisory_xact_lock(hashtext('notify:' || p_idem_key));

  -- BOTH tables, because notify_user() writes to one or the other depending on
  -- is_server_write(). Checking only notifications missed every client-path
  -- notification — which is most of them — and let a retry queue a second
  -- copy of the same message.
  --
  -- notification_outbox is not pruned (the drain sets drained_at and leaves the
  -- row), so a key already flushed into notifications is still found here too.
  IF EXISTS (
    SELECT 1 FROM public.notifications
     WHERE (data ->> 'idem_key') = p_idem_key
  ) OR EXISTS (
    SELECT 1 FROM public.notification_outbox
     WHERE (data ->> 'idem_key') = p_idem_key
  ) THEN
    RETURN NULL;  -- already written by an earlier call
  END IF;

  v_data := COALESCE(p_data, '{}'::jsonb) || jsonb_build_object('idem_key', p_idem_key);

  RETURN public.notify_user(p_user_id, p_type, p_title, p_body, v_data);

EXCEPTION
  WHEN OTHERS THEN
    -- The whole point: a delivery failure is logged, never raised. Raising
    -- here would roll back the money movement, the approval, or the status
    -- change that this notification was describing.
    RAISE WARNING 'notify_user_once(%) failed and was swallowed: %',
      p_idem_key, SQLERRM;
    RETURN NULL;
END;
$$;
-- The call site itself stays server-only. A client that could call it
-- could notify any user id of its choosing.
REVOKE ALL ON FUNCTION public.notify_user_once(text, uuid, public.notification_type, text, text, jsonb)
  FROM public, anon, authenticated;


COMMENT ON FUNCTION public.notify_user_once(text, uuid, public.notification_type, text, text, jsonb) IS
  'The call site for notifications attached to money movement and approvals. '
  'Deduplicates on p_idem_key (advisory lock + existence check across BOTH '
  'notifications and notification_outbox, because notify_user routes to one or '
  'the other) so a retried call cannot send the same message twice, and '
  'swallows any error as a WARNING so a failed notice never rolls back the '
  'payment or approval it describes.';

-- revoke removed

-- The index used by the outbox half of that check. Without it the second
-- EXISTS is a sequential scan of a table that grows by one row per
-- client-initiated notification, forever.
CREATE INDEX IF NOT EXISTS idx_notification_outbox_idem_key
  ON public.notification_outbox ((data ->> 'idem_key'))
  WHERE (data ->> 'idem_key') IS NOT NULL;

-- ===========================================================================
-- Finding 2: restate the assertion so formatting cannot decide it
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_points_conversion_notifies()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  v_missing text := '';
  v_required text[] := ARRAY[
    'pg_advisory_xact_lock',
    'for update',
    'not_your_provider_profile',
    'points_subject_and_wallet_must_match',
    'points_to_birr_rate',
    'wallet_transactions',
    'points-convert:'
  ];
  v_clause text;
  -- Whitespace-insensitive: every whitespace run collapses to a single space
  -- on BOTH sides before matching. The previous version compared a hand-typed
  -- needle against normalised prosrc and so depended on where the author had
  -- wrapped the line.
  v_flat text;
BEGIN
  SELECT regexp_replace(lower(pg_proc.prosrc), '[[:space:]]+', ' ', 'g')
    INTO v_src
    FROM pg_proc JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
   WHERE pg_namespace.nspname = 'public'
     AND pg_proc.proname = 'convert_points_to_wallet';

  IF v_src IS NULL THEN
    RETURN 'FAIL: convert_points_to_wallet() does not exist';
  END IF;

  -- Strip spaces entirely as well, so a needle written without any whitespace
  -- around an operator still matches however the source is laid out.
  v_flat := replace(v_src, ' ', '');

  IF position('notify_user_once' IN v_src) = 0 THEN
    RETURN 'FAIL: convert_points_to_wallet() credits the wallet and notifies '
           || 'nobody; the points balance changes with no way for the user to '
           || 'find out';
  END IF;

  -- The key must be the ledger id, matched with all whitespace removed so the
  -- author's line breaks cannot make a correct key look wrong (or vice versa).
  IF position('points-convert:''||v_ledgerid' IN v_flat) = 0 THEN
    RETURN 'FAIL: the conversion notice is not keyed on the points ledger id, '
           || 'so a retry notifies twice and two identical conversions '
           || 'collide on one key';
  END IF;

  IF position('points_spent' IN v_src) = 0 THEN
    RETURN 'FAIL: the conversion notice does not report the points spent';
  END IF;

  IF position('birr_credited' IN v_src) = 0 THEN
    RETURN 'FAIL: the conversion notice does not report the birr received';
  END IF;

  FOREACH v_clause IN ARRAY v_required LOOP
    IF position(replace(v_clause, ' ', '') IN v_flat) = 0 THEN
      v_missing := v_missing || ' [' || v_clause || ']';
    END IF;
  END LOOP;

  IF v_missing <> '' THEN
    RETURN 'FAIL: convert_points_to_wallet() is missing' || v_missing
           || '. A money invariant was lost in the restatement; restore it '
           || 'from 20260927000059 before deploying.';
  END IF;

  RETURN 'ok: the conversion notifies with the points spent and the birr '
         || 'credited, keyed on the points ledger id; the advisory lock, the '
         || 'FOR UPDATE balance re-read, both ownership checks, the '
         || 'server-owned rate and the ADJUSTMENT ledger row are all present';
END;
$$;

-- ===========================================================================
-- Finding 3: restate the assertion against the real policy design
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_notification_inbox_is_owner_only()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rls boolean;
  v_bad_select text;
  v_bad_insert text;
  v_guard text;
  v_open_insert integer;
BEGIN
  SELECT relrowsecurity INTO v_rls
    FROM pg_class WHERE oid = 'public.notifications'::regclass;

  IF v_rls IS DISTINCT FROM true THEN
    RETURN 'FAIL: row level security is not enabled on notifications, so any '
           || 'signed-in user can read every notification in the system';
  END IF;

  -- Reading stays owner-scoped.
  SELECT string_agg(policyname, ', ' ORDER BY policyname) INTO v_bad_select
    FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'notifications'
     AND cmd = 'SELECT'
     AND lower(COALESCE(qual, '')) NOT LIKE '%auth.uid()%'
     AND lower(COALESCE(qual, '')) NOT LIKE '%is_admin()%';

  IF v_bad_select IS NOT NULL THEN
    RETURN 'FAIL: these SELECT policies on notifications are not scoped to '
           || 'their owner: ' || v_bad_select;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'notifications'
       AND cmd = 'SELECT'
  ) THEN
    RETURN 'FAIL: notifications has no SELECT policy, so a user cannot read '
           || 'their own notifications at all';
  END IF;

  -- Writing is NOT closed to clients in this schema, and that is deliberate:
  -- notifications_admin_all and notifications_staff_insert exist so the admin
  -- broadcast screen can write. The invariant is that every INSERT policy is
  -- gated on a role or permission check — an open WITH CHECK clause would let
  -- any signed-in user post notifications to anyone.
  SELECT string_agg(policyname, ', ' ORDER BY policyname) INTO v_bad_insert
    FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'notifications'
     AND cmd = 'INSERT'
     AND NOT (lower(COALESCE(with_check, '')) LIKE '%is_admin()%'
              OR lower(COALESCE(with_check, '')) LIKE '%staff_has_permission%');

  IF v_bad_insert IS NOT NULL THEN
    RETURN 'FAIL: these INSERT policies on notifications are not gated on '
           || 'is_admin() or a staff permission check, so any signed-in user '
           || 'can post a notification to any user id: ' || v_bad_insert;
  END IF;

  -- No open INSERT policy at all is equally wrong in the other direction:
  -- it would mean the admin broadcast screen cannot write.
  SELECT count(*) INTO v_open_insert
    FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'notifications'
     AND cmd = 'INSERT';

  IF v_open_insert = 0 THEN
    RETURN 'FAIL: notifications has no INSERT policy, so the admin broadcast '
           || 'screen cannot send a notification any more';
  END IF;

  -- The guard trigger is the layer that refuses an ordinary client regardless
  -- of RLS, and it must keep its two exemptions and its refusal.
  SELECT regexp_replace(lower(pg_proc.prosrc), '[[:space:]]+', ' ', 'g')
    INTO v_guard
    FROM pg_proc JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
   WHERE pg_namespace.nspname = 'public'
     AND pg_proc.proname = 'prevent_notification_injection';

  IF v_guard IS NULL THEN
    RETURN 'FAIL: prevent_notification_injection() is missing, so a client '
           || 'can insert its own notifications';
  END IF;

  IF position('is_server_write' IN v_guard) = 0
     OR position('is_admin' IN v_guard) = 0
     OR position('raise exception' IN v_guard) = 0
     OR position('notifications_cannot_be_created_by_clients' IN v_guard) = 0 THEN
    RETURN 'FAIL: prevent_notification_injection() has lost an exemption or '
           || 'its refusal, so the RLS policies above are the only control '
           || 'left on who may write a notification';
  END IF;

  -- The new call site stays server-only, and the dedupe must cover both
  -- delivery tables now that it has been proven to.
  IF has_function_privilege('anon',
       'public.notify_user_once(text, uuid, notification_type, text, text, jsonb)',
       'EXECUTE')
     OR has_function_privilege('authenticated',
       'public.notify_user_once(text, uuid, notification_type, text, text, jsonb)',
       'EXECUTE') THEN
    RETURN 'FAIL: a client role can EXECUTE notify_user_once(), so a user '
           || 'could send a notification to any other user id';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_proc
                  WHERE proname = 'notify_user_once') THEN
    RETURN 'FAIL: notify_user_once() does not exist';
  END IF;

  SELECT pg_proc.prosrc INTO v_guard
    FROM pg_proc JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
   WHERE pg_namespace.nspname = 'public'
     AND pg_proc.proname = 'notify_user_once';

  IF position('notification_outbox' IN v_guard) = 0 THEN
    RETURN 'FAIL: notify_user_once() does not check notification_outbox for an '
           || 'existing key. notify_user() queues client-path notifications '
           || 'there, so a dedupe that reads only notifications lets a retried '
           || 'payment queue the same message twice. This is the defect found '
           || 'by the first live run.';
  END IF;

  RETURN 'ok: RLS on; all '
         || (SELECT count(*) FROM pg_policies
              WHERE schemaname = 'public' AND tablename = 'notifications'
                AND cmd = 'SELECT')::text
         || ' SELECT policy/policies scoped to their owner; every INSERT '
         || 'policy gated on is_admin() or a staff permission check (so the '
         || 'admin broadcast screen still works and an ordinary user still '
         || 'cannot post); the injection guard intact; notify_user_once '
         || 'server-only and deduplicating across both delivery tables';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_points_conversion_notifies()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_points_conversion_notifies()
  TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.assert_notification_inbox_is_owner_only()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_notification_inbox_is_owner_only()
  TO anon, authenticated, service_role;

notify pgrst, 'reload schema';
