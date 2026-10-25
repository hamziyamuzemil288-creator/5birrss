-- =============================================================================
-- 20261025000001 — the two notification classes that were still silent:
-- listings, and the account's own security
-- =============================================================================
--
-- THE AUDIT THIS ANSWERS (UPDATE 1, "automatic notifications")
-- ----------------------------------------------------------
-- The event list was checked against the triggers that actually exist, not
-- against what the brief asked for. Already wired, and therefore NOT touched
-- here: registration welcome (20260927000087), provider documents
-- (20260927000127), transactions and payment proofs (20260927000086,
-- 20260927000130), order and ride status transitions with the fare on both
-- sides (20260927000058, 20261006000005, 20260927000114), provider approvals
-- and suspensions (approve_provider / suspend_provider), wallet recharges,
-- availability request + response (20261006000006), appeals
-- (20260927000131) and points (20260927000089).
--
-- Two classes had NO writer at all:
--
--   1. LISTINGS. `products` has never had a notification trigger. A provider
--      publishing a listing got no receipt, and — the one that matters — an
--      administrator hiding a listing from Content Control (which sets
--      `is_active = false`, 20261006000010) told the business nothing at all.
--      Their product simply stopped selling.
--   2. SECURITY. The `SECURITY` enum value has existed since 0001 and was used
--      exactly once, for a suspected-fraud document. Nothing ever told a person
--      that somebody signed in to their account, or that the password changed —
--      the two events an account holder has to be able to react to.
--
-- WHY THE SECURITY NOTICES GO THROUGH A TABLE
-- -------------------------------------------
-- "New device" is not a fact the client may assert: a caller that could say
-- "this was a new device" could mail-bomb an account. `security_events` is the
-- server's memory of which device keys a user has been seen from, and the RPC
-- notifies only on the FIRST sighting. The client supplies a stable device key;
-- the decision is made here.
--
-- Templates live in this file (one block per event) with the same short, plain
-- English the rest of the notification code uses. There is no separate
-- translation catalog in this project yet, and inventing a second one for these
-- two messages would leave half the notifications in one system and half in
-- another; the strings are kept in one block so a future catalog can lift them
-- mechanically.
--
-- Deploy: needs a Supabase deploy (enum values, one table, four functions,
-- three triggers, one assertion).
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The notification types this adds
-- ---------------------------------------------------------------------------
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'LISTING_PUBLISHED';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'LISTING_HIDDEN';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'LISTING_REMOVED';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'ACCOUNT_DELETED';

-- ---------------------------------------------------------------------------
-- 2. Listing life cycle
--
--   Who is told: the provider who owns the listing (provider_profiles.user_id).
--   Who is NOT told: the person who did it. A provider hiding or deleting their
--   own listing does not need a message describing their own tap, so every
--   trigger below returns early when auth.uid() is the owner.
--
--   Every call goes through notify_user_once() with a key built from the
--   listing id and the event, so a retried transition (or a double tap that
--   reaches the same UPDATE twice) cannot produce a second row. That is the
--   same idempotency the order/ride triggers use.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.on_listing_published()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_owner uuid;
BEGIN
  SELECT pp.user_id INTO v_owner
    FROM public.provider_profiles pp
   WHERE pp.id = NEW.provider_id;

  IF v_owner IS NULL THEN
    RETURN NEW;
  END IF;

  -- The publisher's own confirmation. This one is FOR the actor, so there is
  -- no actor check.
  PERFORM public.notify_user_once(
    'listing-published:' || NEW.id::text,
    v_owner, 'LISTING_PUBLISHED',
    'Your listing is live',
    coalesce(NEW.name, 'Your listing') || ' is now visible to customers.',
    jsonb_build_object('product_id', NEW.id,
                       'provider_id', NEW.provider_id));

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.on_listing_published() IS
  'Confirms to the provider that a listing is public. Idempotent per listing.';

