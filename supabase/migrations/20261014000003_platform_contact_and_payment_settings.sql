-- 20261014000003 — the platform's contact number and payment account, as data
-- =============================================================================
--
-- WHY
-- ---
-- Parts 3 and 4 of the rework: a buyer must never be pointed at a PROVIDER's
-- phone number or bank account. Every customer-facing contact point now
-- routes to the platform instead, so the number a buyer calls and the account
-- a buyer pays into are configuration an administrator edits, not values
-- baked into a screen.
--
-- The two keys already exist in system_settings (20261013000000 seeded them),
-- and admin_update_setting() is already the one client path that writes
-- system_settings (admin-gated, type-checked per key, audited). What was
-- missing is the READ side for ordinary buyers: system_settings is an
-- admin-scoped table (RLS), so a customer screen cannot SELECT it, and it
-- must not be opened up — it holds fee switches, rank rules and money
-- configuration.
--
-- WHAT IS ADDED
-- --------------
-- 1. public_app_settings() — a SECURITY DEFINER reader that returns exactly
--    TWO whitelisted keys and nothing else:
--        admin_contact_phone  — the support number shown to buyers
--        admin_payment_details — the platform's bank / mobile-money details
--    Granted to anon and authenticated: it is the same information any
--    buyer-facing "where do I pay / who do I call" card shows, and the
--    whitelist means a future settings key is never exposed by omission.
--
-- 2. The keys themselves, seeded idempotently (20261013000000 also seeds
--    them; a duplicate seed is a no-op). Both start EMPTY: an empty
--    admin_contact_phone makes the client card fall back to the in-app help
--    chat, and an empty admin_payment_details makes checkout fall back to
--    the platform's Payment Methods rows — never to a provider's account.
--
-- The client surfaces (Admin → Contact Settings / Payment Settings screens,
-- the buyer's "Contact Aliob Support" card, the checkout payment card) live
-- in lib/ in this same release.

SET search_path = public, pg_temp;

-- This file runs at migration time, where auth.uid() is NULL — the blanket
-- guard trigger raises SETTINGS_ARE_ADMIN_ONLY regardless of how privileged
-- the migration connection is (it killed 0113's seed before the lift pattern
-- existed). Lift it for the two seeds and put it straight back.
ALTER TABLE public.system_settings DISABLE TRIGGER trg_system_settings_security;

-- The seeded defaults are JSON STRINGS ('""'::jsonb). `system_settings.value`
-- is jsonb (0001_core_schema), so a bare '' is not valid JSON and the push
-- died with "invalid input syntax for type json (SQLSTATE 22P02)" before any
-- of this file applied. '""'::jsonb is what admin_update_setting() stores when
-- an administrator saves these two keys, so the default and an edited value
-- have the same shape.
INSERT INTO public.system_settings(key, value)
VALUES ('admin_contact_phone', '""'::jsonb)
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.system_settings(key, value)
VALUES ('admin_payment_details', '""'::jsonb)
ON CONFLICT (key) DO NOTHING;

ALTER TABLE public.system_settings ENABLE TRIGGER trg_system_settings_security;

-- (s.value #>> '{}') — NOT s.value. The column is jsonb and these values are
-- stored as JSON strings, so a jsonb -> text conversion hands the client the
-- quoted JSON form ('"+2519..."', '""') instead of the value itself, and the
-- empty default would stop looking empty. `#>> '{}'` extracts the scalar's
-- own text, which is what the buyer-facing card parses (`row['value']`).
CREATE OR REPLACE FUNCTION public.public_app_settings()
RETURNS TABLE (key text, value text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT s.key, (s.value #>> '{}')
    FROM public.system_settings s
   WHERE s.key IN ('admin_contact_phone', 'admin_payment_details');
$$;

REVOKE ALL ON FUNCTION public.public_app_settings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.public_app_settings()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.public_app_settings() IS
  'The only buyer-readable slice of system_settings: the platform contact '
  'number and the platform payment details an administrator configured. '
  'Whitelisted key by key so a new settings row is never exposed by omission.';
