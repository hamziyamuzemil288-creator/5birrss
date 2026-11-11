-- =============================================================================
-- 20261112000002 — photo-optional Fresh Finds and a full main-category rail
-- =============================================================================
--
-- THE REPORT
-- ----------
-- "Show products that have no photo too, using the existing placeholder image
-- on the card. Only keep the rules that hide non-public products. Make the
-- category chips show the full list of main product categories from the
-- database, always, even when a category has no products yet."
--
-- WHAT WAS TRUE BEFORE THIS FILE
-- ------------------------------
-- `home_product_feed()` and `home_product_categories()` both required a
-- `product_images` row. The dashboard therefore had two visible failures:
--
--   * a legitimate active listing without a photo never reached Fresh Finds;
--   * a category whose only listings had no photo disappeared from the chips.
--
-- The card already had a placeholder (`DashboardProductCard._ImageFallback`),
-- so the grid could render the listing honestly; the exclusion was the only
-- thing keeping it out.
--
-- WHAT THIS FILE CHANGES
-- ----------------------
--   1. home_product_feed(): removes ONLY the photo requirement. The public
--      rules stay exactly as they were — active, available, listing_status
--      ACTIVE, APPROVED and non-deleted provider, city, category subtree and
--      stable paging.
--   2. home_product_categories(): removes the photo requirement from the
--      public-product definition, and always includes every active TOP-LEVEL
--      category (the "main" categories), even when its count is zero.
--      Subcategories are still included when they have a public listing, so
--      existing leaf chips such as Electronics do not disappear. Other is
--      still sorted last.
--   3. The live assertion now proves the dashboard is photo-optional and that
--      the main-category rail is complete.
--
-- WHAT DOES NOT CHANGE
-- --------------------
-- `search_products()` and `visible_products_for_city()` keep their photo
-- requirement. This report is about the dashboard Fresh Finds grid; search
-- and the category directory are separate discovery surfaces and were not
-- asked to change. The provider's own page already shows photo-less listings
-- with the text-only card.
--
-- Deploy: this is a new database migration. Apply it after
-- 20261111000001_dashboard_product_feed.sql and
-- 20261111000002_notification_delivery_hardening.sql. No Edge Function change
-- is needed.
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The dashboard page: public listings, with or without a photo
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
     -- Fresh Finds is photo-optional. A product with no image is still a
     -- public listing; the card renders its existing placeholder. There is
     -- deliberately no image-table predicate in this function.
     --
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
  'listing_status ACTIVE, from an APPROVED provider that has not been '
  'deleted. Photos are optional; the card renders its placeholder. Optional '
  'category includes every descendant. Stable server-side paging ordered by '
  'sales_count then created_at then id.';

-- ---------------------------------------------------------------------------
-- 2. The chips: every main category, plus listed subcategories, Other last
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
       -- No image-table predicate: a listing without a photo still counts
       -- for its category and still appears in Fresh Finds.
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
       -- Every main category is always a chip, even when its count is zero.
       c.parent_id IS NULL
       -- A subcategory is a chip when it has something public to show.
       OR EXISTS (
         SELECT 1
           FROM public_products p
           JOIN ancestry a ON a.category_id = p.category_id
          WHERE a.ancestor_id = c.id
       )
       -- Other exists even before the first miscellaneous listing.
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
  'The dashboard category chips: every active top-level (main) category, '
  'every subcategory that has at least one public listing, and Other last. '
  'Photos are optional and product_count includes the category descendants. '
  'Names and order come from categories, never from a Dart constant.';

-- ---------------------------------------------------------------------------
-- 3. Grants stay public; this migration replaces functions, not permissions
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
-- 4. The live assertion
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

  -- The dashboard must NOT hide a listing just because it has no photo.
  IF position('product_images' IN v_src) > 0 THEN
    RETURN 'FAIL: home_product_feed() still filters photo-less listings';
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

  -- Every active main category must remain a chip even when it is empty.
  IF position('c.parent_id is null' IN v_cat) = 0 THEN
    RETURN 'FAIL: home_product_categories() does not return every main category';
  END IF;

  IF position('product_images' IN v_cat) > 0 THEN
    RETURN 'FAIL: home_product_categories() still counts only photo-backed listings';
  END IF;

  RETURN 'ok: public, provider-filtered, photo-optional, full-main-categories, paged and readable by anon';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_home_product_feed_is_public()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_home_product_feed_is_public()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
