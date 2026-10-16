-- 20261016000002 — the posting-gate assertion joins the namespace it reads

-- CONTEXT
-- -------
-- 20261016000001 replaced `assert_posting_requires_payment_account` with
-- `assert_posting_gate_is_document_and_wallet_not_payment_account`, and the
-- second of its three reads into pg_proc was written
--
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.proname
--
-- `pg_namespace.oid` is an oid and `pg_proc.proname` is a name, and Postgres
-- has no `oid = name` operator, so that statement raises SQLSTATE 42883 the
-- moment the function is called:
--
--     operator does not exist: oid = name
--     hint: No operator matches the given name and argument types.
--
-- The migration itself applied cleanly — a plpgsql body is not analysed at
-- CREATE FUNCTION time, only when the statement first runs — so nothing in the
-- deploy log, and nothing in the file-level harness (whole-file parse, body
-- syntax, column scope), can see it. What saw it was the live connectivity
-- suite: both posting-gate tests call this assertion, both got 42883, and the
-- report the assertion exists to make never ran at all. An assertion that
-- raises is worse than an assertion that fails: it cannot say WHICH half of
-- the gate came unstuck, which is the only reason it exists.
--
-- WHAT THIS MIGRATION DOES
-- ------------------------
-- Re-issues the same body with the join repaired: `n.oid = p.pronamespace`,
-- the form every other read in this repository already uses. Nothing else
-- changes — same signature, same SEARCH PATH, same clauses, same wording, so
-- the repair cannot smuggle a rule change in with it. Registered in
-- tools/harness/restated_body_diff.py as a FIX case, which is what pins "only
-- the broken line differs" and stops the bad join from coming back.
--
-- The historical file is left exactly as it was applied. Editing an applied
-- migration would not re-run it (the version is already recorded in
-- supabase_migrations.schema_migrations), so the live database would keep the
-- broken body while the repository claimed otherwise.

CREATE OR REPLACE FUNCTION public.assert_posting_gate_is_document_and_wallet_not_payment_account()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_create text;
  v_search text;
  v_policy text;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_create
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_provider_product';
  IF v_create IS NULL THEN
    v_bad := v_bad || ARRAY[
      'create_provider_product does not exist'];
  ELSE
    -- The live function must have dropped the account branch.
    IF v_create ILIKE '%NO_PAYMENT_ACCOUNT%' THEN
      v_bad := v_bad || ARRAY[
        'create_provider_product still refuses without a payment account — the app '
        'no longer lets a provider publish an account number, so that refusal now blocks '
        'every posting on the platform'];
    END IF;
  END IF;

  SELECT prosrc INTO v_search
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'search_products';
  IF v_search IS NULL THEN
    v_bad := v_bad || ARRAY[
      'search_products does not exist'];
  ELSE
    -- Search must have dropped the account predicate too.
    IF v_search ILIKE '%provider_payment_methods%' THEN
      v_bad := v_bad || ARRAY[
        'search_products still hides providers without a payment account — every '
        'listing would disappear from search'];
    END IF;
  END IF;

  SELECT coalesce(p.qual, '') INTO v_policy
    FROM pg_policies p
   WHERE p.schemaname = 'public' AND p.tablename = 'products'
     AND p.policyname = 'products_public_read';
  IF v_policy NOT ILIKE '%is_active = true%' THEN
    v_bad := v_bad || ARRAY[
      'products_public_read no longer shows active listings'];
  END IF;
  IF v_policy ILIKE '%provider_payment_methods%' THEN
    v_bad := v_bad || ARRAY[
      'products_public_read still hides providers without a payment account — direct '
      'buyer reads would hide every listing'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the payment-account posting gate was not fully removed: %',
      array_to_string(v_bad, '; ');
  END IF;

  -- The surviving gate must still exist server-side.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'provider_fulfilment_blockers'
  ) THEN
    v_bad := v_bad || ARRAY[
      'provider_fulfilment_blockers() is missing — the server posting gate no longer exists'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the posting gate is broken: %',
      array_to_string(v_bad, '; ');
  END IF;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_posting_gate_is_document_and_wallet_not_payment_account()
  TO anon, authenticated;

COMMENT ON FUNCTION public.assert_posting_gate_is_document_and_wallet_not_payment_account IS
  'True when the payment-account posting gate is gone from create_provider_product, '
  'search_products and products_public_read, and the surviving server gate '
  '(provider_fulfilment_blockers) still exists. Repaired by 20261016000002: the '
  'search_products read joined pg_namespace on pg_proc.proname, which raised 42883 '
  'on every call.';

NOTIFY pgrst, 'reload schema';
