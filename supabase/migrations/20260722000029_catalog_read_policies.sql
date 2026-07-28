-- ============================================================================
-- World-readable catalogs need an RLS POLICY, not just a grant
--
-- Found while verifying the arcade deploy: `fish_species`, `fishing_gear` and
-- `slot_symbols` returned [] from the hosted REST API even though the rows were
-- plainly there (get_slot_odds, a SECURITY DEFINER function, returned all seven
-- symbols). Checking the older tables turned up the same thing, and worse:
--
--     property_types      []   <- broken in production since migration 24
--     property_listings   []   <- broken in production since migration 24
--     company_industries  []   <- broken in production since migration 21
--     company_listings    []   <- broken in production since migration 21
--     cosmetics           [rows]
--     asset_classes       [rows]
--
-- The tables that work were all set up in migration 20260721000006 with RLS
-- ENABLED plus a permissive `using (true)` select policy. The broken ones were
-- given a bare `grant select ... to anon, authenticated` and no RLS. That is
-- enough locally — a table with RLS off is readable by anyone holding the grant
-- — but NOT on the hosted project, where reads through PostgREST come back
-- empty. So the Companies "Acquire" list and the Property listings have been
-- silently empty for every live player since they shipped, which is very likely
-- what was behind the earlier "companies not visible" report.
--
-- Fix: follow the established pattern from migration 6 for every public catalog
-- — enable RLS explicitly and attach a read-everyone policy. Idempotent, and it
-- does not affect the RPCs (SECURITY DEFINER runs as owner and bypasses RLS).
--
-- RULE FOR NEW TABLES: a world-readable catalog gets `enable row level
-- security` + a `for select using (true)` policy. A grant on its own is not a
-- read path in production.
-- ============================================================================

do $$
declare
  t text;
begin
  foreach t in array array[
    'company_industries', 'company_name_pool', 'company_listings',
    'company_decision_templates',
    'property_types', 'property_name_pool', 'property_listings',
    'fish_species', 'fishing_gear', 'slot_symbols'
  ]
  loop
    if to_regclass('public.' || t) is null then
      continue;
    end if;

    execute format('alter table public.%I enable row level security', t);

    if not exists (
      select 1 from pg_policies
       where schemaname = 'public' and tablename = t
         and policyname = t || ' readable'
    ) then
      execute format(
        'create policy %I on public.%I for select using (true)',
        t || ' readable', t);
    end if;

    execute format(
      'grant select on public.%I to anon, authenticated', t);
  end loop;
end $$;
