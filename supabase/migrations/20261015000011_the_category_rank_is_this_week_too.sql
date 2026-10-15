-- ===========================================================================
-- 1. The category rank is this week too.
--
-- 20261011000001 gave the PROVIDER rail the week it deserves: the first key
-- is completed work in the last 7 days and career totals are the second, so
-- the rail is about now rather than about the sum of all time. The CATEGORY
-- rank never got the same window. It still orders by
-- `completed_transactions DESC`, which for a marketplace is an ordering that
-- effectively never changes — the same few categories lead forever, and a
-- category that came alive this week is indistinguishable from one that
-- shipped nothing since the seed.
--
-- Same shape, same window, same stable tiebreak as ranked_providers: the two
-- rails must not disagree about what "this week" means, because a buyer who
-- sees the busiest trade on one rail expects the same answer on the other.
--
-- The signature and the RETURNS TABLE are byte-identical to the body this
-- replaces. Only the ORDER BY changes, so CREATE OR REPLACE applies it (a
-- changed return type would need a DROP, and would be caught by gate 8).
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.ranked_categories(
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  category_id uuid,
  name text,
  slug text,
  marketplace_sector text,
  provider_count bigint,
  completed_transactions bigint,
  rank_position bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_limit integer := GREATEST(COALESCE(p_limit, 50), 1);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
  -- The SAME week ranked_providers ranks by. One definition of "now" for both
  -- rails, written the same way, so a future change to one is visible in a
  -- diff of the other.
  v_window interval := interval '7 days';
BEGIN
  RETURN QUERY
  SELECT
    v.category_id,
    v.name,
    v.slug,
    v.marketplace_sector,
    v.provider_count,
    v.completed_transactions,
    v.rank_position
  FROM (
    SELECT
      c.id AS category_id,
      c.name,
      c.slug,
      c.marketplace_sector,
      COALESCE(pr.provider_count, 0)::bigint AS provider_count,
      (COALESCE(pr.txn_count, 0) + COALESCE(pd.sales, 0))::bigint
        AS completed_transactions,
      row_number() OVER (
        -- 1. this week's trade under the category (orders for its listings,
        --    and rides booked against it), 2. career totals, 3. a tiebreak the
        --    client cannot re-derive and must therefore keep stable.
        ORDER BY (
          (SELECT count(*)
             FROM public.order_items oi
             JOIN public.orders o ON o.id = oi.order_id
             JOIN public.products pr2 ON pr2.id = oi.product_id
            WHERE pr2.category_id = c.id
              AND o.status = 'COMPLETED'::order_status
              AND o.updated_at >= now() - v_window)
          +
          (SELECT count(*)
             FROM public.ride_requests r
            WHERE r.vehicle_category_id = c.id
              AND r.status = 'COMPLETED'::ride_status
              AND r.updated_at >= now() - v_window)
        ) DESC,
        (COALESCE(pr.txn_count, 0) + COALESCE(pd.sales, 0)) DESC,
        c.name ASC,
        c.id ASC
      ) AS rank_position
    FROM public.categories c
    LEFT JOIN (
      SELECT pp.category_id,
             count(*) AS provider_count,
             sum(s.completed_transactions) AS txn_count
      FROM public.provider_profiles pp
      JOIN public.provider_transaction_stats() s ON s.provider_id = pp.id
      WHERE pp.status = 'APPROVED'::account_status
        AND pp.category_id IS NOT NULL
      GROUP BY pp.category_id
    ) pr ON pr.category_id = c.id
    LEFT JOIN (
      SELECT p.category_id, sum(COALESCE(p.sales_count, 0)) AS sales
      FROM public.products p
      WHERE p.is_active
        AND p.category_id IS NOT NULL
      GROUP BY p.category_id
    ) pd ON pd.category_id = c.id
    WHERE c.is_active
  ) v
  ORDER BY v.rank_position
  LIMIT v_limit OFFSET v_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ranked_categories(integer, integer)
  TO anon, authenticated;

