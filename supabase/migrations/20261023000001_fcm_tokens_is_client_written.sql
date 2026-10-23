-- =============================================================================
-- 20261023000001 — fcm_tokens joins the expected client write surface
--
-- WHY: the push client (commit "client FCM foundation", lib/core/services/
-- notification_service.dart) registers this device's FCM token by upserting
-- into `fcm_tokens` after sign-in and deleting the row on sign-out. The table
-- has been client-writable since 0007 (`fcm_tokens_owner_all`: FOR ALL with
-- user_id = auth.uid() / WITH CHECK user_id = auth.uid()), and no migration
-- has ever revoked its write privileges — so the writes succeed at runtime.
-- What was missing is the DECLARATION: the comment in 20261015000001 saying
-- "nothing in lib/ writes fcm_tokens" was true when written and became false
-- with the push client, and the expected list inside
-- client_write_surface_report() — the server half of the client-write contract
-- pinned by test/client_write_surface_report.dart — still omitted it, so the
-- report would classify the app's own token registration as an unexpected
-- writable table.
--
-- This restates the function from 20261007000015 (the current definition) with
-- exactly one value added: ('fcm_tokens'). The Dart allowlist pin moves
-- 24 -> 25 in the same change, and so does the live connectivity pin
-- (tools/integration_test/connectivity_test.dart), matching how banks
-- (20261007000013) and product_likes (20260927000070) were added.
--
-- NEEDS A SUPABASE DEPLOY to take effect live; until then the live function
-- keeps the 24-entry list and the connectivity pin (25) fails only after the
-- deploy applies this file — the same ordering every previous addition had.
-- =============================================================================

create or replace function public.client_write_surface_report()
returns table (
  kind text,
  tables text[]
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with expected(t) as (
    values
      ('admin_expenses'), ('admin_notification_broadcasts'), ('appeal_cases'),
      ('banks'), ('cart_items'), ('chat_logs'), ('client_error_logs'),
      ('product_likes'), ('favorites'), ('fcm_tokens'), ('notifications'),
      ('order_messages'), ('payment_methods'), ('payment_proofs'),
      ('product_images'), ('products'), ('profiles'),
      ('provider_payment_methods'), ('provider_profiles'), ('reviews'),
      ('ride_ratings'), ('support_tickets'), ('user_documents'), ('vehicles'),
      ('wallet_recharge_requests')
  ),
  public_tables as (
    select t.table_name
    from information_schema.tables t
    where t.table_schema = 'public'
      and t.table_type = 'BASE TABLE'
  ),
  writable as (
    select pt.table_name
    from public_tables pt
    where has_table_privilege('authenticated', pt.table_name, 'INSERT')
      and exists (
        select 1 from pg_policies p
        where p.schemaname = 'public'
          and p.tablename = pt.table_name
          and p.cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      )
  ),
  unguarded as (
    select w.table_name
    from writable w
    where not exists (
      select 1 from pg_policies p
      where p.schemaname = 'public'
        and p.tablename = w.table_name
        and p.cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        and lower(regexp_replace(replace(coalesce(p.qual, ''), 'public.', ''), '\s+', '', 'g'))
            ~ '(is_admin|is_ceo|is_super_admin)\(\)'
    )
  )
  select 'expected', coalesce(array_agg(t order by t), '{}') from expected
  union all
  select 'unexpected', coalesce(array_agg(w.table_name order by w.table_name), '{}')
    from writable w
    where not exists (select 1 from expected e where e.t = w.table_name)
  union all
  select 'unguarded', coalesce(array_agg(table_name order by table_name), '{}')
    from unguarded;
$$;

comment on function public.client_write_surface_report() is
  'Compares the tables the app is expected to write against the ones it can. '
  'client_error_logs, product_likes and provider_payment_methods are expected: '
  'an app that is failing must be able to record why, a like is written '
  'directly under RLS by design, and a provider manages their own payment '
  'methods from their dashboard. banks is expected because the admin writes '
  'bank account numbers for payment processing. fcm_tokens is expected because '
  'the signed-in client registers and removes its own device push token there '
  '(owner-scoped by fcm_tokens_owner_all since 0007).';

grant execute on function public.client_write_surface_report() to anon, authenticated;

notify pgrst, 'reload schema';