CREATE OR REPLACE FUNCTION public.on_listing_visibility_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_owner uuid;
BEGIN
  IF NEW.is_active IS NOT DISTINCT FROM OLD.is_active THEN
    RETURN NEW;
  END IF;

  SELECT pp.user_id INTO v_owner
    FROM public.provider_profiles pp
   WHERE pp.id = NEW.provider_id;

  IF v_owner IS NULL THEN
    RETURN NEW;
  END IF;

  -- Their own tap: no message, and no idem row either, so an administrator
  -- hiding the same listing later still produces one.
  IF auth.uid() IS NOT NULL AND auth.uid() = v_owner THEN
    RETURN NEW;
  END IF;

  IF NEW.is_active THEN
    PERFORM public.notify_user_once(
      'listing-restored:' || NEW.id::text || ':' || extract(epoch FROM now())::bigint::text,
      v_owner, 'LISTING_PUBLISHED',
      'Your listing is live again',
      coalesce(NEW.name, 'Your listing') || ' is visible to customers again.',
      jsonb_build_object('product_id', NEW.id,
                         'provider_id', NEW.provider_id));
  ELSE
    PERFORM public.notify_user_once(
      'listing-hidden:' || NEW.id::text,
      v_owner, 'LISTING_HIDDEN',
      'Your listing was hidden',
      coalesce(NEW.name, 'A listing')
        || ' was hidden by an administrator and is no longer visible to '
        || 'customers. Contact support if you think this is a mistake.',
      jsonb_build_object('product_id', NEW.id,
                         'provider_id', NEW.provider_id));
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.on_listing_visibility_changed() IS
  'Tells the owner when an administrator hides or restores a listing. Skips '
  'the action when the owner made the change themselves.';

CREATE OR REPLACE FUNCTION public.on_listing_deleted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_owner uuid;
BEGIN
  SELECT pp.user_id INTO v_owner
    FROM public.provider_profiles pp
   WHERE pp.id = OLD.provider_id;

  IF v_owner IS NULL THEN
    RETURN OLD;
  END IF;

  -- The provider deleting their own listing is the ordinary case (that is what
  -- provider_delete_product does when no order line references it). Only an
  -- administrator's removal is news to them.
  IF auth.uid() IS NOT NULL AND auth.uid() = v_owner THEN
    RETURN OLD;
  END IF;

  PERFORM public.notify_user_once(
    'listing-removed:' || OLD.id::text,
    v_owner, 'LISTING_REMOVED',
    'A listing was removed',
    coalesce(OLD.name, 'A listing')
      || ' was removed by an administrator.',
    jsonb_build_object('product_id', OLD.id,
                       'provider_id', OLD.provider_id));

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_listing_published ON public.products;
CREATE TRIGGER trg_listing_published
  AFTER INSERT ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.on_listing_published();

DROP TRIGGER IF EXISTS trg_listing_visibility_changed ON public.products;
CREATE TRIGGER trg_listing_visibility_changed
  AFTER UPDATE OF is_active ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.on_listing_visibility_changed();

DROP TRIGGER IF EXISTS trg_listing_deleted ON public.products;
CREATE TRIGGER trg_listing_deleted
  AFTER DELETE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.on_listing_deleted();

-- ---------------------------------------------------------------------------
-- 3. Security notices
--
--   `security_events` is deny-all like `login_attempts`: it is written only by
--   the SECURITY DEFINER function below, and a client that could write it could
--   suppress its own "new device" notice by pre-registering every device key.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.security_events (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event      text NOT NULL CHECK (event IN ('LOGIN', 'PASSWORD_CHANGED')),
  device_key text NOT NULL,
  label      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, event, device_key)
);

CREATE INDEX IF NOT EXISTS idx_security_events_user
  ON public.security_events (user_id, created_at DESC);

ALTER TABLE public.security_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.security_events FROM public, anon, authenticated;