COMMENT ON FUNCTION public.ranked_categories(integer, integer) IS
  'Active categories from the most to the least transacted. Since '
  '20261015000011 the first key is completed work in the last 7 days (orders '
  'against its listings, plus rides booked against it) — the same window '
  'ranked_providers ranks by — and career totals are the second key, so the '
  'two rails agree about what "this week" means.';

-- ---------------------------------------------------------------------------
-- 2. An administrator can grow the category tree.
--
-- There was no way to add a category from inside the app. The table has a
-- `parent_id` and the schema has always had room for a tree, but the only
-- writes were migrations — so "we need a category for this trade" meant a
-- deploy, and the admin who was asked the question could not answer it.
--
-- It is an RPC rather than a client insert on purpose. The client write
-- allowlist (test/client_write_surface_test.dart) treats every table not on
-- it as server-only, and `categories` is not on it: a direct insert would
-- have failed that test, and would have put category shape in a Flutter
-- screen where nobody can see it. This is the same shape as every other
-- admin write in this repository — SECURITY DEFINER, a named permission
-- check inside, and the server, not the client, deciding what is legal.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_create_category(
  p_parent_id uuid,
  p_name text,
  p_description text DEFAULT NULL,
  p_icon text DEFAULT NULL
)
RETURNS public.categories
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_parent public.categories;
  v_name text := btrim(coalesce(p_name, ''));
  v_slug text;
  v_row public.categories;
