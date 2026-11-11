-- =============================================================================
-- 20261111000001 — the dashboard product feed has ONE server-side definition
-- =============================================================================
--
-- THE REPORT
-- ----------
-- The product grid under "Top categories this week" is missing or incomplete.
-- The dashboard used to read `products` directly:
--
--   select * from products where is_active = true ... limit 20
--
-- That query has no category filter, no paging, and no provider predicate. It
-- can therefore return a hidden/suspended/deleted provider's listing (the RLS
-- policy only asks `is_active`), it stops at 20 rows, and it cannot answer
-- "show me Electronics" without loading everything. A photo-less listing
-- also reaches a card that has nowhere to draw it.
--
-- WHAT THIS FILE ADDS
-- -------------------
--   1. home_product_feed(): the ONE public discovery read for the dashboard.-- It filters is_active / is_available / listing_status ACTIVE, requires
--      the provider to be APPROVED and not deleted, requires a product image
--      (the marketplace's discovery rule), accepts a category plus all of its
--      descendants, is city-scoped, and pages with a stable
--      (sales_count, created_at, id) order.
--   2. home_product_categories(): the real categories that actually have a
--      public product, plus the Other category last, so the chips are data,
--      not a hard-coded list in Dart.
--   3. The indexes both reads need.
--   4. An assertion the live connectivity suite can call.
--
-- SECURITY: both functions are SECURITY DEFINER because they join
-- provider_profiles, which anon cannot read (20261021000000). They are granted
-- to anon on purpose: a guest is the default buyer. The provider predicate is
-- explicit in the function, so bypassing RLS here does not widen what a guest
-- can see — it narrows it to live public listings.
--
-- Deploy: needs a Supabase deploy (two functions, four indexes, one assertion).
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The page a dashboard shows
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.home_product_feed(
  p_category_id uuid DEFAULT NULL,
  p_limit int DEFAULT 24,
  p_offset int DEFAULT 0,
  p_city text DEFAULT NULL
)
RETURNS SETOF public.products
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH RECURSIVE subtree AS (
    SELECT c.id
      FROM public.categories c
     WHERE p_category_id IS NOT NULL
       AND c.id = p_category_id
    UNION ALL
    SELECT child.id
      FROM public.categories child
      JOIN subtree parent ON child.parent_id = parent.id
  )
  SELECT p.*
    FROM public.products p
    JOIN public.provider_profiles pp ON pp.id = p.provider_id
   WHERE p.is_active = true
     AND p.is_available = true
     AND p.listing_status = 'ACTIVE'
     AND pp.status = 'APPROVED'
     AND pp.deleted_at IS NULL
     -- A product with no photo has nowhere to render in a grid. It remains
     -- readable on its provider's own page, where ProductCard draws the
     -- text-only form; it simply never enters discovery.
     AND EXISTS (
       SELECT 1
         FROM public.product_images pi
        WHERE pi.product_id = p.id
     )
     -- Empty/NULL city means "All cities" (the city switcher's option), not
     -- "a city literally named ''".
     AND (
       coalesce(btrim(p_city), '') = ''
       OR p.city IS NULL
       OR p.city = p_city
     )
     AND (
       p_category_id IS NULL
       OR p.category_id IN (SELECT id FROM subtree)
     )
   ORDER BY p.sales_count DESC NULLS LAST,
            p.created_at DESC,
            p.id
   LIMIT greatest(1, least(coalesce(p_limit, 24), 60))
  OFFSET greatest(coalesce(p_offset, 0), 0);
$$;

COMMENT ON FUNCTION public.home_product_feed(uuid, int, int, text) IS
  'The dashboard product grid. Public listings only: active, available, '
  'listing_status ACTIVE, with an image, from an APPROVED provider that has '
  'not been deleted. Optional category includes every descendant. Stable '
  'server-side paging ordered by sales_count then created_at then id.';

-- ---------------------------------------------------------------------------
-- 2. The chips above it: categories that actually have something to show
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.home_product_categories(
  p_city text DEFAULT NULL
)
RETURNS TABLE (
  category_id uuid,
  name text,
  parent_id uuid,
  parent_name text,
  sort_order int,
  parent_sort_order int,
  product_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  -- Every category paired with every ancestor above it. A chip for a parent
  -- must count and later show the products filed in its sub-categories; a
  -- leaf is still its own chip. Without this a marketplace that files each
  -- listing under a leaf would show no parent chip at all, and "Electronics"
  -- would silently mean only the products nobody filed in a sub-category.
  WITH RECURSIVE ancestry AS (
    SELECT c.id AS category_id, c.id AS ancestor_id
      FROM public.categories c
    UNION ALL
    SELECT a.category_id, parent.parent_id
      FROM ancestry a
      JOIN public.categories parent ON parent.id = a.ancestor_id
     WHERE parent.parent_id IS NOT NULL
  ),
  public_products AS (
    SELECT p.id, p.category_id
      FROM public.products p
      JOIN public.provider_profiles pp ON pp.id = p.provider_id
     WHERE p.is_active = true
       AND p.is_available = true
       AND p.listing_status = 'ACTIVE'
       AND pp.status = 'APPROVED'
       AND pp.deleted_at IS NULL
       AND (
         coalesce(btrim(p_city), '') = ''
         OR p.city IS NULL
         OR p.city = p_city
       )
       AND EXISTS (
         SELECT 1 FROM public.product_images pi WHERE pi.product_id = p.id
       )
  )
  SELECT c.id,
         c.name,
         c.parent_id,
         parent.name,
         coalesce(c.sort_order, 0),
         coalesce(parent.sort_order, 0),
         (
           SELECT count(DISTINCT p.id)
             FROM public_products p
             JOIN ancestry a ON a.category_id = p.category_id
            WHERE a.ancestor_id = c.id
         ) AS product_count
    FROM public.categories c
    LEFT JOIN public.categories parent ON parent.id = c.parent_id
   WHERE c.is_active = true
     AND (
       EXISTS (
         SELECT 1
           FROM public_products p
           JOIN ancestry a ON a.category_id = p.category_id
          WHERE a.ancestor_id = c.id
       )
       OR lower(btrim(c.name)) IN ('other', 'other services')
     )
   -- Other is last even when a marketplace names it "Other Services".
   ORDER BY CASE WHEN lower(btrim(c.name)) IN ('other', 'other services')
                 THEN 1 ELSE 0 END,
            coalesce(parent.sort_order, c.sort_order),
            c.parent_id NULLS FIRST,
            coalesce(c.sort_order, 0),
            c.name;
$$;

COMMENT ON FUNCTION public.home_product_categories(text) IS
  'The real category chips for the dashboard: categories that have at least '
  'one public product in the selected city, plus the Other category (last). '
  'Names and order come from categories, never from a Dart constant.';

-- ---------------------------------------------------------------------------
-- 3. The indexes the two reads depend on
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_products_home_feed
  ON public.products (category_id, sales_count DESC NULLS LAST, created_at DESC)
  WHERE is_active = true
    AND is_available = true
    AND listing_status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_products_home_feed_recent
  ON public.products (created_at DESC, sales_count DESC NULLS LAST)
  WHERE is_active = true
    AND is_available = true
    AND listing_status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_product_images_feed_cover
  ON public.product_images (product_id, sort_order);

CREATE INDEX IF NOT EXISTS idx_provider_profiles_public_feed
  ON public.provider_profiles (status, deleted_at)
  WHERE status = 'APPROVED' AND deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- 4. Grants: the feed is public; the admin/provider writes are untouched
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.home_product_feed(uuid, int, int, text)
  FROM public;
REVOKE ALL ON FUNCTION public.home_product_categories(text)
  FROM public;

GRANT EXECUTE ON FUNCTION public.home_product_feed(uuid, int, int, text)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.home_product_categories(text)
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. The live assertion
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_home_product_feed_is_public()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  v_cat text;
BEGIN
  SELECT lower(regexp_replace(p.prosrc, E'\\s+', ' ', 'g'))
    INTO v_src
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'home_product_feed';

  IF v_src IS NULL THEN
    RETURN 'FAIL: home_product_feed() is missing';
  END IF;

  IF position('provider_profiles' IN v_src) = 0
     OR position('approved' IN v_src) = 0
     OR position('deleted_at is null' IN v_src) = 0 THEN
    RETURN 'FAIL: home_product_feed() does not filter to live providers';
  END IF;

  IF position('is_active = true' IN v_src) = 0
     OR position('is_available = true' IN v_src) = 0
     OR position('listing_status = ''active''' IN v_src) = 0 THEN
    RETURN 'FAIL: home_product_feed() can return a hidden or unavailable listing';
  END IF;

  IF position('product_images' IN v_src) = 0 THEN
    RETURN 'FAIL: home_product_feed() can return a photo-less listing';
  END IF;

  IF position('p_limit' IN v_src) = 0 OR position('p_offset' IN v_src) = 0 THEN
    RETURN 'FAIL: home_product_feed() has no server-side paging';
  END IF;

  IF position('parent_id = parent.id' IN v_src) = 0
     AND position('child.parent_id' IN v_src) = 0 THEN
    RETURN 'FAIL: home_product_feed() does not include sub-categories';
  END IF;

  IF NOT has_function_privilege(
       'anon', 'public.home_product_feed(uuid, integer, integer, text)',
       'EXECUTE') THEN
    RETURN 'FAIL: anon cannot execute home_product_feed(), so a guest sees no grid';
  END IF;

  SELECT lower(regexp_replace(p.prosrc, E'\\s+', ' ', 'g'))
    INTO v_cat
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'home_product_categories';

  IF v_cat IS NULL
     OR position('other' IN v_cat) = 0
     OR position('parent_id' IN v_cat) = 0 THEN
    RETURN 'FAIL: home_product_categories() does not come from the category tree or keep Other';
  END IF;

  RETURN 'ok: public, provider-filtered, imaged, category-aware, paged and readable by anon';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_home_product_feed_is_public()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_home_product_feed_is_public()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