-- The one client-reachable door. It can only ever act on auth.uid(), so it
-- cannot be used to notify anybody else, and it answers `true` only when this
-- was the first time the server saw that device key — a repeat call (every
-- login from the same phone) is silent.
CREATE OR REPLACE FUNCTION public.note_security_event(
  p_event text,
  p_device_key text,
  p_label text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_event text := upper(btrim(coalesce(p_event, '')));
  v_device text := btrim(coalesce(p_device_key, ''));
  v_wrote boolean := false;
  v_title text;
  v_body text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  IF v_event NOT IN ('LOGIN', 'PASSWORD_CHANGED') THEN
    RAISE EXCEPTION 'UNKNOWN_SECURITY_EVENT';
  END IF;

  -- A blank key would make every login look like the same device; refuse
  -- rather than silently never notifying.
  IF v_device = '' THEN
    RAISE EXCEPTION 'DEVICE_KEY_REQUIRED';
  END IF;

  INSERT INTO public.security_events (user_id, event, device_key, label)
  VALUES (v_user, v_event, v_device, nullif(btrim(coalesce(p_label, '')), ''))
  ON CONFLICT (user_id, event, device_key) DO NOTHING;

  GET DIAGNOSTICS v_wrote = ROW_COUNT;
  IF v_wrote = 0 THEN
    RETURN false;  -- this device was already known for this event
  END IF;

  IF v_event = 'LOGIN' THEN
    v_title := 'New sign-in to your account';
    v_body  := 'You signed in to Aliob on a new device. If this was not you, '
               'change your password now.';
  ELSE
    v_title := 'Your password was changed';
    v_body  := 'Your Aliob password was just changed. If this was not you, '
               'contact support immediately.';
  END IF;

  -- Idempotency is already guaranteed by the unique row above; the key is
  -- still passed so a manual re-run cannot duplicate the message.
  PERFORM public.notify_user_once(
    'security:' || lower(v_event) || ':' || v_device,
    v_user, 'SECURITY', v_title, v_body,
    jsonb_build_object('event', v_event, 'device', v_device));

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.note_security_event(text, text, text) IS
  'Records that the caller was seen from a device key and notifies them once, '
  'on the first sighting only. Never notifies anybody but auth.uid().';

REVOKE ALL ON FUNCTION public.note_security_event(text, text, text)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.note_security_event(text, text, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. An assertion the live suite can call, and a deploy-time one
--
-- The suite's helper calls these through `ok(...)`, which runs as anon, so the
-- grant is deliberate: the function reads the catalogue and returns a verdict,
-- it does not touch anybody's data.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_listing_and_security_notices_are_live()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_missing text := '';
BEGIN
  IF (SELECT count(*) FROM pg_enum e
       JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'notification_type'
        AND e.enumlabel IN ('LISTING_PUBLISHED', 'LISTING_HIDDEN',
                            'LISTING_REMOVED', 'ACCOUNT_DELETED')) <> 4 THEN
    v_missing := v_missing || ' notification_type values;';
  END IF;

  IF to_regclass('public.security_events') IS NULL THEN
    v_missing := v_missing || ' security_events;';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 'trg_listing_published' AND NOT tgisinternal)
     OR NOT EXISTS (SELECT 1 FROM pg_trigger
                     WHERE tgname = 'trg_listing_visibility_changed'
                       AND NOT tgisinternal)
     OR NOT EXISTS (SELECT 1 FROM pg_trigger
                     WHERE tgname = 'trg_listing_deleted' AND NOT tgisinternal)
  THEN
    v_missing := v_missing || ' listing triggers;';
  END IF;

  -- A client that could write security_events could pre-register every device
  -- key and suppress its own new-device notice.
  IF has_table_privilege('authenticated', 'public.security_events', 'INSERT')
     OR has_table_privilege('anon', 'public.security_events', 'INSERT') THEN
    v_missing := v_missing || ' security_events is client-writable;';
  END IF;

  -- The one door is callable by a signed-in person and by nobody else.
  IF NOT has_function_privilege(
      'authenticated',
      'public.note_security_event(text,text,text)', 'EXECUTE') THEN
    v_missing := v_missing || ' note_security_event is not callable;';
  END IF;
  IF has_function_privilege(
      'anon', 'public.note_security_event(text,text,text)', 'EXECUTE') THEN
    v_missing := v_missing || ' note_security_event is callable by anon;';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION
      'listing/security notices are not fully wired:%. The listing notices, '
      'the security notices or their guards are missing.', v_missing;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_listing_and_security_notices_are_live()
  FROM public;
GRANT EXECUTE ON FUNCTION public.assert_listing_and_security_notices_are_live()
  TO anon, authenticated;

-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_missing text := '';
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid
     WHERE t.typname = 'notification_type'
       AND e.enumlabel IN ('LISTING_PUBLISHED', 'LISTING_HIDDEN',
                           'LISTING_REMOVED', 'ACCOUNT_DELETED')
    GROUP BY t.typname
    HAVING count(*) = 4
  ) THEN
    v_missing := v_missing || ' notification_type values;';
  END IF;

  IF to_regclass('public.security_events') IS NULL THEN
    v_missing := v_missing || ' security_events;';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 'trg_listing_published'
                    AND NOT tgisinternal)
     OR NOT EXISTS (SELECT 1 FROM pg_trigger
                     WHERE tgname = 'trg_listing_visibility_changed'
                       AND NOT tgisinternal)
     OR NOT EXISTS (SELECT 1 FROM pg_trigger
                     WHERE tgname = 'trg_listing_deleted'
                       AND NOT tgisinternal) THEN
    v_missing := v_missing || ' listing triggers;';
  END IF;

  IF has_table_privilege('authenticated', 'public.security_events', 'INSERT')
     OR has_table_privilege('anon', 'public.security_events', 'INSERT') THEN
    v_missing := v_missing || ' security_events is client-writable;';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION '20261025000001 did not take: %', v_missing;
  END IF;
END;
$$;