BEGIN
  -- The permission check is the FIRST statement. A function that validated
  -- before it authenticated would leak "this slug is taken" to anyone who
  -- could call it.
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;

  IF v_name = '' THEN
    RAISE EXCEPTION 'CATEGORY_NAME_REQUIRED';
  END IF;

  IF p_parent_id IS NULL THEN
    RAISE EXCEPTION 'A_CATEGORY_IS_ADDED_UNDER_ITS_MOTHER_CATEGORY';
  END IF;

  SELECT * INTO v_parent
    FROM public.categories c
   WHERE c.id = p_parent_id;
  IF v_parent.id IS NULL THEN
    RAISE EXCEPTION 'MOTHER_CATEGORY_NOT_FOUND';
  END IF;

  -- A mother category is a TOP-LEVEL one. Without this the tree could grow
  -- three deep and every screen that loads `parent_id IS NULL` (the home
  -- groups, the provider's category picker, the fee editor) would silently
  -- stop showing anything past the second level.
  IF v_parent.parent_id IS NOT NULL THEN
    RAISE EXCEPTION 'PICK_A_TOP_LEVEL_CATEGORY_AS_THE_MOTHER';
  END IF;

  -- A category inherits its mother's classification. sector and
  -- marketplace_sector carry CHECK constraints and drive the fee model, the
  -- BUY/BOOK rule and the three big home cards, so an admin does not choose
  -- them again — they are what makes the new category part of its mother's
  -- trade rather than a fourth top-level group.
  v_slug := lower(regexp_replace(v_name, '[^a-zA-Z0-9]+', '-', 'g'));
  v_slug := trim(both '-' from v_slug);
  IF v_slug = '' THEN
    RAISE EXCEPTION 'CATEGORY_NAME_MUST_MAKE_A_URL_SLUG';
  END IF;
  IF EXISTS (SELECT 1 FROM public.categories x WHERE x.slug = v_slug) THEN
    RAISE EXCEPTION 'THAT_CATEGORY_ALREADY_EXISTS';
  END IF;

  INSERT INTO public.categories (
    parent_id, name, sector, marketplace_sector, slug, icon,
    description, is_active, sort_order, updated_at
  ) VALUES (
    v_parent.id, v_name, v_parent.sector, v_parent.marketplace_sector,
    v_slug, coalesce(p_icon, v_parent.icon),
    nullif(btrim(coalesce(p_description, '')), ''), true,
    coalesce(v_parent.sort_order, 0), now()
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

-- Only authenticated: every other caller is refused by the RLS policy anyway,
-- and the function refuses a non-admin before it does anything. `anon` does
-- NOT get it — an anonymous caller has no account to be an admin of.
REVOKE ALL ON FUNCTION public.admin_create_category(uuid, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_category(uuid, text, text, text)
  TO authenticated;

COMMENT ON FUNCTION public.admin_create_category(uuid, text, text, text) IS
  'An administrator adds a category under a top-level (mother) category. The '
  'new category inherits the mother''s sector and marketplace_sector, takes a '
  'slug made from its name, and is active immediately — the admin who asked '
  'for it can use it on the next screen.';

-- ---------------------------------------------------------------------------
-- 3. The test category, seeded and kept.
--
-- A category the admin can see working end to end: it appears in the tree
-- screens, in the provider's picker, in the fee editor and on the home rail,
-- with nothing else in the database to point at. It is deliberately created
-- under a real top-level category rather than as a fourth group, so it
-- exercises exactly the shape the RPC above creates — and it is KEPT: the
-- deploy is idempotent (slug conflict), and nothing later deletes it.
-- ---------------------------------------------------------------------------

INSERT INTO public.categories (
  parent_id, name, sector, marketplace_sector, slug, icon,
  description, is_active, sort_order, updated_at
)
SELECT m.id,
       'Test Category',
       m.sector,
       m.marketplace_sector,
       'test-category',
       m.icon,
       'A seeded category for verifying the category screens end to end.',
       true,
       coalesce(m.sort_order, 0),
       now()
  FROM public.categories m
 WHERE m.parent_id IS NULL
   AND m.is_active
 ORDER BY m.sort_order NULLS LAST, m.created_at ASC
 LIMIT 1
ON CONFLICT (slug) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. The deploy proves its own three claims.
--
-- A body that silently reverts to career totals still parses, still returns
-- rows and still looks ranked; an RPC that lost its permission check still
-- inserts. Neither failure is visible anywhere but in production, which is
-- why both are read back by name here instead of being trusted.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_category_tree_and_rank_are_wired()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rank text;
  v_create text;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_rank
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'ranked_categories';
  IF v_rank IS NULL OR v_rank NOT ILIKE '%interval ''7 days''%' THEN
    v_bad := v_bad || ARRAY[
      'ranked_categories no longer leads with the 7-day window, so the '
      'category rail ranks by career totals and never changes'];
  END IF;
  IF v_rank IS NULL OR v_rank NOT ILIKE '%o.updated_at >= now() - v_window%'
     OR v_rank NOT ILIKE '%r.updated_at >= now() - v_window%' THEN
    v_bad := v_bad || ARRAY[
      'ranked_categories reads no completion time, so its "this week" is a '
      'window over nothing'];
  END IF;

  SELECT prosrc INTO v_create
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'admin_create_category';
  IF v_create IS NULL OR v_create NOT ILIKE '%is_admin%' THEN
    v_bad := v_bad || ARRAY[
      'admin_create_category has no permission check, so any caller who '
      'can reach it can grow the category tree'];
  END IF;
  IF v_create IS NULL OR v_create NOT ILIKE '%v_parent.parent_id is not null%' THEN
    v_bad := v_bad || ARRAY[
      'admin_create_category accepts a mother category that is not top '
      'level, so a third level can appear where no screen shows it'];
  END IF;
  IF v_create IS NULL OR v_create NOT ILIKE '%v_parent.sector%' THEN
    v_bad := v_bad || ARRAY[
      'admin_create_category no longer inherits the mother category''s '
      'classification, so the new row fails its own CHECK constraint'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the category tree wiring is not in place: %',
      array_to_string(v_bad, '; ');
  END IF;
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_category_tree_and_rank_are_wired()
  TO anon, authenticated;

COMMENT ON FUNCTION public.assert_category_tree_and_rank_are_wired() IS
  'True when the category rail ranks by the last 7 days, when an '
  'administrator-only RPC adds a category under a top-level mother, and when '
  'that RPC hands the new category its mother''s classification.';

DO $$
BEGIN
  PERFORM public.assert_category_tree_and_rank_are_wired();
END;
$$;
