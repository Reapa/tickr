-- ============================================================================
-- Every world-readable catalog must be readable AS A CLIENT ROLE.
--
-- Regression: several catalogs shipped with a bare grant and no RLS policy.
-- That reads fine locally (RLS off = grant is enough) but comes back empty
-- through the hosted API, so Companies and Property listings were silently
-- empty for every live player. Asserting the grant is not enough — these
-- assertions run as `anon`, the way a real client does.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, game;

select pg_advisory_xact_lock(hashtext('game.market_tick'));

select plan(9);

-- Structural: no public catalog may sit without RLS and a policy again.
select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and not c.relrowsecurity
      and has_table_privilege('anon', c.oid, 'select')),
  0,
  'no anon-readable public table is left without row level security');

set local role anon;

select isnt((select count(*)::int from fish_species), 0,
  'anon can read the fish catalog');
select isnt((select count(*)::int from fishing_gear), 0,
  'anon can read the fishing gear catalog');
select isnt((select count(*)::int from slot_symbols), 0,
  'anon can read the slot payout table');
select isnt((select count(*)::int from company_industries), 0,
  'anon can read the company industries catalog');
select isnt((select count(*)::int from property_types), 0,
  'anon can read the property types catalog');
select isnt((select count(*)::int from asset_classes), 0,
  'anon can still read asset classes');
select isnt((select count(*)::int from cosmetics), 0,
  'anon can still read cosmetics');

reset role;

-- The generated listings are what a player actually shops from, and they are
-- refreshed by cron rather than seeded, so prove the read path works on them
-- with a row present.
insert into public.property_listings (name, type_id, value, rent_rate)
values ('Policy Test House',
        (select id from public.property_types limit 1), 100000, 5000);
set local role anon;
select isnt((select count(*)::int from property_listings), 0,
  'anon can read generated property listings');
reset role;

select * from finish();
rollback;
